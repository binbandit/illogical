package mux

import (
	"bytes"
	"strings"
	"testing"
	"time"

	vt "go.mitchellh.com/libghostty"
)

func readReplica(t *testing.T, c *testClient, block string) (*vt.Terminal, string, uint64) {
	t.Helper()
	requestID := NewID()
	if err := c.encoder.Encode(Request{ID: requestID, Method: "block.attach", Block: block}); err != nil {
		t.Fatal(err)
	}
	var decoder *vt.SnapshotDecoder
	var terminal *vt.Terminal
	reader := bytes.NewReader(nil)
	var epoch string
	var sequence uint64
	final, reply := false, false
	for !final || !reply {
		m := c.next(t)
		switch m.Type {
		case "snapshot":
			if m.Sequence == nil || m.ReplayID == "" {
				t.Fatal("snapshot missing replay baseline")
			}
			epoch, sequence = m.ReplayID, *m.Sequence
			reader.Reset(m.Data)
			var err error
			decoder, err = vt.NewSnapshotDecoder(reader)
			if err != nil {
				t.Fatal(err)
			}
			terminal, err = decoder.Ready()
			if err != nil {
				t.Fatal(err)
			}
		case "history":
			reader.Reset(m.Data)
			if _, err := decoder.Next(); err != nil {
				t.Fatal(err)
			}
			final = m.Final
		case "output":
			terminal.VTWrite(m.Data)
			sequence = *m.Sequence
		}
		if m.ID == requestID {
			if m.Error != "" {
				t.Fatal(m.Error)
			}
			reply = true
		}
	}
	decoder.Close()
	t.Cleanup(terminal.Close)
	return terminal, epoch, sequence
}
func replicaText(t *testing.T, terminal *vt.Terminal) string {
	t.Helper()
	formatter, err := vt.NewFormatter(terminal, vt.WithFormatterTrim(true), vt.WithFormatterUnwrap(true))
	if err != nil {
		t.Fatal(err)
	}
	defer formatter.Close()
	text, err := formatter.FormatString()
	if err != nil {
		t.Fatal(err)
	}
	return text
}

func TestBriefDisconnectReplaysOrderedMutationsAndOverflowResyncs(t *testing.T) {
	s, socket := startTest(t)
	admin := connectTest(t, socket)
	command := "stty -echo; printf INITIAL; while IFS= read -r line; do if [ \"$line\" = flood ]; then head -c 9437184 /dev/zero | LC_ALL=C tr '\\000' x; printf '\033]2;overflow-done\007'; else printf '%s' \"$line\"; fi; done"
	created := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", command}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "INITIAL")
	first := connectTest(t, socket)
	replica, epoch, sequence := readReplica(t, first, created.Block)
	pid := admin.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID
	first.conn.Close()
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("ONE\n")})
	waitCapture(t, admin, created.Block, "ONE")
	admin.request(t, Request{Method: "block.resize", Block: created.Block, Cols: 80, Rows: 24})
	rgb := uint32(0x123456)
	admin.request(t, Request{Method: "block.theme", Block: created.Block, Theme: &Theme{Foreground: &rgb}})
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("TWO\n")})
	waitCapture(t, admin, created.Block, "TWO")
	second := connectTest(t, socket)
	requestID := NewID()
	second.encoder.Encode(Request{ID: requestID, Method: "block.attach", Block: created.Block, ReplayID: epoch, Sequence: &sequence})
	resumed := false
	mutations := 0
	apply := func(m Message) {
		t.Helper()
		if m.ReplayID != epoch || m.PreviousSequence == nil || *m.PreviousSequence != sequence || m.Sequence == nil || *m.Sequence <= sequence {
			t.Fatalf("replay continuity broken: cursor %d, message %#v", sequence, m)
		}
		switch m.Type {
		case "output":
			replica.VTWrite(m.Data)
		case "resize":
			if err := replica.Resize(m.Cols, m.Rows, 0, 0); err != nil {
				t.Fatal(err)
			}
		case "theme":
			if m.Theme == nil || m.Theme.Foreground == nil || *m.Theme.Foreground != rgb {
				t.Fatal("theme mutation lost")
			}
			replica.SetColorForeground(&vt.ColorRGB{R: 0x12, G: 0x34, B: 0x56})
		}
		sequence = *m.Sequence
		mutations++
	}
	for {
		m := second.next(t)
		if m.ID == requestID {
			if m.Error != "" {
				t.Fatal(m.Error)
			}
			break
		}
		switch m.Type {
		case "resume":
			resumed = true
			if m.Sequence == nil || *m.Sequence != sequence {
				t.Fatal("resume did not preserve cursor")
			}
		case "snapshot", "resync":
			t.Fatal("brief disconnect unexpectedly required full snapshot")
		case "output", "resize", "theme":
			apply(m)
		}
	}
	if !resumed || mutations != 4 {
		t.Fatalf("expected four ordered mutations: resumed=%v count=%d", resumed, mutations)
	}
	if got, want := replicaText(t, replica), admin.request(t, Request{Method: "block.capture", Block: created.Block}).Text; got != want || !strings.Contains(got, "INITIALONETWO") {
		t.Fatalf("replica differs: %q vs %q", got, want)
	}
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("LIVE\n")})
	for {
		m := second.next(t)
		if m.Type == "output" {
			apply(m)
			break
		}
	}
	if !strings.Contains(replicaText(t, replica), "ONETWOLIVE") {
		t.Fatal("live output did not continue after replay")
	}
	second.conn.Close()
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("flood\n")})
	deadline := time.Now().Add(10 * time.Second)
	for {
		m := admin.request(t, Request{Method: "block.title", Block: created.Block})
		if m.Text == "overflow-done" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("real producer did not finish overflow output")
		}
		time.Sleep(10 * time.Millisecond)
	}
	s.mu.Lock()
	b := s.blocks[created.Block]
	s.mu.Unlock()
	b.mu.Lock()
	retained, records, floor := b.replay.bytes, len(b.replay.records)-b.replay.head, b.replay.floor
	b.mu.Unlock()
	if retained > maxReplayBytes || records > maxReplayRecords || floor <= sequence {
		t.Fatal("replay retention did not enforce bounds")
	}
	third := connectTest(t, socket)
	requestID = NewID()
	third.encoder.Encode(Request{ID: requestID, Method: "block.attach", Block: created.Block, ReplayID: epoch, Sequence: &sequence})
	resync, snapshot := false, false
	for !snapshot {
		m := third.next(t)
		if m.Type == "resync" {
			resync = true
			if m.Text == "" {
				t.Fatal("resync omitted reason")
			}
		}
		if m.Type == "snapshot" {
			snapshot = true
			if !resync || m.Sequence == nil || *m.Sequence <= sequence {
				t.Fatal("snapshot missing after explicit resync")
			}
		}
	}
	if current := admin.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID; current != pid {
		t.Fatal("replay/resync restarted child")
	}
}

func TestOutputBatchPreservesReplayContinuity(t *testing.T) {
	q := newMessageQueue()
	zero, one, two, three := uint64(0), uint64(1), uint64(2), uint64(3)
	q.push(Message{Type: "output", Block: "b", Stream: "s", ReplayID: "e", PreviousSequence: &zero, Sequence: &one, Data: []byte("a")})
	q.push(Message{Type: "output", Block: "b", Stream: "s", ReplayID: "e", PreviousSequence: &one, Sequence: &two, Data: []byte("b")})
	// Deliberate gap must form another packet rather than hide the missing record.
	q.push(Message{Type: "output", Block: "b", Stream: "s", ReplayID: "e", PreviousSequence: &three, Sequence: &three, Data: []byte("c")})
	m, ok := q.pop()
	if !ok || string(m.Data) != "ab" || *m.PreviousSequence != 0 || *m.Sequence != 2 {
		t.Fatalf("incorrect batched replay interval %#v", m)
	}
	m, ok = q.pop()
	if !ok || string(m.Data) != "c" {
		t.Fatal("gap was coalesced away")
	}
}
