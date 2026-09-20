package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// Ordinary CLI requests use the same authenticated transport as the native
// relay. No request is submitted until transport selection has finished.
func dialTarget(socket, host, executable string) (*connection, error) {
	return dialTargetUsing(socket, host, executable, openRemote)
}

func dialTargetUsing(socket, host, executable string, remote func(string, string) (net.Conn, error)) (*connection, error) {
	if host == "" {
		return dial(socket)
	}
	conn, err := remote(host, executable)
	if err != nil {
		return nil, err
	}
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64<<10), 128<<20)
	return &connection{Conn: conn, scanner: scanner, encoder: json.NewEncoder(conn)}, nil
}

type sshConnection struct {
	reader    io.ReadCloser
	writer    io.WriteCloser
	process   *exec.Cmd
	host      string
	closeOnce sync.Once
	closed    chan struct{}
	signals   chan os.Signal
}

func startSSHConnection(command *exec.Cmd, host string) (net.Conn, error) {
	input, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := command.StdoutPipe()
	if err != nil {
		input.Close()
		return nil, err
	}
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		input.Close()
		output.Close()
		return nil, err
	}
	connection := &sshConnection{reader: output, writer: input, process: command, host: host, closed: make(chan struct{}), signals: make(chan os.Signal, 1)}
	signal.Notify(connection.signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		select {
		case <-connection.signals:
			_ = connection.Close()
		case <-connection.closed:
		}
	}()
	return connection, nil
}

func (c *sshConnection) Read(data []byte) (int, error)  { return c.reader.Read(data) }
func (c *sshConnection) Write(data []byte) (int, error) { return c.writer.Write(data) }
func (c *sshConnection) LocalAddr() net.Addr            { return sshAddress("local") }
func (c *sshConnection) RemoteAddr() net.Addr           { return sshAddress(c.host) }
func (c *sshConnection) Close() error {
	c.closeOnce.Do(func() {
		signal.Stop(c.signals)
		close(c.closed)
		// Closing a client ends only the SSH transport. The remote service was
		// already started independently by the remote `connect` command.
		c.writer.Close()
		c.reader.Close()
		_ = c.process.Process.Kill()
		_ = c.process.Wait()
	})
	return nil
}

var errSSHDeadline = errors.New("SSH stream deadlines are not supported")

func (c *sshConnection) SetDeadline(time.Time) error      { return errSSHDeadline }
func (c *sshConnection) SetReadDeadline(time.Time) error  { return errSSHDeadline }
func (c *sshConnection) SetWriteDeadline(time.Time) error { return errSSHDeadline }

type sshAddress string

func (a sshAddress) Network() string { return "ssh" }
func (a sshAddress) String() string  { return string(a) }
