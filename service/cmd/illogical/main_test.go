package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"testing"
	"time"

	"illogical/internal/mux"
)

func TestWaitPreservesExitStatusAndEventsBeforeReply(t *testing.T) {
	for _, code := range []int{0, 7, 130} {
		for _, alreadyExited := range []bool{false, true} {
			client, server := net.Pipe()
			_ = client.SetDeadline(time.Now().Add(time.Second))
			c := &connection{Conn: client, scanner: bufio.NewScanner(client), encoder: json.NewEncoder(client)}
			go func() {
				defer server.Close()
				var request mux.Request
				_ = json.NewDecoder(server).Decode(&request)
				encoder := json.NewEncoder(server)
				block := mux.BlockInfo{ID: "test-block"}
				if alreadyExited {
					block.ExitCode = &code
				} else {
					// The server may enqueue this while encoding a state snapshot.
					_ = encoder.Encode(mux.Message{Type: "event", Event: "child_exited", Block: block.ID, ExitCode: &code})
				}
				_ = encoder.Encode(mux.Message{ID: request.ID, Type: "state", State: &mux.State{Blocks: []mux.BlockInfo{block}}})
			}()
			err := waitForBlock(c, "test-block")
			_ = client.Close()
			if code == 0 {
				if err != nil {
					t.Fatal(err)
				}
			} else {
				var status childExitStatus
				if !errors.As(err, &status) || int(status) != code {
					t.Fatalf("wait returned %v, expected exit %d (already exited %v)", err, code, alreadyExited)
				}
			}
		}
	}
}

func TestWaitDisconnectIsNotSuccess(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	c := &connection{Conn: client, scanner: bufio.NewScanner(client), encoder: json.NewEncoder(client)}
	go func() {
		defer server.Close()
		var request mux.Request
		_ = json.NewDecoder(server).Decode(&request)
		_ = json.NewEncoder(server).Encode(mux.Message{ID: request.ID, Type: "state", State: &mux.State{Blocks: []mux.BlockInfo{{ID: "running"}}}})
	}()
	if err := waitForBlock(c, "running"); err == nil {
		t.Fatal("a dropped connection was reported as successful process completion")
	}
}
