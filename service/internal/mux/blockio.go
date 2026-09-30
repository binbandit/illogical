package mux

import (
	"bytes"
	"errors"
	"time"
)

// enqueueInput hands bytes to writeLoop without blocking the caller, so a
// program that stops reading its input cannot stall the service. Caller
// holds b.mu.
func (b *Block) enqueueInput(data []byte) error {
	if b.closed {
		return errBlockClosed
	}
	select {
	case b.input <- bytes.Clone(data):
		return nil
	default:
		return errors.New("terminal input queue is full; retry when the process is reading input")
	}
}

// writeLoop writes input and terminal query replies to the PTY. Replies go
// first so they never wait behind a large paste.
func (b *Block) writeLoop() {
	defer b.io.Done()
	for {
		b.mu.Lock()
		replies, closed := b.replies, b.closed
		b.replies, b.replyOverflow = nil, false
		b.mu.Unlock()
		if closed {
			return
		}
		if len(replies) > 0 {
			if b.writeToPTY(replies) != nil {
				return
			}
			continue
		}
		select {
		case data := <-b.input:
			if b.writeToPTY(data) != nil {
				return
			}
		case <-b.replyReady:
		case <-b.done:
			return
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

// notifyViewerChange makes readLoop re-evaluate which client paces it.
func (b *Block) notifyViewerChange() {
	select {
	case b.viewerWake <- struct{}{}:
	default:
	}
}

// readLoop feeds PTY output to the emulator and attached replicas. It reads
// only while the primary viewer's queue has room, so a program producing
// output faster than the client renders is slowed down like on a real
// terminal instead of growing memory without bound.
func (b *Block) readLoop() {
	defer b.io.Done()
	buffer := make([]byte, 32<<10)
	for b.waitForViewer() {
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
				b.mu.Unlock()
				return
			}
			b.lastOutput = time.Now()
			b.writeOutput(data)
			b.scheduleDirectoryCheck()
			b.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

// waitForViewer blocks while the primary viewer's queue is above its high
// water mark. No lock is held while waiting, so input, Ctrl+C, metadata, and
// every other terminal stay responsive under backpressure.
func (b *Block) waitForViewer() bool {
	const inputAllowance = 128 << 10
	for {
		b.mu.Lock()
		owner, closed := b.info.Owner, b.closed
		b.mu.Unlock()
		if closed {
			return false
		}
		select {
		case <-b.inputWake:
			b.inputReadAllowance = inputAllowance
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
		select {
		case <-space:
		case <-viewer.done:
		case <-b.viewerWake:
		case <-b.inputWake:
			// With ECHO on, Darwin's line discipline can wait for output space
			// before handling Ctrl+C, even after Write returned. A bounded
			// allowance lets the echo and the signal through.
			b.inputReadAllowance = inputAllowance
		case <-b.done:
			return false
		}
	}
}
