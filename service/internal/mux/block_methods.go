package mux

import (
	"errors"
)

// Request handlers for one terminal. blockMethod calls them with b.mu held.

var errExited = errors.New("process has exited")

// handleAttach subscribes c to the terminal. A client that still holds a
// replica resumes from its replay cursor instead of a full snapshot.
func (b *Block) handleAttach(c *client, r Request) (Message, error) {
	if r.Sequence != nil && b.resume(c, r) {
		return Message{Block: r.Block}, nil
	}
	if err := b.attach(c, ""); err != nil {
		return Message{}, err
	}
	return Message{Block: r.Block}, nil
}

func (b *Block) handleDetach(c *client, _ Request) (Message, error) {
	c.mu.Lock()
	delete(c.subscriptions, b.info.ID)
	delete(c.viewportSync, b.info.ID)
	c.mu.Unlock()
	b.releaseViewer(c.id)
	b.notifyViewerChange()
	return Message{}, nil
}

func (b *Block) handleWrite(_ *client, r Request) (Message, error) {
	if b.info.ExitCode != nil {
		return Message{}, errExited
	}
	if len(r.Data) > 1<<20 {
		return Message{}, errors.New("input exceeds one megabyte")
	}
	return Message{}, b.enqueueInput(r.Data)
}

// handleInput encodes a key or mouse event for the terminal's current modes.
func (b *Block) handleInput(_ *client, r Request) (Message, error) {
	if b.info.ExitCode != nil {
		return Message{}, errExited
	}
	if err := b.wake(); err != nil {
		return Message{}, err
	}
	data, err := b.encodeInput(r)
	if err != nil || len(data) == 0 {
		return Message{}, err
	}
	return Message{}, b.enqueueInput(data)
}

func (b *Block) handleResize(c *client, r Request) (Message, error) {
	if r.Release {
		b.releaseViewer(c.id)
		b.notifyViewerChange()
		return Message{Size: b.size()}, nil
	}
	if err := b.requestSize(c.id, r); err != nil {
		return Message{}, err
	}
	return Message{Cols: b.info.Cols, Rows: b.info.Rows, Size: b.size()}, nil
}

func (b *Block) handleSize(*client, Request) (Message, error) {
	return Message{Cols: b.info.Cols, Rows: b.info.Rows, Size: b.size()}, nil
}

func (b *Block) handleRename(_ *client, r Request) (Message, error) {
	b.info.Label = r.Label
	b.server.changed()
	return Message{}, nil
}

func (b *Block) handleCapture(_ *client, r Request) (Message, error) {
	text, err := b.capture(r.Format)
	return Message{Text: text}, err
}

func (b *Block) handleProcess(*client, Request) (Message, error) {
	return Message{Process: b.process()}, nil
}

func (b *Block) handleTitle(*client, Request) (Message, error) {
	return Message{Text: b.info.Title}, nil
}

// handleEvent republishes a client-side interaction to watchers.
func (b *Block) handleEvent(_ *client, r Request) (Message, error) {
	if r.Label != "selection_copied" && r.Label != "url_clicked" {
		return Message{}, errors.New("unsupported client event")
	}
	b.event(Message{Event: r.Label, Text: string(r.Data)})
	return Message{}, nil
}

func (b *Block) handleTheme(_ *client, r Request) (Message, error) {
	theme := r.Theme
	if theme == nil {
		return Message{}, errors.New("theme is missing")
	}
	if len(theme.Palette) != 0 && len(theme.Palette) != 256 {
		return Message{}, errors.New("palette must contain 256 colors or be omitted")
	}
	colors := append([]uint32(nil), theme.Palette...)
	for _, color := range []*uint32{theme.Background, theme.Foreground, theme.Cursor} {
		if color != nil {
			colors = append(colors, *color)
		}
	}
	for _, color := range colors {
		if color > 0xffffff {
			return Message{}, errors.New("theme colors must be 24-bit RGB values")
		}
	}
	b.theme = theme
	b.applyTheme()
	b.publishMutation(Message{Type: "theme", Theme: theme})
	return Message{}, nil
}
