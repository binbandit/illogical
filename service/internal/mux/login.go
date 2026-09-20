package mux

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
)

// Login sessions are opt-in and configured before restored terminals launch.
// The helper never accepts a target account: it may open a session only for its
// own real UID, already authenticated by the service's private Unix socket or
// explicitly configured remote admission policy.
func WithLoginHelper(path string) ServerOption {
	return func(s *Server) error {
		if path == "" {
			return nil
		}
		if runtime.GOOS != "linux" {
			return errors.New("PAM login helper is only supported on Linux")
		}
		if !filepath.IsAbs(path) {
			return errors.New("login helper must be an absolute path")
		}
		resolved, err := filepath.EvalSymlinks(path)
		if err != nil {
			return err
		}
		info, err := os.Stat(resolved)
		if err != nil {
			return err
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 || !info.Mode().IsRegular() || info.Mode()&os.ModeSetuid == 0 || info.Mode().Perm()&0022 != 0 || info.Mode().Perm()&0111 == 0 {
			return errors.New("login helper must be a root-owned setuid executable without group/other write access")
		}
		for directory := filepath.Dir(resolved); ; directory = filepath.Dir(directory) {
			info, err = os.Stat(directory)
			if err != nil {
				return err
			}
			stat, ok = info.Sys().(*syscall.Stat_t)
			if !ok || stat.Uid != 0 || info.Mode().Perm()&0022 != 0 {
				return fmt.Errorf("login helper parent is not protected: %s", directory)
			}
			if directory == string(filepath.Separator) {
				break
			}
		}
		s.loginHelper = resolved
		return nil
	}
}

func (s *Server) prepareLoginCommand(cmd *exec.Cmd) error {
	if s.loginHelper == "" {
		return nil
	}
	if !filepath.IsAbs(cmd.Path) {
		return errors.New("login command must resolve to an absolute executable")
	}
	// exec.Cmd.Path is resolved before the helper; preserve the original argv,
	// including a caller's intended argv[0], without shell interpolation.
	cmd.Args = append([]string{s.loginHelper, "--", cmd.Path}, cmd.Args...)
	cmd.Path = s.loginHelper
	return nil
}
