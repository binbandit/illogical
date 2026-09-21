package mux

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	vt "go.mitchellh.com/libghostty"
)

const terminalIdleTimeout = 60 * time.Second

type Block struct {
	mu                 sync.Mutex
	info               BlockInfo
	terminal           *vt.Terminal
	pty                *os.File
	cmd                *exec.Cmd
	lastOutput         time.Time
	parkRetryAfter     time.Time
	snapshotPath       string
	server             *Server
	closed             bool
	input              chan []byte
	inputWake          chan struct{}
	viewerWake         chan struct{}
	inputReadAllowance int // Owned by readLoop, bounded escape from echo deadlock.
	done               chan struct{}
	io                 sync.WaitGroup
	replyReady         chan struct{}
	replies            []byte
	replyOverflow      bool
	parkedScrollback   uint64
	replay             replayBuffer
	graphics           graphicsTracker
	resetPending       chan struct{}
	desiredSizes       map[string]DesiredSize
	cellWidth          uint32
	cellHeight         uint32
	theme              *Theme
	primaryViewer      string // Owned by readLoop; prefer the explicit resize owner.
}

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
	stat, err := os.Stat(cwd)
	if err != nil || !stat.IsDir() {
		return nil, fmt.Errorf("directory is unavailable: %s", cwd)
	}
	command := r.Command
	if len(command) == 0 {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/zsh"
			if _, err := os.Stat(shell); err != nil {
				shell = "/bin/sh"
			}
		}
		command = []string{shell, "-l"}
	}
	cols, rows := r.Cols, r.Rows
	if cols == 0 {
		cols = 100
	}
	if rows == 0 {
		rows = 30
	}
	b := &Block{server: s, lastOutput: time.Now(), snapshotPath: filepath.Join(s.directory, "snapshots", id+".gz"), info: BlockInfo{ID: id, Session: r.Session, Window: r.Window, Title: filepath.Base(command[0]), Cwd: cwd, Cols: cols, Rows: rows, Command: command, KeepOpen: r.KeepOpen}}
	b.replay.epoch = NewID()
	b.info.Label = r.Label
	b.info.Flavor = "terminal"
	b.info.Host, _ = os.Hostname()
	b.terminal, err = vt.NewTerminal(vt.WithSize(cols, rows), vt.WithContinuationMaxBytes(1<<20), vt.WithMaxScrollbackBytes(64<<20))
	if err != nil {
		return nil, err
	}
	_ = b.terminal.SetPwd(cwd)
	if err = b.configureGraphics(); err != nil {
		b.terminal.Close()
		return nil, err
	}
	b.installEffects()
	b.cmd = exec.Command(command[0], command[1:]...)
	b.cmd.Dir = cwd
	b.cmd.Env = cleanEnvironment(os.Environ())
	executable, _ := os.Executable()
	b.cmd.Env = append(b.cmd.Env, "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=illogical", "ILLOGICAL_BLOCK="+id, "ILLOGICAL_SOCKET="+s.socket, "ILLOGICAL_HOME="+s.directory, "PATH="+filepath.Dir(executable)+":"+os.Getenv("PATH"))
	if err = s.prepareLoginCommand(b.cmd); err != nil {
		b.terminal.Close()
		return nil, err
	}
	b.pty, err = pty.StartWithSize(b.cmd, &pty.Winsize{Cols: cols, Rows: rows})
	if err != nil {
		b.terminal.Close()
		return nil, err
	}
	b.pty, err = pollablePTY(b.pty)
	if err != nil {
		_ = b.cmd.Process.Kill()
		_ = b.cmd.Wait()
		b.terminal.Close()
		return nil, fmt.Errorf("initialize terminal I/O: %w", err)
	}
	b.info.PID = b.cmd.Process.Pid
	b.input = make(chan []byte, 64)
	b.inputWake = make(chan struct{}, 1)
	b.viewerWake = make(chan struct{}, 1)
	b.done = make(chan struct{})
	b.replyReady = make(chan struct{}, 1)
	b.io.Add(2)
	go b.writeLoop()
	go b.readLoop()
	go func() {
		err := b.cmd.Wait()
		code := 0
		if err != nil {
			code = b.cmd.ProcessState.ExitCode()
			if status, ok := b.cmd.ProcessState.Sys().(syscall.WaitStatus); ok && status.Signaled() {
				code = 128 + int(status.Signal())
			}
		}
		b.mu.Lock()
		b.info.ExitCode = &code
		b.event(Message{Event: "child_exited", ExitCode: &code})
		b.mu.Unlock()
		s.changed()
		if !r.KeepOpen {
			select {
			case s.finished <- id:
			case <-s.stop:
			}
		}
	}()
	s.parkingChanged()
	return b, nil
}

// Call with b.mu held. Routing is captured when the event occurs, independently
// of coalesced workspace updates and subsequent moves or removal.
func (b *Block) event(m Message) {
	m.Type, m.Block = "event", b.info.ID
	m.Session, m.Window = b.info.Session, b.info.Window
	b.server.broadcastEvent(m)
}

func cleanEnvironment(env []string) []string {
	result := make([]string, 0, len(env))
	for _, v := range env {
		key, _, _ := strings.Cut(v, "=")
		switch key {
		case "TERM", "COLORTERM", "TERM_PROGRAM", "ILLOGICAL_BLOCK", "ILLOGICAL_SOCKET", "ILLOGICAL_HOME", "PATH":
			continue
		}
		result = append(result, v)
	}
	return result
}

// Only the authoritative emulator answers terminal queries. Client replicas
// deliberately have no write-PTY effect, avoiding duplicate device replies.
func (b *Block) installEffects() {
	t := b.terminal
	t.SetEffectWritePty(func(_ *vt.Terminal, data []byte) {
		if b.pty == nil || b.closed {
			return
		}
		// Effects run under b.mu. Reserve response capacity independently from
		// pasted user input and combine replies from each parsed output chunk.
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

func (b *Block) enqueueInput(data []byte) error {
	if b.closed {
		return errors.New("terminal is closed")
	}
	select {
	case b.input <- bytes.Clone(data):
		return nil
	default:
		return errors.New("terminal input queue is full; retry when the process is reading input")
	}
}

func (b *Block) writeLoop() {
	defer b.io.Done()
	for {
		b.mu.Lock()
		replies, closed := b.replies, b.closed
		b.replies = nil
		b.replyOverflow = false
		b.mu.Unlock()
		if closed {
			return
		}
		if len(replies) > 0 {
			if err := b.writeToPTY(replies); err != nil {
				return
			}
			continue
		}
		select {
		case data := <-b.input:
			if err := b.writeToPTY(data); err != nil {
				return
			}
		case <-b.done:
			return
		case <-b.replyReady:
		}
	}
}

func (b *Block) writeToPTY(data []byte) error {
	select {
	case b.inputWake <- struct{}{}:
	default:
	}
	_, err := b.pty.Write(data)
	return err
}

func (b *Block) notifyViewerChange() {
	select {
	case b.viewerWake <- struct{}{}:
	default:
	}
}

// OSC 7 reports a file URL, while filesystem operations need its decoded path.
func normalizeDirectory(value string) string {
	if strings.HasPrefix(value, "file://") {
		if parsed, err := url.Parse(value); err == nil {
			return parsed.Path
		}
	}
	return value
}

func (b *Block) readLoop() {
	defer b.io.Done()
	buffer := make([]byte, 32<<10)
	for {
		if !b.waitForViewer() {
			return
		}
		n, err := b.pty.Read(buffer)
		if n > 0 {
			b.inputReadAllowance = max(0, b.inputReadAllowance-n)
			data := bytes.Clone(buffer[:n])
			b.mu.Lock()
			if b.closed {
				b.mu.Unlock()
				return
			}
			if err := b.wake(); err != nil {
				b.event(Message{Event: "error", Text: err.Error()})
				b.mu.Unlock()
				return
			}
			b.lastOutput = time.Now()
			b.writeOutput(data)
			b.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

func (b *Block) waitForViewer() bool {
	for {
		b.mu.Lock()
		owner, closed := b.info.Owner, b.closed
		b.mu.Unlock()
		if closed {
			return false
		}
		select {
		case <-b.inputWake:
			b.inputReadAllowance = 128 << 10
		default:
		}
		if b.inputReadAllowance > 0 {
			return true
		}
		viewer := b.server.primaryViewer(b.info.ID, owner, b.primaryViewer)
		if viewer == nil {
			b.primaryViewer = ""
			return true
		}
		b.primaryViewer = viewer.id
		space := viewer.out.waitForSpace()
		if space == nil {
			return true
		}
		// No terminal or workspace lock is held here: input, Ctrl+C, process
		// metadata, and every other PTY remain responsive during backpressure.
		select {
		case <-space:
		case <-viewer.done:
		case <-b.viewerWake:
		case <-b.inputWake:
			// With ECHO enabled, Darwin's line discipline can wait for output
			// space before handling Ctrl+C, even after Write has returned. A
			// bounded allowance lets the deferred echo and signal proceed.
			b.inputReadAllowance = 128 << 10
		case <-b.done:
			return false
		}
	}
}

func (b *Block) wake() error {
	if b.terminal != nil {
		return nil
	}
	snapshot, err := b.snapshot()
	if err != nil {
		return err
	}
	d, err := vt.NewSnapshotDecoderBytes(snapshot)
	if err != nil {
		return err
	}
	defer d.Close()
	// The decoded emulator becomes authoritative again. The decoder defaults
	// to dropping continuation tracking, which would make the next snapshot
	// fail whenever a PTY read ends inside an escape sequence.
	if err = d.SetMaxContinuationBytes(1 << 20); err != nil {
		return err
	}
	if err = d.SetRetainContinuation(true); err != nil {
		return err
	}
	t, err := d.Decode()
	if err != nil {
		return err
	}
	b.terminal = t
	if err = b.configureGraphics(); err != nil {
		t.Close()
		b.terminal = nil
		return err
	}
	b.info.Parked = false
	b.parkRetryAfter = time.Time{}
	b.installEffects()
	b.applyTheme()
	b.server.stateChanged()
	b.server.parkingChanged()
	return nil
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

func (b *Block) snapshot() ([]byte, error) {
	if b.terminal != nil {
		return b.terminal.Snapshot()
	}
	f, err := os.Open(b.snapshotPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	z, err := gzip.NewReader(f)
	if err != nil {
		return nil, err
	}
	defer z.Close()
	return io.ReadAll(io.LimitReader(z, 256<<20))
}

func (b *Block) park(force bool) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed || b.terminal == nil || b.resetPending != nil || b.graphics.retained || b.graphics.pending || (!force && (time.Since(b.lastOutput) < terminalIdleTimeout || time.Now().Before(b.parkRetryAfter))) {
		return nil
	}
	// A failed snapshot or disk write must not create an immediate retry loop.
	b.parkRetryAfter = time.Now().Add(10 * time.Second)
	data, err := b.terminal.Snapshot()
	if err != nil {
		return err
	}
	var encoded bytes.Buffer
	z, _ := gzip.NewWriterLevel(&encoded, gzip.BestSpeed)
	if _, err = z.Write(data); err != nil {
		return err
	}
	if err = z.Close(); err != nil {
		return err
	}
	if err = atomicWrite(b.snapshotPath, encoded.Bytes()); err != nil {
		return err
	}
	history, _ := b.terminal.ScrollbackRows()
	b.parkedScrollback = uint64(history)
	b.terminal.Close()
	b.terminal = nil
	b.info.Parked = true
	b.replay.clear()
	b.parkRetryAfter = time.Time{}
	b.server.stateChanged()
	b.server.parkingChanged()
	return nil
}

func (b *Block) close() {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.closed = true
	close(b.done)
	if b.cmd.Process != nil && b.info.ExitCode == nil {
		_ = syscall.Kill(-b.cmd.Process.Pid, syscall.SIGHUP)
	}
	_ = b.pty.Close()
	if b.terminal != nil {
		b.terminal.Close()
		b.terminal = nil
	}
	b.mu.Unlock()
	b.io.Wait()
}

func (b *Block) capture(format string) (string, error) {
	if format != "" && format != "text" && format != "html" && format != "vt" {
		return "", errors.New("format must be text, html, or vt")
	}
	if err := b.wake(); err != nil {
		return "", err
	}
	kind := vt.FormatterFormatPlain
	if format == "html" {
		kind = vt.FormatterFormatHTML
	}
	if format == "vt" {
		kind = vt.FormatterFormatVT
	}
	f, err := vt.NewFormatter(b.terminal, vt.WithFormatterFormat(kind), vt.WithFormatterTrim(true), vt.WithFormatterUnwrap(true))
	if err != nil {
		return "", err
	}
	defer f.Close()
	return f.FormatString()
}

func (b *Block) process() *ProcessInfo {
	u, _ := user.Current()
	name := ""
	if u != nil {
		name = u.Username
	}
	home, _ := os.UserHomeDir()
	foreground := foregroundProcess(b.pty)
	return &ProcessInfo{Child: processIdentity(b.info.PID), Foreground: processIdentity(foreground), PID: b.info.PID, ForegroundPID: foreground, User: name, Command: b.info.Command, Cwd: b.currentDirectory(), Home: home, ExitCode: b.info.ExitCode}
}

func (b *Block) currentDirectory() string {
	foreground := foregroundProcess(b.pty)
	if foreground > 0 {
		if path := processDirectory(foreground); path != "" {
			return path
		}
	}
	if path := processDirectory(b.info.PID); path != "" {
		return path
	}
	return normalizeDirectory(b.info.Cwd)
}

func atomicWrite(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".write-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(name, path)
}
