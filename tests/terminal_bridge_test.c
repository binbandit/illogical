#include "Bridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void feed(ILTerminal *t, const char *text) { il_terminal_feed(t, (const uint8_t *)text, strlen(text)); }

/// The first `length` cells of the top visible row.
static const char *top_row(ILTerminal *t, size_t length) {
    static char text[64];
    ILFrame frame;
    assert(il_terminal_frame(t, &frame) && length < sizeof(text));
    for (size_t i = 0; i < length; i++) text[i] = frame.cells[i].text[0] ? frame.cells[i].text[0] : ' ';
    text[length] = 0;
    return text;
}

static void search_and_copy(void) {
    ILTerminal *t = il_terminal_new(80, 24);
    assert(t);
    feed(t, "alpha beta alpha\r\nrender-check 123\r\n");
    il_terminal_search(t, "alpha", 5, ILSearchNavigationNext);
    ILFrame f;
    assert(il_terminal_frame(t, &f));
    assert(f.searchCount == 2 && f.searchSelected == 1);
    il_terminal_select_all(t);
    size_t length = 0;
    char *copy = il_terminal_copy(t, &length);
    assert(copy && strstr(copy, "render-check 123"));
    il_bytes_free(copy);
    il_terminal_clear_selection(t);
    copy = il_terminal_copy(t, &length);
    assert(!copy || length == 0);
    il_bytes_free(copy);
    il_terminal_free(t);
}

static void grapheme_clusters(void) {
    ILTerminal *t = il_terminal_new(20, 2);
    assert(t);
    // A family emoji is one grapheme: one wide cell, like Ghostty.
    const char *family = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7";
    feed(t, family);
    feed(t, "x");
    ILFrame frame;
    assert(il_terminal_frame(t, &frame));
    assert(!strcmp(frame.cells[0].text, family) && frame.cells[0].width == 2 && frame.cells[1].width == 0);
    assert(!strcmp(frame.cells[2].text, "x"));
    il_terminal_free(t);
}

static void prompt_jumps(void) {
    ILTerminal *t = il_terminal_new(20, 4);
    assert(t);
    const char *prompt = "\033]133;A\007";
    for (int command = 1; command <= 3; command++) {
        char line[64];
        snprintf(line, sizeof(line), "%s$ cmd%d\r\n", prompt, command);
        feed(t, line);
        for (int output = 0; output < 5; output++) feed(t, "output\r\n");
    }
    assert(il_terminal_jump_to_prompt(t, -1) && !strcmp(top_row(t, 6), "$ cmd3"));
    assert(il_terminal_jump_to_prompt(t, -1) && !strcmp(top_row(t, 6), "$ cmd2"));
    assert(il_terminal_jump_to_prompt(t, -1) && !strcmp(top_row(t, 6), "$ cmd1"));
    assert(!il_terminal_jump_to_prompt(t, -1) && !strcmp(top_row(t, 6), "$ cmd1"));
    assert(il_terminal_jump_to_prompt(t, 2) && !strcmp(top_row(t, 6), "$ cmd3"));
    il_terminal_scroll_top(t);
    assert(!strcmp(top_row(t, 6), "$ cmd1"));
    il_terminal_free(t);
}

static void paste(void) {
    ILTerminal *t = il_terminal_new(20, 4);
    assert(t);
    char out[64];
    const char *text = "one\ntwo\033";
    size_t length = il_terminal_paste(t, text, strlen(text), out, sizeof(out));
    assert(length == 8 && !memcmp(out, "one\rtwo ", 8));
    assert(il_terminal_paste_is_unsafe(t, "ls\n", 3) && !il_terminal_paste_is_unsafe(t, "ls", 2));
    feed(t, "\033[?2004h");
    assert(il_terminal_paste(t, text, strlen(text), NULL, 0) == 8 + 12);
    length = il_terminal_paste(t, text, strlen(text), out, sizeof(out));
    assert(length == 20 && !memcmp(out, "\033[200~one\ntwo \033[201~", 20));
    assert(!il_terminal_paste_is_unsafe(t, "ls\n", 3) && il_terminal_paste_is_unsafe(t, "x\033[201~rm", 9));
    il_terminal_free(t);
}

static void option_as_alt(void) {
    ILTerminal *t = il_terminal_new(20, 4);
    assert(t);
    char out[32];
    // Option-B composes "∫" by default, but sends ESC b when Option is Alt.
    ILKeyEvent key = {.keyCode = 11, .action = ILKeyActionPress, .modifiers = ILModifierOption,
                      .consumedModifiers = ILModifierOption, .unshiftedCodepoint = 'b', .text = "∫", .textLength = 3};
    assert(il_terminal_key(t, &key, out, sizeof(out)) == 3 && !memcmp(out, "∫", 3));
    key.optionAsAlt = ILOptionAsAltBoth;
    key.consumedModifiers = 0;
    key.text = "b";
    key.textLength = 1;
    assert(il_terminal_key(t, &key, out, sizeof(out)) == 2 && !memcmp(out, "\033b", 2));
    // A too-small buffer reports the length it needs.
    assert(il_terminal_key(t, &key, out, 1) == 2);
    assert(!il_terminal_kitty_keyboard(t));
    feed(t, "\033[>1u");
    assert(il_terminal_kitty_keyboard(t));
    il_terminal_free(t);
}

int main(void) {
    search_and_copy();
    grapheme_clusters();
    prompt_jumps();
    paste();
    option_as_alt();
    puts("terminal bridge: search, copy, grapheme clusters, prompt jumps, paste encoding and protection, Option-as-Alt passed");
}
