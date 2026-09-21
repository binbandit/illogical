#ifndef ILLOGICAL_TERMINAL_BRIDGE_H
#define ILLOGICAL_TERMINAL_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ILTerminal ILTerminal;
typedef struct {
    uint64_t viewportRow, startRow, endRow;
    uint16_t startColumn, endColumn;
    int screen;
    bool followsBottom, hasSelection, rectangle;
} ILTerminalViewState;
double il_process_age_ms(void);
int il_connect_unix(const char *path);
bool il_color_parse(const char *value, size_t length, uint32_t *color);
bool il_palette_parse_entry(const char *value, size_t length, uint8_t *index, uint32_t *color);
void il_palette_default(uint32_t *palette);
void il_palette_generate(uint32_t *palette, const bool *explicitColors, uint32_t background, uint32_t foreground, bool harmonious);
bool il_color_is_light(uint32_t color);
typedef struct {
    uint32_t foreground, background, underlineColor;
    uint16_t column, row;
    uint8_t width, flags, underlineStyle, attributes;
    char text[128];
} ILCell;

typedef struct {
    uint16_t columns, rows, cursorColumn, cursorRow;
    uint32_t background, foreground, cursorColor;
    bool cursorVisible, cursorBlinking;
    int cursorStyle;
    uint64_t scrollTotal, scrollOffset, scrollLength;
    size_t count, searchCount, searchSelected;
    int searchRow;
    const ILCell *cells;
} ILFrame;

ILTerminal *il_terminal_new(uint16_t columns, uint16_t rows);
ILTerminal *il_terminal_restore(const uint8_t *data, size_t length);
void il_terminal_free(ILTerminal *terminal);
int il_terminal_history(ILTerminal *terminal, const uint8_t *data, size_t length, bool final);
void il_terminal_feed(ILTerminal *terminal, const uint8_t *data, size_t length);
void il_terminal_resize(ILTerminal *terminal, uint16_t columns, uint16_t rows, uint32_t cellWidth, uint32_t cellHeight);
bool il_terminal_frame(ILTerminal *terminal, ILFrame *frame);
double il_terminal_render_hold_remaining(ILTerminal *terminal);
bool il_terminal_expire_render_hold(ILTerminal *terminal);
void il_terminal_theme(ILTerminal *terminal, uint32_t background, uint32_t foreground, uint32_t cursor, const uint32_t *palette);
// NULL RGB values restore renderer defaults (black/white; cursor follows text).
// Palette is NULL for the built-in palette, or exactly 256 packed RGB values.
void il_terminal_theme_override(ILTerminal *terminal, const uint32_t *background, const uint32_t *foreground, const uint32_t *cursor, const uint32_t *palette);
bool il_terminal_default_palette(ILTerminal *terminal, uint32_t *palette);
void il_terminal_scroll(ILTerminal *terminal, int64_t delta);
void il_terminal_scroll_to(ILTerminal *terminal, uint64_t row);
void il_terminal_scroll_bottom(ILTerminal *terminal);
uint64_t il_terminal_scroll_distance(ILTerminal *terminal);
bool il_terminal_capture_view(ILTerminal *terminal, ILTerminalViewState *state);
void il_terminal_restore_view(ILTerminal *terminal, const ILTerminalViewState *state);
size_t il_terminal_key(ILTerminal *terminal, uint16_t keycode, uint16_t modifiers, uint16_t consumed, int action, const char *text, size_t textLength, uint32_t unshifted, char *out, size_t capacity);
size_t il_terminal_mouse(ILTerminal *terminal, int action, int button, uint16_t modifiers, float x, float y, float cellWidth, float cellHeight, char *out, size_t capacity);
bool il_terminal_mouse_reporting(ILTerminal *terminal);
size_t il_terminal_alternate_scroll(ILTerminal *terminal, bool up, char *out, size_t capacity);
size_t il_terminal_focus(ILTerminal *terminal, bool focused, char *out, size_t capacity);
size_t il_terminal_paste(ILTerminal *terminal, char *text, size_t length, char *out, size_t capacity);
void il_terminal_select(ILTerminal *terminal, int action, uint16_t column, uint16_t row, float x, float y, float cellWidth, float cellHeight, uint64_t timeNanos, bool rectangle);
bool il_terminal_selection_autoscroll(ILTerminal *terminal);
void il_terminal_selection_cancel(ILTerminal *terminal);
void il_terminal_select_all(ILTerminal *terminal);
char *il_terminal_copy(ILTerminal *terminal, size_t *length);
void il_bytes_free(void *bytes);
void il_terminal_search(ILTerminal *terminal, const char *text, size_t length, int direction);
char *il_terminal_link(ILTerminal *terminal, uint16_t column, uint16_t row);
#endif
