package mux

import (
	"strings"
	"testing"
)

// block.clear follows Ghostty's clear_screen on the authoritative emulator and
// reaches attached replicas as ordinary numbered output.
func TestClearScreenMatchesGhosttyAndReplicas(t *testing.T) {
	history := `i=0; while [ $i -lt 200 ]; do echo line$i; i=$((i+1)); done; `
	for _, test := range []struct {
		name, script, ready, want string
	}{
		{"prompt", history + `printf '\033]133;A\007PROMPT> \033]133;B\007'; c=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'); printf 'GOT%s' "$c"`, "PROMPT>", "GOT0c"},
		{"output", history + `printf 'tail'`, "tail", "tail"},
		{"alternate", history + `printf '\033[?1049hALT'`, "ALT", "ALT"},
	} {
		t.Run(test.name, func(t *testing.T) {
			s, socket := startTest(t)
			admin := connectTest(t, socket)
			created := admin.request(t, Request{Method: "session.new", Rows: 10, Command: []string{"/bin/sh", "-c", "stty -icanon -echo; " + test.script + "; sleep 30"}, KeepOpen: true})
			waitCapture(t, admin, created.Block, test.ready)
			viewer := connectTest(t, socket)
			replica, _, _ := readReplica(t, viewer, created.Block)
			admin.request(t, Request{Method: "block.clear", Block: created.Block})
			text := waitCapture(t, admin, created.Block, test.want)
			if test.name != "alternate" && strings.Contains(text, "line") {
				t.Fatalf("screen above the cursor: %q", text)
			}
			if test.name == "output" && !strings.HasPrefix(text, "tail") {
				t.Fatalf("cursor row did not move to the top: %q", text)
			}
			s.mu.Lock()
			b := s.blocks[created.Block]
			s.mu.Unlock()
			b.mu.Lock()
			rows, _ := b.terminal.ScrollbackRows()
			b.mu.Unlock()
			if test.name != "alternate" && rows != 0 {
				t.Fatalf("scrollback rows after clear: %d", rows)
			}
			// Drain the replica up to a barrier reply, then compare.
			id := NewID()
			if err := viewer.encoder.Encode(Request{ID: id, Method: "block.title", Block: created.Block}); err != nil {
				t.Fatal(err)
			}
			for m := viewer.next(t); m.ID != id; m = viewer.next(t) {
				if m.Type == "output" {
					replica.VTWrite(m.Data)
				}
			}
			if got := replicaText(t, replica); got != text {
				t.Fatalf("replica diverged after clear:\n%q\nwant\n%q", got, text)
			}
		})
	}
}
