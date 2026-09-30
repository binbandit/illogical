package mux

import (
	"testing"

	vt "go.mitchellh.com/libghostty"
)

func graphemeMode(t *testing.T, term *vt.Terminal) bool {
	t.Helper()
	on, err := term.Mode(vt.ModeGraphemeCluster)
	if err != nil {
		t.Fatal(err)
	}
	return on
}

func TestEmulatorClustersGraphemesByDefault(t *testing.T) {
	term, err := newEmulator(80, 24)
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	if !graphemeMode(t, term) {
		t.Fatal("new emulators must start with grapheme clustering on")
	}
	term.VTWrite([]byte("\x1b[?2027l\x1bc"))
	if !graphemeMode(t, term) {
		t.Fatal("a full reset must restore grapheme clustering")
	}
}

func TestDecodedSnapshotKeepsProgramModeAndDefault(t *testing.T) {
	term, err := newEmulator(80, 24)
	if err != nil {
		t.Fatal(err)
	}
	term.VTWrite([]byte("\x1b[?2027l"))
	snapshot, err := term.Snapshot()
	term.Close()
	if err != nil {
		t.Fatal(err)
	}
	d, err := vt.NewSnapshotDecoderBytes(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	restored, err := d.Decode()
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	if err = restoreModeDefaults(restored); err != nil {
		t.Fatal(err)
	}
	if graphemeMode(t, restored) {
		t.Fatal("restoring defaults must keep the program's explicit choice")
	}
	restored.VTWrite([]byte("\x1bc"))
	if !graphemeMode(t, restored) {
		t.Fatal("a full reset after restore must return to the Ghostty default")
	}
}
