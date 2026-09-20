package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func TestRemoteProbeCancellationAndBoundedOutput(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := readRemoteProbe(ctx, exec.Command("sleep", "30")); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("probe cancellation: %v", err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("cancelled probe was not reaped promptly")
	}
	ctx, cancel = context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	data, err := readRemoteProbe(ctx, exec.Command("/bin/sh", "-c", "head -c 131072 /dev/zero"))
	if err == nil || len(data) > 64<<10 {
		t.Fatalf("unbounded endpoint output: bytes=%d, err=%v", len(data), err)
	}
}

func TestRemoteSignalFixture(t *testing.T) {
	if os.Getenv("ILLOGICAL_TEST_REMOTE_SIGNAL") != "1" {
		return
	}
	connection, err := startSSHConnection(exec.Command("cat"), "fixture")
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	fmt.Println(connection.(*sshConnection).process.Process.Pid)
	var data [1]byte
	if _, err := connection.Read(data[:]); err == nil {
		t.Fatal("terminated transport kept reading")
	}
}

func TestRemoteRelayTerminationReapsSSHChild(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=^TestRemoteSignalFixture$")
	command.Env = append(os.Environ(), "ILLOGICAL_TEST_REMOTE_SIGNAL=1")
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	command.Stderr = os.Stderr
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	defer command.Process.Kill()
	scanner := bufio.NewScanner(output)
	if !scanner.Scan() {
		t.Fatal("missing relay child PID")
	}
	pid, err := strconv.Atoi(scanner.Text())
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() { finished <- command.Wait() }()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatalf("relay did not close cleanly: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("relay termination did not unblock/reap")
	}
	if err := syscall.Kill(pid, 0); err != syscall.ESRCH {
		t.Fatalf("SSH child remains after relay exit: pid=%d err=%v", pid, err)
	}
}
