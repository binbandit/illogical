package mux

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestOutputQueueBatchesBytesAndPreservesProtocolBarriers(t *testing.T) {
	queue := newMessageQueue()
	push := func(message Message) {
		t.Helper()
		if !queue.push(message) {
			t.Fatal("a small output burst filled the queue")
		}
	}
	push(Message{Type: "snapshot", Block: "a", Stream: "first", Data: []byte("snapshot")})
	for range 10000 {
		push(Message{Type: "output", Block: "a", Stream: "first", Data: []byte("hello")})
	}
	push(Message{Type: "resize", Block: "a", Stream: "first", Cols: 120, Rows: 40})
	push(Message{Type: "output", Block: "a", Stream: "first", Data: []byte("after-resize")})
	push(Message{Type: "output", Block: "a", Stream: "second", Data: []byte("new-stream")})
	push(Message{Type: "output", Block: "b", Stream: "second", Data: []byte("other-block")})
	first, ok := queue.pop()
	if !ok || first.Type != "snapshot" || string(first.Data) != "snapshot" {
		t.Fatal("snapshot was reordered or modified")
	}
	var output []byte
	packets := 0
	for {
		message, ok := queue.pop()
		if !ok {
			t.Fatal("resize barrier disappeared")
		}
		if message.Type == "resize" {
			break
		}
		if message.Type != "output" || message.Block != "a" || message.Stream != "first" || len(message.Data) > maxOutputBatchBytes {
			t.Fatalf("invalid batched output: type %q, block %q, stream %q, bytes %d", message.Type, message.Block, message.Stream, len(message.Data))
		}
		output = append(output, message.Data...)
		packets++
	}
	if !bytes.Equal(output, bytes.Repeat([]byte("hello"), 10000)) || packets >= 100 {
		t.Fatalf("output was corrupted or not batched: %d bytes in %d packets", len(output), packets)
	}
	for _, expected := range []string{"after-resize", "new-stream", "other-block"} {
		message, ok := queue.pop()
		if !ok || string(message.Data) != expected {
			t.Fatalf("protocol barrier was crossed; expected %q", expected)
		}
	}
}

func TestOutputQueueHasBoundedMemory(t *testing.T) {
	queue := newMessageQueue()
	fragment := bytes.Repeat([]byte("x"), 32<<10)
	count := 0
	for queue.push(Message{Type: "output", Block: "a", Stream: "stream", Data: fragment}) {
		count++
		if count > maxClientQueuedBytes/len(fragment)+1 {
			t.Fatal("output queue exceeded its byte budget")
		}
	}
	if count*len(fragment) < 31<<20 || queue.bytes > maxClientQueuedBytes {
		t.Fatalf("unexpected queue budget: %d messages, %d charged bytes", count, queue.bytes)
	}
}

func TestAttachedClientSurvivesOutputBurstAndBriefReadStall(t *testing.T) {
	_, socket := startTest(t)
	admin := connectTest(t, socket)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	created := admin.request(t, Request{Method: "session.new", Cols: 134, Rows: 35, Command: []string{executable, "-test.run=^TestPTYBurstHelper$", "--", "burst-helper"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "burst-ready")
	viewer := connectTest(t, socket)
	viewer.request(t, Request{Method: "block.attach", Block: created.Block})
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte{13}})
	// Simulate an initial snapshot/render keeping this client busy. Other
	// clients must still be able to operate the workspace during this burst.
	time.Sleep(300 * time.Millisecond)
	before := time.Now()
	admin.request(t, Request{Method: "state"})
	if time.Since(before) > time.Second {
		t.Fatal("a briefly stalled viewer blocked another client")
	}
	expected := append(bytes.Repeat(burstFrame(), 2048), []byte("burst-complete")...)
	hash := sha256.New()
	total := 0
	for total < len(expected) {
		message := viewer.next(t)
		if message.Type != "output" {
			continue
		}
		_, _ = hash.Write(message.Data)
		total += len(message.Data)
	}
	want := sha256.Sum256(expected)
	if total != len(expected) || !bytes.Equal(hash.Sum(nil), want[:]) {
		t.Fatalf("output changed during batching: received %d of %d bytes", total, len(expected))
	}
}

func TestPrimaryBackpressureKeepsInputAndOtherPanesResponsive(t *testing.T) {
	s, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "printf ready; read line; exec /usr/bin/yes x"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "ready")
	viewer := connectTest(t, socket)
	viewer.request(t, Request{Method: "block.attach", Block: created.Block})
	viewer.request(t, Request{Method: "block.claim", Block: created.Block})
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("start\n")})
	primary := s.primaryViewer(created.Block, "", "")
	if primary == nil {
		t.Fatal("attached primary viewer not found")
	}
	deadline := time.Now().Add(3 * time.Second)
	queued := 0
	for time.Now().Before(deadline) {
		queued, _ = primary.out.stats()
		if queued >= primaryOutputHighWater {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if queued < primaryOutputHighWater {
		t.Fatal("producer did not reach the flow-control threshold")
	}
	time.Sleep(150 * time.Millisecond)
	queued, _ = primary.out.stats()
	if queued > primaryOutputHighWater+64<<10 {
		t.Fatalf("stalled primary did not throttle its PTY: %d queued bytes", queued)
	}
	select {
	case <-primary.done:
		t.Fatal("primary viewer was disconnected instead of applying backpressure")
	default:
	}
	other := admin.request(t, Request{Method: "window.new", Session: created.Session, Command: []string{"/bin/sh", "-c", "printf sibling-responsive"}, KeepOpen: true})
	waitCapture(t, admin, other.Block, "sibling-responsive")
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("x")})
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte{3}})
	deadline = time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		process := admin.request(t, Request{Method: "block.process", Block: created.Block}).Process
		if process.ExitCode != nil {
			if *process.ExitCode != 130 {
				t.Fatalf("Ctrl+C exit status during backpressure: %d", *process.ExitCode)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("Ctrl+C was blocked by output backpressure")
}

func TestPrimaryFlowControlReleasesOnClientTurnover(t *testing.T) {
	for _, action := range []string{"disconnect", "detach", "claim"} {
		t.Run(action, func(t *testing.T) {
			s, socket := startTest(t)
			admin := connectTest(t, socket)
			executable, err := os.Executable()
			if err != nil {
				t.Fatal(err)
			}
			created := admin.request(t, Request{Method: "session.new", Cols: 134, Rows: 35, Command: []string{executable, "-test.run=^TestPTYBurstHelper$", "--", "burst-helper"}, KeepOpen: true})
			waitCapture(t, admin, created.Block, "burst-ready")
			viewer := connectTest(t, socket)
			viewer.request(t, Request{Method: "block.attach", Block: created.Block})
			viewer.request(t, Request{Method: "block.claim", Block: created.Block})
			admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte{13}})
			primary := s.primaryViewer(created.Block, "", "")
			deadline := time.Now().Add(3 * time.Second)
			for {
				queued, _ := primary.out.stats()
				if queued >= primaryOutputHighWater {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("primary never reached backpressure")
				}
				time.Sleep(10 * time.Millisecond)
			}
			switch action {
			case "disconnect":
				_ = viewer.conn.Close()
			case "detach":
				if err := viewer.encoder.Encode(Request{ID: NewID(), Method: "block.detach", Block: created.Block}); err != nil {
					t.Fatal(err)
				}
			case "claim":
				fast := connectTest(t, socket)
				fast.request(t, Request{Method: "block.attach", Block: created.Block})
				fast.request(t, Request{Method: "block.claim", Block: created.Block})
				go func() { _, _ = io.Copy(io.Discard, fast.conn) }()
			}
			waitCapture(t, admin, created.Block, "burst-complete")
		})
	}
}

func burstFrame() []byte {
	return append([]byte("\x1b[H\x1b[48;5;196m"), bytes.Repeat([]byte(" "), 134*35)...)
}

func TestPTYBurstHelper(t *testing.T) {
	if len(os.Args) == 0 || os.Args[len(os.Args)-1] != "burst-helper" {
		return
	}
	raw := exec.Command("/bin/stty", "raw", "-echo")
	raw.Stdin = os.Stdin
	if raw.Run() != nil {
		os.Exit(2)
	}
	fmt.Print("burst-ready")
	var start [1]byte
	if _, err := io.ReadFull(os.Stdin, start[:]); err != nil {
		os.Exit(3)
	}
	payload := bytes.Repeat(burstFrame(), 64)
	for range 32 {
		if _, err := os.Stdout.Write(payload); err != nil {
			os.Exit(4)
		}
	}
	fmt.Print("burst-complete")
	os.Exit(0)
}
