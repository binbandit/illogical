package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"illogical/internal/mux"
)

func TestScopedCLIEventsIncludeShortLivedChildren(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "illogical-events-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	socket := filepath.Join(directory, "s.sock")
	server, err := mux.NewServer(directory, socket)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = server.Run(); close(done) }()
	t.Cleanup(func() { server.Close(); <-done })
	admin, err := dial(socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Close() })
	request := func(r mux.Request) mux.Message {
		t.Helper()
		m, err := admin.request(r)
		if err != nil {
			t.Fatal(err)
		}
		return m
	}
	parent := request(mux.Request{Method: "session.new", Label: "watched", Command: []string{"/bin/cat"}, KeepOpen: true})
	env := []string{}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "ILLOGICAL_") && !strings.HasPrefix(entry, "GORACE=") {
			env = append(env, entry)
		}
	}
	env = append(env, "ILLOGICAL_TEST_CLI=1", "ILLOGICAL_HOME="+directory, "ILLOGICAL_SOCKET="+socket, "GORACE=atexit_sleep_ms=0")
	watchers := []<-chan mux.Message{}
	for _, args := range [][]string{{}, {"--session", parent.Session}, {"--session", "watched"}, {"--window", parent.Window}} {
		cmd := exec.Command(os.Args[0], append([]string{"-test.run=^TestCLIProcessHelper$", "--", "events"}, args...)...)
		cmd.Env = env
		output, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err = cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
		events := make(chan mux.Message, 256)
		go func() {
			defer close(events)
			decoder := json.NewDecoder(output)
			for {
				var m mux.Message
				if decoder.Decode(&m) != nil {
					return
				}
				events <- m
			}
		}()
		// A visible sentinel confirms watch registration without a timing guess.
		deadline := time.After(5 * time.Second)
	ready:
		for {
			request(mux.Request{Method: "block.event", Block: parent.Block, Label: "selection_copied", Data: []byte("ready")})
			select {
			case m, ok := <-events:
				if !ok {
					t.Fatal("event command exited before registration")
				}
				if m.Event == "selection_copied" {
					break ready
				}
			case <-time.After(10 * time.Millisecond):
			case <-deadline:
				t.Fatal("event command never became ready")
			}
		}
		watchers = append(watchers, events)
	}
	// Name scopes must stay attached to this identity after a rename.
	request(mux.Request{Method: "session.rename", Session: parent.Session, Label: "renamed"})
	children := map[string]bool{}
	for i := 0; i < 5; i++ {
		child := request(mux.Request{Method: "block.split", Block: parent.Block, Command: []string{"/bin/sh", "-c", "printf '\007'; sleep 0.02; exit 19"}})
		children[child.Block] = true
	}
	for i, events := range watchers {
		seen := map[string]bool{}
		deadline := time.After(5 * time.Second)
		for len(seen) < len(children)*3 {
			select {
			case m, ok := <-events:
				if !ok {
					t.Fatalf("watcher %d exited early", i)
				}
				if !children[m.Block] || m.Event != "bell" && m.Event != "child_exited" && m.Event != "block_closed" {
					continue
				}
				if m.Session != parent.Session || m.Window != parent.Window {
					t.Fatalf("watcher %d received incorrect routing: %#v", i, m)
				}
				if m.Event == "child_exited" && (m.ExitCode == nil || *m.ExitCode != 19) {
					t.Fatalf("lost child exit status: %#v", m)
				}
				key := m.Block + ":" + m.Event
				if seen[key] {
					t.Fatalf("watcher %d received duplicate %s", i, key)
				}
				seen[key] = true
			case <-deadline:
				t.Fatalf("watcher %d received %d of 15 child events", i, len(seen))
			}
		}
	}
}

func TestEventScopeUsesCurrentRoutingAndLegacyStateFallback(t *testing.T) {
	state := &mux.State{Sessions: []*mux.Session{
		{ID: "a", Name: "b", Windows: []*mux.Window{{ID: "wa", Root: &mux.Layout{Block: "child"}}}},
		{ID: "b", Name: "work", Windows: []*mux.Window{{ID: "wb", Root: &mux.Layout{Block: "other"}}}},
	}}
	for _, test := range []struct {
		name  string
		scope mux.Request
		event mux.Message
		want  bool
	}{
		{"new-child", mux.Request{Session: "b"}, mux.Message{Block: "new", Session: "b", Window: "wb"}, true},
		{"moved-child", mux.Request{Session: "a"}, mux.Message{Block: "child", Session: "b", Window: "wb"}, false},
		{"name", mux.Request{Session: "work"}, mux.Message{Block: "new", Session: "b", Window: "wb"}, true},
		{"legacy-name", mux.Request{Session: "work"}, mux.Message{Block: "other"}, true},
		{"legacy-window", mux.Request{Window: "wa"}, mux.Message{Block: "child"}, true},
		{"legacy-id-before-name", mux.Request{Session: "b"}, mux.Message{Block: "child"}, false},
		{"window-intersection", mux.Request{Session: "a", Window: "wb"}, mux.Message{Block: "new", Session: "b", Window: "wb"}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			test.event.Type = "event"
			if got := eventMatches(test.scope, test.event, state); got != test.want {
				t.Fatalf("event matches = %t, want %t", got, test.want)
			}
		})
	}
}
