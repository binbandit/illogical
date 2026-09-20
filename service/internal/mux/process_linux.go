package mux

import (
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
)

func processDirectory(pid int) string {
	path, _ := os.Readlink("/proc/" + strconv.Itoa(pid) + "/cwd")
	return path
}

func processIdentity(pid int) *ProcessRecord {
	if pid <= 0 {
		return nil
	}
	base := "/proc/" + strconv.Itoa(pid)
	stat, err := os.Stat(base)
	if err != nil {
		return nil
	}
	raw, ok := stat.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	exe, _ := os.Readlink(base + "/exe")
	result := &ProcessRecord{PID: pid, UID: raw.Uid, Name: filepath.Base(exe), Executable: exe}
	if u, err := user.LookupId(strconv.FormatUint(uint64(raw.Uid), 10)); err == nil {
		result.User = u.Username
	}
	return result
}
