package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

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
  clear                      Clear the screen and scrollback (like Cmd-K)
  kill                       Close a terminal (--block) or session (--session)
  move / swap                Reposition a live block relative to --target
  zoom / resize              Change a layout or terminal dimensions
  session new|inspect|rename|kill  Manage sessions
  window new|inspect|rename|kill|move  Manage tabs
  block inspect|process|park|reset|clear|capture|write
  client list|inspect|rename|detach  Inspect/manage connected clients
  server start|status|inspect|stop   Manage the local service
  events                     Stream workspace events
  wait                       Wait for block/window/session children to exit
  api METHOD                 Invoke a protocol operation
  connect                    Bridge stdin/stdout to the local service (SSH)
  tailscale discover         List registered illogical tailnet Services
  serve                      Run the service in the foreground
  whoami                     Query the service identity and endpoint
  version                    Print the version

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
	if err := run(os.Args[1:]); err != nil {
		var status childExitStatus
		if errors.As(err, &status) {
			os.Exit(int(status))
		}
		fmt.Fprintln(os.Stderr, "illogical:", err)
		os.Exit(1)
	}
}

type options struct {
	request          mux.Request
	positional       []string
	key              mux.KeyInput
	mouse            mux.MouseInput
	socket           string
	explicitSocket   bool
	explicitBlock    bool
	host             string
	remoteExecutable string
	tailscaleConfig  string
	loginHelper      string
}

func run(args []string) error {
	switch {
	case len(args) == 0 || args[0] == "help" || args[0] == "--help":
		fmt.Print(help)
		return nil
	case args[0] == "version" || args[0] == "--version":
		fmt.Println(mux.Version)
		return nil
	case args[0] == "tailscale":
		if len(args) == 2 && args[1] == "discover" {
			return discoverTailscaleServices()
		}
		return errors.New("usage: illogical tailscale discover")
	case args[0] == "remote":
		return connectRemote(args[1:])
	}
	o, err := parseOptions(args)
	if err != nil {
		return err
	}
	if len(o.positional) == 0 {
		return errors.New("a command is required")
	}
	command, rest := o.positional[0], o.positional[1:]
	if command == "server" && len(rest) > 0 && rest[0] == "run" {
		command = "serve"
	}
	if o.host != "" {
		if o.explicitSocket {
			return errors.New("--host cannot be combined with --socket")
		}
		if command == "serve" || command == "connect" || command == "remote-endpoint" {
			return errors.New("use remote HOST for a relay; this command requires a local endpoint")
		}
		// ILLOGICAL_BLOCK names a local terminal, not one on the remote host.
		if !o.explicitBlock {
			o.request.Block = ""
		}
	}
	if command == "serve" {
		return serve(o)
	}

	var c *connection
	if command == "server" && len(rest) > 0 && (rest[0] == "status" || rest[0] == "stop" || rest[0] == "inspect") && o.host == "" {
		c, err = dialRunning(o.socket) // Asking about the service must not start it.
	} else {
		c, err = dialTarget(o.socket, o.host, o.remoteExecutable)
	}
	if err != nil {
		return err
	}
	defer c.Close()
	switch command {
	case "remote-endpoint":
		return pairRemoteEndpoint(c)
	case "connect":
		done := make(chan error, 2)
		go func() { _, err := io.Copy(c.Conn, os.Stdin); done <- err }()
		go func() { _, err := io.Copy(os.Stdout, c.Conn); done <- err }()
		return <-done
	}
	if _, err := c.request(mux.Request{Method: "client.update", Kind: "cli", Label: "illogical " + command}); err != nil {
		return err
	}
	r, err := buildRequest(command, rest, &o)
	if err != nil {
		return err
	}
	switch command {
	case "wait":
		return waitForResource(c, r)
	case "events":
		return streamEvents(c, r)
	}
	m, err := c.request(r)
	if err != nil {
		return err
	}
	if r.Method == "block.capture" || r.Method == "block.format" {
		fmt.Print(m.Text)
		return nil
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(m)
}

func parseOptions(args []string) (options, error) {
	o := options{socket: mux.SocketPath(), request: mux.Request{Block: os.Getenv("ILLOGICAL_BLOCK")}}
	r := &o.request
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--":
			r.Command = args[i+1:]
			return o, nil
		case arg == "--keep-open":
			r.KeepOpen = true
			continue
		case arg == "--release":
			r.Release = true
			continue
		case !strings.HasPrefix(arg, "-"):
			o.positional = append(o.positional, arg)
			continue
		case i+1 == len(args):
			return o, fmt.Errorf("missing value for %s", arg)
		}
		i++
		value := args[i]
		var err error
		switch arg {
		case "--socket":
			o.socket, o.explicitSocket = value, true
		case "--login-helper":
			o.loginHelper = value
		case "--tailscale-config":
			o.tailscaleConfig = value
		case "--host":
			o.host = value
		case "--remote-executable":
			o.remoteExecutable = value
		case "--client":
			r.Client = value
		case "--kind":
			r.Kind = value
		case "--json":
			if err = json.Unmarshal([]byte(value), r); err != nil {
				return o, fmt.Errorf("invalid request JSON: %w", err)
			}
			var fields map[string]json.RawMessage
			if json.Unmarshal([]byte(value), &fields) == nil && fields["block"] != nil {
				o.explicitBlock = true
			}
		case "--theme":
			r.Theme = &mux.Theme{}
			err = json.Unmarshal([]byte(value), r.Theme)
		case "--data":
			r.Data = []byte(value)
		case "--action":
			o.key.Action, o.mouse.Action = value, value
		case "--mods":
			o.key.Mods, o.mouse.Mods = value, value
		case "--x":
			o.mouse.X, err = parseUint[uint32](value)
		case "--y":
			o.mouse.Y, err = parseUint[uint32](value)
		case "--cell-width":
			r.CellWidth, err = parseUint[uint32](value)
		case "--cell-height":
			r.CellHeight, err = parseUint[uint32](value)
		case "--cols":
			r.Cols, err = parseUint[uint16](value)
		case "--rows":
			r.Rows, err = parseUint[uint16](value)
		case "--session", "-s":
			r.Session = value
		case "--window", "-w":
			r.Window = value
		case "--block", "-b":
			r.Block, o.explicitBlock = value, true
		case "--target", "-t":
			r.Target = value
		case "--name", "-n":
			r.Label = value
		case "--cwd", "-C":
			r.Cwd = value
		case "--axis":
			if value != "horizontal" && value != "vertical" {
				return o, errors.New("axis must be horizontal or vertical")
			}
			r.Axis = value
		case "--format":
			r.Format = value
		case "--ratio":
			r.Ratio, err = strconv.ParseFloat(value, 64)
		default:
			return o, fmt.Errorf("unknown option %s", arg)
		}
		if err != nil {
			return o, fmt.Errorf("%s: %w", arg, err)
		}
	}
	return o, nil
}

func parseUint[T uint16 | uint32](value string) (T, error) {
	v, err := strconv.ParseUint(value, 10, 32)
	if err == nil && uint64(T(v)) != v {
		err = strconv.ErrRange
	}
	return T(v), err
}

// buildRequest maps a CLI command onto a protocol request.
func buildRequest(command string, rest []string, o *options) (mux.Request, error) {
	r := o.request
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
		o.key.Name = strings.Join(rest, " ")
		r.Key = &o.key
	case "send-mouse":
		r.Method = "block.mouse"
		o.mouse.Button = strings.Join(rest, " ")
		r.Mouse = &o.mouse
	case "attach", "focus":
		r.Method = "focus"
	case "whoami":
		r.Method = "whoami"
	case "capture":
		r.Method = "block.capture"
	case "clear":
		r.Method = "block.clear"
	case "kill":
		r.Method = "block.kill"
		if r.Session != "" {
			r.Method = "session.kill"
		}
	case "move", "swap":
		r.Method = "block." + command
	case "zoom":
		r.Method = "window.zoom"
		if r.Window == "" {
			r.Window = r.Block
		}
	case "resize":
		r.Method = "block.resize"
		if r.Ratio > 0 {
			r.Method = "layout.resize"
		}
	case "client", "server":
		action := "list"
		if command == "server" {
			action = "status"
		}
		if len(rest) > 0 {
			action = rest[0]
		}
		if command == "server" && action == "start" {
			action = "status" // Connecting already started it.
		}
		r.Method = command + "." + action
		if command == "client" && len(rest) > 1 {
			r.Client = rest[1]
		}
	case "session", "window", "block":
		if err := resourceRequest(command, rest, o, &r); err != nil {
			return r, err
		}
	case "api":
		r.Method = "api"
		if len(rest) > 0 {
			r.Method = rest[0]
		}
	case "events", "wait":
		r.Method = "watch"
		// A session or window scope replaces the ILLOGICAL_BLOCK default.
		if command == "events" && !o.explicitBlock && (r.Session != "" || r.Window != "") {
			r.Block = ""
		}
	default:
		return r, fmt.Errorf("unknown command %s", command)
	}
	if r.Cwd != "" && o.host == "" && r.Method != "block.list_dir" && r.Method != "directory.list" {
		cwd, err := filepath.Abs(r.Cwd)
		if err != nil {
			return r, err
		}
		r.Cwd = cwd
	}
	return r, nil
}

// resourceRequest handles `session|window|block ACTION [ID] [ARGS...]` and
// `block call ID METHOD`.
func resourceRequest(command string, rest []string, o *options, r *mux.Request) error {
	if len(rest) == 0 {
		return errors.New("resource action is required")
	}
	if command == "block" && rest[0] == "call" {
		switch {
		case len(rest) >= 3:
			r.Block, o.explicitBlock = rest[1], true
			rest = rest[2:]
		case len(rest) == 2:
			rest = rest[1:]
		default:
			return errors.New("block call requires a method")
		}
	}
	action := rest[0]
	r.Method = command + "." + action
	isWrite := command == "block" && action == "write"
	// For block write, a lone argument is the text unless no block is known.
	if len(rest) > 1 && (!isWrite || !o.explicitBlock && (r.Block == "" || len(rest) > 2 || r.Data != nil)) {
		switch command {
		case "session":
			r.Session = rest[1]
		case "window":
			r.Window = rest[1]
		default:
			r.Block = rest[1]
		}
	}
	if command == "session" && action == "new" && r.Label == "" && len(rest) > 1 {
		r.Label = rest[1]
	}
	if isWrite {
		payload := rest[1:]
		if len(payload) > 0 && payload[0] == r.Block {
			payload = payload[1:]
		}
		if len(payload) > 0 {
			r.Data = []byte(strings.Join(payload, " "))
		}
	}
	return nil
}

func serve(o options) error {
	s, err := mux.NewServer(mux.DefaultDirectory(), o.socket, mux.WithLoginHelper(o.loginHelper))
	if err != nil {
		return err
	}
	defer s.Close()
	if o.tailscaleConfig != "" {
		config, err := mux.LoadTailscaleConfig(o.tailscaleConfig)
		if err != nil {
			return err
		}
		transport, err := s.StartTailscale(config)
		if err != nil {
			return err
		}
		defer transport.Close()
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(signals)
	go func() { <-signals; s.Close() }()
	log.Printf("illogical %s service listening at %s", mux.Version, o.socket)
	return s.Run()
}

// pairRemoteEndpoint issues QUIC credentials for the SSH client that ran us.
func pairRemoteEndpoint(c *connection) error {
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

// streamEvents prints events in the requested scope until disconnected.
func streamEvents(c *connection, r mux.Request) error {
	m, err := c.request(r)
	if err != nil {
		return err
	}
	state := m.State
	if session := findStateSession(state, r.Session); session != nil {
		r.Session = session.ID // Follow the session through renames.
	}
	encoder := json.NewEncoder(os.Stdout)
	for {
		event, err := c.next()
		if err != nil {
			return err
		}
		matches := eventMatches(r, event, state)
		if event.State != nil {
			state = event.State
		}
		if !matches {
			continue
		}
		if err := encoder.Encode(event); err != nil {
			return err
		}
	}
}
