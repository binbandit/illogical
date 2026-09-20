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

func TestCLIProcessHelper(t *testing.T) {
	if os.Getenv("ILLOGICAL_TEST_CLI") != "1" {
		return
	}
	for i, arg := range os.Args {
		if arg == "--" {
			os.Args = append([]string{os.Args[0]}, os.Args[i+1:]...)
			main()
			os.Exit(0)
		}
	}
	os.Exit(2)
}

func TestCLIResourceAndAutomationEndToEnd(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "illogical-cli-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "s.sock")
	server, err := mux.NewServer(directory, socket)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	done := make(chan struct{})
	go func() { _ = server.Run(); close(done) }()
	env := []string{}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "ILLOGICAL_") && !strings.HasPrefix(entry, "GORACE=") {
			env = append(env, entry)
		}
	}
	env = append(env, "ILLOGICAL_TEST_CLI=1", "ILLOGICAL_HOME="+directory, "ILLOGICAL_SOCKET="+socket, "GORACE=atexit_sleep_ms=0")
	invoke := func(block string, args ...string) ([]byte, error) {
		cmd := exec.Command(os.Args[0], append([]string{"-test.run=^TestCLIProcessHelper$", "--"}, args...)...)
		cmd.Env = append(append([]string{}, env...), "ILLOGICAL_BLOCK="+block)
		return cmd.CombinedOutput()
	}
	request := func(block string, args ...string) mux.Message {
		t.Helper()
		data, err := invoke(block, args...)
		if err != nil {
			t.Fatalf("%v: %v: %s", args, err, data)
		}
		var m mux.Message
		if err = json.Unmarshal(data, &m); err != nil {
			t.Fatalf("%v: %v: %s", args, err, data)
		}
		return m
	}
	first := request("", "new", "First", "--keep-open", "--", "/bin/sh", "-c", "sleep 30")
	second := request("", "new", "Second", "--keep-open", "--", "/bin/sh", "-c", "printf ready; sleep 30")
	run := request(second.Block, "run", "--keep-open", "--", "/bin/sh", "-c", "exit 7")
	if run.Session != second.Session {
		t.Fatal("CLI run selected wrong session")
	}
	request("", "session", "inspect", "--session", second.Session)
	request("", "window", "inspect", "--window", run.Window)
	inspect := request(second.Block, "block", "inspect")
	if inspect.BlockInfo == nil || inspect.BlockInfo.ID != second.Block {
		t.Fatal("CLI block inspector omitted resource identity")
	}
	request("", "block", "call", second.Block, "title")
	request(second.Block, "api", "block.set_theme", "--theme", "{}")
	request(second.Block, "block", "write", "sample")
	request(second.Block, "send-key", "shift-enter")
	request("", "client", "list")
	status := request("", "server", "status")
	if status.Server == nil || status.Server.PID != os.Getpid() {
		t.Fatal("server status did not query connected service")
	}
	request("", "attach", "--session", second.Session)
	data, err := invoke("", "wait", "--window", run.Window)
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 7 || len(data) != 0 {
		t.Fatalf("window wait status: %v %q", err, data)
	}
	short := request("", "new", "Short", "--keep-open", "--", "/bin/sh", "-c", "exit 0")
	if data, err = invoke("", "wait", "--session", short.Session); err != nil || len(data) != 0 {
		t.Fatalf("session wait: %v %q", err, data)
	}
	request("", "kill", "--session", first.Session)
	request("", "server", "stop")
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("server stop did not stop its listener")
	}
	if data, err = invoke("", "server", "status"); err == nil {
		t.Fatalf("status silently restarted stopped service: %s", data)
	}
}
