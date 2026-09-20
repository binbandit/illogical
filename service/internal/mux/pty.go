package mux

import (
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// creack/pty returns a blocking master. Construct a new os.File after enabling
// O_NONBLOCK so Go registers it with the shared poller and Close interrupts I/O.
func pollablePTY(master *os.File) (*os.File, error) {
	defer master.Close()
	raw, err := master.SyscallConn()
	if err != nil {
		return nil, err
	}
	fd := -1
	var syscallErr error
	if err = raw.Control(func(original uintptr) {
		fd, syscallErr = unix.FcntlInt(original, unix.F_DUPFD_CLOEXEC, 0)
	}); err != nil {
		return nil, err
	}
	if syscallErr != nil {
		return nil, syscallErr
	}
	if err = unix.SetNonblock(fd, true); err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	file := os.NewFile(uintptr(fd), master.Name())
	if err = file.SetReadDeadline(time.Time{}); err != nil {
		_ = file.Close()
		return nil, err
	}
	return file, nil
}

func foregroundProcess(file *os.File) int {
	raw, err := file.SyscallConn()
	if err != nil {
		return 0
	}
	var pid int
	_ = raw.Control(func(fd uintptr) { pid, _ = unix.IoctlGetInt(int(fd), unix.TIOCGPGRP) })
	return pid
}

func resizePTY(file *os.File, cols, rows uint16, cellWidth, cellHeight uint32) error {
	raw, err := file.SyscallConn()
	if err != nil {
		return err
	}
	// The legacy kernel winsize uses 16-bit pixel dimensions.
	size := unix.Winsize{Col: cols, Row: rows,
		Xpixel: uint16(min(uint64(cols)*uint64(cellWidth), 65535)),
		Ypixel: uint16(min(uint64(rows)*uint64(cellHeight), 65535))}
	var ioctlErr error
	if err = raw.Control(func(fd uintptr) { ioctlErr = unix.IoctlSetWinsize(int(fd), unix.TIOCSWINSZ, &size) }); err != nil {
		return err
	}
	return ioctlErr
}
