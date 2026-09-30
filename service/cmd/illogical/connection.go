package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"illogical/internal/mux"
)

// connection is a CLI client of the service. Events that arrive while waiting
// for a reply are kept for next.
type connection struct {
	net.Conn
	scanner *bufio.Scanner
	encoder *json.Encoder
	pending []mux.Message
	sendMu  sync.Mutex
}

func newConnection(conn net.Conn) *connection {
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64<<10), 128<<20)
	return &connection{Conn: conn, scanner: scanner, encoder: json.NewEncoder(conn)}
}

// dial connects to the local service, starting it if nothing is listening.
func dial(socket string) (*connection, error) {
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		if err := startService(socket); err != nil {
			return nil, err
		}
		// Another client may be starting the service at the same moment. Only
		// one wins the service lock; both reach the winner here.
		for range 100 {
			if conn, err = net.DialTimeout("unix", socket, 100*time.Millisecond); err == nil {
				break
			}
			time.Sleep(30 * time.Millisecond)
		}
	}
	if err != nil {
		return nil, fmt.Errorf("cannot connect to service: %w", err)
	}
	return newConnection(conn), nil
}

// dialRunning connects only to a service that is already running.
func dialRunning(socket string) (*connection, error) {
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		return nil, err
	}
	return newConnection(conn), nil
}

const maxServiceLog = 4 << 20

// startService launches `illogical serve` detached from this process's
// session and directory, logging to service.log in the state directory.
func startService(socket string) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	// The service runs from /, so relative paths must be resolved here.
	if socket, err = filepath.Abs(socket); err != nil {
		return err
	}
	directory, err := filepath.Abs(mux.DefaultDirectory())
	if err != nil {
		return err
	}
	if err = os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	path := filepath.Join(directory, "service.log")
	if info, err := os.Stat(path); err == nil && info.Size() > maxServiceLog {
		_ = os.Rename(path, path+".old")
	}
	logFile, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	cmd := exec.Command(executable, "serve", "--socket", socket)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	cmd.Env = append(os.Environ(), "ILLOGICAL_HOME="+directory)
	// Do not pin the caller's directory, which may be on removable media.
	cmd.Dir = "/"
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

func (c *connection) send(r mux.Request) error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	return c.encoder.Encode(r)
}

// request sends r and returns its reply, keeping events that arrive first.
func (c *connection) request(r mux.Request) (mux.Message, error) {
	r.ID = mux.NewID()
	if err := c.send(r); err != nil {
		return mux.Message{}, err
	}
	for {
		m, err := c.read()
		if err != nil {
			return m, err
		}
		if m.ID != r.ID {
			if m.Type == "event" {
				c.pending = append(c.pending, m)
			}
			continue
		}
		if m.Error != "" {
			return m, errors.New(m.Error)
		}
		return m, nil
	}
}

// next returns the next pushed message.
func (c *connection) next() (mux.Message, error) {
	if len(c.pending) > 0 {
		m := c.pending[0]
		c.pending = c.pending[1:]
		return m, nil
	}
	return c.read()
}

func (c *connection) read() (mux.Message, error) {
	if !c.scanner.Scan() {
		if err := c.scanner.Err(); err != nil {
			return mux.Message{}, err
		}
		return mux.Message{}, io.EOF
	}
	var m mux.Message
	err := json.Unmarshal(c.scanner.Bytes(), &m)
	return m, err
}
