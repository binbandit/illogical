package mux

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"runtime/debug"
	"sync"
	"time"

	vt "go.mitchellh.com/libghostty"
)

// client is one protocol connection: the app, a CLI invocation, or a remote
// relay. Its requests are handled in order on the connection's reader
// goroutine; replies and pushed messages share one bounded outbound queue so
// a slow reader never blocks the service or other clients.
type client struct {
	id          string
	conn        net.Conn
	connectedAt time.Time
	out         *messageQueue
	done        chan struct{}
	closeOnce   sync.Once

	mu            sync.Mutex
	label         string
	kind          string
	focusBlock    string
	watching      bool              // Receives workspace state and every event.
	subscriptions map[string]string // Attached block ID -> replica stream ID.
	viewportSync  map[string]bool
}

const writeTimeout = 15 * time.Second

// features lets clients gate newer requests when talking to an older service,
// such as a remote host that has not been upgraded.
var features = []string{"viewport", "replay", "graphics", "theme-events", "client-focus", "clear", "window-move"}

func (s *Server) serve(conn net.Conn) {
	c := &client{id: NewID(), conn: conn, connectedAt: time.Now(), kind: "protocol", out: newMessageQueue(), done: make(chan struct{}), subscriptions: map[string]string{}}
	s.clientsMu.Lock()
	s.clients[c.id] = c
	s.clientsMu.Unlock()
	s.stateChanged()
	defer s.disconnect(c)
	go s.writeLoop(c)
	c.send(Message{Type: "hello", Protocol: ProtocolVersion, Engine: EngineVersion, Client: c.id, Features: features})
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	for scanner.Scan() {
		if !c.send(s.dispatch(c, scanner.Bytes())) {
			return
		}
	}
	if err := scanner.Err(); err != nil {
		c.close("reader_error: " + err.Error())
	} else {
		c.close("reader_eof")
	}
}

// dispatch handles one request line. A handler panic is reported to the
// client instead of taking down every terminal the service owns.
func (s *Server) dispatch(c *client, line []byte) (reply Message) {
	var r Request
	if err := json.Unmarshal(line, &r); err != nil {
		return Message{Type: "error", Error: "invalid request JSON"}
	}
	defer func() {
		if p := recover(); p != nil {
			log.Printf("%s panicked: %v\n%s", r.Method, p, debug.Stack())
			reply = Message{ID: r.ID, Type: "error", Error: "internal error in " + r.Method}
		}
	}()
	handle := methods[r.Method]
	if handle == nil {
		return Message{ID: r.ID, Type: "error", Error: fmt.Sprintf("unknown method: %s", r.Method)}
	}
	reply, err := handle(s, c, r)
	if err != nil {
		reply = Message{Type: "error", Error: err.Error()}
	}
	reply.ID = r.ID
	if reply.Type == "" {
		reply.Type = "reply"
	}
	return reply
}

func (s *Server) writeLoop(c *client) {
	encoder := json.NewEncoder(c.conn)
	for {
		m, ok := c.out.pop()
		if !ok {
			select {
			case <-c.out.ready:
				continue
			case <-c.done:
				return
			}
		}
		_ = c.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
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
	}
}

func (s *Server) disconnect(c *client) {
	c.close("handler_finished")
	s.clientsMu.Lock()
	delete(s.clients, c.id)
	s.clientsMu.Unlock()
	for _, b := range s.blockList() {
		b.mu.Lock()
		b.releaseViewer(c.id)
		b.mu.Unlock()
	}
	s.stateChanged()
}

func (c *client) close(reason string) {
	c.closeOnce.Do(func() {
		queuedBytes, queuedPackets := c.out.stats()
		log.Printf("client %s disconnected: %s; transport=%s queued_bytes=%d queued_packets=%d", c.id, reason, c.conn.LocalAddr().Network(), queuedBytes, queuedPackets)
		close(c.done)
		_ = c.conn.Close()
	})
}

func (c *client) closed() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

// send queues m. A client that falls a full queue behind is disconnected; it
// recovers by reattaching from a snapshot.
func (c *client) send(m Message) bool {
	if c.closed() {
		return false
	}
	if c.out.push(m) {
		return true
	}
	c.close("outbound_queue_limit")
	return false
}

func (c *client) stream(block string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.subscriptions[block]
}

// broadcastState sends workspace state to watching clients.
func (s *Server) broadcastState(m Message) {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	for _, c := range s.clients {
		c.mu.Lock()
		watching := c.watching
		c.mu.Unlock()
		if watching {
			c.send(m)
		}
	}
}

// broadcastBlock sends a terminal mutation to each replica attached to block.
func (s *Server) broadcastBlock(m Message, block string) {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	for _, c := range s.clients {
		if stream := c.stream(block); stream != "" {
			m.Stream = stream
			c.send(m)
		}
	}
}

// broadcastEvent delivers a terminal event once to the union of watchers and
// attached replicas.
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

// attachedClients lists the clients with a replica of block.
func (s *Server) attachedClients(block string) []*client {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	var attached []*client
	for _, c := range s.clients {
		if c.stream(block) != "" {
			attached = append(attached, c)
		}
	}
	return attached
}

// primaryViewer picks the attached client whose outbound queue paces the PTY:
// the size owner, else the previous choice, else a stable fallback.
func (s *Server) primaryViewer(block, owner, previous string) *client {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	attached := func(c *client) bool { return c != nil && !c.closed() && c.stream(block) != "" }
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

// attach subscribes c to b with a fresh replica: the active screen now, then
// scrollback history in the background, paced by c's outbound queue so a
// large scrollback cannot overflow it. Caller holds b.mu.
func (b *Block) attach(c *client, reason string) error {
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
	block, stream := b.info.ID, NewID()
	c.mu.Lock()
	c.subscriptions[block] = stream
	c.mu.Unlock()
	b.notifyViewerChange()
	baseline, replayID := b.replay.sequence, b.replay.epoch
	c.send(Message{Type: "snapshot", Block: block, Stream: stream, Text: reason, Data: snapshot[:offset], Cols: b.info.Cols, Rows: b.info.Rows, ReplayID: replayID, Sequence: &baseline})
	c.send(Message{Type: "graphics", Block: block, Stream: stream, Graphics: b.graphicsSnapshot(), ReplayID: replayID, Sequence: &baseline})
	if b.theme != nil {
		c.send(Message{Type: "theme", Block: block, Stream: stream, Theme: b.theme, ReplayID: replayID, Sequence: &baseline})
	}
	// Each history page ends at a decoder record boundary, so the client can
	// apply live output between pages.
	go func() {
		defer func() { d.Close(); t.Close() }()
		previous := offset
		for c.stream(block) == stream {
			advanced, err := d.Next()
			if err != nil {
				c.send(Message{Type: "error", Block: block, Error: "decode terminal history: " + err.Error()})
				return
			}
			next, err := d.SourceOffset()
			if err != nil {
				return
			}
			if !c.send(Message{Type: "history", Block: block, Stream: stream, Data: snapshot[previous:next], Final: !advanced, ReplayID: replayID, Sequence: &baseline}) || !advanced {
				return
			}
			previous = next
			if space := c.out.waitForSpace(); space != nil {
				select {
				case <-space:
				case <-c.done:
					return
				}
			}
		}
	}()
	return nil
}

// resyncViewers replaces every attached replica with a fresh snapshot after a
// change replicas cannot reproduce from the output stream. Caller holds b.mu.
func (b *Block) resyncViewers(reason string) {
	for _, c := range b.server.attachedClients(b.info.ID) {
		if err := b.attach(c, reason); err != nil {
			c.send(Message{Type: "error", Block: b.info.ID, Error: "terminal snapshot: " + err.Error()})
		}
	}
}
