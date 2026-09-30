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

// The app and a CLI may both find no service and start one at once. Exactly
// one must win, and both must end up talking to it.
func TestConcurrentServiceStartsYieldOneService(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "illogical-race-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "s.sock")
	env := append(os.Environ(), "ILLOGICAL_TEST_CLI=1", "ILLOGICAL_HOME="+directory, "ILLOGICAL_SOCKET="+socket, "GORACE=atexit_sleep_ms=0")
	var services []*exec.Cmd
	exited := make(chan error, 4)
	for range 4 {
		cmd := exec.Command(os.Args[0], "-test.run=^TestCLIProcessHelper$", "--", "serve")
		cmd.Env = env
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		services = append(services, cmd)
		go func() { exited <- cmd.Wait() }()
	}
	defer func() {
		for _, cmd := range services {
			_ = cmd.Process.Kill()
		}
	}()
	for range 3 {
		select {
		case err := <-exited:
			if err == nil {
				t.Fatal("a losing service exited successfully")
			}
		case <-time.After(10 * time.Second):
			t.Fatal("losing services kept running")
		}
	}
	c, err := dialRunning(socket)
	for deadline := time.Now().Add(5 * time.Second); err != nil && time.Now().Before(deadline); {
		time.Sleep(10 * time.Millisecond)
		c, err = dialRunning(socket)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err := c.request(mux.Request{Method: "server.stop"}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-exited:
		if err != nil {
			t.Fatalf("winning service: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("winning service did not stop")
	}
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
