#ifndef ILLOGICAL_TERMINAL_BRIDGE_H
#define ILLOGICAL_TERMINAL_BRIDGE_H

// The C boundary between the Swift client and libghostty-vt. This is also the
// app's Swift bridging header, so it never exposes Ghostty's own types.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Same shape as Foundation's NS_CLOSED_ENUM / NS_OPTIONS, so Swift imports
// these as real enums and option sets without depending on Foundation.
#define IL_ENUM(type, name) enum __attribute__((enum_extensibility(closed))) name : type name; enum name : type
#define IL_OPTIONS(type, name) enum __attribute__((flag_enum, enum_extensibility(open))) name : type name; enum name : type

// MARK: - Process and socket helpers

double il_process_age_ms(void);
int il_connect_unix(const char *path);

// MARK: - Colors (packed 0xRRGGBB)

bool il_color_parse(const char *value, size_t length, uint32_t *color);
bool il_palette_parse_entry(const char *value, size_t length, uint8_t *index, uint32_t *color);
void il_palette_default(uint32_t *palette);
void il_palette_generate(uint32_t *palette, const bool *explicitColors, uint32_t background, uint32_t foreground, bool harmonious);
bool il_color_is_light(uint32_t color);

// MARK: - Frames

/// Bits of `ILCell.flags`.
typedef IL_OPTIONS(uint8_t, ILCellFlags) {
    ILCellFlagBold = 1 << 0,
    ILCellFlagItalic = 1 << 1,
    ILCellFlagUnderline = 1 << 2,
    ILCellFlagSelected = 1 << 3,
    ILCellFlagStrikethrough = 1 << 4,
    ILCellFlagOverline = 1 << 5,
    ILCellFlagSearchMatch = 1 << 6,
    ILCellFlagActiveSearchMatch = 1 << 7,
};

/// Bits of `ILCell.attributes`.
typedef IL_OPTIONS(uint8_t, ILCellAttributes) {
    ILCellAttributeUnderlineColor = 1 << 0,
    ILCellAttributeInvisible = 1 << 1,
    ILCellAttributeBlink = 1 << 2,
    ILCellAttributeExplicitBackground = 1 << 3,
    ILCellAttributeInverse = 1 << 4,
};

/// Values of `ILFrame.cursorStyle`.
typedef IL_ENUM(int, ILCursorStyle) {
    ILCursorStyleBar = 0,
    ILCursorStyleBlock = 1,
    ILCursorStyleUnderline = 2,
    ILCursorStyleBlockHollow = 3,
};

typedef struct {
    uint32_t foreground, background, underlineColor;
    uint16_t column, row;
    /// 0 for the spacer half of a wide character.
    uint8_t width;
    /// `ILCellFlags` bits.
    uint8_t flags;
    /// Ghostty underline style: 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    uint8_t underlineStyle;
    /// `ILCellAttributes` bits.
    uint8_t attributes;
    /// NUL-terminated UTF-8 grapheme; the base codepoint when a cluster is too long.
    char text[128];
} ILCell;

typedef struct {
    uint16_t columns, rows, cursorColumn, cursorRow;
    uint32_t background, foreground, cursorColor;
    bool cursorVisible, cursorBlinking;
    /// `ILCursorStyle` value.
    int cursorStyle;
    uint64_t scrollTotal, scrollOffset, scrollLength;
    size_t count, searchCount, searchSelected;
    /// Viewport row of the selected search match, or -1.
    int searchRow;
    /// `count` cells in row-major order, owned by the terminal until its next frame.
    const ILCell *cells;
} ILFrame;

// MARK: - Terminal lifecycle

typedef struct ILTerminal ILTerminal;

/// Viewport and selection in history-independent coordinates, used to keep a
/// user's place while a snapshot is replaced and its history streams in.
typedef struct {
    uint64_t viewportRow, startRow, endRow;
    uint16_t startColumn, endColumn;
    int screen;
    bool followsBottom, hasSelection, rectangle;
} ILTerminalViewState;

ILTerminal *il_terminal_new(uint16_t columns, uint16_t rows);
/// Restores the first chunk of a service snapshot; history arrives through `il_terminal_history`.
ILTerminal *il_terminal_restore(const uint8_t *data, size_t length);
void il_terminal_free(ILTerminal *terminal);
/// Returns 0 on success, a negative bridge error or a positive Ghostty result.
int il_terminal_history(ILTerminal *terminal, const uint8_t *data, size_t length, bool final);
void il_terminal_feed(ILTerminal *terminal, const uint8_t *data, size_t length);
void il_terminal_resize(ILTerminal *terminal, uint16_t columns, uint16_t rows, uint32_t cellWidth, uint32_t cellHeight);
bool il_terminal_frame(ILTerminal *terminal, ILFrame *frame);
bool il_terminal_capture_view(ILTerminal *terminal, ILTerminalViewState *state);
void il_terminal_restore_view(ILTerminal *terminal, const ILTerminalViewState *state);

// MARK: - Synchronized output (DEC mode 2026)

/// Milliseconds until a held frame is released, or 0 when nothing is held.
double il_terminal_render_hold_remaining(ILTerminal *terminal);
/// Releases a hold whose deadline passed. Returns true when it did.
bool il_terminal_expire_render_hold(ILTerminal *terminal);

// MARK: - Colors

void il_terminal_theme(ILTerminal *terminal, uint32_t background, uint32_t foreground, uint32_t cursor, const uint32_t *palette);
/// NULL RGB values restore renderer defaults (black/white; cursor follows text).
/// Palette is NULL for the built-in palette, or exactly 256 packed RGB values.
void il_terminal_theme_override(ILTerminal *terminal, const uint32_t *background, const uint32_t *foreground, const uint32_t *cursor, const uint32_t *palette);
bool il_terminal_default_palette(ILTerminal *terminal, uint32_t *palette);
/// The cursor shown until a program selects one with DECSCUSR, and after it
/// resets with `CSI 0 SP q` (Ghostty's `cursor-style` and `cursor-style-blink`).
void il_terminal_set_default_cursor(ILTerminal *terminal, ILCursorStyle style, bool blink);

// MARK: - Viewport

void il_terminal_scroll(ILTerminal *terminal, int64_t delta);
/// Row 0 is the top of the scrollback.
void il_terminal_scroll_to(ILTerminal *terminal, uint64_t row);
void il_terminal_scroll_top(ILTerminal *terminal);
void il_terminal_scroll_bottom(ILTerminal *terminal);
/// Rows between the viewport and the live bottom.
uint64_t il_terminal_scroll_distance(ILTerminal *terminal);
/// Moves the viewport top to the `delta`th shell prompt (OSC 133) above
/// (negative) or below (positive) it. Returns false when there is none.
bool il_terminal_jump_to_prompt(ILTerminal *terminal, int delta);

// MARK: - Keyboard

/// Matches `GhosttyMods` bit for bit; the side bits mean "the right-hand key".
typedef IL_OPTIONS(uint16_t, ILModifiers) {
    ILModifierShift = 1 << 0,
    ILModifierControl = 1 << 1,
    ILModifierOption = 1 << 2,
    ILModifierCommand = 1 << 3,
    ILModifierCapsLock = 1 << 4,
    ILModifierNumLock = 1 << 5,
    ILModifierRightShift = 1 << 6,
    ILModifierRightControl = 1 << 7,
    ILModifierRightOption = 1 << 8,
    ILModifierRightCommand = 1 << 9,
};

typedef IL_ENUM(uint8_t, ILKeyAction) {
    ILKeyActionRelease = 0,
    ILKeyActionPress = 1,
    ILKeyActionRepeat = 2,
};

/// Which Option keys act as Alt (Meta) instead of composing characters.
/// Mirrors Ghostty's `macos-option-as-alt`.
typedef IL_ENUM(uint8_t, ILOptionAsAlt) {
    ILOptionAsAltDisabled = 0,
    ILOptionAsAltBoth = 1,
    ILOptionAsAltLeft = 2,
    ILOptionAsAltRight = 3,
};

typedef struct {
    /// macOS virtual key code of the physical key.
    uint16_t keyCode;
    ILKeyAction action;
    ILModifiers modifiers;
    /// Modifiers the layout used to produce `text`.
    ILModifiers consumedModifiers;
    /// The key's character with no modifiers, or 0.
    uint32_t unshiftedCodepoint;
    /// UTF-8 text the key produced, without control characters.
    const char *text;
    size_t textLength;
    /// An input method is composing; legacy encoding sends nothing.
    bool composing;
    ILOptionAsAlt optionAsAlt;
} ILKeyEvent;

/// Encodes a key for the terminal's current modes. Returns the full encoded
/// length; bytes are written only when that fits in `capacity`.
size_t il_terminal_key(ILTerminal *terminal, const ILKeyEvent *event, char *out, size_t capacity);
/// True while a program has enabled any Kitty keyboard protocol flag.
bool il_terminal_kitty_keyboard(ILTerminal *terminal);

// MARK: - Mouse

typedef IL_ENUM(uint8_t, ILMouseAction) {
    ILMouseActionPress = 0,
    ILMouseActionRelease = 1,
    ILMouseActionMotion = 2,
};

/// X11 button numbers, as used by the mouse reporting protocols.
typedef IL_ENUM(uint8_t, ILMouseButton) {
    /// No button: plain motion.
    ILMouseButtonUnknown = 0,
    ILMouseButtonLeft = 1,
    ILMouseButtonRight = 2,
    ILMouseButtonMiddle = 3,
    ILMouseButtonWheelUp = 4,
    ILMouseButtonWheelDown = 5,
    ILMouseButtonWheelLeft = 6,
    ILMouseButtonWheelRight = 7,
    ILMouseButtonBack = 8,
    ILMouseButtonForward = 9,
    ILMouseButtonTen = 10,
    ILMouseButtonEleven = 11,
};

/// Encodes a mouse report at a pixel position. Returns bytes written; 0 when
/// the active protocol does not report this event.
size_t il_terminal_mouse(ILTerminal *terminal, ILMouseAction action, ILMouseButton button, ILModifiers modifiers,
                         float x, float y, float cellWidth, float cellHeight, char *out, size_t capacity);
/// True while a program has enabled any mouse reporting mode.
bool il_terminal_mouse_reporting(ILTerminal *terminal);
/// Cursor keys that replace wheel scrolling on the alternate screen (DEC
/// mode 1007). Returns bytes written; 0 when wheel scrolling applies.
size_t il_terminal_alternate_scroll(ILTerminal *terminal, bool up, char *out, size_t capacity);

// MARK: - Focus and paste

/// Focus report (DEC mode 1004). Returns bytes written; 0 when disabled.
size_t il_terminal_focus(ILTerminal *terminal, bool focused, char *out, size_t capacity);
/// Encodes a paste for the current bracketed-paste mode. Returns the full
/// encoded length; bytes are written only when that fits in `capacity`.
size_t il_terminal_paste(ILTerminal *terminal, const char *text, size_t length, char *out, size_t capacity);
/// Ghostty's clipboard-paste-protection rule: an unbracketed paste with a
/// newline, or any paste that tries to end bracketed paste early.
bool il_terminal_paste_is_unsafe(ILTerminal *terminal, const char *text, size_t length);

// MARK: - Selection

typedef IL_ENUM(uint8_t, ILSelectionEvent) {
    ILSelectionEventPress = 0,
    ILSelectionEventDrag = 1,
    ILSelectionEventRelease = 2,
    ILSelectionEventAutoscrollTick = 3,
};

/// Feeds Ghostty's click/drag selection gesture (word and line clicks,
/// Option rectangles) at a viewport cell and its pixel position.
void il_terminal_select(ILTerminal *terminal, ILSelectionEvent event, uint16_t column, uint16_t row, float x, float y,
                        float cellWidth, float cellHeight, uint64_t timeNanos, bool rectangle);
/// True while a held drag sits at a viewport edge and should keep scrolling.
bool il_terminal_selection_autoscroll(ILTerminal *terminal);
void il_terminal_selection_cancel(ILTerminal *terminal);
void il_terminal_select_all(ILTerminal *terminal);
/// Moves the end of an existing selection to a viewport cell. Returns false without a selection.
bool il_terminal_extend_selection(ILTerminal *terminal, uint16_t column, uint16_t row);
void il_terminal_clear_selection(ILTerminal *terminal);
/// Selected text with soft wraps joined and trailing whitespace trimmed.
/// Free with `il_bytes_free`.
char *il_terminal_copy(ILTerminal *terminal, size_t *length);
void il_bytes_free(void *bytes);

// MARK: - Search and links

typedef IL_ENUM(int8_t, ILSearchNavigation) {
    ILSearchNavigationPrevious = -1,
    ILSearchNavigationStay = 0,
    ILSearchNavigationNext = 1,
};

/// An empty query ends the search.
void il_terminal_search(ILTerminal *terminal, const char *text, size_t length, ILSearchNavigation navigation);
/// The OSC 8 target or plain URL under a viewport cell. Free with `il_bytes_free`.
char *il_terminal_link(ILTerminal *terminal, uint16_t column, uint16_t row);

#endif
