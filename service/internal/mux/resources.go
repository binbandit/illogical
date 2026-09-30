package mux

import (
	"errors"
	"os"
	"slices"
	"sort"
)

// Handlers for inspecting and steering the service and its clients.

var errClientNotFound = errors.New("client not found")

func (s *Server) handleServerStatus(c *client, _ Request) (Message, error) {
	host, _ := os.Hostname()
	return Message{Client: c.id, Server: &ServerInfo{PID: os.Getpid(), UID: os.Getuid(), Host: host, Socket: s.socket, StartedAt: s.startedAt, Protocol: ProtocolVersion, Engine: EngineVersion, Version: Version}}, nil
}

// handleServerStop replies first; the connection writer then stops the service.
func (s *Server) handleServerStop(*client, Request) (Message, error) {
	return Message{stopServer: true}, nil
}

func (s *Server) handleClientList(*client, Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return Message{Clients: s.clientListLocked("", "")}, nil
}

// handleClient inspects, relabels, or disconnects a client (default: c).
func (s *Server) handleClient(c *client, r Request) (Message, error) {
	id := r.Client
	if id == "" {
		id = c.id
	}
	s.clientsMu.RLock()
	target := s.clients[id]
	s.clientsMu.RUnlock()
	if target == nil {
		return Message{}, errClientNotFound
	}
	switch r.Method {
	case "client.update", "client.rename":
		target.mu.Lock()
		target.label = r.Label
		if r.Kind != "" {
			target.kind = r.Kind
		}
		target.mu.Unlock()
		s.stateChanged()
	case "client.detach":
		if target == c {
			return Message{closeClient: true}, nil
		}
		target.close("client_detached")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return Message{Client: id, Clients: []ClientInfo{s.clientInfoLocked(target)}}, nil
}

func (s *Server) handleSessionInspect(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ss := s.findSession(r.Session)
	if ss == nil {
		ss, _ = s.findWindow(r.Block)
	}
	if ss == nil {
		return Message{}, errSessionNotFound
	}
	state := s.stateLocked()
	for _, copied := range state.Sessions {
		if copied.ID == ss.ID {
			return Message{Session: ss.ID, SessionInfo: copied, Clients: s.clientListLocked(ss.ID, "")}, nil
		}
	}
	return Message{}, errSessionNotFound
}

func (s *Server) handleWindowInspect(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	id := r.Window
	if id == "" {
		id = r.Block
	}
	ss, w := s.findWindow(id)
	if w == nil {
		return Message{}, errWindowNotFound
	}
	copied := *w
	copied.Root = w.Root.clone()
	return Message{Session: ss.ID, Window: w.ID, WindowInfo: &copied, Clients: s.clientListLocked("", w.ID)}, nil
}

// handleFocus selects a session, tab, or block in a native client: the one
// named by r.Client, or the watching client best placed to show it.
func (s *Server) handleFocus(_ *client, r Request) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ss *Session
	var w *Window
	switch {
	case r.Window != "":
		ss, w = s.findWindow(r.Window)
	case r.Session != "":
		if ss = s.findSession(r.Session); ss != nil {
			if _, w = s.findWindow(ss.FocusedWindow); w == nil && len(ss.Windows) > 0 {
				w = ss.Windows[0]
			}
		}
	default:
		ss, w = s.findWindow(r.Block)
	}
	if ss == nil || w == nil {
		return Message{}, errors.New("focus target not found")
	}
	block := r.Block
	if !w.Root.contains(block) {
		block = w.FocusedBlock
		if ids := w.Root.blocks(); !w.Root.contains(block) && len(ids) > 0 {
			block = ids[0]
		}
	}
	owner := ""
	if b := s.blocks[block]; b != nil {
		b.mu.Lock()
		owner = b.info.Owner
		b.mu.Unlock()
	}
	target, err := s.focusTarget(r.Client, block, owner)
	if err != nil {
		return Message{}, err
	}
	w.FocusedBlock, ss.FocusedWindow = block, w.ID
	s.changed()
	reply := Message{Block: block, Window: w.ID, Session: ss.ID}
	if target != nil {
		target.mu.Lock()
		target.focusBlock = block
		target.mu.Unlock()
		reply.Client = target.id
		focus := reply
		focus.Type = "focus"
		target.send(focus)
	}
	return reply, nil
}

// focusTarget prefers the block's size owner, then native apps, then clients
// already showing the block. Only watching clients can act on focus.
func (s *Server) focusTarget(requested, block, owner string) (*client, error) {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	if requested != "" {
		if target := s.clients[requested]; target != nil {
			return target, nil
		}
		return nil, errClientNotFound
	}
	var target *client
	bestScore := -1
	for _, candidate := range s.clients {
		candidate.mu.Lock()
		watching, attached, kind := candidate.watching, candidate.subscriptions[block] != "", candidate.kind
		candidate.mu.Unlock()
		if !watching {
			continue
		}
		score := 0
		if attached {
			score += 10
		}
		if kind == "native" {
			score += 20
		}
		if candidate.id == owner {
			score += 100
		}
		if score > bestScore || score == bestScore && candidate.id < target.id {
			target, bestScore = candidate, score
		}
	}
	return target, nil
}

// clientInfoLocked describes c; caller holds s.mu to resolve its placement.
func (s *Server) clientInfoLocked(c *client) ClientInfo {
	c.mu.Lock()
	info := ClientInfo{ID: c.id, Label: c.label, Kind: c.kind, Transport: c.conn.LocalAddr().Network(), ConnectedAt: c.connectedAt, Block: c.focusBlock, Subscriptions: []string{}}
	for id := range c.subscriptions {
		info.Subscriptions = append(info.Subscriptions, id)
	}
	c.mu.Unlock()
	sort.Strings(info.Subscriptions)
	if ss, w := s.findWindow(info.Block); w != nil {
		info.Session, info.Window = ss.ID, w.ID
	}
	return info
}

// clientListLocked lists clients focused on or attached to the given session
// or window, or all clients when both are empty. Caller holds s.mu.
func (s *Server) clientListLocked(session, window string) []ClientInfo {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	result := []ClientInfo{}
	for _, c := range s.clients {
		info := s.clientInfoLocked(c)
		matches := session == "" && window == ""
		for _, id := range append(slices.Clone(info.Subscriptions), info.Block) {
			if ss, w := s.findWindow(id); w != nil && (session == "" || session == ss.ID) && (window == "" || window == w.ID) {
				matches = true
				break
			}
		}
		if matches {
			result = append(result, info)
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result
}
