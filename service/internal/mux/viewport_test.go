package mux

import "testing"

func viewportBarrier(t *testing.T, c *testClient) []Message {
	t.Helper()
	id := NewID()
	if err := c.encoder.Encode(Request{ID: id, Method: "state"}); err != nil {
		t.Fatal(err)
	}
	messages := []Message{}
	for {
		m := c.next(t)
		if m.ID == id {
			return messages
		}
		if m.Type == "viewport" {
			messages = append(messages, m)
		}
	}
}
func TestViewportSharingRequiresOptInAndNeverWakesParkedTerminal(t *testing.T) {
	s, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Rows: 3, Command: []string{"/bin/sh", "-c", "i=0; while [ $i -lt 100 ]; do printf 'line %s\n' \"$i\"; i=$((i+1)); done; sleep 30"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "line 99")
	first := connectTest(t, socket)
	readReplica(t, first, created.Block)
	independent := connectTest(t, socket)
	readReplica(t, independent, created.Block)
	peer := connectTest(t, socket)
	readReplica(t, peer, created.Block)
	yes, no := true, false
	offset := uint64(10)
	first.request(t, Request{Method: "block.viewport", Block: created.Block, Synchronized: &yes})
	peer.request(t, Request{Method: "block.viewport", Block: created.Block, Synchronized: &yes})
	first.request(t, Request{Method: "block.viewport", Block: created.Block, Viewport: &offset})
	if m := viewportBarrier(t, independent); len(m) != 0 {
		t.Fatal("default client received another viewport")
	}
	if m := viewportBarrier(t, peer); len(m) != 1 || m[0].Viewport == nil || *m[0].Viewport != offset || m[0].Stream == "" {
		t.Fatalf("opted-in peer did not receive viewport: %#v", m)
	}
	independent.request(t, Request{Method: "block.viewport", Block: created.Block, Synchronized: &yes})
	peer.request(t, Request{Method: "block.viewport", Block: created.Block, Viewport: &offset})
	if m := viewportBarrier(t, first); len(m) != 1 {
		t.Fatal("first client failed to receive shared viewport")
	}
	if m := viewportBarrier(t, independent); len(m) != 1 {
		t.Fatal("newly opted-in client failed to receive shared viewport")
	}
	first.request(t, Request{Method: "block.viewport", Block: created.Block, Synchronized: &no})
	peer.request(t, Request{Method: "block.viewport", Block: created.Block, Viewport: &offset})
	if m := viewportBarrier(t, first); len(m) != 0 {
		t.Fatal("opt-out still received viewport")
	}
	viewportBarrier(t, independent)
	invalid := ^uint64(0)
	id := NewID()
	peer.encoder.Encode(Request{ID: id, Method: "block.viewport", Block: created.Block, Viewport: &invalid})
	for {
		m := peer.next(t)
		if m.ID == id {
			if m.Error == "" {
				t.Fatal("out-of-range viewport accepted")
			}
			break
		}
	}
	independent.conn.Close()
	replacement := connectTest(t, socket)
	readReplica(t, replacement, created.Block)
	peer.request(t, Request{Method: "block.viewport", Block: created.Block, Viewport: &offset})
	if m := viewportBarrier(t, replacement); len(m) != 0 {
		t.Fatal("a new connection inherited viewport opt-in")
	}
	admin.request(t, Request{Method: "block.park", Block: created.Block})
	peer.request(t, Request{Method: "block.viewport", Block: created.Block, Viewport: &offset})
	s.mu.Lock()
	b := s.blocks[created.Block]
	s.mu.Unlock()
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.terminal != nil || b.info.Rows != 3 || b.info.Cols != 100 || b.info.Owner != "" {
		t.Fatal("viewport sharing woke or resized authoritative terminal")
	}
	if b.replay.bytes != 0 || b.replay.records != nil {
		t.Fatal("parking retained the reconnect replay cache")
	}
}
