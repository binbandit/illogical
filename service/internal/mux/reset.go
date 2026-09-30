package mux

import (
	"errors"
	"time"
)

// reset clears the terminal like RIS without restarting its process. Output
// must be at a parser boundary first, so a reset during an unfinished escape
// sequence waits briefly for it to end and otherwise resynchronizes replicas.
func (b *Block) reset() error {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return errBlockClosed
	}
	if err := b.wake(); err != nil {
		b.mu.Unlock()
		return err
	}
	ground, err := b.terminal.VTGround()
	if err != nil {
		b.mu.Unlock()
		return err
	}
	if ground {
		b.finishReset(false)
		b.mu.Unlock()
		return nil
	}
	pending := b.resetPending
	if pending == nil {
		pending = make(chan struct{})
		b.resetPending = pending
		go func() {
			timer := time.NewTimer(250 * time.Millisecond)
			defer timer.Stop()
			select {
			case <-timer.C:
				b.mu.Lock()
				if !b.closed && b.resetPending == pending {
					b.finishReset(true)
				}
				b.mu.Unlock()
			case <-pending:
			case <-b.done:
			}
		}()
	}
	b.mu.Unlock()
	select {
	case <-pending:
		return nil
	case <-b.done:
		return errors.New("terminal closed during reset")
	}
}

// finishReset completes a reset. Caller holds b.mu. The timeout route
// replaces replicas from a snapshot, because injecting bytes into an
// unfinished parser has no well-defined result.
func (b *Block) finishReset(resync bool) {
	if resync {
		b.replay.invalidate()
		b.terminal.VTWrite([]byte{0x18}) // CAN aborts the pending sequence.
		b.terminal.Reset()
	} else {
		data := []byte("\x1bc")
		b.terminal.VTWrite(data)
		b.publishMutation(Message{Type: "output", Data: data})
	}
	b.applyTheme()
	// A reset discards both screens' images, so the block may park again.
	hadGraphics := b.graphics.retained || len(b.graphics.scene.Placements) > 0
	b.graphics = graphicsTracker{}
	_ = b.terminal.SetContinuationMaxBytes(1 << 20)
	_ = b.configureGraphics()
	if hadGraphics && !resync {
		b.publishMutation(Message{Type: "graphics", Graphics: b.graphicsSnapshot()})
	}
	b.server.parkingChanged()
	if resync {
		b.resyncViewers("")
	}
	if pending := b.resetPending; pending != nil {
		b.resetPending = nil
		close(pending)
	}
}

// writeOutput feeds PTY output to the emulator and attached replicas.
// Caller holds b.mu.
func (b *Block) writeOutput(data []byte) {
	if b.resetPending != nil {
		consumed, err := b.terminal.VTWriteUntilGround(data)
		if consumed > 0 {
			b.publishMutation(Message{Type: "output", Data: data[:consumed]})
			b.graphicsOutput(data[:consumed])
		}
		data = data[consumed:]
		if err == nil {
			b.finishReset(false)
		} else if len(data) > 0 { // Unexpected parser error: recover coherently.
			b.finishReset(true)
		}
	}
	if len(data) > 0 {
		b.publishMutation(Message{Type: "output", Data: data})
		b.terminal.VTWrite(data)
		b.graphicsOutput(data)
	}
}
