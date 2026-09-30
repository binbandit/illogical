package mux

import (
	"errors"
	"fmt"

	vt "go.mitchellh.com/libghostty"
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

// handleClear implements Ghostty's clear_screen (Cmd+K). It is expressed as
// ordinary VT output so replicas replay exactly what the service applied.
func (b *Block) handleClear(*client, Request) (Message, error) {
	if err := b.wake(); err != nil {
		return Message{}, err
	}
	sequence, redraw, err := clearSequence(b.terminal)
	if err != nil || sequence == nil {
		return Message{}, err
	}
	if b.resetPending != nil {
		return Message{}, errTerminalBusy
	}
	b.writeOutput(sequence)
	if redraw {
		return Message{}, b.enqueueInput([]byte{0x0c})
	}
	return Message{}, nil
}

var errTerminalBusy = errors.New("terminal is in the middle of an escape sequence; try again")

// clearSequence erases the scrollback and the screen above the cursor. At a
// shell prompt (OSC 133) it erases the whole screen instead and asks for ^L
// so the shell redraws its prompt. The alternate screen belongs to a
// full-screen program and is left alone (nil sequence).
func clearSequence(t *vt.Terminal) (sequence []byte, redraw bool, err error) {
	screen, err := t.ActiveScreen()
	if err != nil || screen == vt.ScreenAlternate {
		return nil, false, err
	}
	// Injected bytes would join an unfinished sequence from the program.
	if ground, err := t.VTGround(); err != nil || !ground {
		return nil, false, errors.Join(err, errTerminalBusy)
	}
	const eraseScrollback = "\x1b[3J"
	if atPrompt, _ := t.CursorAtPrompt(); atPrompt {
		// Marking the row as command output (OSC 133;C) makes ED 2 erase the
		// prompt too rather than scrolling it into history.
		return []byte("\x1b]133;C\x07\x1b[2J" + eraseScrollback), true, nil
	}
	x, err := t.CursorX()
	if err != nil {
		return nil, false, err
	}
	y, err := t.CursorY()
	if err != nil {
		return nil, false, err
	}
	sequence = []byte{}
	if y > 0 {
		// Scroll the cursor's row to the top, then follow it.
		sequence = fmt.Appendf(sequence, "\x1b[%dS\x1b[1;%dH", y, x+1)
	}
	return append(sequence, eraseScrollback...), false, nil
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
