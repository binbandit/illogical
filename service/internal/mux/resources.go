package mux

import (
	"os"
	"sort"
	"time"
)

type ClientInfo struct {
	ID            string    `json:"id"`
	Label         string    `json:"label,omitempty"`
	Kind          string    `json:"kind"`
	Transport     string    `json:"transport"`
	ConnectedAt   time.Time `json:"connectedAt"`
	Block         string    `json:"block,omitempty"`
	Session       string    `json:"session,omitempty"`
	Window        string    `json:"window,omitempty"`
	Subscriptions []string  `json:"subscriptions"`
}
type ServerInfo struct {
	PID       int       `json:"pid"`
	UID       int       `json:"uid"`
	Host      string    `json:"host"`
	Socket    string    `json:"socket"`
	StartedAt time.Time `json:"startedAt"`
	Protocol  int       `json:"protocol"`
	Engine    string    `json:"engine"`
}
type SizeInfo struct {
	Desired    map[string]DesiredSize `json:"desired"`
	Cols       uint16                 `json:"cols"`
	Rows       uint16                 `json:"rows"`
	CellWidth  uint32                 `json:"cellWidth"`
	CellHeight uint32                 `json:"cellHeight"`
	Owner      string                 `json:"owner,omitempty"`
}

func (b *Block) size() *SizeInfo {
	desired := make(map[string]DesiredSize, len(b.desiredSizes))
	for client, size := range b.desiredSizes {
		desired[client] = size
	}
	return &SizeInfo{Cols: b.info.Cols, Rows: b.info.Rows, CellWidth: b.cellWidth, CellHeight: b.cellHeight, Owner: b.info.Owner, Desired: desired}
}

// Called with the workspace lock held; client details are copied before return.
func (s *Server) clientInfo(c *client) ClientInfo {
	c.mu.Lock()
	info := ClientInfo{ID: c.id, Label: c.label, Kind: c.kind, Transport: c.conn.LocalAddr().Network(), ConnectedAt: c.connectedAt, Block: c.focusBlock, Subscriptions: []string{}}
	for id := range c.subscriptions {
		info.Subscriptions = append(info.Subscriptions, id)
	}
	c.mu.Unlock()
	sort.Strings(info.Subscriptions)
	if ss, w := s.findWindow(info.Block); w != nil {
		info.Session = ss.ID
		info.Window = w.ID
	}
	return info
}
func (s *Server) clientList(session, window string) []ClientInfo {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	result := []ClientInfo{}
	for _, c := range s.clients {
		info := s.clientInfo(c)
		matches := session == "" && window == ""
		ids := append(append([]string{}, info.Subscriptions...), info.Block)
		for _, id := range ids {
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
func (s *Server) handleResource(c *client, r Request) (Message, bool) {
	fail := func(text string) (Message, bool) { return Message{Type: "error", Error: text}, true }
	switch r.Method {
	case "server.status", "server.inspect", "whoami":
		host, _ := os.Hostname()
		return Message{Server: &ServerInfo{PID: os.Getpid(), UID: os.Getuid(), Host: host, Socket: s.socket, StartedAt: s.startedAt, Protocol: ProtocolVersion, Engine: EngineVersion}, Client: c.id}, true
	case "server.stop":
		return Message{stopServer: true}, true
	case "client.list":
		return Message{Clients: s.clientList("", "")}, true
	case "client.inspect", "client.update", "client.rename", "client.detach":
		id := r.Client
		if id == "" {
			id = c.id
		}
		s.clientsMu.RLock()
		target := s.clients[id]
		s.clientsMu.RUnlock()
		if target == nil {
			return fail("client not found")
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
				return Message{closeClient: true}, true
			}
			target.close("client_detached")
		}
		return Message{Client: id, Clients: []ClientInfo{s.clientInfo(target)}}, true
	case "session.inspect":
		ss := s.findSession(r.Session)
		if ss == nil {
			ss, _ = s.findWindow(r.Block)
		}
		if ss == nil {
			return fail("session not found")
		}
		state := s.stateLocked()
		for _, copy := range state.Sessions {
			if copy.ID == ss.ID {
				return Message{Session: ss.ID, SessionInfo: copy, Clients: s.clientList(ss.ID, "")}, true
			}
		}
	case "window.inspect":
		id := r.Window
		if id == "" {
			id = r.Block
		}
		ss, w := s.findWindow(id)
		if w == nil {
			return fail("window not found")
		}
		copy := *w
		copy.Root = w.Root.clone()
		return Message{Session: ss.ID, Window: w.ID, WindowInfo: &copy, Clients: s.clientList("", w.ID)}, true
	case "focus":
		var ss *Session
		var w *Window
		block := r.Block
		if r.Window != "" {
			ss, w = s.findWindow(r.Window)
		} else if r.Session != "" {
			ss = s.findSession(r.Session)
			if ss != nil {
				_, w = s.findWindow(ss.FocusedWindow)
				if w == nil && len(ss.Windows) > 0 {
					w = ss.Windows[0]
				}
			}
		} else {
			ss, w = s.findWindow(block)
		}
		if w == nil || ss == nil {
			return fail("focus target not found")
		}
		if block == "" || !w.Root.contains(block) {
			block = w.FocusedBlock
			if !w.Root.contains(block) {
				ids := w.Root.blocks()
				if len(ids) > 0 {
					block = ids[0]
				}
			}
		}
		var target *client
		owner := ""
		if b := s.blocks[block]; b != nil {
			b.mu.Lock()
			owner = b.info.Owner
			b.mu.Unlock()
		}
		s.clientsMu.RLock()
		if r.Client != "" {
			target = s.clients[r.Client]
		} else {
			bestScore := -1
			for _, candidate := range s.clients {
				candidate.mu.Lock()
				watching := candidate.watching
				attached := candidate.subscriptions[block] != ""
				kind := candidate.kind
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
					target = candidate
					bestScore = score
				}
			}
		}
		if r.Client != "" && target == nil {
			s.clientsMu.RUnlock()
			return fail("client not found")
		}
		w.FocusedBlock = block
		ss.FocusedWindow = w.ID
		if target != nil {
			target.mu.Lock()
			target.focusBlock = block
			target.mu.Unlock()
			target.send(Message{Type: "focus", Block: block, Window: w.ID, Session: ss.ID, Client: target.id})
		}
		s.clientsMu.RUnlock()
		s.changed()
		clientID := ""
		if target != nil {
			clientID = target.id
		}
		return Message{Block: block, Window: w.ID, Session: ss.ID, Client: clientID}, true
	}
	return Message{}, false
}
