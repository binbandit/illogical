package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"illogical/internal/mux"
)

const help = `illogical - persistent terminal workspaces

Usage: illogical COMMAND [options] [-- program arguments...]

  new [name]                 Create a session and terminal
  ls                         List sessions, tabs, and terminal blocks
  run / split                Launch a terminal in a new tab / split
  send TEXT                  Send text to a terminal
  send-key KEY               Send a protocol-aware key (ctrl-c, up, f1, ...)
  send-mouse BUTTON          Send mouse input (--x COL --y ROW, zero-based)
  attach / focus             Select a session/window/block in a native client
  capture                    Capture terminal text (--format text|html|vt)
  kill                       Close a terminal (--block) or session (--session)
  move / swap                Reposition a live block relative to --target
  zoom / resize              Change a layout or terminal dimensions
  session new|inspect|rename|kill  Manage sessions
  window new|inspect|rename|kill   Manage tabs
  block inspect|process|park|reset|capture|write
  client list|inspect|rename|detach  Inspect/manage connected clients
  server start|status|inspect|stop   Manage the local service
  events                     Stream workspace events
  wait                       Wait for block/window/session children to exit
  api METHOD                 Invoke a protocol operation
  connect                    Bridge stdin/stdout to the local service (SSH)
  tailscale discover         List registered illogical tailnet Services
  serve                      Run the service in the foreground
  whoami                     Query the service identity and endpoint

Options: --session/-s ID, --window/-w ID, --block/-b ID, --target/-t ID,
         --name/-n NAME, --cwd/-C PATH, --axis horizontal|vertical,
         --cols N, --rows N, --keep-open, --format text|html|vt,
         --ratio 0.1...0.9, --socket PATH, --host SSH_HOST,
         --client ID, --data TEXT, --json REQUEST_JSON, --theme THEME_JSON,
         --action press|release|repeat, --mods ctrl+shift, --x COL, --y ROW,
         --cell-width PX, --cell-height PX, --remote-executable PATH,
         --tailscale-config PATH, --login-helper PATH (serve only)

--host accepts SSH aliases or tailscale:NAME_OR_IP:PORT.

Inside a terminal, --block defaults to ILLOGICAL_BLOCK.
Window/session wait observes the children present when the wait starts.
Attach/focus selects a native client; it is not a terminal-text frontend.
The service starts automatically and outlives GUI and CLI clients.
`

func main() {
	if err := run(); err != nil {
		var status childExitStatus
		if errors.As(err, &status) {
			os.Exit(int(status))
		}
		fmt.Fprintln(os.Stderr, "illogical:", err)
		os.Exit(1)
	}
}

type connection struct {
	net.Conn
	scanner *bufio.Scanner
	encoder *json.Encoder
	pending []mux.Message
	sendMu  sync.Mutex
}

func dial(socket string) (*connection, error) {
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		exe, e := os.Executable()
		if e != nil {
			return nil, e
		}
		if e = os.MkdirAll(mux.DefaultDirectory(), 0700); e != nil {
			return nil, e
		}
		file, e := os.OpenFile(filepath.Join(mux.DefaultDirectory(), "service.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if e != nil {
			return nil, e
		}
		cmd := exec.Command(exe, "serve", "--socket", socket)
		cmd.Stdout = file
		cmd.Stderr = file
		cmd.Stdin = nil
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		e = cmd.Start()
		file.Close()
		if e != nil {
			return nil, e
		}
		_ = cmd.Process.Release()
		for i := 0; i < 100; i++ {
			conn, err = net.DialTimeout("unix", socket, 100*time.Millisecond)
			if err == nil {
				break
			}
			time.Sleep(30 * time.Millisecond)
		}
	}
	if err != nil {
		return nil, fmt.Errorf("cannot connect to service: %w", err)
	}
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64<<10), 128<<20)
	return &connection{Conn: conn, scanner: scanner, encoder: json.NewEncoder(conn)}, nil
}

func (c *connection) send(r mux.Request) error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	return c.encoder.Encode(r)
}

func (c *connection) request(r mux.Request) (mux.Message, error) {
	r.ID = mux.NewID()
	if err := c.send(r); err != nil {
		return mux.Message{}, err
	}
	for c.scanner.Scan() {
		var m mux.Message
		if err := json.Unmarshal(c.scanner.Bytes(), &m); err != nil {
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
	if err := c.scanner.Err(); err != nil {
		return mux.Message{}, err
	}
	return mux.Message{}, io.EOF
}

func (c *connection) next() (mux.Message, error) {
	if len(c.pending) > 0 {
		message := c.pending[0]
		c.pending = c.pending[1:]
		return message, nil
	}
	if !c.scanner.Scan() {
		if err := c.scanner.Err(); err != nil {
			return mux.Message{}, err
		}
		return mux.Message{}, io.EOF
	}
	var message mux.Message
	err := json.Unmarshal(c.scanner.Bytes(), &message)
	return message, err
}

type childExitStatus int

func (status childExitStatus) Error() string {
	return fmt.Sprintf("process exited with status %d", status)
}

func exitResult(code *int) error {
	if code == nil {
		return errors.New("service did not report the process exit status")
	}
	if *code == 0 {
		return nil
	}
	return childExitStatus(*code)
}

func waitForBlock(c *connection, block string) error {
	if block == "" {
		return errors.New("wait requires --block or ILLOGICAL_BLOCK")
	}
	// Enabling the subscription and reading this state are atomic on the server.
	// Preserve events arriving before the reply so even a fast exit is observed.
	message, err := c.request(mux.Request{Method: "watch"})
	if err != nil {
		return err
	}
	found := false
	if message.State != nil {
		for _, info := range message.State.Blocks {
			if info.ID == block {
				found = true
				if info.ExitCode != nil {
					return exitResult(info.ExitCode)
				}
				break
			}
		}
	}
	if !found {
		for _, event := range c.pending {
			if event.Event == "child_exited" && event.Block == block {
				return exitResult(event.ExitCode)
			}
		}
		return errors.New("block not found")
	}
	for {
		event, err := c.next()
		if err != nil {
			return fmt.Errorf("connection closed before the process exited: %w", err)
		}
		if event.Event == "child_exited" && event.Block == block {
			return exitResult(event.ExitCode)
		}
	}
}

func run() error {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "tailscale" {
		if len(args) == 2 && args[1] == "discover" {
			return discoverTailscaleServices()
		}
		return errors.New("usage: illogical tailscale discover")
	}
	if len(args) > 0 && args[0] == "remote" {
		return connectRemote(args[1:])
	}
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" {
		fmt.Print(help)
		return nil
	}
	socket := mux.SocketPath()
	r := mux.Request{Block: os.Getenv("ILLOGICAL_BLOCK")}
	var positional []string
	var host, remoteExecutable, tailscaleConfig, loginHelper string
	var explicitSocket, explicitBlock bool
	keyInput := mux.KeyInput{}
	mouseInput := mux.MouseInput{}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			r.Command = args[i+1:]
			break
		}
		if arg == "--keep-open" {
			r.KeepOpen = true
			continue
		}
		if arg == "--release" {
			r.Release = true
			continue
		}
		if !strings.HasPrefix(arg, "-") {
			positional = append(positional, arg)
			continue
		}
		if i+1 == len(args) {
			return fmt.Errorf("missing value for %s", arg)
		}
		i++
		value := args[i]
		switch arg {
		case "--socket":
			socket = value
			explicitSocket = true
		case "--login-helper":
			loginHelper = value
		case "--tailscale-config":
			tailscaleConfig = value
		case "--host":
			host = value
		case "--remote-executable":
			remoteExecutable = value
		case "--client":
			r.Client = value
		case "--kind":
			r.Kind = value
		case "--json":
			if err := json.Unmarshal([]byte(value), &r); err != nil {
				return fmt.Errorf("invalid request JSON: %w", err)
			}
			var fields map[string]json.RawMessage
			if json.Unmarshal([]byte(value), &fields) == nil {
				if _, ok := fields["block"]; ok {
					explicitBlock = true
				}
			}
		case "--theme":
			r.Theme = &mux.Theme{}
			if err := json.Unmarshal([]byte(value), r.Theme); err != nil {
				return err
			}
		case "--data":
			r.Data = []byte(value)
		case "--action":
			keyInput.Action = value
			mouseInput.Action = value
		case "--mods":
			keyInput.Mods = value
			mouseInput.Mods = value
		case "--x", "--y":
			v, err := strconv.ParseUint(value, 10, 32)
			if err != nil {
				return err
			}
			if arg == "--x" {
				mouseInput.X = uint32(v)
			} else {
				mouseInput.Y = uint32(v)
			}
		case "--cell-width", "--cell-height":
			v, err := strconv.ParseUint(value, 10, 32)
			if err != nil {
				return err
			}
			if arg == "--cell-width" {
				r.CellWidth = uint32(v)
			} else {
				r.CellHeight = uint32(v)
			}
		case "--session", "-s":
			r.Session = value
		case "--window", "-w":
			r.Window = value
		case "--block", "-b":
			r.Block = value
			explicitBlock = true
		case "--target", "-t":
			r.Target = value
		case "--name", "-n":
			r.Label = value
		case "--cwd", "-C":
			r.Cwd = value
		case "--axis":
			if value != "horizontal" && value != "vertical" {
				return errors.New("axis must be horizontal or vertical")
			}
			r.Axis = value
		case "--format":
			r.Format = value
		case "--ratio":
			v, err := strconv.ParseFloat(value, 64)
			if err != nil {
				return err
			}
			r.Ratio = v
		case "--cols", "--rows":
			v, err := strconv.ParseUint(value, 10, 16)
			if err != nil {
				return err
			}
			if arg == "--cols" {
				r.Cols = uint16(v)
			} else {
				r.Rows = uint16(v)
			}
		default:
			return fmt.Errorf("unknown option %s", arg)
		}
	}
	if len(positional) == 0 {
		return errors.New("a command is required")
	}
	command := positional[0]
	rest := positional[1:]
	if host != "" && explicitSocket {
		return errors.New("--host cannot be combined with --socket")
	}
	if host != "" && !explicitBlock {
		r.Block = ""
	}
	if command == "server" && len(rest) > 0 && rest[0] == "run" {
		command = "serve"
	}
	if host != "" && (command == "serve" || command == "connect" || command == "remote-endpoint") {
		return errors.New("use remote HOST for a relay; this command requires a local endpoint")
	}
	if command == "serve" {
		s, err := mux.NewServer(mux.DefaultDirectory(), socket, mux.WithLoginHelper(loginHelper))
		if err != nil {
			return err
		}
		defer s.Close()
		if tailscaleConfig != "" {
			cfg, err := mux.LoadTailscaleConfig(tailscaleConfig)
			if err != nil {
				return err
			}
			transport, err := s.StartTailscale(cfg)
			if err != nil {
				return err
			}
			defer transport.Close()
		}
		interrupt := make(chan os.Signal, 1)
		signal.Notify(interrupt, syscall.SIGTERM, syscall.SIGINT)
		defer signal.Stop(interrupt)
		go func() { <-interrupt; s.Close() }()
		log.Printf("illogical service listening at %s", socket)
		return s.Run()
	}
	var c *connection
	var err error
	if command == "server" && len(rest) > 0 && (rest[0] == "status" || rest[0] == "stop" || rest[0] == "inspect") && host == "" {
		var conn net.Conn
		conn, err = net.DialTimeout("unix", socket, time.Second)
		if err == nil {
			scanner := bufio.NewScanner(conn)
			scanner.Buffer(make([]byte, 64<<10), 128<<20)
			c = &connection{Conn: conn, scanner: scanner, encoder: json.NewEncoder(conn)}
		}
	} else {
		c, err = dialTarget(socket, host, remoteExecutable)
	}
	if err != nil {
		return err
	}
	defer c.Close()
	if command == "remote-endpoint" {
		fields := strings.Fields(os.Getenv("SSH_CONNECTION"))
		if len(fields) != 4 {
			return errors.New("remote pairing must be bootstrapped through SSH")
		}
		response, err := c.request(mux.Request{Method: "remote.pair", Label: fields[2]})
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(response)
	}
	if command == "connect" {
		errors := make(chan error, 2)
		go func() { _, e := io.Copy(c.Conn, os.Stdin); errors <- e }()
		go func() { _, e := io.Copy(os.Stdout, c.Conn); errors <- e }()
		return <-errors
	}
	if _, err := c.request(mux.Request{Method: "client.update", Kind: "cli", Label: "illogical " + command}); err != nil {
		return err
	}
	switch command {
	case "ls", "list":
		r.Method = "state"
	case "new":
		r.Method = "session.new"
		if r.Label == "" && len(rest) > 0 {
			r.Label = rest[0]
		}
	case "run":
		r.Method = "window.new"
	case "split":
		r.Method = "block.split"
	case "send":
		r.Method = "block.write"
		r.Data = []byte(strings.Join(rest, " "))
	case "send-key":
		r.Method = "block.key"
		keyInput.Name = strings.Join(rest, " ")
		r.Key = &keyInput
	case "send-mouse":
		r.Method = "block.mouse"
		mouseInput.Button = strings.Join(rest, " ")
		r.Mouse = &mouseInput
	case "attach", "focus":
		r.Method = "focus"
	case "whoami":
		r.Method = "whoami"
	case "client", "server":
		action := "list"
		if command == "server" {
			action = "status"
		}
		if len(rest) > 0 {
			action = rest[0]
		}
		if command == "server" && action == "start" {
			action = "status"
		}
		r.Method = command + "." + action
		if command == "client" && len(rest) > 1 {
			r.Client = rest[1]
		}
	case "capture":
		r.Method = "block.capture"
	case "kill":
		if r.Session != "" {
			r.Method = "session.kill"
		} else {
			r.Method = "block.kill"
		}
	case "move", "swap":
		r.Method = "block." + command
	case "zoom":
		r.Method = "window.zoom"
	case "resize":
		if r.Ratio > 0 {
			r.Method = "layout.resize"
		} else {
			r.Method = "block.resize"
		}
	case "session", "window", "block":
		if len(rest) == 0 {
			return errors.New("resource action is required")
		}
		if command == "block" && rest[0] == "call" {
			if len(rest) >= 3 {
				r.Block = rest[1]
				explicitBlock = true
				rest = append([]string{rest[2]}, rest[3:]...)
			} else if len(rest) >= 2 {
				rest = rest[1:]
			} else {
				return errors.New("block call requires a method")
			}
		}
		r.Method = command + "." + rest[0]
		isWrite := command == "block" && rest[0] == "write"
		if len(rest) > 1 && (!isWrite || !explicitBlock && (r.Block == "" || len(rest) > 2 || r.Data != nil)) {
			if command == "session" {
				r.Session = rest[1]
			} else if command == "window" {
				r.Window = rest[1]
			} else {
				r.Block = rest[1]
			}
		}
		if command == "session" && rest[0] == "new" && r.Label == "" && len(rest) > 1 {
			r.Label = rest[1]
		}
		if command == "block" && rest[0] == "write" {
			payload := rest[1:]
			if len(payload) > 0 && payload[0] == r.Block {
				payload = payload[1:]
			}
			if len(payload) > 0 {
				r.Data = []byte(strings.Join(payload, " "))
			}
		}
	case "api":
		if len(rest) == 0 {
			r.Method = "api"
		} else {
			r.Method = rest[0]
		}
	case "events", "wait":
		r.Method = "watch"
	default:
		return fmt.Errorf("unknown command %s", command)
	}
	if r.Cwd != "" && host == "" && r.Method != "block.list_dir" && r.Method != "directory.list" {
		r.Cwd, err = filepath.Abs(r.Cwd)
		if err != nil {
			return err
		}
	}
	if r.Method == "window.zoom" && r.Window == "" {
		r.Window = r.Block
	}
	if (command == "events") && !explicitBlock && (r.Session != "" || r.Window != "") {
		r.Block = ""
	}
	if command == "wait" {
		return waitForResource(c, r)
	}
	m, err := c.request(r)
	if err != nil {
		return err
	}
	if command == "events" {
		encoder := json.NewEncoder(os.Stdout)
		for {
			event, err := c.next()
			if err != nil {
				return err
			}
			if !eventMatches(r, event, m.State) {
				if event.State != nil {
					m.State = event.State
				}
				continue
			}
			if event.State != nil {
				m.State = event.State
			}
			if err := encoder.Encode(event); err != nil {
				return err
			}
		}
	}
	if r.Method == "block.capture" || r.Method == "block.format" {
		fmt.Print(m.Text)
		return nil
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(m)
}
