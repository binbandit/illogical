// Including the bridge lets this test compare the private macOS physical-key
// table directly with the pinned Ghostty key identities, without a test API.
#include "../illogical/Terminal/Bridge.c"
#include <assert.h>
#include <stdio.h>

static void feed(ILTerminal *t,const char *s){il_terminal_feed(t,(const uint8_t *)s,strlen(s));}
static void expect(const char *name,const char *actual,size_t n,const char *expected){
    if(n!=strlen(expected)||memcmp(actual,expected,n)){
        fprintf(stderr,"%s: expected %zu bytes, got %zu:",name,strlen(expected),n);
        for(size_t i=0;i<n;i++)fprintf(stderr," %02x",(unsigned char)actual[i]);
        fprintf(stderr,"\n");abort();
    }
}
static void mouse(ILTerminal *t,const char *name,int action,int button,int mods,float x,float y,const char *expected){
    char bytes[128];size_t n=il_terminal_mouse(t,action,button,mods,x,y,10,20,bytes,sizeof(bytes));expect(name,bytes,n,expected);
}

int main(void){
    struct {uint16_t code;GhosttyKey key;} keys[]={
        {105,GHOSTTY_KEY_F13},{107,GHOSTTY_KEY_F14},{113,GHOSTTY_KEY_F15},{106,GHOSTTY_KEY_F16},
        {64,GHOSTTY_KEY_F17},{79,GHOSTTY_KEY_F18},{80,GHOSTTY_KEY_F19},{90,GHOSTTY_KEY_F20},
        {10,GHOSTTY_KEY_INTL_BACKSLASH},{93,GHOSTTY_KEY_INTL_YEN},{94,GHOSTTY_KEY_INTL_RO},
        {81,GHOSTTY_KEY_NUMPAD_EQUAL},{95,GHOSTTY_KEY_NUMPAD_COMMA},{114,GHOSTTY_KEY_INSERT},{110,GHOSTTY_KEY_CONTEXT_MENU},
        {72,GHOSTTY_KEY_AUDIO_VOLUME_UP},{73,GHOSTTY_KEY_AUDIO_VOLUME_DOWN},{74,GHOSTTY_KEY_AUDIO_VOLUME_MUTE}
    };
    ILTerminal *t=il_terminal_new(80,24);assert(t);
    for(size_t i=0;i<sizeof(keys)/sizeof(*keys);i++)assert(physical_key(keys[i].code)==keys[i].key);
    GhosttyKeyEncoder reference=NULL;assert(ghostty_key_encoder_new(NULL,&reference)==GHOSTTY_SUCCESS);
    for(int mode=0;mode<2;mode++){
        if(mode)feed(t,"\033[>31u");
        ghostty_key_encoder_setopt_from_terminal(reference,t->terminal);
        for(size_t i=0;i<sizeof(keys)/sizeof(*keys);i++){
            GhosttyKeyEvent event=NULL;assert(ghostty_key_event_new(NULL,&event)==GHOSTTY_SUCCESS);
            ghostty_key_event_set_key(event,keys[i].key);ghostty_key_event_set_action(event,GHOSTTY_KEY_ACTION_PRESS);
            char actual[128],expected[128];size_t want=0;
            assert(ghostty_key_encoder_encode(reference,event,expected,sizeof(expected),&want)==GHOSTTY_SUCCESS);
            size_t n=il_terminal_key(t,keys[i].code,0,0,1,"",0,0,actual,sizeof(actual));
            assert(n==want && !memcmp(actual,expected,n));
            if(i<8)assert(n>0);
            ghostty_key_event_free(event);
        }
    }
    ghostty_key_encoder_free(reference);
    char output[16];assert(il_terminal_focus(t,true,output,sizeof(output))==0);
    feed(t,"\033[?1004h");expect("focus in",output,il_terminal_focus(t,true,output,sizeof(output)),"\033[I");
    expect("focus out",output,il_terminal_focus(t,false,output,sizeof(output)),"\033[O");
    assert(il_terminal_focus(t,true,output,2)==0);feed(t,"\033[?1004l");assert(il_terminal_focus(t,false,output,sizeof(output))==0);
    feed(t,"\033[?1000h\033[?1006h");
    mouse(t,"left",0,1,0,12,10,"\033[<0;2;1M");mouse(t,"left release",1,1,0,12,10,"\033[<0;2;1m");
    mouse(t,"right",0,2,0,12,10,"\033[<2;2;1M");mouse(t,"middle",0,3,0,12,10,"\033[<1;2;1M");
    mouse(t,"wheel up",0,4,0,12,10,"\033[<64;2;1M");mouse(t,"wheel down",0,5,0,12,10,"\033[<65;2;1M");
    mouse(t,"wheel left",0,6,0,12,10,"\033[<66;2;1M");mouse(t,"wheel right",0,7,0,12,10,"\033[<67;2;1M");
    mouse(t,"extra",0,8,0,12,10,"\033[<128;2;1M");mouse(t,"modifiers",0,1,7,12,10,"\033[<28;2;1M");
    mouse(t,"normal mode ignores drag",2,1,0,20,20,"");
    feed(t,"\033[?1002h");mouse(t,"button mode ignores hover",2,0,0,20,20,"");
    mouse(t,"button drag",2,1,0,20,20,"\033[<32;3;2M");
    mouse(t,"same-cell drag coalesces",2,1,0,21,21,"");
    feed(t,"\033[?1003h");mouse(t,"all-motion hover",2,0,0,30,40,"\033[<35;4;3M");
    feed(t,"\033[?1016h");mouse(t,"pixel motion",2,0,0,12,10,"\033[<35;12;10M");
    mouse(t,"pixel motion within cell",2,0,0,13,10,"\033[<35;13;10M");
    assert(il_terminal_mouse(t,2,0,0,0,0,0,20,output,sizeof(output))==0);
    il_terminal_free(t);
    puts("Terminal protocols: F13-F20, international/keypad mappings, legacy/Kitty reference encoding, focus reports, mouse buttons/wheels/modifiers, drag/all-motion, deduplication, and pixel coordinates passed.");
}
