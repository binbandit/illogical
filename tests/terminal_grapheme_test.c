#include "Bridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void check_base(const char *base) {
    ILTerminal *terminal = il_terminal_new(80, 4);
    assert(terminal);
    char grapheme[256];
    strcpy(grapheme, base);
    for (unsigned i = 0; i < 64; i++) strcat(grapheme, "\xcc\x81");
    il_terminal_feed(terminal, (const uint8_t *)grapheme, strlen(grapheme));
    ILFrame frame;
    assert(il_terminal_frame(terminal, &frame));
    assert(!strcmp(frame.cells[0].text, base));
    assert(strlen(frame.cells[0].text) < sizeof(frame.cells[0].text));
    il_terminal_select_all(terminal);
    size_t length;
    char *copy = il_terminal_copy(terminal, &length);
    assert(copy && strstr(copy, grapheme));
    il_bytes_free(copy);
    il_terminal_free(terminal);
}

int main(void) {
    check_base("a");
    check_base("\xc3\xa9");
    check_base("\xe4\xb8\xad");
    check_base("\xf0\x9f\x98\x80");
    puts("terminal graphemes: oversized clusters keep 1/2/3/4-byte bases and complete copy data");
}
