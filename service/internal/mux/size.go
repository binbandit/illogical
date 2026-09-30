package mux

import (
	"errors"
	"sort"
)

// Size arbitration: every attached client records the size it would like,
// and the block's owner (the client that last claimed it, or first asked)
// decides the real size. When the owner leaves, the next client takes over.

var errSizeBounds = errors.New("terminal dimensions are outside supported bounds")

func validSize(cols, rows uint16) bool {
	return cols >= 2 && rows >= 1 && cols <= 1000 && rows <= 1000
}

func (b *Block) requestSize(client string, r Request) error {
	if !validSize(r.Cols, r.Rows) {
		return errSizeBounds
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

// resizeFor applies size on behalf of client, which becomes the owner. The
// kernel delivers SIGWINCH to the foreground job when the PTY size changes.
// Caller holds b.mu.
func (b *Block) resizeFor(client string, size DesiredSize) error {
	if size.CellWidth == 0 {
		size.CellWidth = b.cellWidth
	}
	if size.CellHeight == 0 {
		size.CellHeight = b.cellHeight
	}
	if b.info.Owner != client {
		b.info.Owner = client
		b.server.stateChanged()
	}
	if size.Cols == b.info.Cols && size.Rows == b.info.Rows && size.CellWidth == b.cellWidth && size.CellHeight == b.cellHeight {
		return nil // Repeated layout passes must not cost a redraw or a save.
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
	b.notifyViewerChange()
	b.publishMutation(Message{Type: "resize", Cols: size.Cols, Rows: size.Rows})
	if b.graphics.retained {
		b.refreshGraphics()
	}
	b.event(Message{Event: "size_changed", Cols: size.Cols, Rows: size.Rows})
	b.server.changed()
	return nil
}

// releaseViewer forgets client's size. If it owned the block, the remaining
// client with the lowest ID takes over. Caller holds b.mu.
func (b *Block) releaseViewer(client string) {
	_, desired := b.desiredSizes[client]
	delete(b.desiredSizes, client)
	if b.info.Owner != client {
		if desired {
			b.notifyViewerChange()
		}
		return
	}
	b.info.Owner = ""
	b.server.stateChanged()
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
	b.notifyViewerChange()
}

func (b *Block) size() *SizeInfo {
	desired := make(map[string]DesiredSize, len(b.desiredSizes))
	for client, size := range b.desiredSizes {
		desired[client] = size
	}
	return &SizeInfo{Cols: b.info.Cols, Rows: b.info.Rows, CellWidth: b.cellWidth, CellHeight: b.cellHeight, Owner: b.info.Owner, Desired: desired}
}
