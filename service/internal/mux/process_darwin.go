package mux

/*
#include <libproc.h>
#include <string.h>
static int il_process_identity(int pid, unsigned int *uid, char *name, int name_cap, char *path, int path_cap) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    *uid = info.pbi_uid;
    strlcpy(name, info.pbi_name[0] ? info.pbi_name : info.pbi_comm, name_cap);
    proc_pidpath(pid, path, path_cap);
    return 1;
}
static int il_process_directory(int pid, char *path, int capacity) {
    struct proc_vnodepathinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    strlcpy(path, info.pvi_cdir.vip_path, capacity);
    return 1;
}
*/
import "C"

import (
	"os/user"
	"strconv"
)

func processDirectory(pid int) string {
	var path [4096]C.char
	if C.il_process_directory(C.int(pid), &path[0], C.int(len(path))) == 0 {
		return ""
	}
	return C.GoString(&path[0])
}

func processIdentity(pid int) *ProcessRecord {
	if pid <= 0 {
		return nil
	}
	var uid C.uint
	var name [256]C.char
	var path [4096]C.char
	if C.il_process_identity(C.int(pid), &uid, &name[0], C.int(len(name)), &path[0], C.int(len(path))) == 0 {
		return nil
	}
	result := &ProcessRecord{PID: pid, UID: uint32(uid), Name: C.GoString(&name[0]), Executable: C.GoString(&path[0])}
	if u, err := user.LookupId(strconv.FormatUint(uint64(uid), 10)); err == nil {
		result.User = u.Username
	}
	return result
}
