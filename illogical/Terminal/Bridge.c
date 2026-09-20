#include "Bridge.h"
#include <ghostty/vt.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <sys/time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <time.h>

int il_connect_unix(const char *path) {
    struct sockaddr_un address = {0};
    if (strlen(path) >= sizeof(address.sun_path)) { errno = ENAMETOOLONG; return -1; }
    address.sun_family = AF_UNIX; address.sun_len = sizeof(address); strcpy(address.sun_path, path);
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) { close(descriptor); return -1; }
    int enabled = 1; setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    return descriptor;
}

double il_process_age_ms(void) {
    struct proc_bsdinfo info = {0}; struct timeval now;
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    gettimeofday(&now, NULL);
    return ((double)now.tv_sec-(double)info.pbi_start_tvsec)*1000.0 + ((double)now.tv_usec-(double)info.pbi_start_tvusec)/1000.0;
}

struct ILTerminal {
    GhosttyTerminal terminal;
    GhosttyRenderState render;
    GhosttyRenderStateRowIterator rows;
    GhosttyRenderStateRowCells cells;
    GhosttyKeyEncoder key;
    GhosttyMouseEncoder mouse;
    GhosttyMouseEncoderSize mouseSize;
    bool mouseEncoderDirty;
    GhosttySelectionGesture gesture;
    GhosttySearch search;
    GhosttySelection *searchMatches;
    size_t searchMatchCapacity;
    GhosttySnapshotDecoder decoder;
    uint64_t missingHistory[2];
    struct { uint8_t *data; size_t length, offset; } reader;
    ILCell *frameCells;
    size_t frameCapacity;
    uint16_t frameColumns, frameRows;
    bool hasFrame, forceFullFrame;
    bool renderHeld;
    double renderHoldDeadline;
    ILFrame heldFrame;
};

static double monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}

static void render_hold(GhosttyTerminal terminal, void *userdata, bool held) {
    (void)terminal;
    ILTerminal *t = userdata;
    if (held) {
        // Capture at the escape sequence itself, before subsequent bytes in
        // this same VT write can clear or partially redraw the screen.
        if (!il_terminal_frame(t, &t->heldFrame)) return;
        t->renderHoldDeadline = monotonic_ms() + 1000;
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
    GhosttyTerminalModeConfig mode = {.mode=GHOSTTY_MODE_SYNC_OUTPUT, .value=false};
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode);
    // A programmatic mode change intentionally does not invoke render_hold.
    t->renderHeld = false;
    return true;
}

static bool read_snapshot(void *context, uint8_t *buffer, size_t capacity, size_t *count) {
    ILTerminal *t = context;
    size_t remaining = t->reader.length - t->reader.offset;
    *count = remaining < capacity ? remaining : capacity;
    if (*count) memcpy(buffer, t->reader.data + t->reader.offset, *count);
    t->reader.offset += *count;
    return true;
}

static bool set_snapshot_chunk(ILTerminal *t, const uint8_t *data, size_t length) {
    uint8_t *copy = malloc(length ? length : 1);
    if (!copy) return false;
    if (length) memcpy(copy, data, length);
    free(t->reader.data);
    t->reader.data = copy; t->reader.length = length; t->reader.offset = 0;
    return true;
}

static bool initialize(ILTerminal *t) {
    bool ready = ghostty_render_state_new(NULL, &t->render) == GHOSTTY_SUCCESS &&
        ghostty_render_state_row_iterator_new(NULL, &t->rows) == GHOSTTY_SUCCESS &&
        ghostty_render_state_row_cells_new(NULL, &t->cells) == GHOSTTY_SUCCESS &&
        ghostty_key_encoder_new(NULL, &t->key) == GHOSTTY_SUCCESS &&
        ghostty_mouse_encoder_new(NULL, &t->mouse) == GHOSTTY_SUCCESS &&
        ghostty_selection_gesture_new(NULL, &t->gesture) == GHOSTTY_SUCCESS;
    if (!ready) return false;
    // The service owns Kitty image storage and protocol responses. Replicas
    // keep only the VT parser boundary and draw the bounded graphics scene.
    uint64_t imageLimit=0;size_t apcLimit=12<<20;
    ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,&imageLimit);
    ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY,&apcLimit);
    bool trackMouseCell=true;
    ghostty_mouse_encoder_setopt(t->mouse,GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL,&trackMouseCell);
    t->mouseEncoderDirty=true;
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, t);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, render_hold);
    GhosttyTerminalModeConfig mode = {.mode=GHOSTTY_MODE_SYNC_OUTPUT};
    ghostty_terminal_get(t->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode);
    if (mode.value) render_hold(t->terminal, t, true);
    return true;
}

ILTerminal *il_terminal_new(uint16_t columns, uint16_t rows) {
    ILTerminal *t = calloc(1, sizeof(*t)); if (!t) return NULL;
    if (ghostty_terminal_new(NULL, &t->terminal, columns, rows) != GHOSTTY_SUCCESS || !initialize(t)) { il_terminal_free(t); return NULL; }
    return t;
}

ILTerminal *il_terminal_restore(const uint8_t *data, size_t length) {
    ILTerminal *t = calloc(1, sizeof(*t)); if (!t) return NULL;
    if (!set_snapshot_chunk(t, data, length)) { il_terminal_free(t); return NULL; }
    GhosttyReader reader = {.read = read_snapshot, .userdata = t};
    size_t continuationLimit=16<<20;
    if (ghostty_snapshot_decoder_new(NULL, &t->decoder, reader) != GHOSTTY_SUCCESS ||
        ghostty_snapshot_decoder_set(t->decoder,GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,&continuationLimit) != GHOSTTY_SUCCESS ||
        ghostty_snapshot_decoder_ready(t->decoder, &t->terminal) != GHOSTTY_SUCCESS || !initialize(t)) {
        il_terminal_free(t); return NULL;
    }
    GhosttyTerminalScreen screen=GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    GhosttyTerminalScrollbar bar={0};uint64_t declared=0;
    ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&screen);
    ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&bar);
    ghostty_snapshot_decoder_get(t->decoder,screen==GHOSTTY_TERMINAL_SCREEN_PRIMARY?GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY:GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_ALTERNATE,&declared);
    uint64_t resident=bar.total>bar.len?bar.total-bar.len:0;
    t->missingHistory[screen==GHOSTTY_TERMINAL_SCREEN_PRIMARY?0:1]=declared>resident?declared-resident:0;
    return t;
}

void il_terminal_free(ILTerminal *t) {
    if (!t) return;
    ghostty_snapshot_decoder_free(t->decoder);
    ghostty_search_free(t->search);
    ghostty_selection_gesture_free(t->gesture,t->terminal);
    ghostty_key_encoder_free(t->key);
    ghostty_mouse_encoder_free(t->mouse);
    ghostty_render_state_row_cells_free(t->cells);
    ghostty_render_state_row_iterator_free(t->rows);
    ghostty_render_state_free(t->render);
    ghostty_terminal_free(t->terminal);
    free(t->reader.data); free(t->frameCells); free(t->searchMatches); free(t);
}

int il_terminal_history(ILTerminal *t, const uint8_t *data, size_t length, bool final) {
    if (!t || !t->decoder || !set_snapshot_chunk(t, data, length)) return -1;
    GhosttyResult result = ghostty_snapshot_decoder_next(t->decoder);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) return (int)result;
    if(result==GHOSTTY_SUCCESS){
        GhosttyTerminalScreen screen=GHOSTTY_TERMINAL_SCREEN_PRIMARY;size_t rows=0;
        ghostty_snapshot_decoder_get(t->decoder,GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_SCREEN,&screen);
        ghostty_snapshot_decoder_get(t->decoder,GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS,&rows);
        int index=screen==GHOSTTY_TERMINAL_SCREEN_PRIMARY?0:1;
        t->missingHistory[index]=t->missingHistory[index]>rows?t->missingHistory[index]-rows:0;
    }
    if (final) {
        if (result != GHOSTTY_NO_VALUE) return -2;
        ghostty_snapshot_decoder_free(t->decoder); t->decoder = NULL;
        free(t->reader.data); t->reader.data = NULL; t->reader.length = t->reader.offset = 0;
        t->missingHistory[0]=0;t->missingHistory[1]=0;
    }
    return 0;
}

void il_terminal_feed(ILTerminal *t, const uint8_t *data, size_t length) { if (t) { ghostty_terminal_vt_write(t->terminal, data, length);t->mouseEncoderDirty=true; } }
void il_terminal_resize(ILTerminal *t, uint16_t columns, uint16_t rows, uint32_t width, uint32_t height) { if (t) ghostty_terminal_resize(t->terminal, columns, rows, width, height); }
static uint32_t pack(GhosttyColorRgb c) { return ((uint32_t)c.r << 16) | ((uint32_t)c.g << 8) | c.b; }
uint64_t il_terminal_scroll_distance(ILTerminal *t) {
    if(!t)return 0;
    GhosttyTerminalScrollbar scrollbar={0};
    if(ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&scrollbar)!=GHOSTTY_SUCCESS)return 0;
    uint64_t bottom=scrollbar.total>scrollbar.len?scrollbar.total-scrollbar.len:0;
    return bottom>scrollbar.offset?bottom-scrollbar.offset:0;
}
bool il_terminal_capture_view(ILTerminal *t,ILTerminalViewState *state) {
    if(!t || !state)return false;
    memset(state,0,sizeof(*state));GhosttyTerminalScrollbar bar={0};GhosttyTerminalScreen screen;
    if(ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&bar)!=GHOSTTY_SUCCESS ||
       ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&screen)!=GHOSTTY_SUCCESS)return false;
    uint64_t missing=t->missingHistory[screen==GHOSTTY_TERMINAL_SCREEN_PRIMARY?0:1];
    state->screen=(int)screen;state->viewportRow=bar.offset+missing;
    state->followsBottom=bar.offset >= (bar.total>bar.len?bar.total-bar.len:0);
    GhosttySelection selection=GHOSTTY_INIT_SIZED(GhosttySelection);GhosttyPointCoordinate start,end;
    if(ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_SELECTION,&selection)==GHOSTTY_SUCCESS &&
       ghostty_terminal_point_from_grid_ref(t->terminal,&selection.start,GHOSTTY_POINT_TAG_SCREEN,&start)==GHOSTTY_SUCCESS &&
       ghostty_terminal_point_from_grid_ref(t->terminal,&selection.end,GHOSTTY_POINT_TAG_SCREEN,&end)==GHOSTTY_SUCCESS){
        state->hasSelection=true;state->rectangle=selection.rectangle;
        state->startColumn=start.x;state->endColumn=end.x;state->startRow=start.y+missing;state->endRow=end.y+missing;
    }
    return true;
}
void il_terminal_restore_view(ILTerminal *t,const ILTerminalViewState *state) {
    if(!t || !state)return;
    GhosttyTerminalScreen screen;ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&screen);
    if((int)screen!=state->screen)return;
    uint64_t missing=t->missingHistory[screen==GHOSTTY_TERMINAL_SCREEN_PRIMARY?0:1];
    if(state->followsBottom)il_terminal_scroll_bottom(t);
    else il_terminal_scroll_to(t,state->viewportRow>missing?state->viewportRow-missing:0);
    if(state->hasSelection && state->startRow>=missing && state->endRow>=missing &&
       state->startRow-missing<=UINT32_MAX && state->endRow-missing<=UINT32_MAX){
        GhosttySelection selection=GHOSTTY_INIT_SIZED(GhosttySelection);selection.rectangle=state->rectangle;
        GhosttyPoint start={.tag=GHOSTTY_POINT_TAG_SCREEN,.value.coordinate={.x=state->startColumn,.y=(uint32_t)(state->startRow-missing)}};
        GhosttyPoint end={.tag=GHOSTTY_POINT_TAG_SCREEN,.value.coordinate={.x=state->endColumn,.y=(uint32_t)(state->endRow-missing)}};
        if(ghostty_terminal_grid_ref(t->terminal,start,&selection.start)==GHOSTTY_SUCCESS &&
           ghostty_terminal_grid_ref(t->terminal,end,&selection.end)==GHOSTTY_SUCCESS)
            ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_SELECTION,&selection);
    }
    t->forceFullFrame=true;
}
static GhosttyColorRgb unpack(uint32_t c) { return (GhosttyColorRgb){.r=c>>16,.g=c>>8,.b=c}; }

bool il_color_parse(const char *value,size_t length,uint32_t *color) {
    GhosttyColorRgb rgb;
    if(!color || ghostty_color_parse(value,length,&rgb)!=GHOSTTY_SUCCESS)return false;
    *color=pack(rgb);return true;
}
bool il_palette_parse_entry(const char *value,size_t length,uint8_t *index,uint32_t *color) {
    GhosttyColorRgb rgb;
    if(!index || !color || ghostty_color_parse_palette_entry(value,length,index,&rgb)!=GHOSTTY_SUCCESS)return false;
    *color=pack(rgb);return true;
}
void il_palette_default(uint32_t *palette) {
    if(!palette)return;
    GhosttyColorRgb colors[256];ghostty_color_palette_default(colors);
    for(int i=0;i<256;i++)palette[i]=pack(colors[i]);
}
void il_palette_generate(uint32_t *palette,const bool *explicitColors,uint32_t background,uint32_t foreground,bool harmonious) {
    if(!palette)return;
    GhosttyColorRgb colors[256],bg=unpack(background),fg=unpack(foreground);
    GhosttyColorPaletteMask skip={0};
    for(int i=0;i<256;i++){colors[i]=unpack(palette[i]);if(explicitColors && explicitColors[i])GHOSTTY_COLOR_PALETTE_MASK_SET(&skip,i);}
    ghostty_color_palette_generate(colors,&skip,&bg,&fg,harmonious,colors);
    for(int i=0;i<256;i++)palette[i]=pack(colors[i]);
}
bool il_color_is_light(uint32_t color) {
    GhosttyColorRgb rgb=unpack(color);return ghostty_color_perceived_luminance(&rgb)>0.5;
}

void il_terminal_theme(ILTerminal *t, uint32_t bg, uint32_t fg, uint32_t cursor, const uint32_t *palette) {
    if (!t) return;
    t->forceFullFrame = true;
    GhosttyColorRgb b = unpack(bg), f = unpack(fg), c = unpack(cursor);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &b);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &f);
    ghostty_terminal_set(t->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c);
    if (palette) { GhosttyColorRgb p[256]; for (int i=0;i<256;i++) p[i]=unpack(palette[i]); ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,&p); }
}

void il_terminal_theme_override(ILTerminal *t,const uint32_t *bg,const uint32_t *fg,const uint32_t *cursor,const uint32_t *palette){
    if(!t)return;
    t->forceFullFrame=true;
    // Ghostty's renderer starts black/white, but its cached render colors are
    // left unchanged if either default becomes unset. Supply those visual
    // defaults explicitly in this rendering replica; the service owns queries.
    GhosttyColorRgb b=unpack(bg?*bg:0),f=unpack(fg?*fg:0xffffff),c=unpack(cursor?*cursor:0);
    ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,&b);
    ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,&f);
    ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_COLOR_CURSOR,cursor?&c:NULL);
    GhosttyColorRgb p[256];
    if(palette)for(int i=0;i<256;i++)p[i]=unpack(palette[i]);
    ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,palette?&p:NULL);
}

bool il_terminal_default_palette(ILTerminal *t,uint32_t *palette){
    if(!t || !palette)return false;
    GhosttyColorRgb p[256];
    if(ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,&p)!=GHOSTTY_SUCCESS)return false;
    for(int i=0;i<256;i++)palette[i]=pack(p[i]);
    return true;
}

static int mark_match(ILTerminal *t, const GhosttySelection *selection, const ILFrame *frame, uint8_t flag) {
    GhosttyPointCoordinate start, end;
    if (!frame->columns || !frame->count ||
        ghostty_terminal_point_from_grid_ref(t->terminal,&selection->start,GHOSTTY_POINT_TAG_SCREEN,&start)!=GHOSTTY_SUCCESS ||
        ghostty_terminal_point_from_grid_ref(t->terminal,&selection->end,GHOSTTY_POINT_TAG_SCREEN,&end)!=GHOSTTY_SUCCESS) return -1;
    // A wrapped match can start above, or finish below, the viewport. Clip its
    // full-screen interval instead of requiring both endpoints to be visible.
    uint64_t first=(uint64_t)start.y*frame->columns+start.x, last=(uint64_t)end.y*frame->columns+end.x;
    if (last<first) { uint64_t swap=first;first=last;last=swap; }
    uint64_t visibleFirst=frame->scrollOffset*frame->columns, visibleEnd=visibleFirst+frame->count;
    if(last<visibleFirst || first>=visibleEnd)return -1;
    if(first<visibleFirst)first=visibleFirst;
    if(last>=visibleEnd)last=visibleEnd-1;
    for(size_t i=(size_t)(first-visibleFirst);i<=(size_t)(last-visibleFirst);i++)t->frameCells[i].flags |= flag;
    return (int)((first-visibleFirst)/frame->columns);
}

bool il_terminal_frame(ILTerminal *t, ILFrame *frame) {
    if (!t || !frame) return false;
    il_terminal_expire_render_hold(t);
    if (t->renderHeld) { *frame=t->heldFrame; return true; }
    if (ghostty_render_state_update(t->render,t->terminal)!=GHOSTTY_SUCCESS) return false;
    memset(frame,0,sizeof(*frame)); frame->searchRow=-1;
    ghostty_render_state_get(t->render,GHOSTTY_RENDER_STATE_DATA_COLS,&frame->columns);
    ghostty_render_state_get(t->render,GHOSTTY_RENDER_STATE_DATA_ROWS,&frame->rows);
    size_t count=(size_t)frame->columns*frame->rows;
    if (count>t->frameCapacity) { ILCell *cells=realloc(t->frameCells,count*sizeof(ILCell));if(!cells)return false;t->frameCells=cells;t->frameCapacity=count; }
    bool full = !t->hasFrame || t->frameColumns != frame->columns || t->frameRows != frame->rows || t->forceFullFrame || t->search;
    frame->cells=t->frameCells;frame->count=count;
    GhosttyRenderStateColors colors=GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    ghostty_render_state_get(t->render,GHOSTTY_RENDER_STATE_DATA_COLORS,&colors);
    frame->background=pack(colors.background);frame->foreground=pack(colors.foreground);frame->cursorColor=pack(colors.cursor_has_value?colors.cursor:colors.foreground);
    GhosttyRenderStateCursor cursor=GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
    ghostty_render_state_get(t->render,GHOSTTY_RENDER_STATE_DATA_CURSOR,&cursor);
    frame->cursorColumn=cursor.viewport_x;frame->cursorRow=cursor.viewport_y;
    frame->cursorVisible=cursor.visible && cursor.viewport_has_value;frame->cursorBlinking=cursor.blinking;frame->cursorStyle=cursor.visual_style;
    GhosttyTerminalScrollbar scrollbar={0};
    ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&scrollbar);
    frame->scrollTotal=scrollbar.total;frame->scrollOffset=scrollbar.offset;frame->scrollLength=scrollbar.len;
    ghostty_render_state_get(t->render,GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,&t->rows);
    uint16_t row=0;
    while ((full ? ghostty_render_state_row_iterator_next(t->rows) : ghostty_render_state_row_iterator_next_dirty(t->rows, &row)) && row<frame->rows) {
        memset(t->frameCells + row*frame->columns, 0, frame->columns*sizeof(ILCell));
        GhosttyRenderStateRowSelection selection=GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
        bool selected=ghostty_render_state_row_get(t->rows,GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION,&selection)==GHOSTTY_SUCCESS;
        ghostty_render_state_row_get(t->rows,GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,&t->cells);
        uint16_t col=0;
        while(ghostty_render_state_row_cells_next(t->cells) && col<frame->columns) {
            ILCell *cell=&t->frameCells[row*frame->columns+col];cell->column=col;cell->row=row;
            GhosttyStyle style=GHOSTTY_INIT_SIZED(GhosttyStyle);
            ghostty_render_state_row_cells_get(t->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,&style);
            GhosttyColorRgb fg=colors.foreground,bg=colors.background;
            ghostty_render_state_row_cells_get(t->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,&fg);
            ghostty_render_state_row_cells_get(t->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,&bg);
            if(style.inverse){GhosttyColorRgb swap=fg;fg=bg;bg=swap;}
            if(style.faint){fg.r=(fg.r+bg.r)/2;fg.g=(fg.g+bg.g)/2;fg.b=(fg.b+bg.b)/2;}
            cell->foreground=pack(fg);cell->background=pack(bg);
            cell->flags=(style.bold?1:0)|(style.italic?2:0)|(style.underline?4:0)|(selected && col>=selection.start_x && col<=selection.end_x?8:0)|(style.strikethrough?16:0)|(style.overline?32:0);
            cell->underlineStyle=(uint8_t)style.underline;
            cell->attributes=(style.underline_color.tag!=GHOSTTY_STYLE_COLOR_NONE?1:0)|(style.invisible?2:0)|(style.blink?4:0)|(style.bg_color.tag!=GHOSTTY_STYLE_COLOR_NONE?8:0)|(style.inverse?16:0);
            cell->underlineColor=style.underline_color.tag==GHOSTTY_STYLE_COLOR_RGB?pack(style.underline_color.value.rgb):
                style.underline_color.tag==GHOSTTY_STYLE_COLOR_PALETTE?pack(colors.palette[style.underline_color.value.palette]):cell->foreground;
            if(style.invisible){cell->flags &= (uint8_t)~(4|16|32);cell->underlineStyle=0;}
            GhosttyCell raw; GhosttyCellWide wide=GHOSTTY_CELL_WIDE_NARROW;
            ghostty_render_state_row_cells_get(t->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,&raw);
            ghostty_cell_get(raw,GHOSTTY_CELL_DATA_WIDE,&wide);
            cell->width=wide==GHOSTTY_CELL_WIDE_WIDE?2:(wide==GHOSTTY_CELL_WIDE_NARROW?1:0);
            if(!style.invisible && cell->width){
                GhosttyBuffer buffer={.ptr=(uint8_t *)cell->text,.cap=sizeof(cell->text)-1};
                if(ghostty_render_state_row_cells_get(t->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,&buffer)==GHOSTTY_SUCCESS)cell->text[buffer.len]=0;
            }
            col++;
        }
        if (full) row++;
    }
    if(t->search){
        ghostty_search_run(t->search);
        ghostty_search_get(t->search,GHOSTTY_SEARCH_DATA_TOTAL_MATCHES,&frame->searchCount);
        size_t index=0;if(ghostty_search_get(t->search,GHOSTTY_SEARCH_DATA_SELECTED_INDEX,&index)==GHOSTTY_SUCCESS)frame->searchSelected=index+1;
        GhosttySelectionBuffer matches={.ptr=t->searchMatches,.cap=t->searchMatchCapacity};
        GhosttyResult result=ghostty_search_get(t->search,GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES,&matches);
        if(result==GHOSTTY_OUT_OF_SPACE && matches.len<=SIZE_MAX/sizeof(GhosttySelection)){
            GhosttySelection *storage=realloc(t->searchMatches,matches.len*sizeof(GhosttySelection));
            if(storage){
                t->searchMatches=storage;t->searchMatchCapacity=matches.len;
                matches.ptr=storage;matches.cap=t->searchMatchCapacity;
                result=ghostty_search_get(t->search,GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES,&matches);
            }
        }
        if(result==GHOSTTY_SUCCESS && matches.len<=matches.cap)
            for(size_t i=0;i<matches.len;i++)mark_match(t,&matches.ptr[i],frame,64);
        GhosttySelection active=GHOSTTY_INIT_SIZED(GhosttySelection);
        if(ghostty_search_get(t->search,GHOSTTY_SEARCH_DATA_SELECTED_MATCH,&active)==GHOSTTY_SUCCESS){
            frame->searchRow=mark_match(t,&active,frame,128);
        }
    }
    t->hasFrame=true;t->frameColumns=frame->columns;t->frameRows=frame->rows;t->forceFullFrame=false;
    ghostty_render_state_clean(t->render);return true;
}

void il_terminal_scroll(ILTerminal *t,int64_t delta){if(t)ghostty_terminal_scroll_viewport(t->terminal,(GhosttyTerminalScrollViewport){.tag=GHOSTTY_SCROLL_VIEWPORT_DELTA,.value={.delta=delta}});}
void il_terminal_scroll_to(ILTerminal *t,uint64_t row){if(t)ghostty_terminal_scroll_viewport(t->terminal,(GhosttyTerminalScrollViewport){.tag=GHOSTTY_SCROLL_VIEWPORT_ROW,.value={.row=row}});}
void il_terminal_scroll_bottom(ILTerminal *t){if(t)ghostty_terminal_scroll_viewport(t->terminal,(GhosttyTerminalScrollViewport){.tag=GHOSTTY_SCROLL_VIEWPORT_BOTTOM});}

void il_terminal_search(ILTerminal *t,const char *text,size_t length,int direction){
    if(!t)return;
    t->forceFullFrame=true;
    if(!length){ghostty_search_free(t->search);t->search=NULL;free(t->searchMatches);t->searchMatches=NULL;t->searchMatchCapacity=0;return;}
    if(!t->search && ghostty_search_new(NULL,&t->search,t->terminal)!=GHOSTTY_SUCCESS)return;
    GhosttyString needle={.ptr=(const uint8_t *)text,.len=length};ghostty_search_set(t->search,GHOSTTY_SEARCH_OPT_NEEDLE,&needle);ghostty_search_run(t->search);
    if(direction)ghostty_search_set(t->search,direction>0?GHOSTTY_SEARCH_OPT_SELECT_NEXT:GHOSTTY_SEARCH_OPT_SELECT_PREV,NULL);
}

void il_bytes_free(void *bytes){free(bytes);}

char *il_terminal_copy(ILTerminal *t,size_t *length){
    *length=0;if(!t)return NULL;
    GhosttyTerminalSelectionFormatOptions options=GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);options.emit=GHOSTTY_FORMATTER_FORMAT_PLAIN;options.unwrap=true;options.trim=true;
    uint8_t *buffer=NULL;size_t count=0;
    if(ghostty_terminal_selection_format_alloc(t->terminal,NULL,options,&buffer,&count)!=GHOSTTY_SUCCESS)return NULL;
    char *copy=malloc(count+1);if(copy){memcpy(copy,buffer,count);copy[count]=0;*length=count;}
    ghostty_free(NULL,buffer,count);return copy;
}

void il_terminal_select_all(ILTerminal *t){if(!t)return;GhosttySelection selection=GHOSTTY_INIT_SIZED(GhosttySelection);if(ghostty_terminal_select_all(t->terminal,&selection)==GHOSTTY_SUCCESS)ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_SELECTION,&selection);}

void il_terminal_select(ILTerminal *t,int action,uint16_t column,uint16_t row,float x,float y,float cellWidth,float cellHeight,uint64_t timeNanos,bool rectangle){
    if(!t)return;
    GhosttyGridRef ref=GHOSTTY_INIT_SIZED(GhosttyGridRef);GhosttyPoint point={.tag=GHOSTTY_POINT_TAG_VIEWPORT,.value={.coordinate={.x=column,.y=row}}};
    if(ghostty_terminal_grid_ref(t->terminal,point,&ref)!=GHOSTTY_SUCCESS)return;
    GhosttySelectionGestureEvent event=NULL;
    GhosttySelectionGestureEventType type=action==0?GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS:(action==1?GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG:GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE);
    if(ghostty_selection_gesture_event_new(NULL,&event,type)!=GHOSTTY_SUCCESS)return;
    GhosttySurfacePosition pos={.x=x,.y=y};uint16_t cols=0,rows=0;ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_COLS,&cols);ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_ROWS,&rows);
    GhosttySelectionGestureGeometry geometry={.columns=cols,.cell_width=cellWidth,.padding_left=0,.screen_height=rows*cellHeight};
    uint64_t interval=500000000;
    ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF,&ref);
    ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION,&pos);
    ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY,&geometry);
    ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS,&timeNanos);
    ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS,&interval);
    ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE,&rectangle);
    GhosttySelection selection=GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result=ghostty_selection_gesture_event(t->gesture,t->terminal,event,&selection);
    if(result==GHOSTTY_SUCCESS)ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_SELECTION,&selection);
    else if(action==0)ghostty_terminal_set(t->terminal,GHOSTTY_TERMINAL_OPT_SELECTION,NULL);
    ghostty_selection_gesture_event_free(event);
}

static GhosttyKey physical_key(uint16_t code) {
    switch(code) {
    case 0:return GHOSTTY_KEY_A;case 1:return GHOSTTY_KEY_S;case 2:return GHOSTTY_KEY_D;case 3:return GHOSTTY_KEY_F;case 4:return GHOSTTY_KEY_H;case 5:return GHOSTTY_KEY_G;
    case 6:return GHOSTTY_KEY_Z;case 7:return GHOSTTY_KEY_X;case 8:return GHOSTTY_KEY_C;case 9:return GHOSTTY_KEY_V;case 10:return GHOSTTY_KEY_INTL_BACKSLASH;case 11:return GHOSTTY_KEY_B;
    case 12:return GHOSTTY_KEY_Q;case 13:return GHOSTTY_KEY_W;case 14:return GHOSTTY_KEY_E;case 15:return GHOSTTY_KEY_R;case 16:return GHOSTTY_KEY_Y;case 17:return GHOSTTY_KEY_T;
    case 18:return GHOSTTY_KEY_DIGIT_1;case 19:return GHOSTTY_KEY_DIGIT_2;case 20:return GHOSTTY_KEY_DIGIT_3;case 21:return GHOSTTY_KEY_DIGIT_4;case 22:return GHOSTTY_KEY_DIGIT_6;case 23:return GHOSTTY_KEY_DIGIT_5;
    case 24:return GHOSTTY_KEY_EQUAL;case 25:return GHOSTTY_KEY_DIGIT_9;case 26:return GHOSTTY_KEY_DIGIT_7;case 27:return GHOSTTY_KEY_MINUS;case 28:return GHOSTTY_KEY_DIGIT_8;case 29:return GHOSTTY_KEY_DIGIT_0;
    case 30:return GHOSTTY_KEY_BRACKET_RIGHT;case 31:return GHOSTTY_KEY_O;case 32:return GHOSTTY_KEY_U;case 33:return GHOSTTY_KEY_BRACKET_LEFT;case 34:return GHOSTTY_KEY_I;case 35:return GHOSTTY_KEY_P;
    case 36:return GHOSTTY_KEY_ENTER;case 37:return GHOSTTY_KEY_L;case 38:return GHOSTTY_KEY_J;case 39:return GHOSTTY_KEY_QUOTE;case 40:return GHOSTTY_KEY_K;case 41:return GHOSTTY_KEY_SEMICOLON;
    case 42:return GHOSTTY_KEY_BACKSLASH;case 43:return GHOSTTY_KEY_COMMA;case 44:return GHOSTTY_KEY_SLASH;case 45:return GHOSTTY_KEY_N;case 46:return GHOSTTY_KEY_M;case 47:return GHOSTTY_KEY_PERIOD;
    case 48:return GHOSTTY_KEY_TAB;case 49:return GHOSTTY_KEY_SPACE;case 50:return GHOSTTY_KEY_BACKQUOTE;case 51:return GHOSTTY_KEY_BACKSPACE;case 53:return GHOSTTY_KEY_ESCAPE;
    case 54:return GHOSTTY_KEY_META_RIGHT;case 55:return GHOSTTY_KEY_META_LEFT;case 56:return GHOSTTY_KEY_SHIFT_LEFT;case 57:return GHOSTTY_KEY_CAPS_LOCK;case 58:return GHOSTTY_KEY_ALT_LEFT;case 59:return GHOSTTY_KEY_CONTROL_LEFT;case 60:return GHOSTTY_KEY_SHIFT_RIGHT;case 61:return GHOSTTY_KEY_ALT_RIGHT;case 62:return GHOSTTY_KEY_CONTROL_RIGHT;
    case 65:return GHOSTTY_KEY_NUMPAD_DECIMAL;case 67:return GHOSTTY_KEY_NUMPAD_MULTIPLY;case 69:return GHOSTTY_KEY_NUMPAD_ADD;case 71:return GHOSTTY_KEY_NUMPAD_CLEAR;case 75:return GHOSTTY_KEY_NUMPAD_DIVIDE;case 76:return GHOSTTY_KEY_NUMPAD_ENTER;case 78:return GHOSTTY_KEY_NUMPAD_SUBTRACT;
    case 72:return GHOSTTY_KEY_AUDIO_VOLUME_UP;case 73:return GHOSTTY_KEY_AUDIO_VOLUME_DOWN;case 74:return GHOSTTY_KEY_AUDIO_VOLUME_MUTE;case 81:return GHOSTTY_KEY_NUMPAD_EQUAL;case 95:return GHOSTTY_KEY_NUMPAD_COMMA;
    case 82:return GHOSTTY_KEY_NUMPAD_0;case 83:return GHOSTTY_KEY_NUMPAD_1;case 84:return GHOSTTY_KEY_NUMPAD_2;case 85:return GHOSTTY_KEY_NUMPAD_3;case 86:return GHOSTTY_KEY_NUMPAD_4;case 87:return GHOSTTY_KEY_NUMPAD_5;case 88:return GHOSTTY_KEY_NUMPAD_6;case 89:return GHOSTTY_KEY_NUMPAD_7;case 91:return GHOSTTY_KEY_NUMPAD_8;case 92:return GHOSTTY_KEY_NUMPAD_9;
    case 96:return GHOSTTY_KEY_F5;case 97:return GHOSTTY_KEY_F6;case 98:return GHOSTTY_KEY_F7;case 99:return GHOSTTY_KEY_F3;case 100:return GHOSTTY_KEY_F8;case 101:return GHOSTTY_KEY_F9;case 103:return GHOSTTY_KEY_F11;case 109:return GHOSTTY_KEY_F10;case 111:return GHOSTTY_KEY_F12;case 118:return GHOSTTY_KEY_F4;case 120:return GHOSTTY_KEY_F2;case 122:return GHOSTTY_KEY_F1;
    // The physical macOS mappings match the pinned Ghostty keycode table.
    case 105:return GHOSTTY_KEY_F13;case 107:return GHOSTTY_KEY_F14;case 113:return GHOSTTY_KEY_F15;case 106:return GHOSTTY_KEY_F16;case 64:return GHOSTTY_KEY_F17;case 79:return GHOSTTY_KEY_F18;case 80:return GHOSTTY_KEY_F19;case 90:return GHOSTTY_KEY_F20;
    case 93:return GHOSTTY_KEY_INTL_YEN;case 94:return GHOSTTY_KEY_INTL_RO;case 110:return GHOSTTY_KEY_CONTEXT_MENU;case 114:return GHOSTTY_KEY_INSERT;
    case 115:return GHOSTTY_KEY_HOME;case 116:return GHOSTTY_KEY_PAGE_UP;case 117:return GHOSTTY_KEY_DELETE;case 119:return GHOSTTY_KEY_END;case 121:return GHOSTTY_KEY_PAGE_DOWN;
    case 123:return GHOSTTY_KEY_ARROW_LEFT;case 124:return GHOSTTY_KEY_ARROW_RIGHT;case 125:return GHOSTTY_KEY_ARROW_DOWN;case 126:return GHOSTTY_KEY_ARROW_UP;
    default:return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

size_t il_terminal_key(ILTerminal *t,uint16_t code,uint16_t modifiers,uint16_t consumed,int action,const char *text,size_t length,uint32_t unshifted,char *out,size_t capacity){
    if(!t)return 0;GhosttyKeyEvent event=NULL;if(ghostty_key_event_new(NULL,&event)!=GHOSTTY_SUCCESS)return 0;
    ghostty_key_encoder_setopt_from_terminal(t->key,t->terminal);
    ghostty_key_event_set_key(event,physical_key(code));ghostty_key_event_set_action(event,(GhosttyKeyAction)action);
    ghostty_key_event_set_mods(event,modifiers);ghostty_key_event_set_consumed_mods(event,consumed);
    ghostty_key_event_set_utf8(event,text,length);ghostty_key_event_set_unshifted_codepoint(event,unshifted);
    size_t written=0;if(ghostty_key_encoder_encode(t->key,event,out,capacity,&written)!=GHOSTTY_SUCCESS)written=0;
    ghostty_key_event_free(event);return written;
}

size_t il_terminal_mouse(ILTerminal *t,int action,int button,uint16_t modifiers,float x,float y,float cellWidth,float cellHeight,char *out,size_t capacity){
    if(!t || action<0 || action>2 || button<0 || button>11 || cellWidth<=0 || cellHeight<=0)return 0;
    uint16_t cols=0,rows=0;ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_COLS,&cols);ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_ROWS,&rows);
    if(t->mouseEncoderDirty){ghostty_mouse_encoder_setopt_from_terminal(t->mouse,t->terminal);t->mouseEncoderDirty=false;}
    GhosttyMouseEncoderSize size={.size=sizeof(size),.screen_width=cols*cellWidth,.screen_height=rows*cellHeight,.cell_width=cellWidth,.cell_height=cellHeight};
    if(size.screen_width!=t->mouseSize.screen_width || size.screen_height!=t->mouseSize.screen_height ||
       size.cell_width!=t->mouseSize.cell_width || size.cell_height!=t->mouseSize.cell_height){
        ghostty_mouse_encoder_setopt(t->mouse,GHOSTTY_MOUSE_ENCODER_OPT_SIZE,&size);t->mouseSize=size;
    }
    bool pressed=action!=1 && ((button>=1 && button<=3) || button>=8);ghostty_mouse_encoder_setopt(t->mouse,GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,&pressed);
    GhosttyMouseEvent event=NULL;if(ghostty_mouse_event_new(NULL,&event)!=GHOSTTY_SUCCESS)return 0;
    ghostty_mouse_event_set_action(event,(GhosttyMouseAction)action);
    if(button)ghostty_mouse_event_set_button(event,(GhosttyMouseButton)button);else ghostty_mouse_event_clear_button(event);
    ghostty_mouse_event_set_mods(event,modifiers);ghostty_mouse_event_set_position(event,(GhosttyMousePosition){.x=x,.y=y});
    size_t written=0;if(ghostty_mouse_encoder_encode(t->mouse,event,out,capacity,&written)!=GHOSTTY_SUCCESS)written=0;
    ghostty_mouse_event_free(event);return written;
}

bool il_terminal_mouse_reporting(ILTerminal *t){
    bool enabled=false;
    if(t)ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,&enabled);
    return enabled;
}

size_t il_terminal_focus(ILTerminal *t,bool focused,char *out,size_t capacity){
    if(!t || !out || capacity<3)return 0;
    GhosttyTerminalModeConfig mode={.mode=GHOSTTY_MODE_FOCUS_EVENT};
    if(ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_MODE,&mode)!=GHOSTTY_SUCCESS || !mode.value)return 0;
    memcpy(out,focused?"\033[I":"\033[O",3);return 3;
}

size_t il_terminal_paste(ILTerminal *t,char *text,size_t length,char *out,size_t capacity){
    if(!t)return 0;GhosttyTerminalModeConfig mode={.mode=GHOSTTY_MODE_BRACKETED_PASTE};ghostty_terminal_get(t->terminal,GHOSTTY_TERMINAL_DATA_MODE,&mode);
    size_t written=0;if(ghostty_paste_encode(text,length,mode.value,out,capacity,&written)!=GHOSTTY_SUCCESS)return 0;return written;
}

char *il_terminal_link(ILTerminal *t,uint16_t column,uint16_t row){
    if(!t)return NULL;GhosttyGridRef ref=GHOSTTY_INIT_SIZED(GhosttyGridRef);GhosttyPoint point={.tag=GHOSTTY_POINT_TAG_VIEWPORT,.value={.coordinate={.x=column,.y=row}}};
    if(ghostty_terminal_grid_ref(t->terminal,point,&ref)!=GHOSTTY_SUCCESS)return NULL;
    size_t length=0;ghostty_grid_ref_hyperlink_uri(&ref,NULL,0,&length);if(!length)return NULL;
    char *result=malloc(length+1);if(!result)return NULL;
    if(ghostty_grid_ref_hyperlink_uri(&ref,(uint8_t *)result,length,&length)!=GHOSTTY_SUCCESS){free(result);return NULL;}result[length]=0;return result;
}
