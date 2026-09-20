#include "Bridge.h"
#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void feed(ILTerminal *t,const char *text){il_terminal_feed(t,(const uint8_t *)text,strlen(text));}
static ILFrame frame(ILTerminal *t){ILFrame f;assert(il_terminal_frame(t,&f));return f;}
static size_t marked(ILFrame f,unsigned flag){size_t n=0;for(size_t i=0;i<f.count;i++)if(f.cells[i].flags&flag)n++;return n;}

static void dense(void){
    ILTerminal *t=il_terminal_new(120,12);assert(t);
    char line[121];memset(line,'a',120);line[120]=0;
    for(int row=0;row<11;row++){feed(t,line);feed(t,"\r\n");}
    il_terminal_search(t,"a",1,1);ILFrame f=frame(t);
    assert(f.searchCount==1320 && f.searchSelected==1 && marked(f,64)==1320 && marked(f,128)==1);
    // A second draw must reuse valid query storage, not stale stack memory.
    f=frame(t);assert(marked(f,64)==1320);
    il_terminal_search(t,"aa",2,1);f=frame(t);assert(f.searchCount>256 && marked(f,64)>1000);
    il_terminal_search(t,"",0,0);f=frame(t);assert(f.searchCount==0 && marked(f,64|128)==0);
    il_terminal_free(t);
}

static void clipping(void){
    ILTerminal *t=il_terminal_new(20,4);assert(t);
    const char *needle="abcdefghijklmnopqrstuvw";
    feed(t,needle);feed(t,"\r\nline2\r\nline3\r\nline4\r\nline5\r\n");
    il_terminal_search(t,needle,strlen(needle),1);
    il_terminal_scroll_to(t,0);ILFrame f=frame(t);assert(marked(f,64)==23 && marked(f,128)==23);
    il_terminal_scroll_to(t,1);f=frame(t);
    assert(marked(f,64)==3 && marked(f,128)==3 && f.searchRow==0);
    assert(!strcmp(f.cells[0].text,"u") && !strcmp(f.cells[2].text,"w"));
    // Ghostty invalidates the selected match on grid resize. Selecting again
    // checks a match whose trailing row now lies below the viewport.
    il_terminal_resize(t,20,1,0,0);il_terminal_search(t,needle,strlen(needle),1);il_terminal_scroll_to(t,0);f=frame(t);
    assert(marked(f,64)==20 && marked(f,128)==20 && f.searchRow==0);
    il_terminal_free(t);

    t=il_terminal_new(20,2);assert(t);
    char longNeedle[101];for(int i=0;i<100;i++)longNeedle[i]='a'+i%26;longNeedle[100]=0;
    feed(t,longNeedle);feed(t,"\r\nother\r\nother\r\nother\r\n");
    il_terminal_search(t,longNeedle,100,1);il_terminal_scroll_to(t,1);f=frame(t);
    assert(f.searchCount==1 && marked(f,64)==40 && marked(f,128)==40 && f.searchRow==0);
    il_terminal_scroll_bottom(t);f=frame(t);assert(marked(f,64|128)==0 && f.searchRow==-1);
    il_terminal_free(t);
}

static void history(void){
    GhosttyTerminal source=NULL;assert(ghostty_terminal_new(NULL,&source,120,12)==GHOSTTY_SUCCESS);
    size_t limit=64<<20;assert(ghostty_terminal_set(source,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,&limit)==GHOSTTY_SUCCESS);
    for(int n=0;n<5000;n++){
        char line[120];snprintf(line,sizeof(line),"line-%04d %s\r\n",n,n==0||n==2499||n==4999?"audit-marker":"ordinary");
        ghostty_terminal_vt_write(source,(const uint8_t *)line,strlen(line));
    }
    uint8_t *bytes=NULL;size_t count=0;assert(ghostty_snapshot_encode_alloc(source,NULL,&bytes,&count)==GHOSTTY_SUCCESS);
    GhosttySnapshotDecoder decoder=NULL;assert(ghostty_snapshot_decoder_new_buf(NULL,&decoder,bytes,count)==GHOSTTY_SUCCESS);
    GhosttyTerminal mirror=NULL;assert(ghostty_snapshot_decoder_ready(decoder,&mirror)==GHOSTTY_SUCCESS);
    size_t offset=0;assert(ghostty_snapshot_decoder_get(decoder,GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET,&offset)==GHOSTTY_SUCCESS);
    ILTerminal *client=il_terminal_restore(bytes,offset);assert(client);
    FILE *fixture=fopen(".build/tests/search-contrast/snapshot-ready.bin","wb");assert(fixture);
    assert(fwrite(bytes,1,offset,fixture)==offset);fclose(fixture);
    il_terminal_search(client,"audit-marker",12,1);ILFrame f=frame(client);assert(f.searchCount==1);
    int pages=0;
    for(;;){
        GhosttyResult result=ghostty_snapshot_decoder_next(decoder);assert(result==GHOSTTY_SUCCESS||result==GHOSTTY_NO_VALUE);
        size_t next=0;assert(ghostty_snapshot_decoder_get(decoder,GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET,&next)==GHOSTTY_SUCCESS);
        char fixture_path[160];snprintf(fixture_path,sizeof(fixture_path),".build/tests/search-contrast/history-%02d.bin",pages);
        fixture=fopen(fixture_path,"wb");assert(fixture);assert(fwrite(bytes+offset,1,next-offset,fixture)==next-offset);fclose(fixture);
        assert(il_terminal_history(client,bytes+offset,next-offset,result==GHOSTTY_NO_VALUE)==0);offset=next;
        if(result==GHOSTTY_NO_VALUE)break;
        pages++;
    }
    fixture=fopen(".build/tests/search-contrast/history-count.txt","w");assert(fixture);fprintf(fixture,"%d",pages+1);fclose(fixture);
    f=frame(client);assert(f.searchCount==3 && f.scrollTotal==5001);
    for(int n=1;n<4;n++){
        il_terminal_search(client,"audit-marker",12,1);f=frame(client);
        assert(f.searchSelected==(size_t)(n%3+1) && marked(f,128)==12);
        if(n==2)assert(f.scrollOffset==0);
    }
    printf("Search: 1,320 dense highlights; wrapped clipping above/below/both; clear; 5,001 retained rows across %d history pages and navigation passed.\n",pages);
    il_terminal_free(client);ghostty_snapshot_decoder_free(decoder);ghostty_terminal_free(mirror);ghostty_terminal_free(source);ghostty_free(NULL,bytes,count);
}

int main(void){dense();clipping();history();}
