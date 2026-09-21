package mux

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSessionRenamePublishesAndPersistsWithoutReplacingTerminals(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	s, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Label: "Original", Command: []string{"/bin/cat"}, KeepOpen: true})
	admin.request(t, Request{Method: "session.new", Label: "Other", Command: []string{"/bin/cat"}, KeepOpen: true})
	before := admin.request(t, Request{Method: "state"}).State
	pid := admin.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID
	observers := []*testClient{connectTest(t, socket), connectTest(t, socket)}
	for _, observer := range observers {
		observer.request(t, Request{Method: "watch"})
	}

	admin.request(t, Request{Method: "session.rename", Session: created.Session, Label: " \tWork Notes \u00a0"})
	before.Sessions[0].Name = "Work Notes"
	assertSessions := func(state *State) {
		t.Helper()
		if state == nil {
			t.Fatal("missing workspace state")
		}
		if !reflect.DeepEqual(state.Sessions, before.Sessions) {
			got, _ := json.Marshal(state.Sessions)
			want, _ := json.Marshal(before.Sessions)
			t.Fatalf("rename changed session identities, layout, focus, or another session:\ngot %s\nwant %s", got, want)
		}
	}
	for _, observer := range observers {
		for {
			message := observer.next(t)
			if message.State == nil || len(message.State.Sessions) > 0 && message.State.Sessions[0].Name == "Original" {
				continue
			}
			assertSessions(message.State)
			break
		}
	}

	data, err := os.ReadFile(filepath.Join(s.directory, "workspace.json"))
	if err != nil {
		t.Fatal(err)
	}
	var saved State
	if err = json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	assertSessions(&saved)
	for _, label := range []string{"", " \t\n\u00a0"} {
		request := Request{ID: NewID(), Method: "session.rename", Session: created.Session, Label: label}
		if err = admin.encoder.Encode(request); err != nil {
			t.Fatal(err)
		}
		for {
			message := admin.next(t)
			if message.ID != request.ID {
				continue
			}
			if message.Error != "name cannot be empty" {
				t.Fatalf("blank rename returned %q", message.Error)
			}
			break
		}
	}
	assertSessions(admin.request(t, Request{Method: "state"}).State)
	if got := admin.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID; got != pid {
		t.Fatalf("renaming changed the running terminal PID from %d to %d", pid, got)
	}

	s.Close()
	restarted, err := NewServer(s.directory, socket)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = restarted.Run(); close(done) }()
	t.Cleanup(func() { restarted.Close(); <-done })
	assertSessions(connectTest(t, socket).request(t, Request{Method: "state"}).State)
}
