package mux

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// handler serves one request method. A returned error becomes the reply.
type handler func(s *Server, c *client, r Request) (Message, error)

var methods map[string]handler

func init() {
	methods = map[string]handler{
		"api":         (*Server).handleAPI,
		"state":       (*Server).handleState,
		"watch":       (*Server).handleState,
		"remote.pair": (*Server).handlePair,

		"server.status":  (*Server).handleServerStatus,
		"server.inspect": (*Server).handleServerStatus,
		"whoami":         (*Server).handleServerStatus,
		"server.stop":    (*Server).handleServerStop,
		"client.list":    (*Server).handleClientList,
		"client.inspect": (*Server).handleClient,
		"client.update":  (*Server).handleClient,
		"client.rename":  (*Server).handleClient,
		"client.detach":  (*Server).handleClient,
		"focus":          (*Server).handleFocus,

		"session.new":     (*Server).handleNewWindow,
		"session.inspect": (*Server).handleSessionInspect,
		"session.rename":  (*Server).handleSessionRename,
		"session.kill":    (*Server).handleSessionKill,
		"window.new":      (*Server).handleNewWindow,
		"window.inspect":  (*Server).handleWindowInspect,
		"window.rename":   (*Server).handleWindow,
		"window.kill":     (*Server).handleWindow,
		"window.move":     (*Server).handleWindow,
		"window.zoom":     (*Server).handleWindow,
		"layout.resize":   (*Server).handleWindow,
		"directory.list":  (*Server).handleDirectoryList,
		"block.list_dir":  (*Server).handleDirectoryList,

		"block.split":   (*Server).handleSplit,
		"block.move":    (*Server).handleMove,
		"block.swap":    (*Server).handleMove,
		"block.kill":    (*Server).handleKill,
		"block.claim":   (*Server).handleClaim,
		"block.inspect": (*Server).handleInspect,
		"block.park":    (*Server).handlePark,
		"block.reset":   (*Server).handleReset,

		"block.attach":    blockMethod((*Block).handleAttach),
		"block.detach":    blockMethod((*Block).handleDetach),
		"block.viewport":  blockMethod((*Block).handleViewport),
		"block.write":     blockMethod((*Block).handleWrite),
		"block.key":       blockMethod((*Block).handleInput),
		"block.mouse":     blockMethod((*Block).handleInput),
		"block.resize":    blockMethod((*Block).handleResize),
		"block.size":      blockMethod((*Block).handleSize),
		"block.rename":    blockMethod((*Block).handleRename),
		"block.clear":     blockMethod((*Block).handleClear),
		"block.capture":   blockMethod((*Block).handleCapture),
		"block.format":    blockMethod((*Block).handleCapture),
		"block.process":   blockMethod((*Block).handleProcess),
		"block.title":     blockMethod((*Block).handleTitle),
		"block.event":     blockMethod((*Block).handleEvent),
		"block.theme":     blockMethod((*Block).handleTheme),
		"block.set_theme": blockMethod((*Block).handleTheme),
	}
}

var (
	errBlockNotFound   = errors.New("terminal block not found")
	errBlockClosed     = errors.New("terminal is closed")
	errWindowNotFound  = errors.New("tab not found")
	errSessionNotFound = errors.New("session not found")
	errNotPlaced       = errors.New("terminal is not placed")
)

// blockMethod adapts a handler for work on one terminal. Only that block's
// lock is held, so a large snapshot or capture never stalls other panes.
func blockMethod(f func(b *Block, c *client, r Request) (Message, error)) handler {
	return func(s *Server, c *client, r Request) (Message, error) {
		s.mu.Lock()
		b := s.blocks[r.Block]
		s.mu.Unlock()
		if b == nil {
			return Message{}, errBlockNotFound
		}
		b.mu.Lock()
		defer b.mu.Unlock()
		if b.closed {
			return Message{}, errBlockClosed
		}
		return f(b, c, r)
	}
}

func (s *Server) handleAPI(*client, Request) (Message, error) {
	names := make([]string, 0, len(methods))
	for name := range methods {
		names = append(names, name)
	}
	slices.Sort(names)
	return Message{Methods: names}, nil
}

// handleState returns the workspace. "watch" also subscribes to state and
// events; it subscribes before reading so no change falls in between.
func (s *Server) handleState(c *client, r Request) (Message, error) {
	if r.Method == "watch" {
		c.mu.Lock()
		c.watching = true
		c.mu.Unlock()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state := s.stateLocked()
	return Message{Type: "state", State: &state}, nil
}

func (s *Server) handlePair(c *client, r Request) (Message, error) {
	if c.conn.LocalAddr().Network() != "unix" {
		return Message{}, errors.New("pairing requires the local authenticated Unix socket")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	credentials, err := s.pairRemote(r.Label)
	if err != nil {
		return Message{}, err
	}
	return Message{Credentials: credentials}, nil
}

// handleNewWindow creates a tab with one terminal, in a new session for
// session.new. A new terminal starts in the directory of r.Block when given.
func (s *Server) handleNewWindow(c *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.Cwd == "" {
		r.Cwd = s.inheritedDirectoryLocked(r.Block)
	}
	var ss *Session
	if r.Method == "session.new" {
		ss = &Session{ID: NewID(), Name: s.sessionName(strings.TrimSpace(r.Label)), Windows: []*Window{}}
	} else if r.Session != "" {
		ss = s.findSession(r.Session)
	} else if r.Block != "" {
		ss, _ = s.findWindow(r.Block)
	} else if len(s.sessions) > 0 {
		ss = s.sessions[0]
	}
	if ss == nil {
		return Message{}, errSessionNotFound
	}
	w := &Window{ID: NewID()}
	b, err := s.startBlockLocked(c, r, ss.ID, w.ID)
	if err != nil {
		return Message{}, err
	}
	w.Root, w.FocusedBlock = leaf(b.info.ID), b.info.ID
	// Like Ghostty, a new tab opens right of the current one: the requesting
	// block's tab, else the session's focused tab.
	current := ss.FocusedWindow
	if placed, window := s.findWindow(r.Block); placed == ss {
		current = window.ID
	}
	position := len(ss.Windows)
	if i := windowIndex(ss.Windows, current); i >= 0 {
		position = i + 1
	}
	ss.Windows = slices.Insert(ss.Windows, position, w)
	ss.FocusedWindow = w.ID
	if r.Method == "session.new" {
		s.sessions = append(s.sessions, ss)
	}
	s.changed()
	return Message{Block: b.info.ID, Session: ss.ID, Window: w.ID}, nil
}

// startBlockLocked starts a terminal and registers it; the caller places it.
func (s *Server) startBlockLocked(c *client, r Request, session, window string) (*Block, error) {
	r.Session, r.Window = session, window
	b, err := s.newBlock(r, "")
	if err != nil {
		return nil, err
	}
	b.mu.Lock()
	b.info.Creator = c.id
	b.mu.Unlock()
	s.blocks[b.info.ID] = b
	return b, nil
}

// inheritedDirectoryLocked is where a terminal opened from block starts: the
// block's current directory, or "" (home) if there is none or it vanished.
func (s *Server) inheritedDirectoryLocked(block string) string {
	b := s.blocks[block]
	if b == nil {
		return ""
	}
	b.mu.Lock()
	directory := b.currentDirectory()
	b.mu.Unlock()
	return existingDirectory(directory)
}

func (s *Server) handleSessionRename(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ss := s.findSession(r.Session)
	if ss == nil {
		return Message{}, errSessionNotFound
	}
	name := strings.TrimSpace(r.Label)
	if name == "" {
		return Message{}, errors.New("name cannot be empty")
	}
	ss.Name = name
	s.changed()
	return Message{}, nil
}

// handleSessionKill closes every terminal; pruning then removes the session.
func (s *Server) handleSessionKill(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ss := s.findSession(r.Session)
	if ss == nil {
		return Message{}, errSessionNotFound
	}
	var ids []string
	for _, w := range ss.Windows {
		ids = append(ids, w.Root.blocks()...)
	}
	for _, id := range ids {
		s.removeBlockLocked(id)
	}
	s.changed()
	return Message{}, nil
}

func (s *Server) handleWindow(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ss, w := s.findWindow(r.Window)
	if w == nil {
		return Message{}, errWindowNotFound
	}
	switch r.Method {
	case "window.rename":
		w.Name = r.Label
	case "window.move":
		// The tab takes r.Target's position, so moving onto a neighbour
		// swaps the two.
		from, to := windowIndex(ss.Windows, w.ID), windowIndex(ss.Windows, r.Target)
		if to < 0 {
			return Message{}, errors.New("destination tab is not in this session")
		}
		ss.Windows = slices.Insert(slices.Delete(ss.Windows, from, from+1), to, w)
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
			return Message{}, errors.New("split not found")
		}
	}
	s.changed()
	return Message{}, nil
}

// handleDirectoryList lists subdirectories of r.Cwd, resolved relative to the
// terminal's current directory, for the directory picker.
func (s *Server) handleDirectoryList(_ *client, r Request) (Message, error) {
	home, _ := os.UserHomeDir()
	base := home
	s.mu.Lock()
	if b := s.blocks[r.Block]; b != nil {
		b.mu.Lock()
		base = b.currentDirectory()
		b.mu.Unlock()
	}
	s.mu.Unlock()
	path := r.Cwd
	switch {
	case path == "~":
		path = home
	case strings.HasPrefix(path, "~/"):
		path = filepath.Join(home, path[2:])
	case !filepath.IsAbs(path):
		path = filepath.Join(base, path)
	}
	path = filepath.Clean(path)
	entries, err := os.ReadDir(path)
	if err != nil {
		return Message{}, err
	}
	directories := []Directory{{Name: "..", Path: filepath.Dir(path)}}
	for _, entry := range entries {
		if entry.IsDir() {
			directories = append(directories, Directory{Name: entry.Name(), Path: filepath.Join(path, entry.Name())})
		}
	}
	return Message{Path: path, Entries: directories}, nil
}

func (s *Server) handleSplit(c *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.blocks[r.Block] == nil {
		return Message{}, errBlockNotFound
	}
	ss, w := s.findWindow(r.Block)
	if w == nil {
		return Message{}, errNotPlaced
	}
	if r.Cwd == "" {
		r.Cwd = s.inheritedDirectoryLocked(r.Block)
	}
	b, err := s.startBlockLocked(c, r, ss.ID, w.ID)
	if err != nil {
		return Message{}, err
	}
	w.Root.insert(r.Block, b.info.ID, splitAxis(r.Axis))
	w.Zoomed = ""
	s.changed()
	return Message{Block: b.info.ID, Window: w.ID, Session: ss.ID}, nil
}

// handleMove moves r.Block next to r.Target (block.move) or exchanges the two
// (block.swap). Both edits work on copies, so a failure changes nothing.
func (s *Server) handleMove(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.blocks[r.Block] == nil {
		return Message{}, errBlockNotFound
	}
	if s.blocks[r.Target] == nil {
		return Message{}, errors.New("destination terminal block not found")
	}
	if r.Block == r.Target {
		return Message{}, nil
	}
	sourceSession, source := s.findWindow(r.Block)
	targetSession, target := s.findWindow(r.Target)
	if source == nil || target == nil || !source.Root.contains(r.Block) || !target.Root.contains(r.Target) {
		return Message{}, errors.New("source or destination is not placed")
	}
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
		if !targetRoot.insert(r.Target, r.Block, splitAxis(r.Axis)) {
			return Message{}, errors.New("destination terminal is not placed")
		}
	}
	source.Root, target.Root = sourceRoot, targetRoot
	source.Zoomed, target.Zoomed = "", ""
	s.placeLocked(r.Block, targetSession.ID, target.ID)
	if r.Method == "block.swap" {
		s.placeLocked(r.Target, sourceSession.ID, source.ID)
	}
	s.pruneLocked()
	s.changed()
	return Message{Window: target.ID, Session: targetSession.ID, Block: r.Block}, nil
}

// placeLocked records where a block lives, which routes its later events.
func (s *Server) placeLocked(block, session, window string) {
	b := s.blocks[block]
	b.mu.Lock()
	b.info.Session, b.info.Window = session, window
	b.mu.Unlock()
}

func (s *Server) handleKill(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.blocks[r.Block] == nil {
		return Message{}, errBlockNotFound
	}
	s.removeBlockLocked(r.Block)
	s.changed()
	return Message{}, nil
}

// handleClaim makes c the focused viewer of a block: it becomes the block's
// size owner and the block becomes the focus of its tab and session.
func (s *Server) handleClaim(c *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.blocks[r.Block]
	if b == nil {
		return Message{}, errBlockNotFound
	}
	if ss, w := s.findWindow(r.Block); w != nil && (w.FocusedBlock != r.Block || ss.FocusedWindow != w.ID) {
		w.FocusedBlock, ss.FocusedWindow = r.Block, w.ID
		s.changed()
	}
	c.mu.Lock()
	c.focusBlock = r.Block
	c.mu.Unlock()
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return Message{}, errBlockClosed
	}
	if b.info.Owner != c.id {
		b.info.Owner = c.id
		s.stateChanged()
	}
	if size, ok := b.desiredSizes[c.id]; ok {
		if err := b.resizeFor(c.id, size); err != nil {
			return Message{}, err
		}
	}
	b.notifyViewerChange()
	return Message{}, nil
}

func (s *Server) handleInspect(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.blocks[r.Block]
	if b == nil {
		return Message{}, errBlockNotFound
	}
	ss, w := s.findWindow(r.Block)
	b.mu.Lock()
	defer b.mu.Unlock()
	info := b.info
	if w != nil {
		info.Session, info.Window = ss.ID, w.ID
	}
	return Message{Block: r.Block, BlockInfo: &info, Process: b.process(),
		Methods: []string{"format", "list_dir", "process", "reset", "resize", "set_theme", "size", "title", "write"},
		Events:  []string{"bell", "child_exited", "clipboard_written", "desktop_notification", "progress_report", "pwd_changed", "selection_copied", "size_changed", "title_changed", "url_clicked"}}, nil
}

func (s *Server) handlePark(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	b := s.blocks[r.Block]
	s.mu.Unlock()
	if b == nil {
		return Message{}, errBlockNotFound
	}
	return Message{}, b.park(true)
}

func (s *Server) handleReset(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	b := s.blocks[r.Block]
	s.mu.Unlock()
	if b == nil {
		return Message{}, errBlockNotFound
	}
	return Message{}, b.reset()
}
