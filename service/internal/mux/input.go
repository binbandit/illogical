package mux

import (
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	vt "go.mitchellh.com/libghostty"
)

// Key and mouse requests come from the CLI and automation. They are encoded
// against the authoritative emulator's current modes (application cursor keys,
// kitty keyboard flags, mouse reporting) so programs receive what a real
// keyboard or mouse would produce. Caller holds b.mu with the terminal awake.

func (b *Block) encodeInput(r Request) ([]byte, error) {
	if r.Method == "block.key" {
		if r.Key == nil {
			return nil, errors.New("key is missing")
		}
		return b.encodeKey(*r.Key)
	}
	if r.Mouse == nil {
		return nil, errors.New("mouse is missing")
	}
	return b.encodeMouse(*r.Mouse)
}

var keyAliases = map[string]string{"up": "arrow_up", "down": "arrow_down", "left": "arrow_left", "right": "arrow_right", "return": "enter", "esc": "escape", "pageup": "page_up", "pagedown": "page_down"}

var punctuationKeys = map[rune]string{' ': "space", '-': "minus", '=': "equal", '[': "bracket_left", ']': "bracket_right", '\\': "backslash", ';': "semicolon", '\'': "quote", ',': "comma", '.': "period", '/': "slash", '`': "backquote"}

// encodeKey accepts names like "ctrl-c", "shift-enter", "up", "f1", or "a",
// with further modifiers in input.Mods.
func (b *Block) encodeKey(input KeyInput) ([]byte, error) {
	name := strings.ToLower(input.Name)
	mods, err := vt.ParseMods(strings.ToLower(input.Mods))
	if err != nil {
		return nil, err
	}
	for {
		prefix, rest, found := strings.Cut(name, "-")
		if !found {
			break
		}
		modifier, err := vt.ParseMods(prefix)
		if err != nil {
			break
		}
		mods |= modifier
		name = rest
	}
	if alias := keyAliases[name]; alias != "" {
		name = alias
	}
	var codepoint rune
	if utf8.RuneCountInString(name) == 1 {
		codepoint, _ = utf8.DecodeRuneInString(name)
		switch {
		case codepoint >= 'a' && codepoint <= 'z':
			name = "key_" + name
		case codepoint >= '0' && codepoint <= '9':
			name = "digit_" + name
		case punctuationKeys[codepoint] != "":
			name = punctuationKeys[codepoint]
		default:
			name = "unidentified"
		}
	}
	key, err := vt.ParseKey(name)
	if err != nil {
		return nil, err
	}
	action := vt.KeyActionPress
	switch input.Action {
	case "", "press":
	case "release":
		action = vt.KeyActionRelease
	case "repeat":
		action = vt.KeyActionRepeat
	default:
		return nil, errors.New("key action must be press, release, or repeat")
	}
	encoder, err := vt.NewKeyEncoder()
	if err != nil {
		return nil, err
	}
	defer encoder.Close()
	encoder.SetOptFromTerminal(b.terminal)
	event, err := vt.NewKeyEvent()
	if err != nil {
		return nil, err
	}
	defer event.Close()
	event.SetKey(key)
	event.SetMods(mods)
	event.SetAction(action)
	if codepoint != 0 {
		event.SetUnshiftedCodepoint(codepoint)
		if input.Text == "" && mods&(vt.ModCtrl|vt.ModSuper) == 0 {
			input.Text = string(codepoint)
			if mods&vt.ModShift != 0 {
				input.Text = strings.ToUpper(input.Text)
				event.SetConsumedMods(vt.ModShift)
			}
		}
	}
	event.SetUTF8(input.Text)
	return encoder.Encode(event)
}

// encodeMouse takes cell coordinates, or pixels when input.Pixels is set.
func (b *Block) encodeMouse(input MouseInput) ([]byte, error) {
	mods, err := vt.ParseMods(input.Mods)
	if err != nil {
		return nil, err
	}
	action := vt.MouseActionPress
	switch input.Action {
	case "", "press":
	case "release":
		action = vt.MouseActionRelease
	case "motion":
		action = vt.MouseActionMotion
	default:
		return nil, errors.New("mouse action must be press, release, or motion")
	}
	event, err := vt.NewMouseEvent()
	if err != nil {
		return nil, err
	}
	defer event.Close()
	event.SetAction(action)
	event.SetMods(mods)
	pressed := input.Button != "" && input.Button != "none"
	if pressed {
		button, err := vt.ParseMouseButton(input.Button)
		if err != nil {
			return nil, err
		}
		event.SetButton(button)
	} else {
		event.ClearButton()
	}
	cols, rows := uint32(b.info.Cols), uint32(b.info.Rows)
	cw, ch := max(1, b.cellWidth), max(1, b.cellHeight)
	x, y := input.X, input.Y
	if !input.Pixels {
		if x >= cols || y >= rows {
			return nil, fmt.Errorf("mouse cell outside %dx%d terminal", cols, rows)
		}
		x, y = x*cw+cw/2, y*ch+ch/2
	}
	if x >= cols*cw || y >= rows*ch {
		return nil, errors.New("mouse position outside terminal")
	}
	event.SetPosition(vt.MousePosition{X: float32(x), Y: float32(y)})
	encoder, err := vt.NewMouseEncoder()
	if err != nil {
		return nil, err
	}
	defer encoder.Close()
	encoder.SetOptFromTerminal(b.terminal)
	encoder.SetOptSize(vt.MouseEncoderSize{ScreenWidth: cols * cw, ScreenHeight: rows * ch, CellWidth: cw, CellHeight: ch})
	encoder.SetOptTrackLastCell(false)
	encoder.SetOptAnyButtonPressed(pressed)
	return encoder.Encode(event)
}
