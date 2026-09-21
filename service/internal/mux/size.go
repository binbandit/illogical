package mux

import (
	"errors"
	"sort"
)

type DesiredSize struct {
	Cols       uint16 `json:"cols"`
	Rows       uint16 `json:"rows"`
	CellWidth  uint32 `json:"cellWidth"`
	CellHeight uint32 `json:"cellHeight"`
}

func (b *Block) resizeFor(client string, size DesiredSize) error {
	if size.CellWidth == 0 {
		size.CellWidth = b.cellWidth
	}
	if size.CellHeight == 0 {
		size.CellHeight = b.cellHeight
	}
	if err := b.wake(); err != nil {
		return err
	}
	if err := b.terminal.Resize(size.Cols, size.Rows, size.CellWidth, size.CellHeight); err != nil {
		return err
	}
	if err := resizePTY(b.pty, size.Cols, size.Rows, size.CellWidth, size.CellHeight); err != nil {
		return err
	}
	b.info.Cols, b.info.Rows = size.Cols, size.Rows
	b.cellWidth, b.cellHeight = size.CellWidth, size.CellHeight
	b.info.Owner = client
	b.notifyViewerChange()
	b.publishMutation(Message{Type: "resize", Cols: size.Cols, Rows: size.Rows})
	if b.graphics.retained {
		b.refreshGraphics()
	}
	b.event(Message{Event: "size_changed", Cols: size.Cols, Rows: size.Rows})
	b.server.changed()
	return nil
}
func (b *Block) requestSize(client string, r Request) error {
	if r.Cols < 2 || r.Rows < 1 || r.Cols > 1000 || r.Rows > 1000 {
		return errors.New("terminal dimensions are outside supported bounds")
	}
	if r.CellWidth > 65535 || r.CellHeight > 65535 {
		return errors.New("cell dimensions are outside supported bounds")
	}
	if b.desiredSizes == nil {
		b.desiredSizes = map[string]DesiredSize{}
	}
	size := DesiredSize{Cols: r.Cols, Rows: r.Rows, CellWidth: r.CellWidth, CellHeight: r.CellHeight}
	b.desiredSizes[client] = size
	if b.info.Owner != "" && b.info.Owner != client {
		return nil
	}
	return b.resizeFor(client, size)
}

// Caller holds b.mu. Removing the last owner cannot strand a waiting viewer.
func (b *Block) releaseViewer(client string) {
	delete(b.desiredSizes, client)
	if b.info.Owner == client {
		b.info.Owner = ""
		ids := make([]string, 0, len(b.desiredSizes))
		for id := range b.desiredSizes {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		for _, id := range ids {
			if b.resizeFor(id, b.desiredSizes[id]) == nil {
				break
			}
		}
		b.server.stateChanged()
	}
	b.notifyViewerChange()
}
