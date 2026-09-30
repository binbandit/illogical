package mux

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The service may be started by launchd (no locale, minimal PATH) or by a CLI
// inside another terminal. Default shells must still be login shells with our
// terminal identity and a UTF-8 locale, and must not inherit the other
// terminal's identity.
func TestDefaultShellIsLoginShellWithCleanTerminalEnvironment(t *testing.T) {
	home := testDirectory(t)
	if err := os.WriteFile(filepath.Join(home, ".profile"), []byte("PROFILE_LOADED=yes\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("HOME", home)
	t.Setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	for _, key := range []string{"LANG", "LC_ALL", "LC_CTYPE"} {
		t.Setenv(key, "")
		os.Unsetenv(key)
	}
	t.Setenv("TMUX", "/tmp/other,1,0")
	t.Setenv("GHOSTTY_RESOURCES_DIR", "/Applications/Ghostty.app")
	t.Setenv("TERM_PROGRAM_VERSION", "other")
	t.Setenv("PWD", "/nowhere")

	_, socket := startTest(t)
	c := connectTest(t, socket)
	created := c.request(t, Request{Method: "session.new", Cwd: home})
	c.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte(`printf 'ENV[%s|%s|%s|%s|%s|%s|%s|%s]\n' "$TERM" "$COLORTERM" "$TERM_PROGRAM" "${TERM_PROGRAM_VERSION:+set}" "$PROFILE_LOADED" "${TMUX-unset}" "${GHOSTTY_RESOURCES_DIR-unset}" "$(pwd)"` + "\n")})
	text := waitCapture(t, c, created.Block, "ENV[xterm")
	start := strings.LastIndex(text, "ENV[")
	got := text[start : start+strings.Index(text[start:], "]")+1]
	want := "ENV[xterm-256color|truecolor|illogical|set|yes|unset|unset|" + home + "]"
	if resolved, _ := filepath.EvalSymlinks(home); got != want && got != strings.Replace(want, home, resolved, 1) {
		t.Fatalf("shell environment %s, want %s", got, want)
	}
	c.request(t, Request{Method: "block.write", Block: created.Block, Data: []byte("printf 'LOCALE[%s]\\n' \"$LANG\"\n")})
	waitCapture(t, c, created.Block, ".UTF-8]")
}
