package mux

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	vt "go.mitchellh.com/libghostty"
)

type ServerOption func(*Server) error

type Server struct {
	loginHelper    string
	mu             sync.Mutex
	sessions       []*Session
	blocks         map[string]*Block
	revision       uint64
	clientsMu      sync.RWMutex
	clients        map[string]*client
	changes        chan struct{}
	parkChanges    chan struct{}
	persistPending atomic.Bool
	finished       chan string
	directory      string
	socket         string
	listener       net.Listener
	lock           *os.File
	stop           chan struct{}
	stopOnce       sync.Once
	remotes        map[string]*remoteListener
	startedAt      time.Time
}

type client struct {
	id            string
	label         string
	kind          string
	connectedAt   time.Time
	focusBlock    string
	conn          net.Conn
	mu            sync.Mutex
	subscriptions map[string]string
	watching      bool
	viewportSync  map[string]bool
	out           *messageQueue
	done          chan struct{}
	once          sync.Once
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
	lock, err := os.OpenFile(filepath.Join(directory, "daemon.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, errors.New("illogical service is already running")
	}
	_ = os.Remove(socket)
	l, err := net.Listen("unix", socket)
	if err != nil {
		lock.Close()
		return nil, err
	}
	if err = os.Chmod(socket, 0600); err != nil {
		l.Close()
		lock.Close()
		return nil, err
	}
	s := &Server{sessions: []*Session{}, blocks: map[string]*Block{}, clients: map[string]*client{}, changes: make(chan struct{}, 1), parkChanges: make(chan struct{}, 1), finished: make(chan string, 1024), directory: directory, socket: socket, listener: l, lock: lock, stop: make(chan struct{})}
	s.startedAt = time.Now()
	s.remotes = make(map[string]*remoteListener)
	for _, option := range options {
		if err = option(s); err != nil {
			l.Close()
			lock.Close()
			os.Remove(socket)
			return nil, err
		}
	}
	if err = s.restore(); err != nil {
		log.Printf("restore: %v", err)
	}
	return s, nil
}

func (s *Server) Run() error {
	go s.maintenance()
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

func (s *Server) Close() {
	s.stopOnce.Do(func() {
		close(s.stop)
		s.listener.Close()
		s.mu.Lock()
		for _, remote := range s.remotes {
			_ = remote.listener.Close()
		}
		_ = s.persistLocked()
		for _, b := range s.blocks {
			_ = b.park(true)
			b.close()
		}
		s.mu.Unlock()
		s.clientsMu.Lock()
		for _, c := range s.clients {
			c.close("service_shutdown")
		}
		s.clientsMu.Unlock()
		_ = os.Remove(s.socket)
		_ = s.lock.Close()
	})
}

func (c *client) close(reason string) {
	c.once.Do(func() {
		queuedBytes, queuedPackets := c.out.stats()
		log.Printf("client %s disconnected: %s; transport=%s queued_bytes=%d queued_packets=%d", c.id, reason, c.conn.LocalAddr().Network(), queuedBytes, queuedPackets)
		close(c.done)
		_ = c.conn.Close()
	})
}

func (c *client) send(m Message) bool {
	select {
	case <-c.done:
		return false
	default:
	}
	if c.out.push(m) {
		return true
	}
	c.close("outbound_queue_limit")
	return false
}

func (s *Server) serve(conn net.Conn) {
	c := &client{id: NewID(), connectedAt: time.Now(), kind: "protocol", conn: conn, subscriptions: map[string]string{}, out: newMessageQueue(), done: make(chan struct{})}
	s.clientsMu.Lock()
	s.clients[c.id] = c
	s.clientsMu.Unlock()
	s.stateChanged()
	defer func() {
		c.close("handler_finished")
		s.clientsMu.Lock()
		delete(s.clients, c.id)
		s.clientsMu.Unlock()
		s.mu.Lock()
		for _, b := range s.blocks {
			b.mu.Lock()
			b.releaseViewer(c.id)
			b.mu.Unlock()
		}
		s.mu.Unlock()
		s.stateChanged()
	}()
	go func() {
		encoder := json.NewEncoder(conn)
		for {
			if m, ok := c.out.pop(); ok {
				_ = conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
				if err := encoder.Encode(m); err != nil {
					c.close("writer_error: " + err.Error())
					return
				}
				if m.stopServer {
					go s.Close()
					return
				}
				if m.closeClient {
					c.close("client_detached")
					return
				}
				continue
			}
			select {
			case <-c.out.ready:
			case <-c.done:
				return
			}
		}
	}()
	c.send(Message{Type: "hello", Protocol: ProtocolVersion, Engine: EngineVersion, Client: c.id, Features: []string{"viewport", "replay", "graphics", "theme-events", "client-focus"}})
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	for scanner.Scan() {
		var r Request
		if err := json.Unmarshal(scanner.Bytes(), &r); err != nil {
			c.send(Message{Type: "error", Error: "invalid request JSON"})
			continue
		}
		m := s.handle(c, r)
		m.ID = r.ID
		if m.Type == "" {
			m.Type = "reply"
		}
		if !c.send(m) {
			return
		}
	}
	if err := scanner.Err(); err != nil {
		c.close("reader_error: " + err.Error())
	} else {
		c.close("reader_eof")
	}
}

func (s *Server) broadcast(m Message, block string) {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	for _, c := range s.clients {
		c.mu.Lock()
		stream := c.subscriptions[block]
		watching := c.watching
		c.mu.Unlock()
		if block != "" {
			if stream == "" {
				continue
			}
			m.Stream = stream
		} else if !watching {
			continue
		}
		c.send(m)
	}
}

// Deliver terminal events once to the union of observers and attached replicas.
func (s *Server) broadcastEvent(m Message) {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	for _, c := range s.clients {
		c.mu.Lock()
		stream, watching := c.subscriptions[m.Block], c.watching
		c.mu.Unlock()
		if stream != "" || watching {
			m.Stream = stream
			c.send(m)
		}
	}
}

func (s *Server) primaryViewer(block, owner, previous string) *client {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	attached := func(c *client) bool {
		if c == nil {
			return false
		}
		select {
		case <-c.done:
			return false
		default:
		}
		c.mu.Lock()
		stream := c.subscriptions[block]
		c.mu.Unlock()
		return stream != ""
	}
	if c := s.clients[owner]; attached(c) {
		return c
	}
	if c := s.clients[previous]; attached(c) {
		return c
	}
	var selected *client
	for _, c := range s.clients {
		if (selected == nil || c.id < selected.id) && attached(c) {
			selected = c
		}
	}
	return selected
}

func (s *Server) changed() {
	s.persistPending.Store(true)
	s.stateChanged()
}

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

func (s *Server) nextParkDeadline() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	var next time.Time
	for _, b := range s.blocks {
		b.mu.Lock()
		if !b.closed && b.terminal != nil && !b.graphics.retained && !b.graphics.pending {
			deadline := b.lastOutput.Add(terminalIdleTimeout)
			if b.parkRetryAfter.After(deadline) {
				deadline = b.parkRetryAfter
			}
			if next.IsZero() || deadline.Before(next) {
				next = deadline
			}
		}
		b.mu.Unlock()
	}
	return next
}

func (s *Server) maintenance() {
	flush := time.NewTimer(time.Hour)
	flush.Stop()
	defer flush.Stop()
	park := time.NewTimer(time.Hour)
	park.Stop()
	defer park.Stop()
	var flushC, parkC <-chan time.Time
	resetParkDeadline := func() {
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
			// Start one bounded coalescing window. Further changes do not push
			// its deadline back, and a quiet service has no metadata timer.
			if flushC == nil {
				flush.Reset(100 * time.Millisecond)
				flushC = flush.C
			}
		case <-flushC:
			flushC = nil
			s.mu.Lock()
			durable := s.persistPending.Swap(false)
			s.revision++
			state := s.stateLocked()
			if durable {
				if err := s.persistStateLocked(state); err != nil {
					log.Printf("persist: %v", err)
				}
			}
			s.mu.Unlock()
			s.broadcast(Message{Type: "state", State: &state}, "")
		case id := <-s.finished:
			s.mu.Lock()
			if b := s.blocks[id]; b != nil {
				s.removeBlockLocked(id)
			}
			s.mu.Unlock()
			s.changed()
		case <-s.parkChanges:
			resetParkDeadline()
		case <-parkC:
			parkC = nil
			s.mu.Lock()
			blocks := make([]*Block, 0, len(s.blocks))
			for _, b := range s.blocks {
				blocks = append(blocks, b)
			}
			s.mu.Unlock()
			for _, b := range blocks {
				if err := b.park(false); err != nil {
					log.Printf("park %s: %v", b.info.ID, err)
				}
			}
			resetParkDeadline()
		case <-s.stop:
			return
		}
	}
}

func (s *Server) stateLocked() State {
	state := State{Revision: s.revision, Sessions: make([]*Session, 0, len(s.sessions)), Blocks: make([]BlockInfo, 0, len(s.blocks))}
	for _, session := range s.sessions {
		copySession := &Session{ID: session.ID, Name: session.Name, FocusedWindow: session.FocusedWindow, Windows: make([]*Window, 0, len(session.Windows))}
		for _, w := range session.Windows {
			copySession.Windows = append(copySession.Windows, &Window{ID: w.ID, Name: w.Name, Root: w.Root.clone(), Zoomed: w.Zoomed, FocusedBlock: w.FocusedBlock})
		}
		state.Sessions = append(state.Sessions, copySession)
	}
	for _, b := range s.blocks {
		b.mu.Lock()
		info := b.info
		if ss, w := s.findWindow(info.ID); w != nil {
			info.Session = ss.ID
			info.Window = w.ID
		}
		state.Blocks = append(state.Blocks, info)
		b.mu.Unlock()
	}
	sort.Slice(state.Blocks, func(i, j int) bool { return state.Blocks[i].ID < state.Blocks[j].ID })
	s.clientsMu.RLock()
	state.Clients = len(s.clients)
	s.clientsMu.RUnlock()
	return state
}

func (n *Layout) clone() *Layout {
	if n == nil {
		return nil
	}
	return &Layout{ID: n.ID, Block: n.Block, Axis: n.Axis, Ratio: n.Ratio, First: n.First.clone(), Second: n.Second.clone()}
}

func (s *Server) persistLocked() error {
	return s.persistStateLocked(s.stateLocked())
}

func (s *Server) persistStateLocked(state State) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return atomicWrite(filepath.Join(s.directory, "workspace.json"), data)
}

func (s *Server) restore() error {
	data, err := os.ReadFile(filepath.Join(s.directory, "workspace.json"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var state State
	if err = json.Unmarshal(data, &state); err != nil {
		return err
	}
	s.sessions = state.Sessions
	if s.sessions == nil {
		s.sessions = []*Session{}
	}
	for _, info := range state.Blocks {
		// A service restart recreates a shell at its saved location. Process
		// survival is guaranteed across client detach, not host/service death.
		r := Request{Cwd: info.Cwd, Cols: info.Cols, Rows: info.Rows, KeepOpen: true}
		if ss, w := s.findWindow(info.ID); w != nil {
			r.Session, r.Window = ss.ID, w.ID
		}
		b, err := s.newBlock(r, info.ID)
		if err != nil {
			for _, ss := range s.sessions {
				for _, w := range ss.Windows {
					w.Root = w.Root.remove(info.ID)
				}
			}
			continue
		}
		b.mu.Lock()
		b.info.Label = info.Label
		b.info.Creator = info.Creator
		b.mu.Unlock()
		s.blocks[b.info.ID] = b
	}
	s.pruneLocked()
	return nil
}

func (s *Server) findSession(id string) *Session {
	for _, ss := range s.sessions {
		if ss.ID == id {
			return ss
		}
	}
	for _, ss := range s.sessions {
		if ss.Name == id {
			return ss
		}
	}
	return nil
}
func (s *Server) findWindow(id string) (*Session, *Window) {
	if id == "" {
		return nil, nil
	}
	for _, ss := range s.sessions {
		for _, w := range ss.Windows {
			if w.ID == id || w.Root.contains(id) {
				return ss, w
			}
		}
	}
	return nil, nil
}

func (s *Server) removeBlockLocked(id string) {
	ss, window := s.findWindow(id)
	event := Message{Type: "event", Event: "block_closed", Block: id}
	if window != nil {
		event.Session, event.Window = ss.ID, window.ID
	}
	for _, ss := range s.sessions {
		for _, w := range ss.Windows {
			w.Root = w.Root.remove(id)
			if w.Zoomed == id {
				w.Zoomed = ""
			}
		}
	}
	if b := s.blocks[id]; b != nil {
		b.close()
		if err := os.Remove(b.snapshotPath); err != nil && !os.IsNotExist(err) {
			log.Printf("remove snapshot %s: %v", id, err)
		}
		delete(s.blocks, id)
		s.parkingChanged()
	}
	s.pruneLocked()
	s.broadcastEvent(event)
}

func (s *Server) pruneLocked() {
	for _, ss := range s.sessions {
		kept := ss.Windows[:0]
		for _, w := range ss.Windows {
			if w.Root != nil {
				if !w.Root.contains(w.FocusedBlock) {
					ids := w.Root.blocks()
					if len(ids) > 0 {
						w.FocusedBlock = ids[0]
					}
				}
				kept = append(kept, w)
			}
		}
		ss.Windows = kept
		found := false
		for _, w := range kept {
			if w.ID == ss.FocusedWindow {
				found = true
				break
			}
		}
		if !found {
			ss.FocusedWindow = ""
			if len(kept) > 0 {
				ss.FocusedWindow = kept[0].ID
			}
		}
	}
}

func (s *Server) handle(c *client, r Request) Message {
	if r.Method == "block.reset" {
		return s.resetTerminal(r)
	}
	switch r.Method {
	case "block.format":
		r.Method = "block.capture"
	case "block.list_dir":
		r.Method = "directory.list"
	case "block.set_theme":
		r.Method = "block.theme"
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	fail := func(err error) Message { return Message{Type: "error", Error: err.Error()} }
	changed := false
	defer func() {
		if changed {
			s.changed()
		}
	}()
	if m, ok := s.handleResource(c, r); ok {
		return m
	}
	switch r.Method {
	case "remote.pair":
		if c.conn.LocalAddr().Network() != "unix" {
			return fail(errors.New("pairing requires the local authenticated Unix socket"))
		}
		credentials, err := s.pairRemote(r.Label)
		if err != nil {
			return fail(err)
		}
		return Message{Credentials: credentials}
	case "state", "watch":
		if r.Method == "watch" {
			c.mu.Lock()
			c.watching = true
			c.mu.Unlock()
		}
		state := s.stateLocked()
		return Message{Type: "state", State: &state}
	case "api":
		return Message{Methods: []string{"focus", "session.inspect", "window.inspect", "client.list", "client.inspect", "client.update", "client.rename", "client.detach", "server.status", "server.inspect", "server.stop", "whoami", "block.key", "block.mouse", "block.rename", "block.viewport", "session.new", "session.rename", "session.kill", "window.new", "window.rename", "window.kill", "block.split", "block.move", "block.swap", "block.kill", "block.attach", "block.detach", "block.write", "block.resize", "block.claim", "block.capture", "block.format", "block.list_dir", "block.process", "block.inspect", "block.reset", "block.theme", "block.set_theme", "block.size", "block.title", "block.event", "block.park", "directory.list", "layout.resize", "window.zoom", "state", "watch"}}
	case "session.new", "window.new":
		if r.Cwd == "" {
			if parent := s.blocks[r.Block]; parent != nil {
				parent.mu.Lock()
				r.Cwd = parent.currentDirectory()
				parent.mu.Unlock()
			}
		}
		ss := s.findSession(r.Session)
		if r.Method == "window.new" && r.Session == "" {
			ss, _ = s.findWindow(r.Block)
			if ss == nil && r.Block == "" && len(s.sessions) > 0 {
				ss = s.sessions[0]
			}
		}
		if r.Method == "window.new" && ss == nil {
			return fail(errors.New("session not found"))
		}
		if r.Method == "session.new" {
			name := strings.TrimSpace(r.Label)
			if name == "" {
				names := []string{"quiet-cedar", "silver-tide", "drifting-pine", "gentle-orbit", "morning-fern", "distant-shore"}
				name = names[len(s.sessions)%len(names)]
				if s.findSession(name) != nil {
					name += "-" + NewID()[:4]
				}
			}
			ss = &Session{ID: NewID(), Name: name, Windows: []*Window{}}
		}
		w := &Window{ID: NewID(), Name: ""}
		r.Session, r.Window = ss.ID, w.ID
		b, err := s.newBlock(r, "")
		if err != nil {
			return fail(err)
		}
		if r.Method == "session.new" {
			s.sessions = append(s.sessions, ss)
		}
		s.blocks[b.info.ID] = b
		w.Root, w.FocusedBlock = leaf(b.info.ID), b.info.ID
		ss.FocusedWindow = w.ID
		b.mu.Lock()
		b.info.Creator = c.id
		b.mu.Unlock()
		ss.Windows = append(ss.Windows, w)
		changed = true
		return Message{Block: b.info.ID, Session: ss.ID, Window: w.ID}
	case "session.rename", "session.kill":
		ss := s.findSession(r.Session)
		if ss == nil {
			return fail(errors.New("session not found"))
		}
		if r.Method == "session.rename" {
			name := strings.TrimSpace(r.Label)
			if name == "" {
				return fail(errors.New("name cannot be empty"))
			}
			ss.Name = name
		} else {
			var ids []string
			for _, w := range ss.Windows {
				ids = append(ids, w.Root.blocks()...)
			}
			for _, id := range ids {
				s.removeBlockLocked(id)
			}
			for i, existing := range s.sessions {
				if existing.ID == ss.ID {
					s.sessions = append(s.sessions[:i], s.sessions[i+1:]...)
					break
				}
			}
		}
		changed = true
		return Message{}
	case "window.rename", "window.kill", "window.zoom", "layout.resize":
		_, w := s.findWindow(r.Window)
		if w == nil {
			return fail(errors.New("tab not found"))
		}
		switch r.Method {
		case "window.rename":
			w.Name = r.Label
		case "window.kill":
			for _, id := range w.Root.blocks() {
				s.removeBlockLocked(id)
			}
		case "window.zoom":
			if w.Zoomed == r.Block {
				w.Zoomed = ""
			} else if w.Root.contains(r.Block) {
				w.Zoomed = r.Block
			}
		case "layout.resize":
			if !w.Root.resize(r.Target, r.Ratio) {
				return fail(errors.New("split not found"))
			}
		}
		changed = true
		return Message{}
	case "directory.list":
		base, _ := os.UserHomeDir()
		if b := s.blocks[r.Block]; b != nil {
			b.mu.Lock()
			base = b.currentDirectory()
			b.mu.Unlock()
		}
		path := r.Cwd
		if path == "~" || strings.HasPrefix(path, "~/") {
			home, _ := os.UserHomeDir()
			path = filepath.Join(home, strings.TrimPrefix(path, "~/"))
			if r.Cwd == "~" {
				path = home
			}
		} else if !filepath.IsAbs(path) {
			path = filepath.Join(base, path)
		}
		path, err := filepath.Abs(path)
		if err != nil {
			return fail(err)
		}
		entries, err := os.ReadDir(path)
		if err != nil {
			return fail(err)
		}
		dirs := []Directory{{Name: "..", Path: filepath.Dir(path)}}
		for _, entry := range entries {
			if entry.IsDir() {
				dirs = append(dirs, Directory{Name: entry.Name(), Path: filepath.Join(path, entry.Name())})
			}
		}
		return Message{Path: path, Entries: dirs}
	}
	b := s.blocks[r.Block]
	if b == nil {
		return fail(errors.New("terminal block not found"))
	}
	if r.Method == "block.kill" {
		s.removeBlockLocked(r.Block)
		changed = true
		return Message{}
	}
	if r.Method == "block.split" {
		ss, w := s.findWindow(r.Block)
		if w == nil {
			return fail(errors.New("terminal is not placed"))
		}
		if r.Cwd == "" {
			b.mu.Lock()
			r.Cwd = b.currentDirectory()
			b.mu.Unlock()
		}
		r.Session, r.Window = ss.ID, w.ID
		newBlock, err := s.newBlock(r, "")
		if err != nil {
			return fail(err)
		}
		newBlock.mu.Lock()
		newBlock.info.Creator = c.id
		newBlock.mu.Unlock()
		s.blocks[newBlock.info.ID] = newBlock
		axis := "horizontal"
		if r.Axis == "vertical" {
			axis = "vertical"
		}
		w.Root.insert(r.Block, newBlock.info.ID, axis)
		w.Zoomed = ""
		changed = true
		return Message{Block: newBlock.info.ID, Window: w.ID, Session: ss.ID}
	}
	if r.Method == "block.move" || r.Method == "block.swap" {
		if s.blocks[r.Target] == nil {
			return fail(errors.New("destination terminal block not found"))
		}
		if r.Block == r.Target {
			return Message{}
		}
		sourceSession, source := s.findWindow(r.Block)
		ss, target := s.findWindow(r.Target)
		if source == nil || target == nil || !source.Root.contains(r.Block) || !target.Root.contains(r.Target) {
			return fail(errors.New("source or destination is not placed"))
		}
		// Work on copies so even a failed insertion cannot strand a live process.
		sourceRoot, targetRoot := source.Root.clone(), target.Root.clone()
		if source == target {
			targetRoot = sourceRoot
		}
		if r.Method == "block.swap" {
			placeholder := NewID()
			sourceRoot.replace(r.Block, placeholder)
			targetRoot.replace(r.Target, r.Block)
			sourceRoot.replace(placeholder, r.Target)
		} else {
			sourceRoot = sourceRoot.remove(r.Block)
			if source == target {
				targetRoot = sourceRoot
			}
			axis := "horizontal"
			if r.Axis == "vertical" {
				axis = "vertical"
			}
			if !targetRoot.insert(r.Target, r.Block, axis) {
				return fail(errors.New("destination terminal is not placed"))
			}
		}
		source.Root, target.Root = sourceRoot, targetRoot
		b.mu.Lock()
		b.info.Session, b.info.Window = ss.ID, target.ID
		b.mu.Unlock()
		if r.Method == "block.swap" {
			other := s.blocks[r.Target]
			other.mu.Lock()
			other.info.Session, other.info.Window = sourceSession.ID, source.ID
			other.mu.Unlock()
		}
		s.pruneLocked()
		source.Zoomed = ""
		target.Zoomed = ""
		changed = true
		return Message{Window: target.ID, Session: ss.ID, Block: r.Block}
	}
	if r.Method == "block.park" {
		if err := b.park(true); err != nil {
			return fail(err)
		}
		return Message{}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	switch r.Method {
	case "block.viewport":
		return b.handleViewport(c, r)
	case "block.attach":
		if r.Sequence != nil && b.resume(c, r) {
			return Message{Block: r.Block}
		}
		if err := s.attach(c, b, ""); err != nil {
			return fail(err)
		}
		return Message{Block: r.Block}
	case "block.detach":
		c.mu.Lock()
		delete(c.subscriptions, r.Block)
		delete(c.viewportSync, r.Block)
		c.mu.Unlock()
		b.releaseViewer(c.id)
		return Message{}
	case "block.claim":
		if ss, w := s.findWindow(r.Block); w != nil && (w.FocusedBlock != r.Block || ss.FocusedWindow != w.ID) {
			w.FocusedBlock = r.Block
			ss.FocusedWindow = w.ID
			changed = true
		}
		c.mu.Lock()
		c.focusBlock = r.Block
		c.mu.Unlock()
		b.info.Owner = c.id
		if size, ok := b.desiredSizes[c.id]; ok {
			if err := b.resizeFor(c.id, size); err != nil {
				return fail(err)
			}
		}
		b.notifyViewerChange()
		s.stateChanged()
		return Message{}
	case "block.key", "block.mouse":
		if b.info.ExitCode != nil {
			return fail(errors.New("process has exited"))
		}
		if err := b.wake(); err != nil {
			return fail(err)
		}
		data, err := b.encodeInput(r)
		if err != nil {
			return fail(err)
		}
		if len(data) > 0 {
			if err = b.enqueueInput(data); err != nil {
				return fail(err)
			}
		}
		return Message{}
	case "block.rename":
		b.info.Label = r.Label
		changed = true
		return Message{}
	case "block.write":
		if b.info.ExitCode != nil {
			return fail(errors.New("process has exited"))
		}
		if len(r.Data) > 1<<20 {
			return fail(errors.New("input exceeds one megabyte"))
		}
		err := b.enqueueInput(r.Data)
		if err != nil {
			return fail(err)
		}
		return Message{}
	case "block.resize":
		if r.Release {
			b.releaseViewer(c.id)
			return Message{Size: b.size()}
		}
		if err := b.requestSize(c.id, r); err != nil {
			return fail(err)
		}
		return Message{Cols: b.info.Cols, Rows: b.info.Rows, Size: b.size()}
	case "block.capture":
		text, err := b.capture(r.Format)
		if err != nil {
			return fail(err)
		}
		return Message{Text: text}
	case "block.process":
		return Message{Process: b.process()}
	case "block.size":
		return Message{Cols: b.info.Cols, Rows: b.info.Rows, Size: b.size()}
	case "block.title":
		return Message{Text: b.info.Title}
	case "block.event":
		if r.Label != "selection_copied" && r.Label != "url_clicked" {
			return fail(errors.New("unsupported client event"))
		}
		b.event(Message{Event: r.Label, Text: string(r.Data)})
		return Message{}
	case "block.inspect":
		info := b.info
		if ss, w := s.findWindow(r.Block); w != nil {
			info.Session = ss.ID
			info.Window = w.ID
		}
		return Message{Block: r.Block, BlockInfo: &info, Process: b.process(), Methods: []string{"format", "list_dir", "process", "reset", "resize", "set_theme", "size", "title", "write"}, Events: []string{"bell", "child_exited", "clipboard_written", "desktop_notification", "progress_report", "pwd_changed", "selection_copied", "size_changed", "title_changed", "url_clicked"}}
	case "block.theme":
		if r.Theme == nil {
			return fail(errors.New("theme is missing"))
		}
		if len(r.Theme.Palette) != 0 && len(r.Theme.Palette) != 256 {
			return fail(errors.New("palette must contain 256 colors or be omitted"))
		}
		for _, color := range []*uint32{r.Theme.Background, r.Theme.Foreground, r.Theme.Cursor} {
			if color != nil && *color > 0xffffff {
				return fail(errors.New("theme colors must be 24-bit RGB values"))
			}
		}
		for _, color := range r.Theme.Palette {
			if color > 0xffffff {
				return fail(errors.New("theme colors must be 24-bit RGB values"))
			}
		}
		b.theme = r.Theme
		b.applyTheme()
		b.publishMutation(Message{Type: "theme", Theme: b.theme})
		return Message{}
	default:
		return fail(fmt.Errorf("unknown method: %s", r.Method))
	}
}

func (n *Layout) replace(old, new string) {
	if n == nil {
		return
	}
	if n.Block == old {
		n.Block = new
	}
	n.First.replace(old, new)
	n.Second.replace(old, new)
}

func (s *Server) attach(c *client, b *Block, reason string) error {
	snapshot, err := b.snapshot()
	if err != nil {
		return fmt.Errorf("encode terminal snapshot: %w", err)
	}
	d, err := vt.NewSnapshotDecoderBytes(snapshot)
	if err != nil {
		return fmt.Errorf("initialize terminal snapshot decoder: %w", err)
	}
	if err = d.SetMaxContinuationBytes(16 << 20); err != nil {
		d.Close()
		return err
	}
	t, err := d.Ready()
	if err != nil {
		d.Close()
		return fmt.Errorf("decode active terminal snapshot: %w", err)
	}
	offset, err := d.SourceOffset()
	if err != nil {
		d.Close()
		t.Close()
		return err
	}
	stream := NewID()
	c.mu.Lock()
	c.subscriptions[b.info.ID] = stream
	c.mu.Unlock()
	b.notifyViewerChange()
	baseline := b.replay.sequence
	replayID := b.replay.epoch
	c.send(Message{Type: "snapshot", Block: b.info.ID, Stream: stream, Text: reason, Data: snapshot[:offset], Cols: b.info.Cols, Rows: b.info.Rows, ReplayID: replayID, Sequence: &baseline})
	c.send(Message{Type: "graphics", Block: b.info.ID, Stream: stream, Graphics: b.graphicsSnapshot(), ReplayID: replayID, Sequence: &baseline})
	if b.theme != nil {
		c.send(Message{Type: "theme", Block: b.info.ID, Stream: stream, Theme: b.theme, ReplayID: replayID, Sequence: &baseline})
	}
	// Old history is lower priority than live output and sent after READY.
	// Each message ends at a decoder record boundary, so clients can safely
	// apply live output between complete history pages.
	go func() {
		defer func() { d.Close(); t.Close() }()
		previous := offset
		for {
			c.mu.Lock()
			current := c.subscriptions[b.info.ID]
			c.mu.Unlock()
			if current != stream {
				return
			}
			advanced, err := d.Next()
			if err != nil {
				c.send(Message{Type: "error", Block: b.info.ID, Error: "decode terminal history: " + err.Error()})
				return
			}
			next, err := d.SourceOffset()
			if err != nil {
				return
			}
			if !c.send(Message{Type: "history", Block: b.info.ID, Stream: stream, Data: snapshot[previous:next], Final: !advanced, ReplayID: replayID, Sequence: &baseline}) {
				return
			}
			previous = next
			if !advanced {
				return
			}
			select {
			case <-time.After(time.Millisecond):
			case <-c.done:
				return
			}
		}
	}()
	return nil
}
