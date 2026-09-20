package mux

import (
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	vt "go.mitchellh.com/libghostty"
)

type KeyInput struct {
	Name   string `json:"name"`
	Action string `json:"action,omitempty"`
	Mods   string `json:"mods,omitempty"`
	Text   string `json:"text,omitempty"`
}
type MouseInput struct {
	Button string `json:"button,omitempty"`
	Action string `json:"action,omitempty"`
	Mods   string `json:"mods,omitempty"`
	X      uint32 `json:"x"`
	Y      uint32 `json:"y"`
	Pixels bool   `json:"pixels,omitempty"`
}

func (b *Block) encodeInput(r Request) ([]byte, error) {
	if r.Method == "block.key" {
		if r.Key == nil {
			return nil, errors.New("key is missing")
		}
		input := *r.Key
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
		aliases := map[string]string{"up": "arrow_up", "down": "arrow_down", "left": "arrow_left", "right": "arrow_right", "return": "enter", "esc": "escape", "pageup": "page_up", "pagedown": "page_down"}
		if alias := aliases[name]; alias != "" {
			name = alias
		}
		var codepoint rune
		if utf8.RuneCountInString(name) == 1 {
			codepoint, _ = utf8.DecodeRuneInString(name)
			if codepoint >= 'a' && codepoint <= 'z' {
				name = "key_" + name
			} else if codepoint >= '0' && codepoint <= '9' {
				name = "digit_" + name
			} else {
				names := map[rune]string{' ': "space", '-': "minus", '=': "equal", '[': "bracket_left", ']': "bracket_right", '\\': "backslash", ';': "semicolon", '\'': "quote", ',': "comma", '.': "period", '/': "slash", '`': "backquote"}
				name = names[codepoint]
				if name == "" {
					name = "unidentified"
				}
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
	if r.Mouse == nil {
		return nil, errors.New("mouse is missing")
	}
	input := r.Mouse
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
	if input.Button != "" && input.Button != "none" {
		button, err := vt.ParseMouseButton(input.Button)
		if err != nil {
			return nil, err
		}
		event.SetButton(button)
	} else {
		event.ClearButton()
	}
	cw, ch := max(uint32(1), b.cellWidth), max(uint32(1), b.cellHeight)
	x, y := input.X, input.Y
	if !input.Pixels {
		if x >= uint32(b.info.Cols) || y >= uint32(b.info.Rows) {
			return nil, fmt.Errorf("mouse cell outside %dx%d terminal", b.info.Cols, b.info.Rows)
		}
		x = x*cw + cw/2
		y = y*ch + ch/2
	}
	if x >= uint32(b.info.Cols)*cw || y >= uint32(b.info.Rows)*ch {
		return nil, errors.New("mouse position outside terminal")
	}
	event.SetPosition(vt.MousePosition{X: float32(x), Y: float32(y)})
	encoder, err := vt.NewMouseEncoder()
	if err != nil {
		return nil, err
	}
	defer encoder.Close()
	encoder.SetOptFromTerminal(b.terminal)
	encoder.SetOptSize(vt.MouseEncoderSize{ScreenWidth: uint32(b.info.Cols) * cw, ScreenHeight: uint32(b.info.Rows) * ch, CellWidth: cw, CellHeight: ch})
	encoder.SetOptTrackLastCell(false)
	encoder.SetOptAnyButtonPressed(input.Button != "" && input.Button != "none")
	return encoder.Encode(event)
}
