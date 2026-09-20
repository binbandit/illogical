package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"illogical/internal/mux"
)

// The client is the real system SSH executable, authenticated with private test
// keys against a loopback SSH server. Its channel reaches a real private mux.
func TestRemoteCLIRequestsUseAuthenticatedSSHFallback(t *testing.T) {
	if _, err := os.Stat("/usr/bin/ssh"); err != nil {
		t.Skip("system SSH client unavailable")
	}
	directory, err := os.MkdirTemp("/tmp", "ilg-remote-cli-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "mux.sock")
	server, err := mux.NewServer(directory, socket)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go func() { _ = server.Run() }()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := os.Stat(socket); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("private service did not listen")
		}
		time.Sleep(time.Millisecond)
	}
	clientPublic, clientPrivate, _ := ed25519.GenerateKey(rand.Reader)
	_, hostPrivate, _ := ed25519.GenerateKey(rand.Reader)
	clientKey, _ := ssh.NewPublicKey(clientPublic)
	hostKey, _ := ssh.NewSignerFromKey(hostPrivate)
	privatePEM, _ := ssh.MarshalPrivateKey(clientPrivate, "isolated test")
	identity := filepath.Join(directory, "identity")
	if err := os.WriteFile(identity, pem.EncodeToMemory(privatePEM), 0600); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	knownHosts := filepath.Join(directory, "known_hosts")
	known := fmt.Sprintf("[127.0.0.1]:%s %s", port, ssh.MarshalAuthorizedKey(hostKey.PublicKey()))
	if err := os.WriteFile(knownHosts, []byte(known), 0600); err != nil {
		t.Fatal(err)
	}
	config := &ssh.ServerConfig{PublicKeyCallback: func(metadata ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
		if metadata.User() != "fixture" || !bytes.Equal(key.Marshal(), clientKey.Marshal()) {
			return nil, fmt.Errorf("unauthorized test key")
		}
		return &ssh.Permissions{}, nil
	}}
	config.AddHostKey(hostKey)
	var probes, relays atomic.Int32
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				peer, channels, requests, err := ssh.NewServerConn(conn, config)
				if err != nil {
					conn.Close()
					return
				}
				defer peer.Close()
				go ssh.DiscardRequests(requests)
				for incoming := range channels {
					if incoming.ChannelType() != "session" {
						_ = incoming.Reject(ssh.UnknownChannelType, "session required")
						continue
					}
					channel, requests, err := incoming.Accept()
					if err != nil {
						return
					}
					go func() {
						defer channel.Close()
						for request := range requests {
							if request.Type != "exec" {
								_ = request.Reply(false, nil)
								continue
							}
							var payload struct{ Command string }
							if ssh.Unmarshal(request.Payload, &payload) != nil {
								_ = request.Reply(false, nil)
								return
							}
							_ = request.Reply(true, nil)
							if strings.HasSuffix(payload.Command, " remote-endpoint") {
								probes.Add(1)
								_, _ = channel.SendRequest("exit-status", false, ssh.Marshal(struct{ Code uint32 }{1}))
								return
							}
							if !strings.HasSuffix(payload.Command, " connect") {
								return
							}
							relays.Add(1)
							local, err := net.Dial("unix", socket)
							if err != nil {
								return
							}
							defer local.Close()
							done := make(chan struct{}, 2)
							go func() { _, _ = io.Copy(local, channel); done <- struct{}{} }()
							go func() { _, _ = io.Copy(channel, local); done <- struct{}{} }()
							<-done
							return
						}
					}()
				}
			}()
		}
	}()
	command := func(host, executable, action string) *exec.Cmd {
		if host != "fixture-host" || executable != "fixture-illogical" {
			t.Errorf("wrong remote route: %q %q", host, executable)
		}
		cmd := remoteCommand("fixture@127.0.0.1", executable, action)
		args := []string{"-F", "/dev/null", "-i", identity, "-p", port, "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=" + knownHosts, "-o", "GlobalKnownHostsFile=/dev/null"}
		cmd.Args = append([]string{cmd.Path}, append(args, cmd.Args[1:]...)...)
		return cmd
	}
	dialRemote := func(host, executable string) (net.Conn, error) { return openRemoteUsing(host, executable, command) }
	c, err := dialTargetUsing("/tmp/this-local-socket-must-not-be-used", "fixture-host", "fixture-illogical", dialRemote)
	if err != nil {
		t.Fatal(err)
	}
	message, err := c.request(mux.Request{Method: "session.new", Label: "remote once", Cwd: directory, Command: []string{"/bin/sh", "-c", "printf REMOTE; read line"}, KeepOpen: true})
	if err != nil {
		c.Close()
		t.Fatal(err)
	}
	block := message.Block
	state, err := c.request(mux.Request{Method: "state"})
	if err != nil || state.State == nil || len(state.State.Sessions) != 1 || len(state.State.Blocks) != 1 {
		c.Close()
		t.Fatalf("remote creation was missing or duplicated: %+v %v", state, err)
	}
	pid := state.State.Blocks[0].PID
	if pid <= 0 || block == "" {
		c.Close()
		t.Fatal("real remote child was not created")
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	c, err = dialTargetUsing("/tmp/this-local-socket-must-not-be-used", "fixture-host", "fixture-illogical", dialRemote)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	state, err = c.request(mux.Request{Method: "state"})
	if err != nil || state.State == nil || len(state.State.Blocks) != 1 || state.State.Blocks[0].PID != pid {
		t.Fatalf("SSH reconnect lost process identity: %+v %v", state, err)
	}
	if probes.Load() != 2 || relays.Load() != 2 {
		t.Fatalf("transport attempts %d probes / %d relays", probes.Load(), relays.Load())
	}
}

func TestSSHConnectionCloseUnblocksReadAndReapsProcess(t *testing.T) {
	conn, err := startSSHConnection(exec.Command("cat"), "fixture")
	if err != nil {
		t.Fatal(err)
	}
	readFinished := make(chan error, 1)
	go func() { var b [1]byte; _, err := conn.Read(b[:]); readFinished <- err }()
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-readFinished:
		if err == nil {
			t.Fatal("blocked read unexpectedly succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("close did not cancel SSH pipe read")
	}
	if conn.(*sshConnection).process.ProcessState == nil {
		t.Fatal("SSH process was not reaped")
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
}
