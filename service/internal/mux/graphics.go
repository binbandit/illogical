package mux

import (
	"bytes"
	"errors"
	"image/png"
	"slices"
	"sort"
	"sync"

	vt "go.mitchellh.com/libghostty"
	syspng "go.mitchellh.com/libghostty/sys/png"
)

const maxGraphicsBytes = 8 << 20 // Per screen, including Ghostty animation frames.
const maxGraphicsPlacements = 1024

// Graphics scenes are authoritative service state. Snapshot format v1 omits
// the Kitty registry, so replicas render these records instead of reparsing
// image commands. Rows are relative to the live screen, not the local viewport.
type GraphicsState struct {
	Generation uint64              `json:"generation"`
	Reset      bool                `json:"reset"`
	CellWidth  uint32              `json:"cellWidth"`
	CellHeight uint32              `json:"cellHeight"`
	Images     []GraphicsImage     `json:"images"`
	Placements []GraphicsPlacement `json:"placements"`
}
type GraphicsImage struct {
	ID         uint32 `json:"id"`
	Generation uint64 `json:"generation"`
	Width      uint32 `json:"width"`
	Height     uint32 `json:"height"`
	Format     int    `json:"format"`
	Data       []byte `json:"data"`
}
type GraphicsPlacement struct {
	ImageID         uint32 `json:"imageID"`
	ImageGeneration uint64 `json:"imageGeneration"`
	ID              uint32 `json:"id"`
	Column          uint32 `json:"column"`
	Row             int64  `json:"row"`
	XOffset         uint32 `json:"xOffset"`
	YOffset         uint32 `json:"yOffset"`
	PixelWidth      uint32 `json:"pixelWidth"`
	PixelHeight     uint32 `json:"pixelHeight"`
	SourceX         uint32 `json:"sourceX"`
	SourceY         uint32 `json:"sourceY"`
	SourceWidth     uint32 `json:"sourceWidth"`
	SourceHeight    uint32 `json:"sourceHeight"`
	Z               int32  `json:"z"`
}
type graphicsTracker struct {
	retained bool // Images on either screen must survive detach and idle time.
	pending  bool // An APC can span multiple PTY reads.
	escape   bool
	scene    GraphicsState
}

var graphicsDecoderOnce sync.Once
var graphicsDecoderError error

func installGraphicsDecoder() error {
	graphicsDecoderOnce.Do(func() { graphicsDecoderError = vt.SysSetDecodePng(decodeGraphicsPNG) })
	return graphicsDecoderError
}
func decodeGraphicsPNG(data []byte) (*vt.SysImage, error) {
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width > 10000 || config.Height > 10000 || uint64(config.Width)*uint64(config.Height) > maxGraphicsBytes/4 {
		return nil, errors.New("PNG exceeds the terminal image budget")
	}
	return syspng.Decode(data)
}

func (b *Block) configureGraphics() error {
	if err := installGraphicsDecoder(); err != nil {
		return err
	}
	limit := uint64(maxGraphicsBytes)
	if err := b.terminal.SetKittyImageStorageLimit(&limit); err != nil {
		return err
	}
	apcLimit := uint(12 << 20)
	if err := b.terminal.SetAPCMaxBytesKitty(&apcLimit); err != nil {
		return err
	}
	// File and shared-memory payloads are machine-local capabilities and do
	// not work consistently across remote sessions. Only direct data is used.
	_ = b.terminal.SetKittyImageMediumFile(false)
	_ = b.terminal.SetKittyImageMediumTempFile(nil)
	_ = b.terminal.SetKittyImageMediumSharedMem(false)
	if b.cellWidth == 0 {
		b.cellWidth = 8
	}
	if b.cellHeight == 0 {
		b.cellHeight = 16
	}
	return b.terminal.Resize(b.info.Cols, b.info.Rows, b.cellWidth, b.cellHeight)
}

// Plain text output needs no additional terminal queries or background timer.
// Looking for APC introducers also accounts for an ESC split across reads.
func (b *Block) graphicsOutput(data []byte) {
	g := &b.graphics
	if bytes.Contains(data, []byte("\x1b_")) || bytes.IndexByte(data, 0x9f) >= 0 || (g.escape && len(data) > 0 && data[0] == '_') {
		g.pending = true
		// Pending m=1 uploads have no public registry generation yet. Keep
		// the authoritative emulator until explicit reset, even for a query.
		if !g.retained {
			g.retained = true
			_ = b.terminal.SetContinuationMaxBytes(16 << 20)
			b.server.parkingChanged()
		}
	}
	if len(data) > 0 {
		g.escape = data[len(data)-1] == 0x1b
	}
	if !g.retained && !g.pending {
		return
	}
	b.refreshGraphics()
	if g.pending {
		ground, err := b.terminal.VTGround()
		if err == nil && ground {
			g.pending = false
		}
	}
}

// Caller holds b.mu; all borrowed image/grid references are consumed before
// another terminal mutation. Immutable blobs are shared by scene/replay/queues.
func (b *Block) refreshGraphics() {
	storage, err := b.terminal.KittyGraphics()
	if err != nil {
		return
	}
	generation, err := storage.Generation()
	if err != nil {
		return
	}
	if generation != 0 && !b.graphics.retained {
		b.graphics.retained = true
		b.server.parkingChanged()
	}
	if generation == 0 && b.graphics.scene.Generation == 0 {
		return
	}
	iter, err := vt.NewKittyGraphicsPlacementIterator()
	if err != nil {
		return
	}
	defer iter.Close()
	if storage.PlacementIterator(iter) != nil {
		return
	}
	history, _ := b.terminal.ScrollbackRows()
	scene := GraphicsState{Generation: generation, CellWidth: b.cellWidth, CellHeight: b.cellHeight, Images: []GraphicsImage{}, Placements: []GraphicsPlacement{}}
	old := map[uint32]GraphicsImage{}
	for _, image := range b.graphics.scene.Images {
		old[image.ID] = image
	}
	images := map[uint32]GraphicsImage{}
	count, total := 0, 0
	for iter.Next() {
		count++
		if count > maxGraphicsPlacements {
			// Bound placement metadata too. This uses the storage option, never
			// VT input, so an unfinished parser cannot consume the cleanup.
			zero, limit := uint64(0), uint64(maxGraphicsBytes)
			_ = b.terminal.SetKittyImageStorageLimit(&zero)
			_ = b.terminal.SetKittyImageStorageLimit(&limit)
			b.event(Message{Event: "error", Text: "Terminal image placement limit exceeded; images cleared"})
			scene.Images = []GraphicsImage{}
			scene.Placements = []GraphicsPlacement{}
			clear(images)
			break
		}
		placement, err := iter.Info()
		if err != nil || placement.IsVirtual {
			continue
		}
		imageHandle := storage.Image(placement.ImageID)
		if imageHandle == nil {
			continue
		}
		info, err := imageHandle.Info()
		if err != nil || info.DataPending || len(info.Data) == 0 {
			continue
		}
		channels := 0
		switch info.Format {
		case vt.KittyImageFormatRGB:
			channels = 3
		case vt.KittyImageFormatRGBA:
			channels = 4
		case vt.KittyImageFormatGrayAlpha:
			channels = 2
		case vt.KittyImageFormatGray:
			channels = 1
		}
		if channels == 0 || info.Width > 10000 || info.Height > 10000 || uint64(info.Width)*uint64(info.Height)*uint64(channels) != uint64(len(info.Data)) || len(info.Data) > maxGraphicsBytes {
			continue
		}
		geometry, err := iter.RenderInfo(imageHandle, b.terminal)
		if err != nil {
			continue
		}
		rect, err := iter.Rect(imageHandle, b.terminal)
		if err != nil {
			continue
		}
		point, err := b.terminal.PointFromGridRef(&rect.Start, vt.PointTagScreen)
		if err != nil {
			continue
		}
		if _, exists := images[info.ID]; !exists {
			total += len(info.Data)
			if total > maxGraphicsBytes {
				continue
			}
			image := old[info.ID]
			if image.Generation != info.Generation {
				image = GraphicsImage{ID: info.ID, Generation: info.Generation, Width: info.Width, Height: info.Height, Format: int(info.Format), Data: bytes.Clone(info.Data)}
			}
			images[info.ID] = image
		}
		scene.Placements = append(scene.Placements, GraphicsPlacement{ImageID: info.ID, ImageGeneration: info.Generation, ID: placement.PlacementID, Column: uint32(point.X), Row: int64(point.Y) - int64(history), XOffset: placement.XOffset, YOffset: placement.YOffset, PixelWidth: geometry.PixelWidth, PixelHeight: geometry.PixelHeight, SourceX: geometry.SourceX, SourceY: geometry.SourceY, SourceWidth: geometry.SourceWidth, SourceHeight: geometry.SourceHeight, Z: placement.Z})
	}
	for _, image := range images {
		scene.Images = append(scene.Images, image)
	}
	sort.Slice(scene.Images, func(i, j int) bool { return scene.Images[i].ID < scene.Images[j].ID })
	sort.Slice(scene.Placements, func(i, j int) bool {
		a, z := scene.Placements[i], scene.Placements[j]
		if a.ImageID != z.ImageID {
			return a.ImageID < z.ImageID
		}
		return a.ID < z.ID
	})
	previous := &b.graphics.scene
	if scene.Generation == previous.Generation && scene.CellWidth == previous.CellWidth && scene.CellHeight == previous.CellHeight && slices.Equal(scene.Placements, previous.Placements) {
		return
	}
	delta := scene
	delta.Images = []GraphicsImage{}
	for _, image := range scene.Images {
		if old[image.ID].Generation != image.Generation {
			delta.Images = append(delta.Images, image)
		}
	}
	correctGrid := scene.Generation != previous.Generation && (len(scene.Placements) > 0 || len(previous.Placements) > 0)
	b.graphics.scene = scene
	if correctGrid {
		// Kitty display commands can move the cursor, scroll, and then be
		// followed by ordinary text in the same PTY read. A replica with its
		// image parser disabled cannot reconstruct that text by a cursor-only
		// correction. Establish an authoritative snapshot boundary instead.
		// Geometry-only updates do not enter this path.
		b.replay.append(Message{Type: "graphics", Graphics: &delta})
		b.replay.clear()
		b.server.clientsMu.RLock()
		viewers := make([]*client, 0, len(b.server.clients))
		for _, c := range b.server.clients {
			viewers = append(viewers, c)
		}
		b.server.clientsMu.RUnlock()
		for _, c := range viewers {
			c.mu.Lock()
			attached := c.subscriptions[b.info.ID] != ""
			c.mu.Unlock()
			if attached {
				if err := b.server.attach(c, b, "graphics"); err != nil {
					c.send(Message{Type: "error", Block: b.info.ID, Error: "image snapshot: " + err.Error()})
				}
			}
		}
		return
	}
	b.publishMutation(Message{Type: "graphics", Graphics: &delta})
}

func (b *Block) graphicsSnapshot() *GraphicsState {
	scene := b.graphics.scene
	scene.Reset = true
	if scene.Images == nil {
		scene.Images = []GraphicsImage{}
	}
	if scene.Placements == nil {
		scene.Placements = []GraphicsPlacement{}
	}
	scene.CellWidth, scene.CellHeight = b.cellWidth, b.cellHeight
	return &scene
}

func graphicsCharge(g *GraphicsState) int {
	if g == nil {
		return 0
	}
	charge := len(g.Placements)*128 + len(g.Images)*128 + 128
	for _, image := range g.Images {
		charge += len(image.Data)
	}
	return charge
}
