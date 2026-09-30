package mux

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
)

// stateLocked copies the workspace for publishing or saving. Caller holds s.mu.
func (s *Server) stateLocked() State {
	state := State{Revision: s.revision, Sessions: make([]*Session, 0, len(s.sessions)), Blocks: make([]BlockInfo, 0, len(s.blocks))}
	for _, ss := range s.sessions {
		copied := &Session{ID: ss.ID, Name: ss.Name, FocusedWindow: ss.FocusedWindow, Windows: make([]*Window, 0, len(ss.Windows))}
		for _, w := range ss.Windows {
			copied.Windows = append(copied.Windows, &Window{ID: w.ID, Name: w.Name, Root: w.Root.clone(), Zoomed: w.Zoomed, FocusedBlock: w.FocusedBlock})
		}
		state.Sessions = append(state.Sessions, copied)
	}
	for _, b := range s.blocks {
		b.mu.Lock()
		info := b.info
		b.mu.Unlock()
		if ss, w := s.findWindow(info.ID); w != nil {
			info.Session, info.Window = ss.ID, w.ID
		}
		state.Blocks = append(state.Blocks, info)
	}
	sort.Slice(state.Blocks, func(i, j int) bool { return state.Blocks[i].ID < state.Blocks[j].ID })
	s.clientsMu.RLock()
	state.Clients = len(s.clients)
	s.clientsMu.RUnlock()
	return state
}

func (s *Server) persist(state State) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return atomicWrite(filepath.Join(s.directory, "workspace.json"), data)
}

// atomicWrite replaces path so a crash leaves either the old or new contents.
func atomicWrite(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".write-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name) // No-op after a successful rename.
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(name, path)
}

// restore recreates the saved layout with a fresh shell in each pane's last
// directory. Processes survive client detach, not service or host restarts.
// Anything the saved state references but cannot back with a shell is dropped.
func (s *Server) restore() error {
	// Scrollback snapshots and interrupted atomic writes belong to the
	// previous service's processes; nothing below reads them.
	_ = os.RemoveAll(filepath.Join(s.directory, "snapshots"))
	if temporary, err := filepath.Glob(filepath.Join(s.directory, ".write-*")); err == nil {
		for _, path := range temporary {
			_ = os.Remove(path)
		}
	}
	path := filepath.Join(s.directory, "workspace.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var state State
	if err = json.Unmarshal(data, &state); err != nil {
		aside := path + ".corrupt"
		_ = os.Rename(path, aside)
		return fmt.Errorf("unreadable workspace moved to %s: %w", aside, err)
	}
	saved := make(map[string]BlockInfo, len(state.Blocks))
	for _, info := range state.Blocks {
		saved[info.ID] = info
	}
	for _, ss := range state.Sessions {
		if ss == nil {
			continue
		}
		windows := make([]*Window, 0, len(ss.Windows))
		for _, w := range ss.Windows {
			if w == nil {
				continue
			}
			for _, id := range w.Root.blocks() {
				info, ok := saved[id]
				if ok && s.blocks[id] == nil {
					b, err := s.restoreBlock(info, ss.ID, w.ID)
					if err == nil {
						s.blocks[id] = b
						continue
					}
					log.Printf("restore terminal %s: %v", id, err)
				}
				w.Root = w.Root.remove(id)
			}
			windows = append(windows, w)
		}
		ss.Windows = windows
		s.sessions = append(s.sessions, ss)
	}
	s.pruneLocked()
	return nil
}

func (s *Server) restoreBlock(info BlockInfo, session, window string) (*Block, error) {
	r := Request{Session: session, Window: window, Label: info.Label, Cwd: existingDirectory(info.Cwd), KeepOpen: info.KeepOpen}
	if validSize(info.Cols, info.Rows) {
		r.Cols, r.Rows = info.Cols, info.Rows
	}
	b, err := s.newBlock(r, info.ID)
	if err != nil {
		return nil, err
	}
	b.mu.Lock()
	b.info.Creator = info.Creator
	b.mu.Unlock()
	return b, nil
}

// existingDirectory returns path if it is still a directory, or "" so the
// caller falls back to the home directory.
func existingDirectory(path string) string {
	if info, err := os.Stat(path); err == nil && info.IsDir() {
		return path
	}
	return ""
}

// findSession matches an exact ID before falling back to a name.
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

// findWindow finds a window by its ID or the ID of a block placed in it.
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

// removeBlockLocked closes a block and removes it from every layout.
func (s *Server) removeBlockLocked(id string) {
	event := Message{Type: "event", Event: "block_closed", Block: id}
	if ss, w := s.findWindow(id); w != nil {
		event.Session, event.Window = ss.ID, w.ID
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
		if err := os.Remove(b.snapshotPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
			log.Printf("remove snapshot %s: %v", id, err)
		}
		delete(s.blocks, id)
		s.parkingChanged()
	}
	s.pruneLocked()
	s.broadcastEvent(event)
}

// pruneLocked drops empty windows and sessions and repairs focus references.
func (s *Server) pruneLocked() {
	sessions := s.sessions[:0]
	for _, ss := range s.sessions {
		windows := ss.Windows[:0]
		for _, w := range ss.Windows {
			ids := w.Root.blocks()
			if len(ids) == 0 {
				continue
			}
			if !w.Root.contains(w.FocusedBlock) {
				w.FocusedBlock = ids[0]
			}
			windows = append(windows, w)
		}
		clear(ss.Windows[len(windows):])
		ss.Windows = windows
		if len(windows) == 0 {
			continue
		}
		if !containsWindow(windows, ss.FocusedWindow) {
			ss.FocusedWindow = windows[0].ID
		}
		sessions = append(sessions, ss)
	}
	clear(s.sessions[len(sessions):])
	s.sessions = sessions
}

func containsWindow(windows []*Window, id string) bool {
	for _, w := range windows {
		if w.ID == id {
			return true
		}
	}
	return false
}

var sessionNames = []string{"quiet-cedar", "silver-tide", "drifting-pine", "gentle-orbit", "morning-fern", "distant-shore"}

func (s *Server) sessionName(requested string) string {
	if requested != "" {
		return requested
	}
	name := sessionNames[len(s.sessions)%len(sessionNames)]
	if s.findSession(name) != nil {
		name += "-" + NewID()[:4]
	}
	return name
}
