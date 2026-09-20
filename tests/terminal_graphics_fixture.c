#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    GhosttyTerminal terminal=NULL, mirror=NULL;
    assert(ghostty_terminal_new(NULL,&terminal,20,4)==GHOSTTY_SUCCESS);
    for(int row=0;row<2000;row++){
        char text[40];snprintf(text,sizeof(text),"r%04d chosen-text\r\n",row);
        ghostty_terminal_vt_write(terminal,(const uint8_t *)text,strlen(text));
    }
    uint8_t *bytes=NULL;size_t count=0,offset=0;
    assert(ghostty_snapshot_encode_alloc(terminal,NULL,&bytes,&count)==GHOSTTY_SUCCESS);
    GhosttySnapshotDecoder decoder=NULL;
    assert(ghostty_snapshot_decoder_new_buf(NULL,&decoder,bytes,count)==GHOSTTY_SUCCESS);
    assert(ghostty_snapshot_decoder_ready(decoder,&mirror)==GHOSTTY_SUCCESS);
    assert(ghostty_snapshot_decoder_get(decoder,GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET,&offset)==GHOSTTY_SUCCESS);
    FILE *file=fopen(".build/tests/graphics/ready.bin","wb");assert(file);
    assert(fwrite(bytes,1,offset,file)==offset);fclose(file);
    int pages=0;
    for(;;){
        GhosttyResult result=ghostty_snapshot_decoder_next(decoder);assert(result==GHOSTTY_SUCCESS || result==GHOSTTY_NO_VALUE);
        size_t next=0;assert(ghostty_snapshot_decoder_get(decoder,GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET,&next)==GHOSTTY_SUCCESS);
        char path[100];snprintf(path,sizeof(path),".build/tests/graphics/history-%d.bin",pages++);
        file=fopen(path,"wb");assert(file);assert(fwrite(bytes+offset,1,next-offset,file)==next-offset);fclose(file);offset=next;
        if(result==GHOSTTY_NO_VALUE)break;
    }
    file=fopen(".build/tests/graphics/history-count.txt","w");assert(file);fprintf(file,"%d",pages);fclose(file);
    ghostty_snapshot_decoder_free(decoder);ghostty_terminal_free(mirror);
    ghostty_terminal_free(terminal);ghostty_free(NULL,bytes,count);
    return 0;
}
