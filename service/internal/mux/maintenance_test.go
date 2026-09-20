package mux

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestReadOnlyClientDisconnectDoesNotRewriteWorkspace(t *testing.T) {
	s, socket := startTest(t)
	observer := connectTest(t, socket)
	created := observer.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "printf ready; sleep 30"}, KeepOpen: true})
	waitCapture(t, observer, created.Block, "ready")
	path := filepath.Join(s.directory, "workspace.json")
	deadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(path); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("new workspace was not persisted")
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(150 * time.Millisecond)
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	query := connectTest(t, socket)
	query.request(t, Request{Method: "block.process", Block: created.Block})
	query.conn.Close()
	time.Sleep(250 * time.Millisecond)
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("a read-only client disconnect rewrote durable workspace state")
	}
}

func TestQuietMetadataChangeIsPublishedAndPersisted(t *testing.T) {
	s, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "stty -echo; printf ready; read line; printf '\033]2;quiet-title\007'; sleep 30"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "ready")
	observer := connectTest(t, socket)
	observer.request(t, Request{Method: "watch"})
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("go\n")})
	for {
		message := observer.next(t)
		if message.State == nil {
			continue
		}
		for _, info := range message.State.Blocks {
			if info.ID == created.Block && info.Title == "quiet-title" {
				data, err := os.ReadFile(filepath.Join(s.directory, "workspace.json"))
				if err != nil {
					t.Fatal(err)
				}
				var saved State
				if err = json.Unmarshal(data, &saved); err != nil {
					t.Fatal(err)
				}
				for _, persisted := range saved.Blocks {
					if persisted.ID == created.Block && persisted.Title == info.Title {
						return
					}
				}
				t.Fatal("published quiet metadata was not persisted")
			}
		}
	}
}

func TestClientPresenceIsPublishedWithoutPersistence(t *testing.T) {
	s, socket := startTest(t)
	observer := connectTest(t, socket)
	observer.request(t, Request{Method: "watch"})
	waitClients := func(count int) {
		t.Helper()
		for {
			message := observer.next(t)
			if message.State != nil && message.State.Clients == count {
				return
			}
		}
	}
	query := connectTest(t, socket)
	waitClients(2)
	query.conn.Close()
	waitClients(1)
	if _, err := os.Stat(filepath.Join(s.directory, "workspace.json")); !os.IsNotExist(err) {
		t.Fatalf("transient client presence created a saved workspace: %v", err)
	}
}

func TestAutomaticParkingUsesLastOutputDeadline(t *testing.T) {
	s, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "stty -echo; printf ready; while IFS= read -r line; do printf '%s' \"$line\"; done"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "ready")
	s.mu.Lock()
	b := s.blocks[created.Block]
	s.mu.Unlock()
	expire := func(after time.Duration) {
		b.mu.Lock()
		b.lastOutput = time.Now().Add(-terminalIdleTimeout + after)
		b.mu.Unlock()
		s.parkingChanged()
	}
	// Advance the idle clock, then produce output before its deadline. The
	// one-shot parking timer must consult the newer output timestamp.
	expire(100 * time.Millisecond)
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("fresh\n")})
	waitCapture(t, admin, created.Block, "fresh")
	time.Sleep(150 * time.Millisecond)
	b.mu.Lock()
	parkedTooSoon := b.terminal == nil
	pid := b.info.PID
	b.mu.Unlock()
	if parkedTooSoon {
		t.Fatal("parking ignored output received before its previous deadline")
	}
	expire(-time.Millisecond)
	waitParked := func(want bool) {
		t.Helper()
		deadline := time.Now().Add(time.Second)
		for time.Now().Before(deadline) {
			state := admin.request(t, Request{Method: "state"}).State
			for _, info := range state.Blocks {
				if info.ID == created.Block && info.Parked == want {
					return
				}
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("automatic parked state did not become %v", want)
	}
	waitParked(true)
	if next := s.nextParkDeadline(); !next.IsZero() {
		t.Fatalf("fully parked workspace retains a parking deadline: %s", next)
	}
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("wake\n")})
	waitParked(false)
	if next := s.nextParkDeadline(); next.IsZero() {
		t.Fatal("output restored an emulator without a future parking deadline")
	}
	if got := admin.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID; got != pid {
		t.Fatal("automatic parking restarted the process")
	}
	if text := waitCapture(t, admin, created.Block, "wake"); text == "" {
		t.Fatal("park/wake lost terminal output")
	}
}
