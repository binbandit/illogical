package mux

import (
	"errors"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type ServerOption func(*Server) error

// Server owns the workspace (sessions, tabs, split layouts), every terminal
// block and its child process, and the connected clients.
//
// Lock order: s.mu, then Block.mu, then s.clientsMu, then client.mu. Terminal
// work on one block holds only that block's lock so other panes stay live.
type Server struct {
	directory   string
	socket      string
	loginHelper string
	startedAt   time.Time
	listener    net.Listener
	lock        *os.File

	mu       sync.Mutex
	sessions []*Session
	blocks   map[string]*Block
	revision uint64
	remotes  map[string]*remoteListener

	clientsMu sync.RWMutex
	clients   map[string]*client

	changes        chan struct{} // Workspace state should be published.
	persistPending atomic.Bool   // ...and saved to disk.
	parkChanges    chan struct{}
	finished       chan string // Blocks whose child exited and should close.
	stop           chan struct{}
	stopOnce       sync.Once
	background     sync.WaitGroup
}

func NewServer(directory, socket string, options ...ServerOption) (*Server, error) {
	if len(socket) > 100 {
		return nil, errors.New("socket path exceeds the macOS Unix socket limit; set ILLOGICAL_SOCKET to a shorter private path")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(directory, 0700); err != nil {
		return nil, err
	}
	// The lock, not the socket, decides which service owns this directory. It
	// dies with its process, so a crash never leaves a stale lock behind.
	lock, err := os.OpenFile(filepath.Join(directory, "daemon.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, errors.New("illogical service is already running")
	}
	_ = os.Remove(socket) // Left behind by a service that crashed.
	listener, err := net.Listen("unix", socket)
	if err != nil {
		lock.Close()
		return nil, err
	}
	if err = os.Chmod(socket, 0600); err != nil {
		listener.Close()
		lock.Close()
		return nil, err
	}
	s := &Server{
		directory:   directory,
		socket:      socket,
		startedAt:   time.Now(),
		listener:    listener,
		lock:        lock,
		sessions:    []*Session{},
		blocks:      map[string]*Block{},
		remotes:     map[string]*remoteListener{},
		clients:     map[string]*client{},
		changes:     make(chan struct{}, 1),
		parkChanges: make(chan struct{}, 1),
		finished:    make(chan string, 1024),
		stop:        make(chan struct{}),
	}
	for _, option := range options {
		if err = option(s); err != nil {
			listener.Close()
			lock.Close()
			return nil, err
		}
	}
	if err = s.restore(); err != nil {
		log.Printf("restore: %v", err)
	}
	return s, nil
}

func (s *Server) Run() error {
	s.background.Add(1)
	go func() { defer s.background.Done(); s.maintenance() }()
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.stop:
				return nil
			default:
				return err
			}
		}
		go s.serve(conn)
	}
}

// Close saves the workspace and hangs up every terminal. Shells do not survive
// the service; the next service restores the layout with fresh shells.
func (s *Server) Close() {
	s.stopOnce.Do(func() {
		close(s.stop)
		s.listener.Close()
		s.background.Wait()
		s.mu.Lock()
		for _, remote := range s.remotes {
			_ = remote.listener.Close()
		}
		state := s.stateLocked()
		blocks := make([]*Block, 0, len(s.blocks))
		for _, b := range s.blocks {
			b.close()
			blocks = append(blocks, b)
		}
		s.mu.Unlock()
		if err := s.persist(state); err != nil {
			log.Printf("persist: %v", err)
		}
		s.clientsMu.Lock()
		for _, c := range s.clients {
			c.close("service_shutdown")
		}
		s.clientsMu.Unlock()
		// Nothing outlives the service to reap a shell that ignores SIGHUP.
		deadline := time.Now().Add(hangupGracePeriod)
		for _, b := range blocks {
			select {
			case <-b.exited:
			case <-time.After(time.Until(deadline)):
				_ = syscall.Kill(-b.cmd.Process.Pid, syscall.SIGKILL)
			}
		}
		_ = os.Remove(s.socket)
		_ = s.lock.Close()
	})
}

// changed schedules publishing and saving the workspace.
func (s *Server) changed() {
	s.persistPending.Store(true)
	s.stateChanged()
}

// stateChanged schedules publishing transient state such as client counts.
func (s *Server) stateChanged() {
	select {
	case s.changes <- struct{}{}:
	default:
	}
}

func (s *Server) parkingChanged() {
	select {
	case s.parkChanges <- struct{}{}:
	default:
	}
}

func (s *Server) blockList() []*Block {
	s.mu.Lock()
	defer s.mu.Unlock()
	blocks := make([]*Block, 0, len(s.blocks))
	for _, b := range s.blocks {
		blocks = append(blocks, b)
	}
	return blocks
}

// maintenance is the service's only timer-driven work. A quiet service holds
// no armed timers: state is flushed only after a change and parking is armed
// only while an emulator is resident.
func (s *Server) maintenance() {
	flush := time.NewTimer(time.Hour)
	flush.Stop()
	defer flush.Stop()
	park := time.NewTimer(time.Hour)
	park.Stop()
	defer park.Stop()
	var flushC, parkC <-chan time.Time
	armPark := func() {
		park.Stop()
		parkC = nil
		if next := s.nextParkDeadline(); !next.IsZero() {
			park.Reset(max(time.Until(next), time.Millisecond))
			parkC = park.C
		}
	}
	for {
		select {
		case <-s.changes:
			// One bounded coalescing window; later changes do not extend it.
			if flushC == nil {
				flush.Reset(100 * time.Millisecond)
				flushC = flush.C
			}
		case <-flushC:
			flushC = nil
			s.flush()
		case id := <-s.finished:
			s.mu.Lock()
			if s.blocks[id] != nil {
				s.removeBlockLocked(id)
			}
			s.mu.Unlock()
			s.changed()
		case <-s.parkChanges:
			armPark()
		case <-parkC:
			parkC = nil
			for _, b := range s.blockList() {
				if err := b.park(false); err != nil {
					log.Printf("park %s: %v", b.info.ID, err)
				}
			}
			armPark()
		case <-s.stop:
			return
		}
	}
}

// flush publishes the workspace and saves it if anything durable changed.
func (s *Server) flush() {
	// Swap first: a change racing with this flush sets it again for the next.
	durable := s.persistPending.Swap(false)
	s.mu.Lock()
	s.revision++
	state := s.stateLocked()
	s.mu.Unlock()
	if durable {
		if err := s.persist(state); err != nil {
			log.Printf("persist: %v", err)
		}
	}
	s.broadcastState(Message{Type: "state", State: &state})
}

func (s *Server) nextParkDeadline() time.Time {
	var next time.Time
	for _, b := range s.blockList() {
		b.mu.Lock()
		if deadline, ok := b.parkDeadline(); ok && (next.IsZero() || deadline.Before(next)) {
			next = deadline
		}
		b.mu.Unlock()
	}
	return next
}
