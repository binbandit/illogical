#include "Bridge.h"

// Only Carbon's virtual key code constants are used; keep its legacy
// unprefixed assertion macros (check, verify, require) out of scope.
#define __ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES 0
#include <Carbon/Carbon.h>
#include <ctype.h>
#include <errno.h>
#include <ghostty/vt.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

// The public enums mirror Ghostty's values so they cross the boundary as-is.
_Static_assert(ILModifierShift == GHOSTTY_MODS_SHIFT && ILModifierControl == GHOSTTY_MODS_CTRL &&
               ILModifierOption == GHOSTTY_MODS_ALT && ILModifierCommand == GHOSTTY_MODS_SUPER &&
               ILModifierCapsLock == GHOSTTY_MODS_CAPS_LOCK && ILModifierNumLock == GHOSTTY_MODS_NUM_LOCK &&
               ILModifierRightShift == GHOSTTY_MODS_SHIFT_SIDE && ILModifierRightControl == GHOSTTY_MODS_CTRL_SIDE &&
               ILModifierRightOption == GHOSTTY_MODS_ALT_SIDE && ILModifierRightCommand == GHOSTTY_MODS_SUPER_SIDE,
               "ILModifiers must match GhosttyMods");
_Static_assert((int)ILKeyActionRelease == GHOSTTY_KEY_ACTION_RELEASE && (int)ILKeyActionPress == GHOSTTY_KEY_ACTION_PRESS &&
               (int)ILKeyActionRepeat == GHOSTTY_KEY_ACTION_REPEAT, "ILKeyAction must match GhosttyKeyAction");
_Static_assert((int)ILOptionAsAltDisabled == GHOSTTY_OPTION_AS_ALT_FALSE && (int)ILOptionAsAltBoth == GHOSTTY_OPTION_AS_ALT_TRUE &&
               (int)ILOptionAsAltLeft == GHOSTTY_OPTION_AS_ALT_LEFT && (int)ILOptionAsAltRight == GHOSTTY_OPTION_AS_ALT_RIGHT,
               "ILOptionAsAlt must match GhosttyOptionAsAlt");
_Static_assert((int)ILMouseActionPress == GHOSTTY_MOUSE_ACTION_PRESS && (int)ILMouseActionRelease == GHOSTTY_MOUSE_ACTION_RELEASE &&
               (int)ILMouseActionMotion == GHOSTTY_MOUSE_ACTION_MOTION, "ILMouseAction must match GhosttyMouseAction");
_Static_assert((int)ILMouseButtonLeft == GHOSTTY_MOUSE_BUTTON_LEFT && (int)ILMouseButtonWheelUp == GHOSTTY_MOUSE_BUTTON_FOUR &&
               (int)ILMouseButtonEleven == GHOSTTY_MOUSE_BUTTON_ELEVEN, "ILMouseButton must match GhosttyMouseButton");
_Static_assert((int)ILCursorStyleBar == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR &&
               (int)ILCursorStyleBlockHollow == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW &&
               (int)ILCursorStyleBar == GHOSTTY_TERMINAL_CURSOR_STYLE_BAR &&
               (int)ILCursorStyleBlockHollow == GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW,
               "ILCursorStyle must match Ghostty's cursor styles");

// MARK: - Process and socket helpers

int il_connect_unix(const char *path) {
    struct sockaddr_un address = {0};
    if (strlen(path) >= sizeof(address.sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strcpy(address.sun_path, path);

    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(descriptor);
        return -1;
    }
    int enabled = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    return descriptor;
}

double il_process_age_ms(void) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    struct timeval now;
    gettimeofday(&now, NULL);
    return ((double)now.tv_sec - (double)info.pbi_start_tvsec) * 1000.0 +
           ((double)now.tv_usec - (double)info.pbi_start_tvusec) / 1000.0;
}

// MARK: - Colors

static uint32_t pack(GhosttyColorRgb color) {
    return ((uint32_t)color.r << 16) | ((uint32_t)color.g << 8) | color.b;
}

static GhosttyColorRgb unpack(uint32_t color) {
    return (GhosttyColorRgb){.r = (uint8_t)(color >> 16), .g = (uint8_t)(color >> 8), .b = (uint8_t)color};
}

bool il_color_parse(const char *value, size_t length, uint32_t *color) {
    GhosttyColorRgb rgb;
    if (!color || ghostty_color_parse(value, length, &rgb) != GHOSTTY_SUCCESS) return false;
    *color = pack(rgb);
    return true;
}

bool il_palette_parse_entry(const char *value, size_t length, uint8_t *index, uint32_t *color) {
    GhosttyColorRgb rgb;
    if (!index || !color || ghostty_color_parse_palette_entry(value, length, index, &rgb) != GHOSTTY_SUCCESS) return false;
    *color = pack(rgb);
    return true;
}

void il_palette_default(uint32_t *palette) {
    if (!palette) return;
    GhosttyColorRgb colors[256];
    ghostty_color_palette_default(colors);
    for (int i = 0; i < 256; i++) palette[i] = pack(colors[i]);
}

void il_palette_generate(uint32_t *palette, const bool *explicitColors, uint32_t background, uint32_t foreground, bool harmonious) {
    if (!palette) return;
    GhosttyColorRgb colors[256];
    GhosttyColorPaletteMask keep = {0};
    for (int i = 0; i < 256; i++) {
        colors[i] = unpack(palette[i]);
        if (explicitColors && explicitColors[i]) GHOSTTY_COLOR_PALETTE_MASK_SET(&keep, i);
    }
    GhosttyColorRgb backgroundColor = unpack(background), foregroundColor = unpack(foreground);
    ghostty_color_palette_generate(colors, &keep, &backgroundColor, &foregroundColor, harmonious, colors);
    for (int i = 0; i < 256; i++) palette[i] = pack(colors[i]);
}

bool il_color_is_light(uint32_t color) {
    GhosttyColorRgb rgb = unpack(color);
    return ghostty_color_perceived_luminance(&rgb) > 0.5;
}

// MARK: - Terminal state

// Ghostty's own deadline for an unfinished synchronized update.
static const double RENDER_HOLD_MS = 1000;

enum {
    // The service owns images; the replica only has to parse (and drop) them.
    APC_KITTY_MAX_BYTES = 12 << 20,
    SNAPSHOT_CONTINUATION_MAX_BYTES = 16 << 20,
};

typedef enum { SCREEN_PRIMARY, SCREEN_ALTERNATE, SCREEN_COUNT } ScreenIndex;

struct ILTerminal {
    GhosttyTerminal terminal;
    GhosttyRenderState render;
    GhosttyRenderStateRowIterator rows;
    GhosttyRenderStateRowCells cells;
    GhosttyKeyEncoder key;
    GhosttyMouseEncoder mouse;
    GhosttyMouseEncoderSize mouseSize;
    bool mouseModesChanged;
    GhosttySelectionGesture gesture;
    GhosttySearch search;
    GhosttySelection *searchMatches;
    size_t searchMatchCapacity;

    // A restored snapshot streams its scrollback afterwards. Until the last
    // chunk arrives, rows missing from the top shift history coordinates.
    GhosttySnapshotDecoder decoder;
    uint64_t missingHistory[SCREEN_COUNT];
    struct {
        uint8_t *data;
        size_t length, offset;
    } chunk;

    // Cells are rebuilt only for dirty rows; the buffer persists between frames.
    ILCell *frameCells;
    size_t frameCapacity;
    uint16_t frameColumns, frameRows;
    bool hasFrame, forceFullFrame;

    // Synchronized output shows the frame captured when the hold began.
    bool renderHeld;
    double renderHoldDeadline;
    ILFrame heldFrame;
};

static ScreenIndex active_screen(ILTerminal *t) {
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    return screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY ? SCREEN_PRIMARY : SCREEN_ALTERNATE;
}

static bool mode_enabled(ILTerminal *t, GhosttyMode mode) {
    GhosttyTerminalModeConfig config = {.mode = mode};
    return ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS && config.value;
}

static GhosttyTerminalScrollbar scrollbar(ILTerminal *t) {
    GhosttyTerminalScrollbar bar = {0};
    ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);
    return bar;
}

/// First scrollbar row of the live bottom.
static uint64_t bottom_row(GhosttyTerminalScrollbar bar) {
    return bar.total > bar.len ? bar.total - bar.len : 0;
}

static void grid_size(ILTerminal *t, uint16_t *columns, uint16_t *rows) {
    *columns = 0;
    *rows = 0;
    ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_COLS, columns);
    ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_ROWS, rows);
}

// MARK: - Synchronized output

static double monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}

static void render_hold_changed(GhosttyTerminal terminal, void *userdata, bool held) {
    (void)terminal;
    ILTerminal *t = userdata;
    if (held) {
        // Capture at the escape sequence itself, before later bytes in the
        // same write can clear or partially redraw the screen.
        if (!il_terminal_frame(t, &t->heldFrame)) return;
        t->renderHoldDeadline = monotonic_ms() + RENDER_HOLD_MS;
    }
    t->renderHeld = held;
}

double il_terminal_render_hold_remaining(ILTerminal *t) {
    if (!t || !t->renderHeld) return 0;
    double remaining = t->renderHoldDeadline - monotonic_ms();
    return remaining > 0 ? remaining : 0;
}

bool il_terminal_expire_render_hold(ILTerminal *t) {
    if (!t || !t->renderHeld || monotonic_ms() < t->renderHoldDeadline) return false;
    GhosttyTerminalModeConfig mode = {.mode = GHOSTTY_MODE_SYNC_OUTPUT, .value = false};
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode);
    // A programmatic mode change does not invoke the render hold callback.
    t->renderHeld = false;
    return true;
}

// MARK: - Lifecycle

static bool read_snapshot_chunk(void *context, uint8_t *buffer, size_t capacity, size_t *count) {
    ILTerminal *t = context;
    size_t remaining = t->chunk.length - t->chunk.offset;
    *count = remaining < capacity ? remaining : capacity;
    if (*count) memcpy(buffer, t->chunk.data + t->chunk.offset, *count);
    t->chunk.offset += *count;
    return true;
}

static bool set_snapshot_chunk(ILTerminal *t, const uint8_t *data, size_t length) {
    uint8_t *copy = malloc(length ? length : 1);
    if (!copy) return false;
    if (length) memcpy(copy, data, length);
    free(t->chunk.data);
    t->chunk.data = copy;
    t->chunk.length = length;
    t->chunk.offset = 0;
    return true;
}

static void release_snapshot_chunk(ILTerminal *t) {
    free(t->chunk.data);
    t->chunk.data = NULL;
    t->chunk.length = t->chunk.offset = 0;
}

static bool initialize(ILTerminal *t) {
    bool ready = ghostty_render_state_new(NULL, &t->render) == GHOSTTY_SUCCESS &&
                 ghostty_render_state_row_iterator_new(NULL, &t->rows) == GHOSTTY_SUCCESS &&
                 ghostty_render_state_row_cells_new(NULL, &t->cells) == GHOSTTY_SUCCESS &&
                 ghostty_key_encoder_new(NULL, &t->key) == GHOSTTY_SUCCESS &&
                 ghostty_mouse_encoder_new(NULL, &t->mouse) == GHOSTTY_SUCCESS &&
                 ghostty_selection_gesture_new(NULL, &t->gesture) == GHOSTTY_SUCCESS;
    if (!ready) return false;

    // The service owns Kitty image storage and protocol replies. Replicas only
    // keep the parser boundary and draw the service's bounded image scene.
    uint64_t imageLimit = 0;
    size_t apcLimit = APC_KITTY_MAX_BYTES;
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &imageLimit);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY, &apcLimit);

    // Suppress motion reports that stay within one cell.
    bool trackLastCell = true;
    ghostty_mouse_encoder_setopt(t->mouse, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell);
    t->mouseModesChanged = true;

    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, t);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, render_hold_changed);
    // A snapshot can arrive mid-update; honour its hold like live output.
    if (mode_enabled(t, GHOSTTY_MODE_SYNC_OUTPUT)) render_hold_changed(t->terminal, t, true);
    return true;
}

ILTerminal *il_terminal_new(uint16_t columns, uint16_t rows) {
    ILTerminal *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    if (ghostty_terminal_new(NULL, &t->terminal, columns, rows) != GHOSTTY_SUCCESS || !initialize(t)) {
        il_terminal_free(t);
        return NULL;
    }
    // Ghostty's default grapheme-width-method (unicode) starts terminals in
    // mode 2027. Restored snapshots carry the service's mode instead.
    GhosttyTerminalModeConfig graphemes = {.mode = GHOSTTY_MODE_GRAPHEME_CLUSTER, .value = true};
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_MODE, &graphemes);
    return t;
}

ILTerminal *il_terminal_restore(const uint8_t *data, size_t length) {
    ILTerminal *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    size_t continuationLimit = SNAPSHOT_CONTINUATION_MAX_BYTES;
    GhosttyReader reader = {.read = read_snapshot_chunk, .userdata = t};
    bool restored = set_snapshot_chunk(t, data, length) &&
                    ghostty_snapshot_decoder_new(NULL, &t->decoder, reader) == GHOSTTY_SUCCESS &&
                    ghostty_snapshot_decoder_set(t->decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,
                                                 &continuationLimit) == GHOSTTY_SUCCESS &&
                    ghostty_snapshot_decoder_ready(t->decoder, &t->terminal) == GHOSTTY_SUCCESS && initialize(t);
    if (!restored) {
        il_terminal_free(t);
        return NULL;
    }

    // Rows the snapshot declares but has not delivered yet.
    ScreenIndex screen = active_screen(t);
    uint64_t declared = 0;
    ghostty_snapshot_decoder_get(t->decoder,
                                 screen == SCREEN_PRIMARY ? GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY
                                                          : GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_ALTERNATE,
                                 &declared);
    uint64_t resident = bottom_row(scrollbar(t));
    t->missingHistory[screen] = declared > resident ? declared - resident : 0;
    return t;
}

void il_terminal_free(ILTerminal *t) {
    if (!t) return;
    ghostty_snapshot_decoder_free(t->decoder);
    ghostty_search_free(t->search);
    ghostty_selection_gesture_free(t->gesture, t->terminal);
    ghostty_key_encoder_free(t->key);
    ghostty_mouse_encoder_free(t->mouse);
    ghostty_render_state_row_cells_free(t->cells);
    ghostty_render_state_row_iterator_free(t->rows);
    ghostty_render_state_free(t->render);
    ghostty_terminal_free(t->terminal);
    free(t->chunk.data);
    free(t->frameCells);
    free(t->searchMatches);
    free(t);
}

int il_terminal_history(ILTerminal *t, const uint8_t *data, size_t length, bool final) {
    if (!t || !t->decoder || !set_snapshot_chunk(t, data, length)) return -1;
    GhosttyResult result = ghostty_snapshot_decoder_next(t->decoder);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) return (int)result;
    if (result == GHOSTTY_SUCCESS) {
        GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        size_t rows = 0;
        ghostty_snapshot_decoder_get(t->decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_SCREEN, &screen);
        ghostty_snapshot_decoder_get(t->decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS, &rows);
        uint64_t *missing = &t->missingHistory[screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY ? SCREEN_PRIMARY : SCREEN_ALTERNATE];
        *missing = *missing > rows ? *missing - rows : 0;
    }
    if (final) {
        // The service marks the last chunk; the decoder must agree it is done.
        if (result != GHOSTTY_NO_VALUE) return -2;
        ghostty_snapshot_decoder_free(t->decoder);
        t->decoder = NULL;
        release_snapshot_chunk(t);
        memset(t->missingHistory, 0, sizeof(t->missingHistory));
    }
    return 0;
}

void il_terminal_feed(ILTerminal *t, const uint8_t *data, size_t length) {
    if (!t) return;
    ghostty_terminal_vt_write(t->terminal, data, length);
    t->mouseModesChanged = true;
}

void il_terminal_resize(ILTerminal *t, uint16_t columns, uint16_t rows, uint32_t cellWidth, uint32_t cellHeight) {
    if (t) ghostty_terminal_resize(t->terminal, columns, rows, cellWidth, cellHeight);
}

// MARK: - Frames

/// UTF-8 for a cell's base codepoint, used when its grapheme cluster does
/// not fit in `ILCell.text`.
static void base_codepoint_text(GhosttyCell raw, char text[128]) {
    uint32_t codepoint = 0;
    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint);
    unsigned char *out = (unsigned char *)text;
    if (codepoint <= 0x7f) {
        out[0] = (unsigned char)codepoint;
        out[1] = 0;
    } else if (codepoint <= 0x7ff) {
        out[0] = (unsigned char)(0xc0 | (codepoint >> 6));
        out[1] = (unsigned char)(0x80 | (codepoint & 0x3f));
        out[2] = 0;
    } else if (codepoint <= 0xffff) {
        out[0] = (unsigned char)(0xe0 | (codepoint >> 12));
        out[1] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f));
        out[2] = (unsigned char)(0x80 | (codepoint & 0x3f));
        out[3] = 0;
    } else if (codepoint <= 0x10ffff) {
        out[0] = (unsigned char)(0xf0 | (codepoint >> 18));
        out[1] = (unsigned char)(0x80 | ((codepoint >> 12) & 0x3f));
        out[2] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f));
        out[3] = (unsigned char)(0x80 | (codepoint & 0x3f));
        out[4] = 0;
    } else {
        out[0] = 0;
    }
}

static void fill_cell(ILTerminal *t, ILCell *cell, const GhosttyRenderStateColors *colors, bool selected) {
    GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
    ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
    GhosttyColorRgb foreground = colors->foreground, background = colors->background;
    ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground);
    ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background);
    if (style.inverse) {
        GhosttyColorRgb swap = foreground;
        foreground = background;
        background = swap;
    }
    if (style.faint) {
        foreground.r = (uint8_t)((foreground.r + background.r) / 2);
        foreground.g = (uint8_t)((foreground.g + background.g) / 2);
        foreground.b = (uint8_t)((foreground.b + background.b) / 2);
    }
    cell->foreground = pack(foreground);
    cell->background = pack(background);

    ILCellFlags flags = 0;
    if (style.bold) flags |= ILCellFlagBold;
    if (style.italic) flags |= ILCellFlagItalic;
    if (style.underline) flags |= ILCellFlagUnderline;
    if (selected) flags |= ILCellFlagSelected;
    if (style.strikethrough) flags |= ILCellFlagStrikethrough;
    if (style.overline) flags |= ILCellFlagOverline;
    cell->underlineStyle = (uint8_t)style.underline;

    ILCellAttributes attributes = 0;
    if (style.underline_color.tag != GHOSTTY_STYLE_COLOR_NONE) attributes |= ILCellAttributeUnderlineColor;
    if (style.invisible) attributes |= ILCellAttributeInvisible;
    if (style.blink) attributes |= ILCellAttributeBlink;
    if (style.bg_color.tag != GHOSTTY_STYLE_COLOR_NONE) attributes |= ILCellAttributeExplicitBackground;
    if (style.inverse) attributes |= ILCellAttributeInverse;

    switch (style.underline_color.tag) {
    case GHOSTTY_STYLE_COLOR_RGB: cell->underlineColor = pack(style.underline_color.value.rgb); break;
    case GHOSTTY_STYLE_COLOR_PALETTE: cell->underlineColor = pack(colors->palette[style.underline_color.value.palette]); break;
    default: cell->underlineColor = cell->foreground; break;
    }
    if (style.invisible) {
        flags &= (ILCellFlags) ~(ILCellFlagUnderline | ILCellFlagStrikethrough | ILCellFlagOverline);
        cell->underlineStyle = 0;
    }
    cell->flags = flags;
    cell->attributes = attributes;

    GhosttyCell raw;
    GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
    ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
    cell->width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : wide == GHOSTTY_CELL_WIDE_NARROW ? 1 : 0;
    if (style.invisible || !cell->width) return;

    GhosttyBuffer buffer = {.ptr = (uint8_t *)cell->text, .cap = sizeof(cell->text) - 1};
    GhosttyResult result = ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer);
    if (result == GHOSTTY_SUCCESS) cell->text[buffer.len] = 0;
    // Keep per-cell memory bounded for pathological clusters. Ghostty still
    // keeps the complete text for copy and search.
    else if (result == GHOSTTY_OUT_OF_SPACE) base_codepoint_text(raw, cell->text);
}

/// Flags the visible part of a match. A wrapped match can start above or end
/// below the viewport, so its whole-screen interval is clipped. Returns the
/// viewport row where the visible part starts, or -1.
static int mark_match(ILTerminal *t, const GhosttySelection *match, const ILFrame *frame, ILCellFlags flag) {
    GhosttyPointCoordinate start, end;
    if (!frame->columns || !frame->count ||
        ghostty_terminal_point_from_grid_ref(t->terminal, &match->start, GHOSTTY_POINT_TAG_SCREEN, &start) != GHOSTTY_SUCCESS ||
        ghostty_terminal_point_from_grid_ref(t->terminal, &match->end, GHOSTTY_POINT_TAG_SCREEN, &end) != GHOSTTY_SUCCESS)
        return -1;
    uint64_t first = (uint64_t)start.y * frame->columns + start.x;
    uint64_t last = (uint64_t)end.y * frame->columns + end.x;
    if (last < first) {
        uint64_t swap = first;
        first = last;
        last = swap;
    }
    uint64_t visibleFirst = frame->scrollOffset * frame->columns, visibleEnd = visibleFirst + frame->count;
    if (last < visibleFirst || first >= visibleEnd) return -1;
    if (first < visibleFirst) first = visibleFirst;
    if (last >= visibleEnd) last = visibleEnd - 1;
    for (uint64_t index = first - visibleFirst; index <= last - visibleFirst; index++) t->frameCells[index].flags |= flag;
    return (int)((first - visibleFirst) / frame->columns);
}

static void mark_search(ILTerminal *t, ILFrame *frame) {
    ghostty_search_run(t->search);
    ghostty_search_get(t->search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &frame->searchCount);
    size_t selected = 0;
    if (ghostty_search_get(t->search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &selected) == GHOSTTY_SUCCESS)
        frame->searchSelected = selected + 1;

    GhosttySelectionBuffer matches = {.ptr = t->searchMatches, .cap = t->searchMatchCapacity};
    GhosttyResult result = ghostty_search_get(t->search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &matches);
    if (result == GHOSTTY_OUT_OF_SPACE && matches.len <= SIZE_MAX / sizeof(GhosttySelection)) {
        GhosttySelection *storage = realloc(t->searchMatches, matches.len * sizeof(GhosttySelection));
        if (storage) {
            t->searchMatches = storage;
            t->searchMatchCapacity = matches.len;
            matches.ptr = storage;
            matches.cap = matches.len;
            result = ghostty_search_get(t->search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &matches);
        }
    }
    if (result == GHOSTTY_SUCCESS && matches.len <= matches.cap)
        for (size_t i = 0; i < matches.len; i++) mark_match(t, &matches.ptr[i], frame, ILCellFlagSearchMatch);

    GhosttySelection active = GHOSTTY_INIT_SIZED(GhosttySelection);
    if (ghostty_search_get(t->search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &active) == GHOSTTY_SUCCESS)
        frame->searchRow = mark_match(t, &active, frame, ILCellFlagActiveSearchMatch);
}

bool il_terminal_frame(ILTerminal *t, ILFrame *frame) {
    if (!t || !frame) return false;
    il_terminal_expire_render_hold(t);
    if (t->renderHeld) {
        *frame = t->heldFrame;
        return true;
    }
    if (ghostty_render_state_update(t->render, t->terminal) != GHOSTTY_SUCCESS) return false;

    memset(frame, 0, sizeof(*frame));
    frame->searchRow = -1;
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_COLS, &frame->columns);
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &frame->rows);
    size_t count = (size_t)frame->columns * frame->rows;
    if (count > t->frameCapacity) {
        ILCell *cells = realloc(t->frameCells, count * sizeof(ILCell));
        if (!cells) return false;
        t->frameCells = cells;
        t->frameCapacity = count;
    }
    frame->cells = t->frameCells;
    frame->count = count;
    // Search highlights are not tracked by dirty rows, so searching redraws everything.
    bool full = !t->hasFrame || t->frameColumns != frame->columns || t->frameRows != frame->rows || t->forceFullFrame || t->search;

    GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
    frame->background = pack(colors.background);
    frame->foreground = pack(colors.foreground);
    frame->cursorColor = pack(colors.cursor_has_value ? colors.cursor : colors.foreground);

    GhosttyRenderStateCursor cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
    frame->cursorColumn = cursor.viewport_x;
    frame->cursorRow = cursor.viewport_y;
    frame->cursorVisible = cursor.visible && cursor.viewport_has_value;
    frame->cursorBlinking = cursor.blinking;
    frame->cursorStyle = (int)cursor.visual_style;

    GhosttyTerminalScrollbar bar = scrollbar(t);
    frame->scrollTotal = bar.total;
    frame->scrollOffset = bar.offset;
    frame->scrollLength = bar.len;

    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &t->rows);
    uint16_t row = 0;
    while ((full ? ghostty_render_state_row_iterator_next(t->rows) : ghostty_render_state_row_iterator_next_dirty(t->rows, &row)) &&
           row < frame->rows) {
        ILCell *rowCells = t->frameCells + (size_t)row * frame->columns;
        memset(rowCells, 0, frame->columns * sizeof(ILCell));
        GhosttyRenderStateRowSelection selection = GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
        bool hasSelection = ghostty_render_state_row_get(t->rows, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS;
        ghostty_render_state_row_get(t->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &t->cells);
        for (uint16_t column = 0; column < frame->columns && ghostty_render_state_row_cells_next(t->cells); column++) {
            ILCell *cell = &rowCells[column];
            cell->column = column;
            cell->row = row;
            fill_cell(t, cell, &colors, hasSelection && column >= selection.start_x && column <= selection.end_x);
        }
        if (full) row++;
    }
    if (t->search) mark_search(t, frame);

    t->hasFrame = true;
    t->frameColumns = frame->columns;
    t->frameRows = frame->rows;
    t->forceFullFrame = false;
    ghostty_render_state_clean(t->render);
    return true;
}

// MARK: - View state

bool il_terminal_capture_view(ILTerminal *t, ILTerminalViewState *state) {
    if (!t || !state) return false;
    memset(state, 0, sizeof(*state));
    GhosttyTerminalScrollbar bar = {0};
    GhosttyTerminalScreen screen;
    if (ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar) != GHOSTTY_SUCCESS ||
        ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen) != GHOSTTY_SUCCESS)
        return false;
    uint64_t missing = t->missingHistory[active_screen(t)];
    state->screen = (int)screen;
    state->viewportRow = bar.offset + missing;
    state->followsBottom = bar.offset >= bottom_row(bar);

    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyPointCoordinate start, end;
    if (ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS &&
        ghostty_terminal_point_from_grid_ref(t->terminal, &selection.start, GHOSTTY_POINT_TAG_SCREEN, &start) == GHOSTTY_SUCCESS &&
        ghostty_terminal_point_from_grid_ref(t->terminal, &selection.end, GHOSTTY_POINT_TAG_SCREEN, &end) == GHOSTTY_SUCCESS) {
        state->hasSelection = true;
        state->rectangle = selection.rectangle;
        state->startColumn = start.x;
        state->endColumn = end.x;
        state->startRow = start.y + missing;
        state->endRow = end.y + missing;
    }
    return true;
}

void il_terminal_restore_view(ILTerminal *t, const ILTerminalViewState *state) {
    if (!t || !state) return;
    GhosttyTerminalScreen screen;
    ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    if ((int)screen != state->screen) return;
    uint64_t missing = t->missingHistory[active_screen(t)];
    if (state->followsBottom) il_terminal_scroll_bottom(t);
    else il_terminal_scroll_to(t, state->viewportRow > missing ? state->viewportRow - missing : 0);

    // A selection inside history that has not arrived yet cannot be restored.
    bool selectionResident = state->hasSelection && state->startRow >= missing && state->endRow >= missing &&
                             state->startRow - missing <= UINT32_MAX && state->endRow - missing <= UINT32_MAX;
    if (selectionResident) {
        GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
        selection.rectangle = state->rectangle;
        GhosttyPoint start = {.tag = GHOSTTY_POINT_TAG_SCREEN,
                              .value.coordinate = {.x = state->startColumn, .y = (uint32_t)(state->startRow - missing)}};
        GhosttyPoint end = {.tag = GHOSTTY_POINT_TAG_SCREEN,
                            .value.coordinate = {.x = state->endColumn, .y = (uint32_t)(state->endRow - missing)}};
        if (ghostty_terminal_grid_ref(t->terminal, start, &selection.start) == GHOSTTY_SUCCESS &&
            ghostty_terminal_grid_ref(t->terminal, end, &selection.end) == GHOSTTY_SUCCESS)
            ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
    }
    t->forceFullFrame = true;
}

// MARK: - Theme

void il_terminal_theme(ILTerminal *t, uint32_t background, uint32_t foreground, uint32_t cursor, const uint32_t *palette) {
    if (!t) return;
    t->forceFullFrame = true;
    GhosttyColorRgb backgroundColor = unpack(background), foregroundColor = unpack(foreground), cursorColor = unpack(cursor);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &backgroundColor);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foregroundColor);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursorColor);
    if (palette) {
        GhosttyColorRgb colors[256];
        for (int i = 0; i < 256; i++) colors[i] = unpack(palette[i]);
        ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &colors);
    }
}

void il_terminal_theme_override(ILTerminal *t, const uint32_t *background, const uint32_t *foreground, const uint32_t *cursor,
                                const uint32_t *palette) {
    if (!t) return;
    t->forceFullFrame = true;
    // Ghostty's renderer starts black on white, but its cached render colors
    // are left unchanged when a default becomes unset. Supply the visual
    // defaults explicitly in this replica; the service answers color queries.
    GhosttyColorRgb backgroundColor = unpack(background ? *background : 0);
    GhosttyColorRgb foregroundColor = unpack(foreground ? *foreground : 0xffffff);
    GhosttyColorRgb cursorColor = unpack(cursor ? *cursor : 0);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &backgroundColor);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foregroundColor);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, cursor ? &cursorColor : NULL);
    GhosttyColorRgb colors[256];
    if (palette)
        for (int i = 0; i < 256; i++) colors[i] = unpack(palette[i]);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette ? &colors : NULL);
}

void il_terminal_set_default_cursor(ILTerminal *t, ILCursorStyle style, bool blink) {
    if (!t) return;
    // Ghostty applies these at once unless a program chose its own cursor.
    GhosttyTerminalCursorStyle cursor = (GhosttyTerminalCursorStyle)style;
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursor);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink);
}

bool il_terminal_default_palette(ILTerminal *t, uint32_t *palette) {
    if (!t || !palette) return false;
    GhosttyColorRgb colors[256];
    if (ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &colors) != GHOSTTY_SUCCESS) return false;
    for (int i = 0; i < 256; i++) palette[i] = pack(colors[i]);
    return true;
}

// MARK: - Viewport

static void scroll_viewport(ILTerminal *t, GhosttyTerminalScrollViewport behavior) {
    if (t) ghostty_terminal_scroll_viewport(t->terminal, behavior);
}

void il_terminal_scroll(ILTerminal *t, int64_t delta) {
    scroll_viewport(t, (GhosttyTerminalScrollViewport){.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA, .value.delta = (intptr_t)delta});
}

void il_terminal_scroll_to(ILTerminal *t, uint64_t row) {
    scroll_viewport(t, (GhosttyTerminalScrollViewport){.tag = GHOSTTY_SCROLL_VIEWPORT_ROW, .value.row = (size_t)row});
}

void il_terminal_scroll_top(ILTerminal *t) {
    scroll_viewport(t, (GhosttyTerminalScrollViewport){.tag = GHOSTTY_SCROLL_VIEWPORT_TOP});
}

void il_terminal_scroll_bottom(ILTerminal *t) {
    scroll_viewport(t, (GhosttyTerminalScrollViewport){.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM});
}

uint64_t il_terminal_scroll_distance(ILTerminal *t) {
    if (!t) return 0;
    GhosttyTerminalScrollbar bar = scrollbar(t);
    uint64_t bottom = bottom_row(bar);
    return bottom > bar.offset ? bottom - bar.offset : 0;
}

static bool row_starts_prompt(ILTerminal *t, uint64_t y) {
    if (y > UINT32_MAX) return false;
    GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_SCREEN, .value.coordinate = {.x = 0, .y = (uint32_t)y}};
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttyRow row = 0;
    GhosttyRowSemanticPrompt prompt = GHOSTTY_ROW_SEMANTIC_NONE;
    return ghostty_terminal_grid_ref(t->terminal, point, &ref) == GHOSTTY_SUCCESS &&
           ghostty_grid_ref_row(&ref, &row) == GHOSTTY_SUCCESS &&
           ghostty_row_get(row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &prompt) == GHOSTTY_SUCCESS &&
           prompt == GHOSTTY_ROW_SEMANTIC_PROMPT;
}

bool il_terminal_jump_to_prompt(ILTerminal *t, int delta) {
    if (!t || delta == 0) return false;
    GhosttyTerminalScrollbar bar = scrollbar(t);
    uint64_t row = bar.offset;
    for (int remaining = abs(delta); remaining > 0; remaining--) {
        do {
            if (delta < 0 ? row == 0 : row + 1 >= bar.total) return false;
            row = delta < 0 ? row - 1 : row + 1;
        } while (!row_starts_prompt(t, row));
    }
    il_terminal_scroll_to(t, row);
    return true;
}

// MARK: - Keyboard

/// macOS virtual key codes to Ghostty's physical keys; matches Ghostty's own table.
static const GhosttyKey physical_keys[128] = {
    [kVK_ANSI_A] = GHOSTTY_KEY_A, [kVK_ANSI_B] = GHOSTTY_KEY_B, [kVK_ANSI_C] = GHOSTTY_KEY_C,
    [kVK_ANSI_D] = GHOSTTY_KEY_D, [kVK_ANSI_E] = GHOSTTY_KEY_E, [kVK_ANSI_F] = GHOSTTY_KEY_F,
    [kVK_ANSI_G] = GHOSTTY_KEY_G, [kVK_ANSI_H] = GHOSTTY_KEY_H, [kVK_ANSI_I] = GHOSTTY_KEY_I,
    [kVK_ANSI_J] = GHOSTTY_KEY_J, [kVK_ANSI_K] = GHOSTTY_KEY_K, [kVK_ANSI_L] = GHOSTTY_KEY_L,
    [kVK_ANSI_M] = GHOSTTY_KEY_M, [kVK_ANSI_N] = GHOSTTY_KEY_N, [kVK_ANSI_O] = GHOSTTY_KEY_O,
    [kVK_ANSI_P] = GHOSTTY_KEY_P, [kVK_ANSI_Q] = GHOSTTY_KEY_Q, [kVK_ANSI_R] = GHOSTTY_KEY_R,
    [kVK_ANSI_S] = GHOSTTY_KEY_S, [kVK_ANSI_T] = GHOSTTY_KEY_T, [kVK_ANSI_U] = GHOSTTY_KEY_U,
    [kVK_ANSI_V] = GHOSTTY_KEY_V, [kVK_ANSI_W] = GHOSTTY_KEY_W, [kVK_ANSI_X] = GHOSTTY_KEY_X,
    [kVK_ANSI_Y] = GHOSTTY_KEY_Y, [kVK_ANSI_Z] = GHOSTTY_KEY_Z,

    [kVK_ANSI_0] = GHOSTTY_KEY_DIGIT_0, [kVK_ANSI_1] = GHOSTTY_KEY_DIGIT_1, [kVK_ANSI_2] = GHOSTTY_KEY_DIGIT_2,
    [kVK_ANSI_3] = GHOSTTY_KEY_DIGIT_3, [kVK_ANSI_4] = GHOSTTY_KEY_DIGIT_4, [kVK_ANSI_5] = GHOSTTY_KEY_DIGIT_5,
    [kVK_ANSI_6] = GHOSTTY_KEY_DIGIT_6, [kVK_ANSI_7] = GHOSTTY_KEY_DIGIT_7, [kVK_ANSI_8] = GHOSTTY_KEY_DIGIT_8,
    [kVK_ANSI_9] = GHOSTTY_KEY_DIGIT_9,

    [kVK_ANSI_Equal] = GHOSTTY_KEY_EQUAL, [kVK_ANSI_Minus] = GHOSTTY_KEY_MINUS,
    [kVK_ANSI_LeftBracket] = GHOSTTY_KEY_BRACKET_LEFT, [kVK_ANSI_RightBracket] = GHOSTTY_KEY_BRACKET_RIGHT,
    [kVK_ANSI_Quote] = GHOSTTY_KEY_QUOTE, [kVK_ANSI_Semicolon] = GHOSTTY_KEY_SEMICOLON,
    [kVK_ANSI_Backslash] = GHOSTTY_KEY_BACKSLASH, [kVK_ANSI_Comma] = GHOSTTY_KEY_COMMA,
    [kVK_ANSI_Slash] = GHOSTTY_KEY_SLASH, [kVK_ANSI_Period] = GHOSTTY_KEY_PERIOD,
    [kVK_ANSI_Grave] = GHOSTTY_KEY_BACKQUOTE, [kVK_ISO_Section] = GHOSTTY_KEY_INTL_BACKSLASH,
    [kVK_JIS_Yen] = GHOSTTY_KEY_INTL_YEN, [kVK_JIS_Underscore] = GHOSTTY_KEY_INTL_RO,

    [kVK_Return] = GHOSTTY_KEY_ENTER, [kVK_Tab] = GHOSTTY_KEY_TAB, [kVK_Space] = GHOSTTY_KEY_SPACE,
    [kVK_Delete] = GHOSTTY_KEY_BACKSPACE, [kVK_ForwardDelete] = GHOSTTY_KEY_DELETE, [kVK_Escape] = GHOSTTY_KEY_ESCAPE,
    [kVK_Help] = GHOSTTY_KEY_INSERT, [kVK_Home] = GHOSTTY_KEY_HOME, [kVK_End] = GHOSTTY_KEY_END,
    [kVK_PageUp] = GHOSTTY_KEY_PAGE_UP, [kVK_PageDown] = GHOSTTY_KEY_PAGE_DOWN, [kVK_ContextualMenu] = GHOSTTY_KEY_CONTEXT_MENU,
    [kVK_LeftArrow] = GHOSTTY_KEY_ARROW_LEFT, [kVK_RightArrow] = GHOSTTY_KEY_ARROW_RIGHT,
    [kVK_DownArrow] = GHOSTTY_KEY_ARROW_DOWN, [kVK_UpArrow] = GHOSTTY_KEY_ARROW_UP,

    [kVK_Command] = GHOSTTY_KEY_META_LEFT, [kVK_RightCommand] = GHOSTTY_KEY_META_RIGHT,
    [kVK_Shift] = GHOSTTY_KEY_SHIFT_LEFT, [kVK_RightShift] = GHOSTTY_KEY_SHIFT_RIGHT,
    [kVK_Option] = GHOSTTY_KEY_ALT_LEFT, [kVK_RightOption] = GHOSTTY_KEY_ALT_RIGHT,
    [kVK_Control] = GHOSTTY_KEY_CONTROL_LEFT, [kVK_RightControl] = GHOSTTY_KEY_CONTROL_RIGHT,
    [kVK_CapsLock] = GHOSTTY_KEY_CAPS_LOCK,

    [kVK_ANSI_Keypad0] = GHOSTTY_KEY_NUMPAD_0, [kVK_ANSI_Keypad1] = GHOSTTY_KEY_NUMPAD_1, [kVK_ANSI_Keypad2] = GHOSTTY_KEY_NUMPAD_2,
    [kVK_ANSI_Keypad3] = GHOSTTY_KEY_NUMPAD_3, [kVK_ANSI_Keypad4] = GHOSTTY_KEY_NUMPAD_4, [kVK_ANSI_Keypad5] = GHOSTTY_KEY_NUMPAD_5,
    [kVK_ANSI_Keypad6] = GHOSTTY_KEY_NUMPAD_6, [kVK_ANSI_Keypad7] = GHOSTTY_KEY_NUMPAD_7, [kVK_ANSI_Keypad8] = GHOSTTY_KEY_NUMPAD_8,
    [kVK_ANSI_Keypad9] = GHOSTTY_KEY_NUMPAD_9, [kVK_ANSI_KeypadDecimal] = GHOSTTY_KEY_NUMPAD_DECIMAL,
    [kVK_ANSI_KeypadMultiply] = GHOSTTY_KEY_NUMPAD_MULTIPLY, [kVK_ANSI_KeypadPlus] = GHOSTTY_KEY_NUMPAD_ADD,
    [kVK_ANSI_KeypadClear] = GHOSTTY_KEY_NUMPAD_CLEAR, [kVK_ANSI_KeypadDivide] = GHOSTTY_KEY_NUMPAD_DIVIDE,
    [kVK_ANSI_KeypadEnter] = GHOSTTY_KEY_NUMPAD_ENTER, [kVK_ANSI_KeypadMinus] = GHOSTTY_KEY_NUMPAD_SUBTRACT,
    [kVK_ANSI_KeypadEquals] = GHOSTTY_KEY_NUMPAD_EQUAL, [kVK_JIS_KeypadComma] = GHOSTTY_KEY_NUMPAD_COMMA,

    [kVK_F1] = GHOSTTY_KEY_F1, [kVK_F2] = GHOSTTY_KEY_F2, [kVK_F3] = GHOSTTY_KEY_F3, [kVK_F4] = GHOSTTY_KEY_F4,
    [kVK_F5] = GHOSTTY_KEY_F5, [kVK_F6] = GHOSTTY_KEY_F6, [kVK_F7] = GHOSTTY_KEY_F7, [kVK_F8] = GHOSTTY_KEY_F8,
    [kVK_F9] = GHOSTTY_KEY_F9, [kVK_F10] = GHOSTTY_KEY_F10, [kVK_F11] = GHOSTTY_KEY_F11, [kVK_F12] = GHOSTTY_KEY_F12,
    [kVK_F13] = GHOSTTY_KEY_F13, [kVK_F14] = GHOSTTY_KEY_F14, [kVK_F15] = GHOSTTY_KEY_F15, [kVK_F16] = GHOSTTY_KEY_F16,
    [kVK_F17] = GHOSTTY_KEY_F17, [kVK_F18] = GHOSTTY_KEY_F18, [kVK_F19] = GHOSTTY_KEY_F19, [kVK_F20] = GHOSTTY_KEY_F20,

    [kVK_VolumeUp] = GHOSTTY_KEY_AUDIO_VOLUME_UP, [kVK_VolumeDown] = GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
    [kVK_Mute] = GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
};

static GhosttyKey physical_key(uint16_t keyCode) {
    return keyCode < sizeof(physical_keys) / sizeof(*physical_keys) ? physical_keys[keyCode] : GHOSTTY_KEY_UNIDENTIFIED;
}

size_t il_terminal_key(ILTerminal *t, const ILKeyEvent *key, char *out, size_t capacity) {
    if (!t || !key) return 0;
    GhosttyKeyEvent event = NULL;
    if (ghostty_key_event_new(NULL, &event) != GHOSTTY_SUCCESS) return 0;

    // Option-as-Alt is app configuration, so it is applied after the modes
    // copied from the terminal (which reset it).
    ghostty_key_encoder_setopt_from_terminal(t->key, t->terminal);
    GhosttyOptionAsAlt optionAsAlt = (GhosttyOptionAsAlt)key->optionAsAlt;
    ghostty_key_encoder_setopt(t->key, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt);

    ghostty_key_event_set_key(event, physical_key(key->keyCode));
    ghostty_key_event_set_action(event, (GhosttyKeyAction)key->action);
    ghostty_key_event_set_mods(event, key->modifiers);
    ghostty_key_event_set_consumed_mods(event, key->consumedModifiers);
    ghostty_key_event_set_utf8(event, key->text ? key->text : "", key->text ? key->textLength : 0);
    ghostty_key_event_set_unshifted_codepoint(event, key->unshiftedCodepoint);
    ghostty_key_event_set_composing(event, key->composing);

    size_t length = 0;
    GhosttyResult result = ghostty_key_encoder_encode(t->key, event, out, capacity, &length);
    ghostty_key_event_free(event);
    return result == GHOSTTY_SUCCESS || result == GHOSTTY_OUT_OF_SPACE ? length : 0;
}

bool il_terminal_kitty_keyboard(ILTerminal *t) {
    GhosttyKittyKeyFlags flags = GHOSTTY_KITTY_KEY_DISABLED;
    return t && ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags) == GHOSTTY_SUCCESS &&
           flags != GHOSTTY_KITTY_KEY_DISABLED;
}

// MARK: - Mouse

static bool reports_held_button(ILMouseAction action, ILMouseButton button) {
    if (action == ILMouseActionRelease) return false;
    switch (button) {
    case ILMouseButtonUnknown:
    case ILMouseButtonWheelUp:
    case ILMouseButtonWheelDown:
    case ILMouseButtonWheelLeft:
    case ILMouseButtonWheelRight:
        return false;
    default:
        return true;
    }
}

size_t il_terminal_mouse(ILTerminal *t, ILMouseAction action, ILMouseButton button, ILModifiers modifiers, float x, float y,
                         float cellWidth, float cellHeight, char *out, size_t capacity) {
    if (!t || !(cellWidth > 0) || !(cellHeight > 0) || button > ILMouseButtonEleven) return 0;
    if (t->mouseModesChanged) {
        ghostty_mouse_encoder_setopt_from_terminal(t->mouse, t->terminal);
        t->mouseModesChanged = false;
    }

    uint16_t columns, rows;
    grid_size(t, &columns, &rows);
    GhosttyMouseEncoderSize size = {
        .size = sizeof(size),
        .screen_width = columns * cellWidth,
        .screen_height = rows * cellHeight,
        .cell_width = cellWidth,
        .cell_height = cellHeight,
    };
    if (size.screen_width != t->mouseSize.screen_width || size.screen_height != t->mouseSize.screen_height ||
        size.cell_width != t->mouseSize.cell_width || size.cell_height != t->mouseSize.cell_height) {
        ghostty_mouse_encoder_setopt(t->mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        t->mouseSize = size;
    }
    // Button-event tracking (mode 1002) reports motion only while a button is held.
    bool held = reports_held_button(action, button);
    ghostty_mouse_encoder_setopt(t->mouse, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &held);

    GhosttyMouseEvent event = NULL;
    if (ghostty_mouse_event_new(NULL, &event) != GHOSTTY_SUCCESS) return 0;
    ghostty_mouse_event_set_action(event, (GhosttyMouseAction)action);
    if (button == ILMouseButtonUnknown) ghostty_mouse_event_clear_button(event);
    else ghostty_mouse_event_set_button(event, (GhosttyMouseButton)button);
    ghostty_mouse_event_set_mods(event, modifiers);
    ghostty_mouse_event_set_position(event, (GhosttyMousePosition){.x = x, .y = y});
    size_t written = 0;
    if (ghostty_mouse_encoder_encode(t->mouse, event, out, capacity, &written) != GHOSTTY_SUCCESS) written = 0;
    ghostty_mouse_event_free(event);
    return written;
}

bool il_terminal_mouse_reporting(ILTerminal *t) {
    bool enabled = false;
    if (t) ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &enabled);
    return enabled;
}

size_t il_terminal_alternate_scroll(ILTerminal *t, bool up, char *out, size_t capacity) {
    if (!t || !out || capacity < 3 || il_terminal_mouse_reporting(t)) return 0;
    if (active_screen(t) != SCREEN_ALTERNATE || !mode_enabled(t, GHOSTTY_MODE_ALT_SCROLL)) return 0;
    // Like Ghostty, turning the wheel into cursor keys drops the selection.
    il_terminal_clear_selection(t);
    out[0] = '\033';
    out[1] = mode_enabled(t, GHOSTTY_MODE_DECCKM) ? 'O' : '[';
    out[2] = up ? 'A' : 'B';
    return 3;
}

// MARK: - Focus and paste

size_t il_terminal_focus(ILTerminal *t, bool focused, char *out, size_t capacity) {
    if (!t || !out || capacity < 3 || !mode_enabled(t, GHOSTTY_MODE_FOCUS_EVENT)) return 0;
    memcpy(out, focused ? "\033[I" : "\033[O", 3);
    return 3;
}

size_t il_terminal_paste(ILTerminal *t, const char *text, size_t length, char *out, size_t capacity) {
    if (!t || (!text && length)) return 0;
    // The encoder rewrites unsafe control bytes in its input, so it gets a copy.
    char *copy = malloc(length ? length : 1);
    if (!copy) return 0;
    if (length) memcpy(copy, text, length);
    size_t written = 0;
    GhosttyResult result = ghostty_paste_encode(copy, length, mode_enabled(t, GHOSTTY_MODE_BRACKETED_PASTE), out, capacity, &written);
    free(copy);
    return result == GHOSTTY_SUCCESS || result == GHOSTTY_OUT_OF_SPACE ? written : 0;
}

bool il_terminal_paste_is_unsafe(ILTerminal *t, const char *text, size_t length) {
    static const char bracketEnd[] = "\033[201~";
    if (!t || !text || !length) return false;
    if (memmem(text, length, bracketEnd, sizeof(bracketEnd) - 1)) return true;
    // Bracketed paste frames newlines, so the shell will not run them.
    if (mode_enabled(t, GHOSTTY_MODE_BRACKETED_PASTE)) return false;
    return !ghostty_paste_is_safe(text, length);
}

// MARK: - Selection

static GhosttySelectionGestureEventType gesture_event_type(ILSelectionEvent event) {
    switch (event) {
    case ILSelectionEventPress: return GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS;
    case ILSelectionEventDrag: return GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG;
    case ILSelectionEventRelease: return GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE;
    case ILSelectionEventAutoscrollTick: return GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK;
    }
    return GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS;
}

void il_terminal_select(ILTerminal *t, ILSelectionEvent kind, uint16_t column, uint16_t row, float x, float y, float cellWidth,
                        float cellHeight, uint64_t timeNanos, bool rectangle) {
    if (!t || kind > ILSelectionEventAutoscrollTick) return;
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value.coordinate = {.x = column, .y = row}};
    if (ghostty_terminal_grid_ref(t->terminal, point, &ref) != GHOSTTY_SUCCESS) return;
    GhosttySelectionGestureEvent event = NULL;
    if (ghostty_selection_gesture_event_new(NULL, &event, gesture_event_type(kind)) != GHOSTTY_SUCCESS) return;

    uint16_t columns, rows;
    grid_size(t, &columns, &rows);
    GhosttySurfacePosition position = {.x = x, .y = y};
    GhosttySelectionGestureGeometry geometry = {
        .columns = columns, .cell_width = cellWidth, .padding_left = 0, .screen_height = rows * cellHeight};
    // macOS's default double-click interval.
    uint64_t repeatInterval = 500000000;
    ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
    if (kind == ILSelectionEventAutoscrollTick) {
        GhosttyPointCoordinate viewport = {.x = column, .y = row};
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport);
    }
    ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position);
    ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry);
    ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &timeNanos);
    ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &repeatInterval);
    ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle);

    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_selection_gesture_event(t->gesture, t->terminal, event, &selection);
    if (result == GHOSTTY_SUCCESS) ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
    else if (kind == ILSelectionEventPress) il_terminal_clear_selection(t);
    ghostty_selection_gesture_event_free(event);
}

bool il_terminal_selection_autoscroll(ILTerminal *t) {
    GhosttySelectionGestureAutoscroll state = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE;
    return t &&
           ghostty_selection_gesture_get(t->gesture, t->terminal, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &state) == GHOSTTY_SUCCESS &&
           state != GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE;
}

void il_terminal_selection_cancel(ILTerminal *t) {
    if (t) ghostty_selection_gesture_reset(t->gesture, t->terminal);
}

void il_terminal_select_all(ILTerminal *t) {
    if (!t) return;
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    if (ghostty_terminal_select_all(t->terminal, &selection) == GHOSTTY_SUCCESS)
        ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
}

bool il_terminal_extend_selection(ILTerminal *t, uint16_t column, uint16_t row) {
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    if (!t || ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) != GHOSTTY_SUCCESS) return false;
    GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value.coordinate = {.x = column, .y = row}};
    if (ghostty_terminal_grid_ref(t->terminal, point, &selection.end) != GHOSTTY_SUCCESS) return false;
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
    return true;
}

void il_terminal_clear_selection(ILTerminal *t) {
    if (t) ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
}

void il_bytes_free(void *bytes) { free(bytes); }

/// Copies Ghostty-allocated bytes into a NUL-terminated buffer freed with `il_bytes_free`.
static char *adopt_bytes(uint8_t *bytes, size_t count, size_t *length) {
    char *copy = malloc(count + 1);
    if (copy) {
        memcpy(copy, bytes, count);
        copy[count] = 0;
        if (length) *length = count;
    }
    ghostty_free(NULL, bytes, count);
    return copy;
}

char *il_terminal_copy(ILTerminal *t, size_t *length) {
    if (length) *length = 0;
    if (!t) return NULL;
    GhosttyTerminalSelectionFormatOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    options.unwrap = true;
    options.trim = true;
    uint8_t *bytes = NULL;
    size_t count = 0;
    if (ghostty_terminal_selection_format_alloc(t->terminal, NULL, options, &bytes, &count) != GHOSTTY_SUCCESS) return NULL;
    return adopt_bytes(bytes, count, length);
}

// MARK: - Search

void il_terminal_search(ILTerminal *t, const char *text, size_t length, ILSearchNavigation navigation) {
    if (!t) return;
    t->forceFullFrame = true;
    if (!length) {
        ghostty_search_free(t->search);
        t->search = NULL;
        free(t->searchMatches);
        t->searchMatches = NULL;
        t->searchMatchCapacity = 0;
        return;
    }
    if (!t->search && ghostty_search_new(NULL, &t->search, t->terminal) != GHOSTTY_SUCCESS) return;
    GhosttyString needle = {.ptr = (const uint8_t *)text, .len = length};
    ghostty_search_set(t->search, GHOSTTY_SEARCH_OPT_NEEDLE, &needle);
    ghostty_search_run(t->search);
    if (navigation == ILSearchNavigationNext) ghostty_search_set(t->search, GHOSTTY_SEARCH_OPT_SELECT_NEXT, NULL);
    else if (navigation == ILSearchNavigationPrevious) ghostty_search_set(t->search, GHOSTTY_SEARCH_OPT_SELECT_PREV, NULL);
}

// MARK: - Links

static bool is_link_boundary(unsigned char value) {
    return value <= 0x20 || value == 0x7f || strchr("\"'<>`", value) != NULL;
}

/// Characters that make a scheme part of a longer word (`xhttps://`).
static bool continues_word(unsigned char value) {
    return isalnum(value) || value >= 0x80 || strchr("_+-./", value) != NULL;
}

static size_t link_scheme_length(const char *text, size_t length) {
    static const char *const schemes[] = {"https://", "http://", "mailto:", "file:"};
    for (size_t i = 0; i < sizeof(schemes) / sizeof(*schemes); i++) {
        size_t size = strlen(schemes[i]);
        if (length > size && !strncasecmp(text, schemes[i], size)) return size;
    }
    return 0;
}

/// End of the URL whose scheme ends at `start + scheme`: stops at unmatched
/// closing brackets and drops trailing sentence punctuation.
static size_t link_end(const char *text, size_t length, size_t start, size_t scheme) {
    size_t end = start + scheme;
    int parentheses = 0, brackets = 0;
    for (; end < length && !is_link_boundary((unsigned char)text[end]); end++) {
        if (text[end] == '(') parentheses++;
        else if (text[end] == ')' && --parentheses < 0) break;
        else if (text[end] == '[') brackets++;
        else if (text[end] == ']' && --brackets < 0) break;
    }
    while (end > start + scheme && strchr(".,;:!?", text[end - 1])) end--;
    return end;
}

/// A plain-text URL around `ref`, found in its whole logical (unwrapped) line.
static char *plain_link(ILTerminal *t, const GhosttyGridRef *ref) {
    GhosttyCell cell;
    uint32_t codepoint = 0;
    if (ghostty_grid_ref_cell(ref, &cell) != GHOSTTY_SUCCESS) return NULL;
    ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint);
    if (codepoint < 0x80 && is_link_boundary((unsigned char)codepoint)) return NULL;

    GhosttyTerminalSelectLineOptions lineOptions = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
    lineOptions.ref = *ref;
    lineOptions.semantic_prompt_boundary = true;
    GhosttySelection line = GHOSTTY_INIT_SIZED(GhosttySelection);
    if (ghostty_terminal_select_line(t->terminal, &lineOptions, &line) != GHOSTTY_SUCCESS) return NULL;
    bool contains = false;
    GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_SCREEN};
    if (ghostty_terminal_point_from_grid_ref(t->terminal, ref, point.tag, &point.value.coordinate) != GHOSTTY_SUCCESS ||
        ghostty_terminal_selection_contains(t->terminal, &line, point, &contains) != GHOSTTY_SUCCESS || !contains)
        return NULL;

    // Ghostty's formatter maps soft wraps, scrollback and wide characters to
    // UTF-8 offsets. The clicked offset is the length of the line up to the
    // clicked cell. This runs only on Command-click or hover, never per frame.
    GhosttyTerminalSelectionFormatOptions format = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
    format.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    format.unwrap = true;
    format.selection = &line;
    uint8_t *bytes = NULL;
    size_t length = 0;
    if (ghostty_terminal_selection_format_alloc(t->terminal, NULL, format, &bytes, &length) != GHOSTTY_SUCCESS) return NULL;
    GhosttySelection prefix = line;
    prefix.end = *ref;
    format.selection = &prefix;
    size_t clickedEnd = 0;
    GhosttyResult result = ghostty_terminal_selection_format_buf(t->terminal, format, NULL, 0, &clickedEnd);

    char *uri = NULL;
    const char *text = (const char *)bytes;
    if ((result == GHOSTTY_SUCCESS || result == GHOSTTY_OUT_OF_SPACE) && clickedEnd) {
        for (size_t start = 0; start < length; start++) {
            if (start && continues_word((unsigned char)text[start - 1])) continue;
            size_t scheme = link_scheme_length(text + start, length - start);
            if (!scheme) continue;
            size_t end = link_end(text, length, start, scheme);
            if (end > start + scheme && clickedEnd > start && clickedEnd <= end) {
                uri = strndup(text + start, end - start);
                break;
            }
            if (end > start) start = end - 1;
        }
    }
    ghostty_free(NULL, bytes, length);
    return uri;
}

char *il_terminal_link(ILTerminal *t, uint16_t column, uint16_t row) {
    if (!t) return NULL;
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value.coordinate = {.x = column, .y = row}};
    if (ghostty_terminal_grid_ref(t->terminal, point, &ref) != GHOSTTY_SUCCESS) return NULL;

    // The right half of a wide character belongs to the cell before it.
    GhosttyCell cell;
    GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
    if (ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS) ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
    if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL && column > 0) {
        point.value.coordinate.x--;
        if (ghostty_terminal_grid_ref(t->terminal, point, &ref) != GHOSTTY_SUCCESS) return NULL;
    }

    // An OSC 8 hyperlink wins over any URL-looking text it displays.
    size_t length = 0;
    ghostty_grid_ref_hyperlink_uri(&ref, NULL, 0, &length);
    if (!length) return plain_link(t, &ref);
    if (length == SIZE_MAX) return NULL;
    char *uri = malloc(length + 1);
    if (!uri) return NULL;
    if (ghostty_grid_ref_hyperlink_uri(&ref, (uint8_t *)uri, length, &length) != GHOSTTY_SUCCESS) {
        free(uri);
        return NULL;
    }
    uri[length] = 0;
    return uri;
}
