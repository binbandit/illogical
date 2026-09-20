package mux

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestPTYRemainsPollableAfterMetadataAndResize(t *testing.T) {
	s, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "printf ready; sleep 30"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "ready")
	s.mu.Lock()
	block := s.blocks[created.Block]
	s.mu.Unlock()
	assertPollable := func(stage string) {
		t.Helper()
		raw, err := block.pty.SyscallConn()
		if err != nil {
			t.Fatal(err)
		}
		var flags int
		var ioctlErr error
		if err = raw.Control(func(fd uintptr) { flags, ioctlErr = unix.FcntlInt(fd, unix.F_GETFL, 0) }); err != nil {
			t.Fatal(err)
		}
		if ioctlErr != nil {
			t.Fatal(ioctlErr)
		}
		if flags&unix.O_NONBLOCK == 0 {
			t.Fatalf("PTY is blocking %s; idle terminals consume operating-system threads", stage)
		}
		if err := block.pty.SetWriteDeadline(time.Time{}); err != nil {
			t.Fatalf("PTY is not registered with Go's I/O poller %s: %v", stage, err)
		}
	}
	assertPollable("after creation")
	c.request(t, Request{Method: "block.process", Block: created.Block})
	assertPollable("after reading foreground process metadata")
	c.request(t, Request{Method: "block.resize", Block: created.Block, Cols: 120, Rows: 40, CellWidth: 9, CellHeight: 18})
	assertPollable("after resizing")
}

func TestTerminalRepliesSurviveAnInFlightPaste(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	created := c.request(t, Request{Method: "session.new", Command: []string{executable, "-test.run=^TestPTYQueryHelper$", "--", "query-helper"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "ready")
	c.request(t, Request{Method: "block.write", Block: created.Block, Data: bytes.Repeat([]byte("x"), 1<<20)})
	waitCapture(t, c, created.Block, "queries-complete")
}

func TestControlCInterruptsForegroundProcess(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "printf interrupt-ready; exec sleep 30"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "interrupt-ready")
	c.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte{3}})
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		process := c.request(t, Request{Method: "block.process", Block: created.Block}).Process
		if process.ExitCode != nil {
			if *process.ExitCode != 130 {
				t.Fatalf("Ctrl+C returned exit %d instead of 130", *process.ExitCode)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("Ctrl+C did not interrupt the PTY's foreground process")
}

func TestPTYQueryHelper(t *testing.T) {
	if len(os.Args) == 0 || os.Args[len(os.Args)-1] != "query-helper" {
		return
	}
	raw := exec.Command("/bin/stty", "raw", "-echo")
	raw.Stdin = os.Stdin
	if raw.Run() != nil {
		os.Exit(3)
	}
	fmt.Print("ready")
	var first [1]byte
	if _, err := io.ReadFull(os.Stdin, first[:]); err != nil {
		os.Exit(4)
	}
	// Issue many replies while the server is still writing the user's paste.
	fmt.Print("\x1b[H" + strings.Repeat("\x1b[6n", 400))
	if _, err := io.CopyN(io.Discard, os.Stdin, (1<<20)-1); err != nil {
		os.Exit(5)
	}
	want := bytes.Repeat([]byte("\x1b[1;1R"), 400)
	replies := make([]byte, len(want))
	if _, err := io.ReadFull(os.Stdin, replies); err != nil || !bytes.Equal(replies, want) {
		os.Exit(6)
	}
	fmt.Print("queries-complete")
	os.Exit(0)
}
