#include "Bridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    ILTerminal *t=il_terminal_new(80,24);assert(t);
    const char *text="alpha beta alpha\r\nrender-check 123\r\n";
    il_terminal_feed(t,(const uint8_t*)text,strlen(text));
    il_terminal_search(t,"alpha",5,1);
    ILFrame f;assert(il_terminal_frame(t,&f));
    printf("count=%zu selected=%zu row=%d\n",f.searchCount,f.searchSelected,f.searchRow);
    assert(f.searchCount==2);assert(f.searchSelected==1);
    il_terminal_select_all(t);size_t length=0;char*copy=il_terminal_copy(t,&length);
    assert(copy&&strstr(copy,"render-check 123"));il_bytes_free(copy);
    il_terminal_free(t);
    puts("terminal bridge: passed");
}
