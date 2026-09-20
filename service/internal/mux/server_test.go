package mux

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	vt "go.mitchellh.com/libghostty"
)

type testClient struct {
	conn    net.Conn
	scanner *bufio.Scanner
	encoder *json.Encoder
}

func startTest(t *testing.T) (*Server, string) {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "illogical-test-")
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(directory, "s.sock")
	s, err := NewServer(directory, socket)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = s.Run(); close(done) }()
	t.Cleanup(func() { s.Close(); <-done; os.RemoveAll(directory) })
	return s, socket
}
func connectTest(t *testing.T, socket string) *testClient {
	t.Helper()
	conn, err := net.Dial("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64<<10), 128<<20)
	return &testClient{conn, scanner, json.NewEncoder(conn)}
}
func (c *testClient) next(t *testing.T) Message {
	t.Helper()
	_ = c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if !c.scanner.Scan() {
		t.Fatalf("read: %v", c.scanner.Err())
	}
	var m Message
	if err := json.Unmarshal(c.scanner.Bytes(), &m); err != nil {
		t.Fatal(err)
	}
	return m
}
func (c *testClient) request(t *testing.T, r Request) Message {
	t.Helper()
	r.ID = NewID()
	if err := c.encoder.Encode(r); err != nil {
		t.Fatal(err)
	}
	for {
		m := c.next(t)
		if m.ID == r.ID {
			if m.Error != "" {
				t.Fatal(m.Error)
			}
			return m
		}
	}
}
func waitCapture(t *testing.T, c *testClient, block, needle string) string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		m := c.request(t, Request{Method: "block.capture", Block: block})
		if strings.Contains(m.Text, needle) {
			return m.Text
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("did not capture %q; current capture: %q", needle, c.request(t, Request{Method: "block.capture", Block: block}).Text)
	return ""
}

func TestProcessesSurviveClientDisconnectAndLayouts(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Label: "Work", Cwd: "/tmp", Command: []string{"/bin/sh", "-c", "printf 'before\\n'; sleep 0.3; printf 'after\\n'; sleep 10"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "before")
	pid := c.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID
	c.conn.Close()
	time.Sleep(400 * time.Millisecond)
	c2 := connectTest(t, socket)
	waitCapture(t, c2, created.Block, "after")
	other := c2.request(t, Request{Method: "block.split", Block: created.Block, Axis: "horizontal", Cwd: "/tmp", Command: []string{"/bin/sh", "-c", "sleep 10"}, KeepOpen: true})
	c2.request(t, Request{Method: "block.move", Block: created.Block, Target: other.Block, Axis: "vertical"})
	if got := c2.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID; got != pid {
		t.Fatalf("moving a block changed PID %d to %d", pid, got)
	}
	state := c2.request(t, Request{Method: "state"}).State
	if len(state.Sessions) != 1 || len(state.Blocks) != 2 || state.Sessions[0].Windows[0].Root.Axis != "vertical" {
		t.Fatalf("unexpected layout: %#v", state)
	}
}

func TestIncrementalSnapshotAndLiveOutput(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Cwd: "/tmp", Cols: 200, Rows: 5, Command: []string{"/bin/sh", "-c", "i=0; while [ $i -lt 4000 ]; do printf 'history %s\\n' \"$i\"; i=$((i+1)); done; printf '\033[31'; sleep 0.5; printf 'mLIVE-CONTINUATION\033[0m\\n'; sleep 10"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "history 3999")
	c.encoder.Encode(Request{ID: NewID(), Method: "block.attach", Block: created.Block})
	var decoder *vt.SnapshotDecoder
	var terminal *vt.Terminal
	reader := bytes.NewReader(nil)
	finished := false
	live := false
	pages := 0
	defer func() {
		if decoder != nil {
			decoder.Close()
		}
		if terminal != nil {
			terminal.Close()
		}
	}()
	for !finished || !live {
		m := c.next(t)
		switch m.Type {
		case "snapshot":
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
			advanced, err := decoder.Next()
			if err != nil {
				t.Fatal(err)
			}
			pages++
			if m.Final {
				if advanced {
					t.Fatal("FINISH did not terminate decoder")
				}
				finished = true
			}
		case "output":
			terminal.VTWrite(m.Data)
			if bytes.Contains(m.Data, []byte("LIVE-CONTINUATION")) {
				live = true
			}
		}
	}
	if pages < 2 {
		t.Fatalf("expected deferred history pages, got %d", pages)
	}
	f, err := vt.NewFormatter(terminal, vt.WithFormatterTrim(true))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	text, err := f.FormatString()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, "history 0") || !strings.Contains(text, "LIVE-CONTINUATION") {
		t.Fatalf("snapshot or continuation lost data: %s", text[max(0, len(text)-200):])
	}
}

func TestParkingKeepsProcessAndWakesOnOutput(t *testing.T) {
	s, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Cwd: "/tmp", Command: []string{"/bin/sh", "-c", "printf 'awake\\n'; sleep 0.5; printf 'woke-up\\n'; sleep 10"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "awake")
	c.request(t, Request{Method: "block.park", Block: created.Block})
	s.mu.Lock()
	b := s.blocks[created.Block]
	b.mu.Lock()
	parked := b.terminal == nil
	pid := b.info.PID
	b.mu.Unlock()
	s.mu.Unlock()
	if !parked {
		t.Fatal("parking did not release emulator")
	}
	// A snapshot attachment reads persisted state without waking the server.
	c.encoder.Encode(Request{ID: NewID(), Method: "block.attach", Block: created.Block})
	for c.next(t).Type != "snapshot" {
	}
	b.mu.Lock()
	stillParked := b.terminal == nil
	b.mu.Unlock()
	if !stillParked {
		t.Fatal("attachment woke parked emulator")
	}
	time.Sleep(600 * time.Millisecond)
	waitCapture(t, c, created.Block, "woke-up")
	if got := c.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID; got != pid {
		t.Fatal("parking restarted child")
	}
}

func TestSocketIsPrivateAndDuplicateServiceRejected(t *testing.T) {
	s, socket := startTest(t)
	info, err := os.Stat(socket)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("socket mode %v", info.Mode())
	}
	if second, err := NewServer(s.directory, socket); err == nil {
		second.Close()
		t.Fatal("second service acquired same workspace")
	}
	c := connectTest(t, socket)
	c.request(t, Request{Method: "state"})
}

func TestParkedTerminalCanReattachDuringPartialEscapeSequence(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "stty -echo; printf ready; read line; printf '\033[31'; sleep 30"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "ready")
	c.request(t, Request{Method: "block.park", Block: created.Block})
	c.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("wake\n")})
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		state := c.request(t, Request{Method: "state"}).State
		if !state.Blocks[0].Parked {
			// The shell has emitted an incomplete CSI. Its decoder continuation
			// must survive parking so a new client can attach at this boundary.
			c.request(t, Request{Method: "block.attach", Block: created.Block})
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("terminal did not wake on output")
}
