package mux

import (
	"bytes"
	"compress/gzip"
	"io"
	"log"
	"os"
	"time"

	vt "go.mitchellh.com/libghostty"
)

// Parking releases an idle terminal's emulator, which holds up to 64 MiB of
// scrollback, by saving a compressed snapshot to disk. The process keeps
// running; the next output, input, or query decodes the snapshot again.
// Clients attach to a parked terminal straight from the file.

const terminalIdleTimeout = 60 * time.Second

// parkDeadline reports when a resident emulator may next be parked. Caller
// holds b.mu. Images cannot be parked because snapshots omit them.
func (b *Block) parkDeadline() (time.Time, bool) {
	if b.closed || b.terminal == nil || b.graphics.retained || b.graphics.pending {
		return time.Time{}, false
	}
	deadline := b.lastOutput.Add(terminalIdleTimeout)
	if b.parkRetryAfter.After(deadline) {
		deadline = b.parkRetryAfter
	}
	return deadline, true
}

// park snapshots the emulator and releases it, if idle or forced. Compression
// and disk I/O run without b.mu, and the result is discarded if the terminal
// changed meanwhile.
func (b *Block) park(force bool) error {
	b.mu.Lock()
	deadline, ok := b.parkDeadline()
	if !ok || b.resetPending != nil || !force && time.Now().Before(deadline) {
		b.mu.Unlock()
		return nil
	}
	// A failed snapshot or disk write must not become a tight retry loop.
	b.parkRetryAfter = time.Now().Add(10 * time.Second)
	data, err := b.terminal.Snapshot()
	epoch, sequence := b.replay.epoch, b.replay.sequence
	b.mu.Unlock()
	if err != nil {
		return err
	}
	var encoded bytes.Buffer
	z, _ := gzip.NewWriterLevel(&encoded, gzip.BestSpeed)
	if _, err = z.Write(data); err == nil {
		err = z.Close()
	}
	if err == nil {
		err = atomicWrite(b.snapshotPath, encoded.Bytes())
	}
	if err != nil {
		return err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, ok := b.parkDeadline(); !ok || b.resetPending != nil || b.replay.epoch != epoch || b.replay.sequence != sequence {
		return nil // Changed while compressing; the next deadline retries.
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

// wake restores a parked emulator. If its snapshot is unreadable the
// scrollback is lost, but the terminal carries on blank rather than stopping
// its process's output. Caller holds b.mu.
func (b *Block) wake() error {
	if b.closed {
		return errBlockClosed
	}
	if b.terminal != nil {
		return nil
	}
	t, err := b.decodeParked()
	lost := err != nil
	if lost {
		log.Printf("wake %s: %v; continuing with an empty terminal", b.info.ID, err)
		if t, err = newEmulator(b.info.Cols, b.info.Rows); err != nil {
			return err
		}
	}
	if err = b.adoptTerminal(t); err != nil {
		return err
	}
	b.info.Parked = false
	b.parkRetryAfter = time.Time{}
	b.server.stateChanged()
	b.server.parkingChanged()
	if lost {
		b.replay.invalidate()
		b.resyncViewers("")
	}
	return nil
}

func (b *Block) decodeParked() (*vt.Terminal, error) {
	snapshot, err := b.snapshot()
	if err != nil {
		return nil, err
	}
	d, err := vt.NewSnapshotDecoderBytes(snapshot)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	// The decoder drops continuation state by default, which would break the
	// next snapshot whenever a PTY read ends inside an escape sequence.
	if err = d.SetMaxContinuationBytes(1 << 20); err != nil {
		return nil, err
	}
	if err = d.SetRetainContinuation(true); err != nil {
		return nil, err
	}
	t, err := d.Decode()
	if err != nil {
		return nil, err
	}
	if err = restoreModeDefaults(t); err != nil {
		t.Close()
		return nil, err
	}
	return t, nil
}

// snapshot encodes the terminal, or reads the parked snapshot.
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
