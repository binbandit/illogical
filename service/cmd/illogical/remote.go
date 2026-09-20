package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	"illogical/internal/mux"
)

func remoteCommand(host, executable, action string) *exec.Cmd {
	quote := func(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }
	path := quote(executable)
	if strings.HasPrefix(executable, "~/") {
		path = "\"$HOME\"/" + quote(strings.TrimPrefix(executable, "~/"))
	}
	return exec.Command("ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "--", host, path+" "+action)
}

func connectRemote(args []string) error {
	if len(args) < 1 || len(args) > 2 {
		return errors.New("usage: illogical remote user@host [path-to-illogical]")
	}
	executable := ""
	if len(args) == 2 {
		executable = args[1]
	}
	conn, err := openRemote(args[0], executable)
	if err != nil {
		return err
	}
	defer conn.Close()
	done := make(chan error, 2)
	go func() { _, err := io.Copy(conn, os.Stdin); done <- err }()
	go func() { _, err := io.Copy(os.Stdout, conn); done <- err }()
	return <-done
}

func openRemote(host, executable string) (net.Conn, error) {
	if strings.HasPrefix(host, "tailscale:") {
		return dialTailscale(strings.TrimPrefix(host, "tailscale:"))
	}
	return openRemoteUsing(host, executable, remoteCommand)
}

func openRemoteUsing(host, executable string, command func(string, string, string) *exec.Cmd) (net.Conn, error) {
	if !regexp.MustCompile(`^[A-Za-z0-9_.@:\[\]-]+$`).MatchString(host) || strings.HasPrefix(host, "-") {
		return nil, errors.New("invalid SSH host")
	}
	if executable == "" {
		executable = "~/.local/bin/illogical"
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	probe := command(host, executable, "remote-endpoint")
	// No terminal bytes have been forwarded before QUIC succeeds, so fallback
	// cannot duplicate input or replay a partially executed command.
	probeContext, cancelProbe := context.WithTimeout(ctx, 10*time.Second)
	output, err := readRemoteProbe(probeContext, probe)
	cancelProbe()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err == nil {
		var response mux.Message
		if json.Unmarshal(output, &response) == nil && response.Credentials != nil {
			ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
			conn, err := mux.DialRemote(ctx, *response.Credentials)
			cancel()
			if err == nil {
				return conn, nil
			}
		}
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	connection, err := startSSHConnection(command(host, executable, "connect"), host)
	if ctx.Err() != nil {
		if connection != nil {
			_ = connection.Close()
		}
		return nil, ctx.Err()
	}
	return connection, err
}

// A remote shell must not keep a cancelled bootstrap alive or grow its output
// indefinitely. Endpoint credentials fit comfortably inside this bounded buffer.
type remoteProbeBuffer struct{ buffer bytes.Buffer }

func (b *remoteProbeBuffer) Write(data []byte) (int, error) {
	if len(data) > 64<<10-b.buffer.Len() {
		return 0, errors.New("remote endpoint reply exceeds 64 KiB")
	}
	return b.buffer.Write(data)
}
func readRemoteProbe(ctx context.Context, command *exec.Cmd) ([]byte, error) {
	var output remoteProbeBuffer
	command.Stdout = &output
	command.Stderr = io.Discard
	command.WaitDelay = time.Second
	if err := command.Start(); err != nil {
		return nil, err
	}
	finished := make(chan error, 1)
	go func() { finished <- command.Wait() }()
	select {
	case err := <-finished:
		return output.buffer.Bytes(), err
	case <-ctx.Done():
		_ = command.Process.Kill()
		<-finished
		return nil, ctx.Err()
	}
}
