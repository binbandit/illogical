package mux

import (
	"os"
	"os/user"
	"path/filepath"
	"strings"
)

// Version is stamped at build time with -ldflags "-X illogical/internal/mux.Version=...".
var Version = "dev"

// loginShell prefers $SHELL, then the account's passwd entry. A GUI launch may
// provide neither, so fall back to the platform shells.
func loginShell() string {
	for _, candidate := range []string{os.Getenv("SHELL"), passwdShell(), "/bin/zsh", "/bin/bash"} {
		if isExecutable(candidate) {
			return candidate
		}
	}
	return "/bin/sh"
}

func isExecutable(path string) bool {
	if !filepath.IsAbs(path) {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0
}

// Variables that identify another terminal, multiplexer, or debugger. The
// service inherits the environment of whatever started it (launchd, Xcode, or
// a CLI inside Ghostty or tmux), and none of that describes our PTYs.
var strippedVariables = map[string]bool{
	"TERM": true, "TERMINFO": true, "COLORTERM": true, "TERM_PROGRAM": true, "TERM_PROGRAM_VERSION": true,
	"TERM_SESSION_ID": true, "LC_TERMINAL": true, "LC_TERMINAL_VERSION": true, "VTE_VERSION": true, "WINDOWID": true,
	"TMUX": true, "TMUX_PANE": true, "STY": true, "WINDOW": true, "WT_SESSION": true, "WT_PROFILE_ID": true,
	"SHLVL": true, "PWD": true, "OLDPWD": true, "_": true,
	"XPC_SERVICE_NAME": true, "XPC_FLAGS": true, "__CFBundleIdentifier": true,
	"OS_ACTIVITY_DT_MODE": true, "NSUnbufferedIO": true, "NSZombieEnabled": true,
	"CA_DEBUG_TRANSACTIONS": true, "CA_ASSERT_MAIN_THREAD_TRANSACTIONS": true,
	"MTL_DEBUG_LAYER": true, "MTL_SHADER_VALIDATION": true, "MTL_HUD_ENABLED": true,
}

var strippedPrefixes = []string{
	"ILLOGICAL_", "GHOSTTY_", "KITTY_", "WEZTERM_", "ITERM_", "ALACRITTY_", "ZELLIJ",
	"DYLD_", "__XCODE_", "__XPC_", "Malloc",
}

func stripped(key string) bool {
	if strippedVariables[key] {
		return true
	}
	for _, prefix := range strippedPrefixes {
		if strings.HasPrefix(key, prefix) {
			return true
		}
	}
	return false
}

// childEnvironment builds a PTY child's environment from the service's own.
func (s *Server) childEnvironment(block, shell string) []string {
	env := make([]string, 0, 64)
	values := map[string]string{}
	for _, entry := range os.Environ() {
		key, value, _ := strings.Cut(entry, "=")
		if key == "" || stripped(key) {
			continue
		}
		values[key] = value
		if key != "PATH" {
			env = append(env, entry)
		}
	}
	set := func(key, value string) { env = append(env, key+"="+value) }
	setDefault := func(key, value string) {
		if values[key] == "" && value != "" {
			set(key, value)
		}
	}
	set("TERM", "xterm-256color")
	set("COLORTERM", "truecolor")
	set("TERM_PROGRAM", "illogical")
	set("TERM_PROGRAM_VERSION", Version)
	set("ILLOGICAL_BLOCK", block)
	set("ILLOGICAL_SOCKET", s.socket)
	set("ILLOGICAL_HOME", s.directory)
	set("PATH", childPath(values["PATH"]))
	setDefault("SHELL", shell)
	if u, err := user.Current(); err == nil {
		setDefault("USER", u.Username)
		setDefault("LOGNAME", u.Username)
		setDefault("HOME", u.HomeDir)
	}
	// Without a locale, shells treat input as ASCII and mangle UTF-8.
	if values["LC_ALL"] == "" && values["LC_CTYPE"] == "" && values["LANG"] == "" {
		set("LANG", defaultLocale())
	}
	return env
}

// childPath puts the bundled CLI first. launchd's minimal PATH is fine here:
// login shells extend it through path_helper and the user's profile.
func childPath(inherited string) string {
	if inherited == "" {
		inherited = "/usr/bin:/bin:/usr/sbin:/sbin"
	}
	executable, err := os.Executable()
	if err != nil {
		return inherited
	}
	directory := filepath.Dir(executable)
	entries := []string{directory}
	for _, entry := range filepath.SplitList(inherited) {
		if entry != directory {
			entries = append(entries, entry)
		}
	}
	return strings.Join(entries, string(filepath.ListSeparator))
}
