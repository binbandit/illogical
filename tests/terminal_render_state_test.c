#include "Bridge.h"
#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void feed(ILTerminal *t, const char *text) { il_terminal_feed(t, (const uint8_t *)text, strlen(text)); }
static ILFrame frame(ILTerminal *t) { ILFrame f; assert(il_terminal_frame(t, &f)); return f; }
static void expect_text(ILTerminal *t, const char *text) {
    ILFrame f = frame(t);
    for (size_t i = 0; text[i]; ++i) assert(f.cells[i].text[0] == text[i]);
}

static void test_render_hold(void) {
    ILTerminal *t = il_terminal_new(20, 4); assert(t);
    // The finished frame before the hold was never drawn. Capture at the
    // exact escape sequence, even if unfinished output shares its VT write.
    feed(t, "complete\x1b[?2026h\rpartial!");
    assert(il_terminal_render_hold_remaining(t) > 0);
    expect_text(t, "complete");
    feed(t, "\x1b[?2026l");
    expect_text(t, "partial!");
    // Back-to-back frames in a single read must keep making visible progress.
    feed(t, "\x1b[?2026h\rfinished\x1b[?2026l\x1b[?2026h\rhalfway!");
    expect_text(t, "finished");
    feed(t, "\x1b[?2026l");
    expect_text(t, "halfway!");

    // Starting an already active hold does not extend its deadline.
    feed(t, "\x1b[?2026h\rtimeout!");
    usleep(550000);
    feed(t, "\x1b[?2026h");
    assert(il_terminal_render_hold_remaining(t) < 600);
    usleep(550000);
    assert(il_terminal_expire_render_hold(t));
    expect_text(t, "timeout!");
    assert(!il_terminal_expire_render_hold(t));

    feed(t, "\x1b[?2026h\rresized!");
    il_terminal_resize(t, 21, 4, 8, 16);
    assert(il_terminal_render_hold_remaining(t) == 0);
    expect_text(t, "resized!");
    feed(t, "\x1b[?2026h\x1b" "creset");
    assert(il_terminal_render_hold_remaining(t) == 0);
    expect_text(t, "reset");
    il_terminal_free(t);
}

static void test_restored_hold(void) {
    GhosttyTerminal source; assert(ghostty_terminal_new(NULL, &source, 20, 4) == GHOSTTY_SUCCESS);
    const char *text = "restored\x1b[?2026h";
    ghostty_terminal_vt_write(source, (const uint8_t *)text, strlen(text));
    uint8_t *bytes; size_t count;
    assert(ghostty_snapshot_encode_alloc(source, NULL, &bytes, &count) == GHOSTTY_SUCCESS);
    ILTerminal *t = il_terminal_restore(bytes, count); assert(t);
    ghostty_free(NULL, bytes, count); ghostty_terminal_free(source);
    assert(il_terminal_render_hold_remaining(t) > 0);
    feed(t, "\rnew data");
    expect_text(t, "restored");
    feed(t, "\x1b[?2026l");
    expect_text(t, "new data");
    il_terminal_free(t);
}

static void test_dirty_rows(void) {
    ILTerminal *t = il_terminal_new(12, 4); assert(t);
    feed(t, "first\r\nsecond\r\nthird");
    ILFrame initial = frame(t);
    ILCell unchanged[12]; memcpy(unchanged, initial.cells, sizeof(unchanged));
    feed(t, "\x1b[2;1HSECOND");
    ILFrame f = frame(t);
    assert(memcmp(unchanged, f.cells, sizeof(unchanged)) == 0);
    assert(f.cells[12].text[0] == 'S');
    // Repeated clean frames reuse the exact cell contents.
    ILCell copy[48]; memcpy(copy, f.cells, sizeof(copy));
    f = frame(t); assert(memcmp(copy, f.cells, sizeof(copy)) == 0);

    il_terminal_select_all(t); f = frame(t); assert(f.cells[0].flags & 8);
    il_terminal_select(t, 0, 9, 3, 72, 48, 8, 16, 1, false);
    f = frame(t); assert(!(f.cells[0].flags & 8));
    il_terminal_search(t, "first", 5, 1); f = frame(t);
    assert(f.searchCount == 1 && (f.cells[0].flags & 64));
    il_terminal_search(t, "", 0, 0); f = frame(t);
    assert(f.searchCount == 0 && !(f.cells[0].flags & (64 | 128)));

    il_terminal_theme(t, 0x101112, 0xaabbcc, 0x112233, NULL); f = frame(t);
    assert(f.cells[0].foreground == 0xaabbcc && f.cells[0].background == 0x101112);
    feed(t, "\x1b[1;1H\x1b[31mR"); f = frame(t);
    uint32_t previous = f.cells[0].foreground;
    feed(t, "\x1b]4;1;#123456\x1b\\"); f = frame(t);
    assert(f.cells[0].foreground == 0x123456 && f.cells[0].foreground != previous);
    il_terminal_resize(t, 8, 6, 8, 16); f = frame(t);
    assert(f.columns == 8 && f.rows == 6 && f.count == 48);
    for (size_t i = 0; i < f.count; ++i) assert(f.cells[i].column == i % 8 && f.cells[i].row == i / 8);
    il_terminal_free(t);
}

static void test_text_attributes(void) {
    ILTerminal *t=il_terminal_new(40,4);assert(t);
    il_terminal_theme(t,0x102030,0xa0b0c0,0xffffff,NULL);
    feed(t,"\033[4:1mA\033[4:2mB\033[4:3mC\033[4:4mD\033[4:5mE");
    ILFrame f=frame(t);
    for(int i=0;i<5;i++)assert(f.cells[i].underlineStyle==i+1 && (f.cells[i].flags&4));
    feed(t,"\033[58:2::12:34:56mF\033[58:5:200mG\033[59mH");f=frame(t);
    assert(f.cells[5].underlineColor==0x0c2238 && (f.cells[5].attributes&1));
    assert(f.cells[6].underlineColor==0xff00d7 && (f.cells[6].attributes&1));
    assert(!(f.cells[7].attributes&1) && f.cells[7].underlineColor==0xa0b0c0);
    feed(t,"\033[0;38;2;1;2;3;48;2;4;5;6mI\033[7mJ\033[0;9;53mK\033[4:3;8mL\033[28mM");f=frame(t);
    assert(f.cells[8].foreground==0x010203 && f.cells[8].background==0x040506);
    assert(f.cells[9].foreground==0x040506 && f.cells[9].background==0x010203);
    assert((f.cells[8].attributes&8) && !(f.cells[8].attributes&16));
    assert((f.cells[9].attributes&(8|16))==(8|16) && !(f.cells[10].attributes&8));
    assert((f.cells[10].flags&(16|32))==(16|32));
    assert(f.cells[11].text[0]==0 && (f.cells[11].attributes&2) && !(f.cells[11].flags&(4|16|32)) && f.cells[11].underlineStyle==0);
    assert(f.cells[12].text[0]=='M' && f.cells[12].underlineStyle==3 && (f.cells[12].flags&(16|32))==(16|32));
    feed(t,"\033[0;5mN\033[25mO");f=frame(t);
    assert((f.cells[13].attributes&4) && !(f.cells[14].attributes&4));
    il_terminal_free(t);
}

int main(void) {
    test_render_hold(); test_restored_hold(); test_dirty_rows();test_text_attributes();
    puts("Render state: synchronized frames, back-to-back holds, timeout, snapshot, resize/reset, dirty rows, five underline styles/colors, truecolor, inverse, strike, overline, and invisible decorations passed.");
}
