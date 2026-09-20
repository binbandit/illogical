package mux

import (
	"bufio"
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestQUICMutualTLSAndPersistentReconnect(t *testing.T) {
	_, socket := startTest(t)
	local := connectTest(t, socket)
	credentials := local.request(t, Request{Method: "remote.pair", Label: "127.0.0.1"}).Credentials
	if credentials == nil {
		t.Fatal("missing credentials")
	}
	connect := func() *testClient {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		conn, err := DialRemote(ctx, *credentials)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		scanner := bufio.NewScanner(conn)
		scanner.Buffer(make([]byte, 65536), 128<<20)
		return &testClient{conn: conn, scanner: scanner, encoder: json.NewEncoder(conn)}
	}
	remote := connect()
	created := remote.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "printf quic-ready; sleep 30"}, KeepOpen: true})
	waitCapture(t, remote, created.Block, "quic-ready")
	pid := remote.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID
	remote.conn.Close()
	reconnected := connect()
	if got := reconnected.request(t, Request{Method: "block.process", Block: created.Block}).Process.PID; got != pid {
		t.Fatal("reconnect restarted terminal")
	}
	// A different service's authority must fail server verification.
	_, otherSocket := startTest(t)
	other := connectTest(t, otherSocket).request(t, Request{Method: "remote.pair", Label: "127.0.0.1"}).Credentials
	wrong := *credentials
	wrong.Authority = other.Authority
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if conn, err := DialRemote(ctx, wrong); err == nil {
		conn.Close()
		t.Fatal("accepted an untrusted service")
	}
	// A valid server pin with an unrelated client certificate is rejected too.
	wrong = *credentials
	wrong.Certificate = other.Certificate
	wrong.PrivateKey = other.PrivateKey
	ctx2, cancel2 := context.WithTimeout(context.Background(), time.Second)
	defer cancel2()
	if conn, err := DialRemote(ctx2, wrong); err == nil {
		defer conn.Close()
		conn.SetReadDeadline(time.Now().Add(time.Second))
		var byte [1]byte
		if _, err = conn.Read(byte[:]); err == nil {
			t.Fatal("unauthorized client received protocol greeting")
		}
	}
}

func TestOSCWorkingDirectoryAndForegroundMetadata(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "cd /tmp; printf '\033]7;file://localhost/tmp\007directory-ready'; sleep 30"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "directory-ready")
	process := c.request(t, Request{Method: "block.process", Block: created.Block}).Process
	if process.ForegroundPID <= 0 {
		t.Fatal("foreground PID missing")
	}
	if process.Cwd != "/tmp" && process.Cwd != "/private/tmp" {
		t.Fatalf("unexpected cwd %q", process.Cwd)
	}
	c.request(t, Request{Method: "block.split", Block: created.Block, Command: []string{"/bin/sh", "-c", "pwd; sleep 30"}})
	if normalizeDirectory("file://host/tmp/a%20b") != "/tmp/a b" {
		t.Fatal("OSC URL was not decoded")
	}
}

func TestBlockedInputDoesNotBlockWorkspace(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "stty -echo; printf input-ready; sleep 30"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "input-ready")
	c.request(t, Request{Method: "block.write", Block: created.Block, Data: make([]byte, 1<<20)})
	before := time.Now()
	c.request(t, Request{Method: "state"})
	if time.Since(before) > time.Second {
		t.Fatal("a blocked writer stalled workspace requests")
	}
}
