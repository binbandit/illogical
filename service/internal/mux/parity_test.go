package mux

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	vt "go.mitchellh.com/libghostty"
)

func TestRelativeDirectoryAndImplicitSessionUseTerminalContext(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	directory := t.TempDir()
	if err := os.Mkdir(filepath.Join(directory, "child"), 0700); err != nil {
		t.Fatal(err)
	}
	command := []string{"/bin/sh", "-c", "printf ready; sleep 30"}
	c.request(t, Request{Method: "session.new", Label: "first", Command: command, KeepOpen: true})
	second := c.request(t, Request{Method: "session.new", Label: "second", Cwd: directory, Command: command, KeepOpen: true})
	waitCapture(t, c, second.Block, "ready")
	listed := c.request(t, Request{Method: "block.list_dir", Block: second.Block, Cwd: "child"})
	// macOS resolves /var aliases in the process's actual cwd.
	want, _ := filepath.EvalSymlinks(filepath.Join(directory, "child"))
	if listed.Path != want {
		t.Fatalf("directory %q, want %q", listed.Path, want)
	}
	run := c.request(t, Request{Method: "window.new", Block: second.Block, Command: command, KeepOpen: true})
	if run.Session != second.Session {
		t.Fatalf("run escaped inherited session: %s != %s", run.Session, second.Session)
	}
}

func TestThemeDefaultResetAndAttachedPropagation(t *testing.T) {
	s, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "printf ready; sleep 30"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "ready")
	viewer := connectTest(t, socket)
	viewer.request(t, Request{Method: "block.attach", Block: created.Block})
	rgb := uint32(0x123456)
	palette := make([]uint32, 256)
	for i := range palette {
		palette[i] = 0x010203
	}
	admin.request(t, Request{Method: "block.set_theme", Block: created.Block, Theme: &Theme{Background: &rgb, Foreground: &rgb, Cursor: &rgb, Palette: palette}})
	for {
		m := viewer.next(t)
		if m.Type == "theme" {
			if m.Theme == nil || m.Theme.Background == nil || *m.Theme.Background != rgb || m.Stream == "" {
				t.Fatalf("invalid theme notification: %#v", m)
			}
			break
		}
	}
	admin.request(t, Request{Method: "block.set_theme", Block: created.Block, Theme: &Theme{}})
	for {
		m := viewer.next(t)
		if m.Type == "theme" {
			if m.Theme == nil || m.Theme.Background != nil || len(m.Theme.Palette) != 0 {
				t.Fatalf("invalid default notification: %#v", m)
			}
			break
		}
	}
	fresh, err := vt.NewTerminal(vt.WithSize(100, 30))
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	original, _ := fresh.ColorPaletteDefault()
	s.mu.Lock()
	b := s.blocks[created.Block]
	s.mu.Unlock()
	b.mu.Lock()
	defer b.mu.Unlock()
	actual, _ := b.terminal.ColorPaletteDefault()
	bg, _ := b.terminal.ColorBackgroundDefault()
	fg, _ := b.terminal.ColorForegroundDefault()
	cursor, _ := b.terminal.ColorCursorDefault()
	if bg != nil || fg != nil || cursor != nil || *actual != *original {
		t.Fatal("omitted theme values did not restore built-in defaults")
	}
}

func TestClipboardWrittenReachesWatchersAndAttachedExactlyOnce(t *testing.T) {
	_, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "stty -echo; printf ready; read line; printf '\033]52;c;Y2xpcA==\007\033]2;after-clipboard\007'; sleep 30"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "ready")
	watcher := connectTest(t, socket)
	watcher.request(t, Request{Method: "watch"})
	attached := connectTest(t, socket)
	attached.request(t, Request{Method: "watch"})
	attached.request(t, Request{Method: "block.attach", Block: created.Block})
	admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("go\n")})
	for _, c := range []*testClient{watcher, attached} {
		count := 0
		for {
			m := c.next(t)
			if m.Event == "clipboard_written" {
				count++
				if string(m.Data) != "clip" {
					t.Fatalf("wrong clipboard %q", m.Data)
				}
			}
			if m.Event == "title_changed" {
				break
			}
		}
		if count != 1 {
			t.Fatalf("clipboard delivered %d times", count)
		}
	}
}

func TestResourceInspectionFocusAndClientDetach(t *testing.T) {
	_, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Label: "workspace", Command: []string{"/bin/sh", "-c", "printf ready; sleep 30"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "ready")
	viewer := connectTest(t, socket)
	hello := viewer.next(t)
	viewer.request(t, Request{Method: "client.update", Label: "Native window", Kind: "native"})
	viewer.request(t, Request{Method: "watch"})
	viewer.request(t, Request{Method: "block.attach", Block: created.Block})
	viewer.request(t, Request{Method: "block.claim", Block: created.Block})
	split := admin.request(t, Request{Method: "block.split", Block: created.Block, Command: []string{"/bin/sh", "-c", "sleep 30"}, KeepOpen: true})
	viewer.request(t, Request{Method: "block.claim", Block: split.Block})
	claimed := admin.request(t, Request{Method: "window.inspect", Window: created.Window})
	if claimed.WindowInfo.FocusedBlock != split.Block {
		t.Fatal("claim did not update focused block metadata")
	}
	viewer.request(t, Request{Method: "block.claim", Block: created.Block})
	admin.request(t, Request{Method: "focus", Block: created.Block})
	for {
		m := viewer.next(t)
		if m.Type == "focus" {
			if m.Client != hello.Client || m.Block != created.Block || m.Window != created.Window || m.Session != created.Session {
				t.Fatalf("wrong focus %#v", m)
			}
			break
		}
	}
	inspected := admin.request(t, Request{Method: "session.inspect", Session: created.Session})
	if inspected.SessionInfo == nil || inspected.SessionInfo.FocusedWindow != created.Window || len(inspected.Clients) != 1 || inspected.Clients[0].Kind != "native" {
		t.Fatalf("bad session inspection %#v", inspected)
	}
	window := admin.request(t, Request{Method: "window.inspect", Window: created.Window})
	if window.WindowInfo == nil || window.WindowInfo.FocusedBlock != created.Block {
		t.Fatalf("bad window inspection %#v", window)
	}
	info := admin.request(t, Request{Method: "block.inspect", Block: created.Block})
	if info.Block != created.Block || info.BlockInfo == nil || info.BlockInfo.Creator == "" || info.BlockInfo.Host == "" || info.BlockInfo.Flavor != "terminal" || info.BlockInfo.Window != created.Window || info.BlockInfo.Session != created.Session {
		t.Fatalf("incomplete block metadata %#v", info)
	}
	if info.Process.Child == nil || info.Process.Child.PID != info.Process.PID || info.Process.Child.Executable == "" || info.Process.Child.User == "" {
		t.Fatalf("missing child identity %#v", info.Process)
	}
	admin.request(t, Request{Method: "client.detach", Client: hello.Client})
	if next := admin.request(t, Request{Method: "block.process", Block: created.Block}); next.Process.PID != info.Process.PID || next.Process.ExitCode != nil {
		t.Fatal("detaching a client terminated its child")
	}
}

func TestProtocolAwareKeyAndMouseReachRealProcess(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	// Each mode is enabled by the actual child before the corresponding request.
	command := "stty raw -echo; printf '\033[?1hREADY'; dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -d ' \\n'; printf '\033[>3uKITTY'; dd bs=1 count=9 2>/dev/null | od -An -tx1 | tr -d ' \\n'; printf '\033[?1000h\033[?1006hMOUSE'; dd bs=1 count=9 2>/dev/null | od -An -tx1 | tr -d ' \\n'; sleep 30"
	created := c.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", command}, KeepOpen: true})
	waitCapture(t, c, created.Block, "READY")
	c.request(t, Request{Method: "block.key", Block: created.Block, Key: &KeyInput{Name: "up"}})
	waitCapture(t, c, created.Block, "1b4f41")
	waitCapture(t, c, created.Block, "KITTY")
	c.request(t, Request{Method: "block.key", Block: created.Block, Key: &KeyInput{Name: "a", Action: "release"}})
	waitCapture(t, c, created.Block, "1b5b39373b313a3375")
	waitCapture(t, c, created.Block, "MOUSE")
	c.request(t, Request{Method: "block.mouse", Block: created.Block, Mouse: &MouseInput{Button: "left", X: 2, Y: 3}})
	waitCapture(t, c, created.Block, "1b5b3c303b333b344d")
}

func TestDesiredResizeTransfersWhenOwnerReleases(t *testing.T) {
	_, socket := startTest(t)
	owner := connectTest(t, socket)
	ownerID := owner.next(t).Client
	created := owner.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "stty -echo; printf ready; read line; stty size; sleep 30"}, KeepOpen: true})
	waitCapture(t, owner, created.Block, "ready")
	owner.request(t, Request{Method: "block.resize", Block: created.Block, Cols: 80, Rows: 24, CellWidth: 8, CellHeight: 16})
	peer := connectTest(t, socket)
	peerID := peer.next(t).Client
	result := peer.request(t, Request{Method: "block.resize", Block: created.Block, Cols: 120, Rows: 40, CellWidth: 10, CellHeight: 20})
	if result.Cols != 80 || result.Size.Owner != ownerID || result.Size.Desired[peerID].Cols != 120 {
		t.Fatalf("desired resize was not recorded %#v", result.Size)
	}
	owner.request(t, Request{Method: "block.resize", Block: created.Block, Release: true})
	result = peer.request(t, Request{Method: "block.size", Block: created.Block})
	if result.Size.Owner != peerID || result.Size.Cols != 120 || result.Size.CellWidth != 10 || len(result.Size.Desired) != 1 {
		t.Fatalf("resize ownership did not transfer %#v", result.Size)
	}
	peer.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("go\n")})
	waitCapture(t, peer, created.Block, "40 120")
	owner.request(t, Request{Method: "block.claim", Block: created.Block})
	owner.conn.Close()
	deadline := time.Now().Add(time.Second)
	for {
		result = peer.request(t, Request{Method: "block.size", Block: created.Block})
		if result.Size.Owner == peerID {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("disconnect did not release ownership")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestResetWaitsForRealProcessParserBoundary(t *testing.T) {
	for _, fixture := range []struct{ name, prefix, suffix string }{{"CSI", "\\033[31", "mAFTER"}, {"UTF8", "\\342\\202", "\\254AFTER"}} {
		t.Run(fixture.name, func(t *testing.T) {
			s, socket := startTest(t)
			admin := connectTest(t, socket)
			command := "stty -echo; printf 'before" + fixture.prefix + "'; read line; printf '" + fixture.suffix + "'; sleep 30"
			created := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", command}, KeepOpen: true})
			waitCapture(t, admin, created.Block, "before")
			s.mu.Lock()
			b := s.blocks[created.Block]
			s.mu.Unlock()
			reset := connectTest(t, socket)
			result := make(chan Message, 1)
			go func() { result <- reset.request(t, Request{Method: "block.reset", Block: created.Block}) }()
			deadline := time.Now().Add(time.Second)
			for {
				b.mu.Lock()
				pending := b.resetPending != nil
				b.mu.Unlock()
				if pending {
					break
				}
				select {
				case <-result:
					t.Fatal("reset did not wait for the unfinished sequence")
				default:
				}
				if time.Now().After(deadline) {
					t.Fatal("reset was not queued")
				}
				time.Sleep(time.Millisecond)
			}
			admin.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("continue\n")})
			select {
			case <-result:
			case <-time.After(time.Second):
				t.Fatal("boundary reset did not finish")
			}
			capture := waitCapture(t, admin, created.Block, "AFTER")
			if strings.Contains(capture, "before") {
				t.Fatalf("reset did not clear previous screen: %q", capture)
			}
		})
	}
}

func TestResetTimeoutResynchronizesAttachedReplica(t *testing.T) {
	for _, prefix := range []string{"\\033[31", "\\342\\202"} {
		t.Run(fmt.Sprintf("%x", prefix), func(t *testing.T) { testResetTimeout(t, prefix) })
	}
}
func testResetTimeout(t *testing.T, prefix string) {
	s, socket := startTest(t)
	admin := connectTest(t, socket)
	created := admin.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "printf 'before" + prefix + "'; sleep 30"}, KeepOpen: true})
	waitCapture(t, admin, created.Block, "before")
	viewer := connectTest(t, socket)
	viewer.request(t, Request{Method: "block.attach", Block: created.Block})
	s.mu.Lock()
	b := s.blocks[created.Block]
	s.mu.Unlock()
	b.mu.Lock()
	pid := b.info.PID
	b.mu.Unlock()
	rgb := uint32(0xabcdef)
	admin.request(t, Request{Method: "block.theme", Block: created.Block, Theme: &Theme{Foreground: &rgb}})
	started := time.Now()
	admin.request(t, Request{Method: "block.reset", Block: created.Block})
	elapsed := time.Since(started)
	if elapsed < 230*time.Millisecond || elapsed > time.Second {
		t.Fatalf("unexpected reset timeout: %s", elapsed)
	}
	for {
		m := viewer.next(t)
		if m.Type == "snapshot" {
			decoder, err := vt.NewSnapshotDecoderBytes(m.Data)
			if err != nil {
				t.Fatal(err)
			}
			replica, err := decoder.Ready()
			if err != nil {
				decoder.Close()
				t.Fatal(err)
			}
			ground, err := replica.VTGround()
			replica.Close()
			decoder.Close()
			if err != nil || !ground {
				t.Fatalf("reset replica parser not at ground: %v", err)
			}
			break
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	fg, _ := b.terminal.ColorForegroundDefault()
	ground, _ := b.terminal.VTGround()
	if !ground || fg == nil || fg.R != 0xab || b.info.PID != pid {
		t.Fatal("reset changed PID/defaults or left unfinished parser")
	}
}

func TestProcessMetadataFollowsRealExec(t *testing.T) {
	_, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Command: []string{"/bin/sh", "-c", "printf before-exec; exec /bin/cat"}, KeepOpen: true})
	waitCapture(t, c, created.Block, "before-exec")
	deadline := time.Now().Add(time.Second)
	for {
		process := c.request(t, Request{Method: "block.process", Block: created.Block}).Process
		if process.Child != nil && filepath.Base(process.Child.Executable) == "cat" {
			if process.Foreground == nil || process.Foreground.PID != process.Child.PID || filepath.Base(process.Foreground.Executable) != "cat" {
				t.Fatalf("foreground identity did not track exec: %#v", process)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("identity still reflects launch command: %#v", process)
		}
		time.Sleep(time.Millisecond)
	}
}
