#include "Bridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void feed(ILTerminal *terminal, const char *text) {
    il_terminal_feed(terminal, (const uint8_t *)text, strlen(text));
}

static void expect_link(ILTerminal *terminal, unsigned column, unsigned row, const char *expected) {
    char *actual = il_terminal_link(terminal, column, row);
    if (expected ? (!actual || strcmp(actual, expected)) : actual != NULL) {
        fprintf(stderr, "link at %u,%u: expected %s, got %s\n", column, row,
                expected ? expected : "nil", actual ? actual : "nil");
        assert(false);
    }
    il_bytes_free(actual);
}

int main(void) {
    ILTerminal *terminal = il_terminal_new(100, 10);
    assert(terminal);
    feed(terminal, "Server: http://localhost:3000/path?q=1#result.\r\n"
                   "See (https://example.com/a_(b)).\r\n"
                   "https://one.test https://two.test\r\n"
                   "\033]8;;https://actual.test\033\\https://display.test\033]8;;\033\\\r\n"
                   "prefix https://example.com/日本語 end\r\n"
                   "mailto:person@example.com file:///tmp/example.txt\r\n"
                   "not-a-url xhttps://not.test https://\r\n"
                   "漢字 https://example.test/end\r\n");
    expect_link(terminal, 15, 0, "http://localhost:3000/path?q=1#result");
    expect_link(terminal, 45, 0, NULL);
    expect_link(terminal, 1, 0, NULL);
    expect_link(terminal, 10, 1, "https://example.com/a_(b)");
    expect_link(terminal, 30, 1, NULL);
    expect_link(terminal, 5, 2, "https://one.test");
    expect_link(terminal, 20, 2, "https://two.test");
    expect_link(terminal, 16, 2, NULL);
    expect_link(terminal, 5, 3, "https://actual.test");
    expect_link(terminal, 28, 4, "https://example.com/日本語");
    expect_link(terminal, 5, 5, "mailto:person@example.com");
    expect_link(terminal, 30, 5, "file:///tmp/example.txt");
    expect_link(terminal, 2, 6, NULL);
    expect_link(terminal, 16, 6, NULL);
    expect_link(terminal, 31, 6, NULL);
    expect_link(terminal, 10, 7, "https://example.test/end");
    il_terminal_select_all(terminal);
    size_t before_length, after_length;
    char *before = il_terminal_copy(terminal, &before_length);
    expect_link(terminal, 20, 2, "https://two.test");
    char *after = il_terminal_copy(terminal, &after_length);
    assert(before && after && before_length == after_length && !memcmp(before, after, before_length));
    il_bytes_free(before); il_bytes_free(after);
    il_terminal_free(terminal);

    terminal = il_terminal_new(16, 3);
    feed(terminal, "url https://example.com/long/path\r\nnext\r\nlast\r\n");
    il_terminal_scroll_to(terminal, 0);
    expect_link(terminal, 8, 0, "https://example.com/long/path");
    expect_link(terminal, 3, 1, "https://example.com/long/path");
    il_terminal_scroll_to(terminal, 1);
    expect_link(terminal, 3, 0, "https://example.com/long/path");
    il_terminal_free(terminal);
    puts("terminal links: plain, OSC 8 priority, punctuation, Unicode, wrapped scrollback and selection preservation passed");
}
