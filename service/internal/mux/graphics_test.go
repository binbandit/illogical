package mux

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	vt "go.mitchellh.com/libghostty"
)

func kittyImage(id uint32, format, width, height int, data []byte) string {
	return fmt.Sprintf("\x1b_Ga=T,f=%d,s=%d,v=%d,i=%d,p=7,c=2,r=1,q=2;%s\x1b\\", format, width, height, id, base64.StdEncoding.EncodeToString(data))
}
func graphicsFixture(t *testing.T, fixtures map[string]string) (*Server, *testClient, *Block, string) {
	t.Helper()
	s, socket := startTest(t)
	c := connectTest(t, socket)
	dir := t.TempDir()
	for name, contents := range fixtures {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	created := c.request(t, Request{Method: "session.new", Cols: 12, Rows: 4, KeepOpen: true, Command: []string{"/bin/sh", "-c", `stty -echo; printf ready; while IFS= read -r item; do cat "$1/$item"; [ "$item" = first ] || printf '\033]2;%s\007' "$item"; done`, "fixture", dir}})
	waitCapture(t, c, created.Block, "ready")
	s.mu.Lock()
	b := s.blocks[created.Block]
	s.mu.Unlock()
	return s, c, b, socket
}
func emitGraphicsFixture(t *testing.T, c *testClient, b *Block, name string) {
	t.Helper()
	c.request(t, Request{Method: "block.write", Block: b.info.ID, Data: []byte(name + "\n")})
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if c.request(t, Request{Method: "block.title", Block: b.info.ID}).Text == name {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("fixture output did not arrive")
}
func snapshotGraphics(t *testing.T, c *testClient, block string) (GraphicsState, string, uint64) {
	t.Helper()
	id := NewID()
	if err := c.encoder.Encode(Request{ID: id, Method: "block.attach", Block: block}); err != nil {
		t.Fatal(err)
	}
	var result *GraphicsState
	var epoch string
	var sequence uint64
	for {
		m := c.next(t)
		if m.Type == "graphics" {
			if m.PreviousSequence != nil || m.Sequence == nil || !m.Graphics.Reset {
				t.Fatal("graphics snapshot is not baseline metadata")
			}
			result = m.Graphics
			epoch = m.ReplayID
			sequence = *m.Sequence
		}
		if m.ID == id {
			break
		}
	}
	if result == nil {
		t.Fatal("missing complete graphics scene")
	}
	return *result, epoch, sequence
}

func TestGraphicsRealPTYReconnectScrollResizeScreensDeleteAndParking(t *testing.T) {
	rgba := []byte{255, 0, 0, 255, 0, 255, 0, 128}
	pngImage := image.NewNRGBA(image.Rect(0, 0, 1, 1))
	pngImage.SetNRGBA(0, 0, color.NRGBA{B: 255, A: 255})
	var pngBytes bytes.Buffer
	if err := png.Encode(&pngBytes, pngImage); err != nil {
		t.Fatal(err)
	}
	s, c, b, socket := graphicsFixture(t, map[string]string{
		"image":     "\x1b[2;3H" + kittyImage(11, 32, 2, 1, rgba),
		"scroll":    strings.Repeat("\r\n", 10),
		"alternate": "\x1b[?1049h" + kittyImage(12, 100, 1, 1, pngBytes.Bytes()),
		"primary":   "\x1b[?1049l",
		"delete":    "\x1b_Ga=d,d=I,i=11,q=2\x1b\\",
	})
	if b.graphics.retained {
		t.Fatal("ordinary text retained graphics state")
	}
	pid := b.info.PID
	emitGraphicsFixture(t, c, b, "image")
	viewer := connectTest(t, socket)
	scene, epoch, sequence := snapshotGraphics(t, viewer, b.info.ID)
	if len(scene.Images) != 1 || len(scene.Placements) != 1 || !bytes.Equal(scene.Images[0].Data, rgba) || scene.Images[0].Format != 1 {
		t.Fatalf("RGBA scene %+v", scene)
	}
	placement := scene.Placements[0]
	if placement.Row != 1 || placement.Column != 2 || placement.PixelWidth != 16 || placement.PixelHeight != 16 || scene.CellWidth != 8 || scene.CellHeight != 16 {
		t.Fatalf("wrong initial geometry %+v / %+v", placement, scene)
	}
	viewer.conn.Close()
	if err := b.park(true); err != nil {
		t.Fatal(err)
	}
	b.mu.Lock()
	resident := b.terminal != nil && !b.info.Parked
	b.mu.Unlock()
	if !resident {
		t.Fatal("parking discarded canonical image registry")
	}
	if !s.nextParkDeadline().IsZero() {
		t.Fatal("graphics block scheduled perpetual parking retries")
	}
	emitGraphicsFixture(t, c, b, "scroll")
	c.request(t, Request{Method: "block.resize", Block: b.info.ID, Cols: 14, Rows: 5, CellWidth: 10, CellHeight: 20})
	resumed := connectTest(t, socket)
	id := NewID()
	resumed.encoder.Encode(Request{ID: id, Method: "block.attach", Block: b.info.ID, ReplayID: epoch, Sequence: &sequence})
	graphicsMutations := 0
	for {
		m := resumed.next(t)
		if m.ID == id {
			break
		}
		switch m.Type {
		case "snapshot", "resync":
			t.Fatal("brief image disconnect lost replay")
		case "output", "resize", "theme", "graphics":
			if m.PreviousSequence == nil || *m.PreviousSequence != sequence {
				t.Fatal("image replay ordering lost")
			}
			sequence = *m.Sequence
			if m.Type == "graphics" {
				scene = *m.Graphics
				graphicsMutations++
				if len(scene.Images) != 0 {
					t.Fatal("unchanged pixels resent on geometry update")
				}
			}
		}
	}
	if graphicsMutations < 2 || len(scene.Placements) != 1 || scene.Placements[0].Row >= 0 || scene.Placements[0].PixelWidth != 20 {
		t.Fatalf("scrollback geometry lost: %+v", scene)
	}
	resumed.conn.Close()
	fresh := connectTest(t, socket)
	full, _, _ := snapshotGraphics(t, fresh, b.info.ID)
	if len(full.Images) != 1 || !bytes.Equal(full.Images[0].Data, rgba) || !slices.Equal(full.Placements, scene.Placements) {
		t.Fatal("fresh snapshot omitted offscreen image state")
	}
	emitGraphicsFixture(t, c, b, "alternate")
	b.mu.Lock()
	alt := b.graphicsSnapshot()
	b.mu.Unlock()
	if len(alt.Images) != 1 || alt.Images[0].ID != 12 || !bytes.Equal(alt.Images[0].Data, []byte{0, 0, 255, 255}) {
		t.Fatalf("PNG/alternate scene %+v", alt)
	}
	emitGraphicsFixture(t, c, b, "primary")
	b.mu.Lock()
	primary := b.graphicsSnapshot()
	b.mu.Unlock()
	if len(primary.Images) != 1 || primary.Images[0].ID != 11 {
		t.Fatal("primary registry lost across alternate screen")
	}
	emitGraphicsFixture(t, c, b, "delete")
	b.mu.Lock()
	deleted := b.graphicsSnapshot()
	b.mu.Unlock()
	if len(deleted.Images) != 0 || len(deleted.Placements) != 0 {
		t.Fatal("delete did not remove client image state")
	}
	c.request(t, Request{Method: "block.reset", Block: b.info.ID})
	if err := b.park(true); err != nil {
		t.Fatal(err)
	}
	b.mu.Lock()
	parked := b.info.Parked
	b.mu.Unlock()
	if !parked {
		t.Fatal("explicit reset did not allow parking again")
	}
	if c.request(t, Request{Method: "block.process", Block: b.info.ID}).Process.PID != pid {
		t.Fatal("image transitions restarted child")
	}
}

func TestGraphicsBoundsAndSplitIntroducer(t *testing.T) {
	s, c, b, _ := graphicsFixture(t, map[string]string{})
	_ = s
	_ = c
	b.mu.Lock()
	defer b.mu.Unlock()
	b.writeOutput([]byte("\x1b"))
	b.writeOutput([]byte(kittyImage(5, 24, 1, 1, []byte{1, 2, 3})[1:]))
	if !b.graphics.retained || len(b.graphics.scene.Images) != 1 || b.graphics.scene.Images[0].Format != 0 {
		t.Fatal("split APC/RGB not captured")
	}
	for n := 1; n <= maxGraphicsPlacements; n++ {
		b.writeOutput([]byte(fmt.Sprintf("\x1b_Ga=p,i=5,p=%d,q=2\x1b\\", n+10)))
	}
	if len(b.graphics.scene.Placements) != 0 || len(b.graphics.scene.Images) != 0 {
		t.Fatal("placement limit did not clear scene")
	}
	if b.replay.bytes > maxReplayBytes {
		t.Fatal("graphics replay not bounded")
	}
	q := newMessageQueue()
	image := GraphicsImage{Data: make([]byte, 8<<20)}
	msg := Message{Type: "graphics", Graphics: &GraphicsState{Images: []GraphicsImage{image}}}
	accepted := 0
	for q.push(msg) {
		accepted++
	}
	if accepted != 3 {
		t.Fatalf("outbound queue failed to charge image bytes: %d", accepted)
	}
	var replay replayBuffer
	replay.epoch = NewID()
	replay.append(msg)
	if replay.bytes != 0 || len(replay.records) != 0 {
		t.Fatal("oversized image replay record retained beyond budget")
	}
}

func TestGraphicsRejectsOversizedAndMalformedPNG(t *testing.T) {
	if _, err := decodeGraphicsPNG([]byte("not png")); err == nil {
		t.Fatal("malformed PNG accepted")
	}
	img := image.NewNRGBA(image.Rect(0, 0, 2049, 1024))
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		t.Fatal(err)
	}
	if _, err := decodeGraphicsPNG(encoded.Bytes()); err == nil {
		t.Fatal("over-budget decoded PNG accepted")
	}
}

func TestGraphicsUploadAndInflateBudget(t *testing.T) {
	for _, compressed := range []bool{false, true} {
		t.Run(fmt.Sprint(compressed), func(t *testing.T) {
			terminal, err := vt.NewTerminal(vt.WithSize(12, 4))
			if err != nil {
				t.Fatal(err)
			}
			defer terminal.Close()
			limit := uint64(maxGraphicsBytes)
			terminal.SetKittyImageStorageLimit(&limit)
			var replies bytes.Buffer
			terminal.SetEffectWritePty(func(_ *vt.Terminal, p []byte) { replies.Write(p) })
			if compressed {
				var encoded bytes.Buffer
				z := zlib.NewWriter(&encoded)
				z.Write(make([]byte, maxGraphicsBytes+1))
				z.Close()
				terminal.VTWrite([]byte("\x1b_Ga=t,f=24,s=1,v=1,i=19,o=z;" + base64.StdEncoding.EncodeToString(encoded.Bytes()) + "\x1b\\"))
				if !strings.Contains(replies.String(), "decompression failed") {
					t.Fatalf("inflate did not stop at decoded budget: %q", replies.String())
				}
			} else {
				chunk := base64.StdEncoding.EncodeToString(make([]byte, 4096))
				terminal.VTWrite([]byte("\x1b_Ga=t,f=24,s=1,v=1,i=19,m=1;" + chunk + "\x1b\\"))
				for n := 4096; n < maxGraphicsBytes; n += 4096 {
					terminal.VTWrite([]byte("\x1b_Gm=1;" + chunk + "\x1b\\"))
				}
				if replies.Len() != 0 {
					t.Fatalf("valid pending payload failed too early: %q", replies.String())
				}
				terminal.VTWrite([]byte("\x1b_Gm=1;AAAA\x1b\\"))
				if !strings.Contains(replies.String(), "EINVAL") {
					t.Fatalf("pending upload grew past 8 MiB without rejection: %q", replies.String())
				}
			}
		})
	}
}

func TestGraphicsUnplacedImageMetadataBudget(t *testing.T) {
	terminal, err := vt.NewTerminal(vt.WithSize(12, 4))
	if err != nil {
		t.Fatal(err)
	}
	defer terminal.Close()
	limit := uint64(maxGraphicsBytes)
	terminal.SetKittyImageStorageLimit(&limit)
	var replies bytes.Buffer
	terminal.SetEffectWritePty(func(_ *vt.Terminal, data []byte) { replies.Write(data) })
	for id := 1; id <= 1025; id++ {
		terminal.VTWrite([]byte(fmt.Sprintf("\x1b_Ga=t,f=24,s=1,v=1,i=%d;AQID\x1b\\", id)))
	}
	storage, err := terminal.KittyGraphics()
	if err != nil {
		t.Fatal(err)
	}
	if storage.Image(1) == nil || storage.Image(1024) == nil {
		t.Fatal("valid image IDs lost below metadata cap")
	}
	if storage.Image(1025) != nil || !strings.Contains(replies.String(), "ENOMEM") {
		t.Fatal("more than 1,024 unplaced image records retained despite tiny pixel payload")
	}
	terminal.VTWrite([]byte("\x1b_Ga=t,f=24,s=1,v=1,i=1;BAUG\x1b\\"))
	storage, _ = terminal.KittyGraphics()
	pixels, err := storage.Image(1).Data()
	if err != nil || !bytes.Equal(pixels, []byte{4, 5, 6}) {
		t.Fatal("replacing an existing image failed at the metadata cap")
	}
}

func TestGraphicsRejectsUnsupportedAnimationWithoutMutation(t *testing.T) {
	terminal, err := vt.NewTerminal(vt.WithSize(12, 4))
	if err != nil {
		t.Fatal(err)
	}
	defer terminal.Close()
	limit := uint64(maxGraphicsBytes)
	terminal.SetKittyImageStorageLimit(&limit)
	var replies bytes.Buffer
	terminal.SetEffectWritePty(func(_ *vt.Terminal, data []byte) { replies.Write(data) })
	terminal.VTWrite([]byte("\x1b_Ga=t,f=32,s=1,v=1,i=1;AQIDBA==\x1b\\"))
	storage, _ := terminal.KittyGraphics()
	before, _ := storage.Generation()
	for _, command := range []string{"a=f,f=32,s=1,v=1,i=1;BAUGBw==", "a=a,i=1,s=3", "a=c,i=1,r=1,c=1,s=1,v=1"} {
		replies.Reset()
		terminal.VTWrite([]byte("\x1b_G" + command + "\x1b\\"))
		if !strings.Contains(replies.String(), "ENOTSUP") {
			t.Fatalf("unsupported animation accepted: %s, reply %q", command, replies.String())
		}
		storage, _ = terminal.KittyGraphics()
		after, _ := storage.Generation()
		if before != after {
			t.Fatal("rejected animation mutated image registry")
		}
	}
	replies.Reset()
	terminal.VTWrite([]byte("\x1b_Ga=a,i=1,s=3,q=2\x1b\\"))
	if replies.Len() != 0 {
		t.Fatal("quiet animation rejection emitted a reply")
	}
}

func TestGraphicsLargestImageOverUnixAndPartialUploadSnapshot(t *testing.T) {
	pixels := make([]byte, maxGraphicsBytes)
	for n := 0; n < len(pixels); n += 4 {
		pixels[n], pixels[n+3] = 17, 255
	}
	image := kittyImage(42, 32, 2048, 1024, pixels)
	cut := 2 << 20
	// No title checkpoint inside the unterminated APC. Inspect continuation
	// length to wait until the real child has finished the first write.
	s, c, b, socket := graphicsFixture(t, map[string]string{"first": image[:cut], "last": image[cut:]})
	_ = s
	c.request(t, Request{Method: "block.write", Block: b.info.ID, Data: []byte("first\n")})
	deadline := time.Now().Add(5 * time.Second)
	for {
		b.mu.Lock()
		count, err := b.terminal.ContinuationBuf(nil)
		b.mu.Unlock()
		if count >= cut {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("partial APC not retained: %v", err)
		}
		time.Sleep(time.Millisecond)
	}
	viewer := connectTest(t, socket)
	partial, _, _ := snapshotGraphics(t, viewer, b.info.ID)
	if len(partial.Images) != 0 || len(partial.Placements) != 0 {
		t.Fatal("incomplete image appeared in scene")
	}
	viewer.conn.Close()
	emitGraphicsFixture(t, c, b, "last")
	fresh := connectTest(t, socket)
	full, _, _ := snapshotGraphics(t, fresh, b.info.ID)
	if len(full.Images) != 1 || !bytes.Equal(full.Images[0].Data, pixels) {
		t.Fatal("largest image did not survive JSON/base64 Unix transport")
	}
	if len(full.Placements) != 1 {
		t.Fatal("largest image placement lost")
	}
}

func TestGraphicsPlacementCorrectsLiveTextAndForcesReplayBoundary(t *testing.T) {
	first := "\x1b[H" + strings.Replace(kittyImage(55, 32, 1, 1, []byte{255, 0, 0, 255}), "r=1", "r=3", 1) + "\r\nAFTER-IMAGE"
	_, admin, b, socket := graphicsFixture(t, map[string]string{
		"first-image": first,
		"place-again": "\x1b[H\x1b_Ga=p,i=55,p=8,c=2,r=2,q=2\x1b\\\r\nAFTER-PLACEMENT",
		"plain":       "\r\nPLAIN-OUTPUT",
	})
	viewer := connectTest(t, socket)
	replica, epoch, sequence := readReplica(t, viewer, b.info.ID)
	zero := uint64(0)
	replica.SetKittyImageStorageLimit(&zero)
	var decoder *vt.SnapshotDecoder
	reader := bytes.NewReader(nil)
	defer func() {
		if decoder != nil {
			decoder.Close()
		}
		replica.Close()
	}()
	for _, name := range []string{"first-image", "place-again"} {
		emitGraphicsFixture(t, admin, b, name)
		requestID := NewID()
		viewer.encoder.Encode(Request{ID: requestID, Method: "block.title", Block: b.info.ID})
		corrected, final, replied := false, false, false
		for !corrected || !final || !replied {
			m := viewer.next(t)
			if m.ID == requestID {
				replied = true
			}
			switch m.Type {
			case "snapshot":
				if m.Text != "graphics" {
					t.Fatal("image grid correction did not identify itself")
				}
				if decoder != nil {
					decoder.Close()
				}
				replica.Close()
				reader.Reset(m.Data)
				var err error
				decoder, err = vt.NewSnapshotDecoder(reader)
				if err != nil {
					t.Fatal(err)
				}
				replica, err = decoder.Ready()
				if err != nil {
					t.Fatal(err)
				}
				replica.SetKittyImageStorageLimit(&zero)
				corrected = true
				final = false
			case "history":
				if decoder == nil {
					t.Fatal("history without correction")
				}
				reader.Reset(m.Data)
				if _, err := decoder.Next(); err != nil {
					t.Fatal(err)
				}
				final = m.Final
			case "output":
				replica.VTWrite(m.Data)
			}
		}
		want := admin.request(t, Request{Method: "block.capture", Block: b.info.ID}).Text
		if got := replicaText(t, replica); got != want {
			t.Fatalf("live image replica text differs: %q vs %q", got, want)
		}
		b.mu.Lock()
		wantY, _ := b.terminal.CursorY()
		b.mu.Unlock()
		if got, _ := replica.CursorY(); got != wantY {
			t.Fatalf("image cursor row %d, want %d", got, wantY)
		}
	}
	emitGraphicsFixture(t, admin, b, "plain")
	plainID := NewID()
	viewer.encoder.Encode(Request{ID: plainID, Method: "block.title", Block: b.info.ID})
	for {
		m := viewer.next(t)
		if m.Type == "snapshot" {
			t.Fatal("ordinary text caused image correction snapshot")
		}
		if m.ID == plainID {
			break
		}
	}
	// A client that missed these corrections must not replay the original
	// divergent image bytes alone. Its older cursor receives a full resync.
	stale := connectTest(t, socket)
	id := NewID()
	stale.encoder.Encode(Request{ID: id, Method: "block.attach", Block: b.info.ID, ReplayID: epoch, Sequence: &sequence})
	resync, snapshot := false, false
	for {
		m := stale.next(t)
		if m.Type == "resync" {
			resync = true
		}
		if m.Type == "snapshot" {
			snapshot = true
		}
		if m.Type == "resume" {
			t.Fatal("image correction barrier allowed divergent replay")
		}
		if m.ID == id {
			break
		}
	}
	if !resync || !snapshot {
		t.Fatal("missed image correction did not resynchronize")
	}
}
