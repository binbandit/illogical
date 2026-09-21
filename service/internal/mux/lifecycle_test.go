package mux

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestMoveAndSwapRejectNonBlockTargetsAtomically(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	first := c.request(t, Request{Method: "session.new", Command: []string{"/bin/cat"}, KeepOpen: true})
	second := c.request(t, Request{Method: "session.new", Command: []string{"/bin/cat"}, KeepOpen: true})
	before := c.request(t, Request{Method: "state"}).State
	for _, method := range []string{"block.move", "block.swap"} {
		for _, target := range []string{second.Window, second.Session, "missing", ""} {
			r := Request{ID: NewID(), Method: method, Block: first.Block, Target: target}
			if err := c.encoder.Encode(r); err != nil {
				t.Fatal(err)
			}
			for {
				m := c.next(t)
				if m.ID != r.ID {
					continue
				}
				if m.Error == "" {
					t.Fatalf("%s accepted non-block target %q", method, target)
				}
				break
			}
			after := c.request(t, Request{Method: "state"}).State
			if !reflect.DeepEqual(before.Sessions, after.Sessions) || !reflect.DeepEqual(before.Blocks, after.Blocks) {
				t.Fatalf("%s changed layout or terminal state on rejection", method)
			}
		}
	}
	c.request(t, Request{Method: "block.swap", Block: first.Block, Target: second.Block})
	state := c.request(t, Request{Method: "state"}).State
	if state.Sessions[0].Windows[0].Root.Block != second.Block || state.Sessions[1].Windows[0].Root.Block != first.Block {
		t.Fatal("valid cross-session swap did not exchange blocks")
	}
	c.request(t, Request{Method: "block.move", Block: first.Block, Target: second.Block, Axis: "vertical"})
	c.request(t, Request{Method: "block.swap", Block: first.Block, Target: second.Block})
	state = c.request(t, Request{Method: "state"}).State
	root := state.Sessions[0].Windows[0].Root
	if root.Axis != "vertical" || root.First.Block != first.Block || root.Second.Block != second.Block || len(state.Sessions[1].Windows) != 0 {
		t.Fatalf("valid move or same-window swap failed: %#v", root)
	}
	for _, info := range state.Blocks {
		if info.Session != first.Session || info.Window != first.Window || info.ExitCode != nil {
			t.Fatalf("block has incorrect placement or exited after movement: %#v", info)
		}
	}
}

func TestSessionExactIDPrecedesNames(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	first := c.request(t, Request{Method: "session.new", Label: "first", Command: []string{"/bin/cat"}, KeepOpen: true})
	second := c.request(t, Request{Method: "session.new", Label: "second", Command: []string{"/bin/cat"}, KeepOpen: true})
	c.request(t, Request{Method: "session.rename", Session: first.Session, Label: second.Session})
	if got := c.request(t, Request{Method: "session.inspect", Session: second.Session}).SessionInfo.ID; got != second.Session {
		t.Fatalf("exact ID inspected %s instead of %s", got, second.Session)
	}
	c.request(t, Request{Method: "session.kill", Session: second.Session})
	state := c.request(t, Request{Method: "state"}).State
	if len(state.Sessions) != 1 || state.Sessions[0].ID != first.Session || len(state.Blocks) != 1 || state.Blocks[0].ID != first.Block {
		t.Fatal("exact ID kill removed the wrong session")
	}
	if got := c.request(t, Request{Method: "session.inspect", Session: second.Session}).SessionInfo.ID; got != first.Session {
		t.Fatal("name fallback no longer works after the colliding ID disappears")
	}
}

func TestPermanentRemovalDeletesSnapshotButShutdownRetainsIt(t *testing.T) {
	for _, method := range []string{"block.kill", "window.kill", "session.kill", "child-exit", "shutdown"} {
		t.Run(method, func(t *testing.T) {
			s, socket := startTest(t)
			c := connectTest(t, socket)
			created := c.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "stty -echo; printf ready; read line"}})
			waitCapture(t, c, created.Block, "ready")
			c.request(t, Request{Method: "block.park", Block: created.Block})
			path := filepath.Join(s.directory, "snapshots", created.Block+".gz")
			if _, err := os.Stat(path); err != nil {
				t.Fatal(err)
			}
			if method == "shutdown" {
				s.Close()
				if _, err := os.Stat(path); err != nil {
					t.Fatalf("shutdown removed a retained snapshot: %v", err)
				}
				return
			}
			if method == "child-exit" {
				c.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("finish\n")})
			} else {
				c.request(t, Request{Method: method, Block: created.Block, Window: created.Window, Session: created.Session})
			}
			deadline := time.Now().Add(3 * time.Second)
			for {
				if _, err := os.Stat(path); os.IsNotExist(err) {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("permanently removed block retained its scrollback snapshot")
				}
				time.Sleep(time.Millisecond)
			}
		})
	}
}

func TestEventsKeepPlacementAcrossMoveSwapAndClose(t *testing.T) {
	_, socket := startTest(t)
	admin := connectTest(t, socket)
	first := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/cat"}, KeepOpen: true})
	second := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/cat"}, KeepOpen: true})
	watcher := connectTest(t, socket)
	watcher.request(t, Request{Method: "watch"})
	check := func(block, session, window, event string) {
		t.Helper()
		for {
			m := watcher.next(t)
			if m.Event != event || m.Block != block {
				continue
			}
			if m.Session != session || m.Window != window {
				t.Fatalf("%s has stale placement: %#v", event, m)
			}
			return
		}
	}
	admin.request(t, Request{Method: "block.swap", Block: first.Block, Target: second.Block})
	for _, expected := range []struct{ block, session, window string }{{first.Block, second.Session, second.Window}, {second.Block, first.Session, first.Window}} {
		admin.request(t, Request{Method: "block.event", Block: expected.block, Label: "selection_copied"})
		check(expected.block, expected.session, expected.window, "selection_copied")
	}
	admin.request(t, Request{Method: "block.move", Block: first.Block, Target: second.Block})
	admin.request(t, Request{Method: "block.event", Block: first.Block, Label: "selection_copied"})
	check(first.Block, first.Session, first.Window, "selection_copied")
	admin.request(t, Request{Method: "block.kill", Block: first.Block})
	check(first.Block, first.Session, first.Window, "block_closed")
}
