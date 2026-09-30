package mux

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	vt "go.mitchellh.com/libghostty"
)

// Block is one terminal: a child process on a PTY and the authoritative
// emulator that parses its output. Clients render replicas fed from it.
// Unless noted, fields are guarded by mu.
type Block struct {
	mu     sync.Mutex
	server *Server
	info   BlockInfo
	cmd    *exec.Cmd
	pty    *os.File
	closed bool
	done   chan struct{} // Closed by close.
	exited chan struct{} // Closed once the child has been reaped.
	io     sync.WaitGroup

	// The emulator is nil while parked; see park.go.
	terminal         *vt.Terminal
	lastOutput       time.Time
	parkRetryAfter   time.Time
	parkedScrollback uint64
	snapshotPath     string

	replay       replayBuffer
	graphics     graphicsTracker
	resetPending chan struct{}
	theme        *Theme
	desiredSizes map[string]DesiredSize
	cellWidth    uint32
	cellHeight   uint32

	// Input and replies to terminal queries, written by writeLoop.
	input         chan []byte
	replies       []byte
	replyOverflow bool
	replyReady    chan struct{}

	// Output flow control; see readLoop.
	inputWake          chan struct{}
	viewerWake         chan struct{}
	inputReadAllowance int    // Owned by readLoop.
	primaryViewer      string // Owned by readLoop.
}

const (
	defaultCols       = 100
	defaultRows       = 30
	maxScrollback     = 64 << 20
	hangupGracePeriod = 2 * time.Second
)

// newBlock starts r.Command, or the user's login shell, on a new PTY.
func (s *Server) newBlock(r Request, id string) (*Block, error) {
	if id == "" {
		id = NewID()
	}
	cwd := normalizeDirectory(r.Cwd)
	if cwd == "" {
		cwd, _ = os.UserHomeDir()
	}
	if !filepath.IsAbs(cwd) {
		return nil, errors.New("working directory must be an absolute path")
	}
	if stat, err := os.Stat(cwd); err != nil || !stat.IsDir() {
		return nil, fmt.Errorf("directory is unavailable: %s", cwd)
	}
	shell := loginShell()
	command := r.Command
	if len(command) == 0 {
		// A login shell reads the profile files that set PATH and friends.
		command = []string{shell, "-l"}
	}
	cols, rows := r.Cols, r.Rows
	if cols == 0 {
		cols = defaultCols
	}
	if rows == 0 {
		rows = defaultRows
	}
	if !validSize(cols, rows) {
		return nil, errSizeBounds
	}
	host, _ := os.Hostname()
	b := &Block{
		server:       s,
		info:         BlockInfo{ID: id, Label: r.Label, Host: host, Session: r.Session, Window: r.Window, Title: filepath.Base(command[0]), Cwd: cwd, Cols: cols, Rows: rows, Command: command, KeepOpen: r.KeepOpen},
		lastOutput:   time.Now(),
		snapshotPath: filepath.Join(s.directory, "snapshots", id+".gz"),
		done:         make(chan struct{}),
		exited:       make(chan struct{}),
		input:        make(chan []byte, 64),
		replyReady:   make(chan struct{}, 1),
		inputWake:    make(chan struct{}, 1),
		viewerWake:   make(chan struct{}, 1),
	}
	b.replay.epoch = NewID()
	terminal, err := vt.NewTerminal(vt.WithSize(cols, rows), vt.WithContinuationMaxBytes(1<<20), vt.WithMaxScrollbackBytes(maxScrollback))
	if err != nil {
		return nil, err
	}
	_ = terminal.SetPwd(cwd)
	if err = b.adoptTerminal(terminal); err != nil {
		return nil, err
	}
	b.cmd = exec.Command(command[0], command[1:]...)
	b.cmd.Dir = cwd
	b.cmd.Env = s.childEnvironment(id, shell)
	if err = s.prepareLoginCommand(b.cmd); err != nil {
		b.terminal.Close()
		return nil, err
	}
	master, err := pty.StartWithSize(b.cmd, &pty.Winsize{Cols: cols, Rows: rows})
	if err != nil {
		b.terminal.Close()
		return nil, err
	}
	if b.pty, err = pollablePTY(master); err != nil {
		_ = b.cmd.Process.Kill()
		_ = b.cmd.Wait()
		b.terminal.Close()
		return nil, fmt.Errorf("initialize terminal I/O: %w", err)
	}
	b.info.PID = b.cmd.Process.Pid
	b.io.Add(2)
	go b.writeLoop()
	go b.readLoop()
	go b.waitForExit(r.KeepOpen)
	s.parkingChanged()
	return b, nil
}

// adoptTerminal makes t the authoritative emulator: image limits, effects
// and the current theme. On failure t is closed.
func (b *Block) adoptTerminal(t *vt.Terminal) error {
	b.terminal = t
	if err := b.configureGraphics(); err != nil {
		t.Close()
		b.terminal = nil
		return err
	}
	b.installEffects()
	b.applyTheme()
	return nil
}

// waitForExit reaps the child and reports its status. Unless the block was
// asked to stay open, the service then removes it from the workspace.
func (b *Block) waitForExit(keepOpen bool) {
	_ = b.cmd.Wait()
	close(b.exited)
	code := exitCode(b.cmd.ProcessState)
	b.mu.Lock()
	b.info.ExitCode = &code
	b.event(Message{Event: "child_exited", ExitCode: &code})
	b.mu.Unlock()
	s := b.server
	s.changed()
	if !keepOpen {
		select {
		case s.finished <- b.info.ID:
		case <-s.stop:
		}
	}
}

// exitCode follows shell convention: 128+N for a child killed by signal N.
func exitCode(state *os.ProcessState) int {
	if state == nil {
		return 1
	}
	if status, ok := state.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return 128 + int(status.Signal())
	}
	return state.ExitCode()
}

// close hangs up the terminal the way closing a terminal window does: the
// shell's process group and the foreground job get SIGHUP. A shell that
// survives without its PTY is killed after a grace period so it is reaped.
func (b *Block) close() {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.closed = true
	close(b.done)
	running := true
	select {
	case <-b.exited:
		running = false
	default:
	}
	if running {
		pid := b.cmd.Process.Pid
		if foreground := foregroundProcess(b.pty); foreground > 0 && foreground != pid {
			_ = syscall.Kill(-foreground, syscall.SIGHUP)
		}
		_ = syscall.Kill(-pid, syscall.SIGHUP)
	}
	_ = b.pty.Close()
	if b.terminal != nil {
		b.terminal.Close()
		b.terminal = nil
	}
	b.mu.Unlock()
	b.io.Wait()
	if running {
		go b.killAfter(hangupGracePeriod)
	}
}

func (b *Block) killAfter(grace time.Duration) {
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-b.exited:
	case <-timer.C:
		_ = syscall.Kill(-b.cmd.Process.Pid, syscall.SIGKILL)
	}
}

// event publishes a terminal event with the block's placement at the moment
// it happened, independent of later moves or removal. Caller holds b.mu.
func (b *Block) event(m Message) {
	m.Type, m.Block = "event", b.info.ID
	m.Session, m.Window = b.info.Session, b.info.Window
	b.server.broadcastEvent(m)
}

// installEffects connects emulator callbacks. They run during VTWrite, so
// with b.mu held. Only the authoritative emulator answers terminal queries;
// replicas have no write-PTY effect, which avoids duplicate replies.
func (b *Block) installEffects() {
	t := b.terminal
	t.SetEffectWritePty(func(_ *vt.Terminal, data []byte) {
		if b.closed {
			return
		}
		// Replies have their own budget, separate from pasted input.
		if len(b.replies)+len(data) > 1<<20 {
			if !b.replyOverflow {
				b.event(Message{Event: "error", Text: "Terminal query reply limit exceeded: the process is not reading its replies"})
				b.replyOverflow = true
			}
			return
		}
		b.replies = append(b.replies, data...)
		select {
		case b.replyReady <- struct{}{}:
		default:
		}
	})
	t.SetEffectTitleChanged(func(t *vt.Terminal) {
		b.info.Title, _ = t.Title()
		b.server.changed()
		b.event(Message{Event: "title_changed", Text: b.info.Title})
	})
	t.SetEffectPwdChanged(func(t *vt.Terminal) {
		if cwd, err := t.Pwd(); err == nil && cwd != "" {
			b.info.Cwd = normalizeDirectory(cwd)
			b.event(Message{Event: "pwd_changed", Text: b.info.Cwd})
			b.server.changed()
		}
	})
	t.SetEffectProgressReport(func(_ *vt.Terminal, report vt.TerminalProgressReport) {
		b.event(Message{Event: "progress_report", Text: fmt.Sprintf("%d:%d", report.State, report.Progress)})
	})
	t.SetEffectBell(func(_ *vt.Terminal) { b.event(Message{Event: "bell"}) })
	t.SetEffectDesktopNotification(func(_ *vt.Terminal, n vt.TerminalDesktopNotification) {
		b.event(Message{Event: "desktop_notification", Text: n.Title + "\n" + n.Body})
	})
	t.SetEffectClipboardWrite(func(_ *vt.Terminal, w vt.ClipboardWrite) vt.ClipboardWriteReply {
		for _, content := range w.Contents {
			if content.MIME == "text/plain" {
				b.event(Message{Event: "clipboard_written", Data: content.Data})
			}
		}
		return vt.ClipboardWriteReply{Result: vt.ClipboardWriteSuccess}
	})
}

// normalizeDirectory decodes an OSC 7 file URL into a path.
func normalizeDirectory(value string) string {
	if parsed, err := url.Parse(value); err == nil && parsed.Scheme == "file" {
		return parsed.Path
	}
	return value
}

func (b *Block) applyTheme() {
	if b.terminal == nil || b.theme == nil {
		return
	}
	color := func(v *uint32) *vt.ColorRGB {
		if v == nil {
			return nil
		}
		return &vt.ColorRGB{R: uint8(*v >> 16), G: uint8(*v >> 8), B: uint8(*v)}
	}
	_ = b.terminal.SetColorBackground(color(b.theme.Background))
	_ = b.terminal.SetColorForeground(color(b.theme.Foreground))
	_ = b.terminal.SetColorCursor(color(b.theme.Cursor))
	var palette *vt.Palette
	if len(b.theme.Palette) == 256 {
		palette = new(vt.Palette)
		for i, v := range b.theme.Palette {
			palette[i] = *color(&v)
		}
	}
	_ = b.terminal.SetColorPalette(palette)
}

func (b *Block) capture(format string) (string, error) {
	kind := vt.FormatterFormatPlain
	switch format {
	case "", "text":
	case "html":
		kind = vt.FormatterFormatHTML
	case "vt":
		kind = vt.FormatterFormatVT
	default:
		return "", errors.New("format must be text, html, or vt")
	}
	if err := b.wake(); err != nil {
		return "", err
	}
	f, err := vt.NewFormatter(b.terminal, vt.WithFormatterFormat(kind), vt.WithFormatterTrim(true), vt.WithFormatterUnwrap(true))
	if err != nil {
		return "", err
	}
	defer f.Close()
	return f.FormatString()
}

func (b *Block) process() *ProcessInfo {
	name := ""
	if u, err := user.Current(); err == nil {
		name = u.Username
	}
	home, _ := os.UserHomeDir()
	foreground := foregroundProcess(b.pty)
	return &ProcessInfo{Child: processIdentity(b.info.PID), Foreground: processIdentity(foreground), PID: b.info.PID, ForegroundPID: foreground, User: name, Command: b.info.Command, Cwd: b.currentDirectory(), Home: home, ExitCode: b.info.ExitCode}
}

// currentDirectory prefers the live process's directory over the last one the
// shell reported, which may be stale or absent without shell integration.
func (b *Block) currentDirectory() string {
	if foreground := foregroundProcess(b.pty); foreground > 0 {
		if path := processDirectory(foreground); path != "" {
			return path
		}
	}
	if path := processDirectory(b.info.PID); path != "" {
		return path
	}
	return b.info.Cwd
}
