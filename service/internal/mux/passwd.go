package mux

/*
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int il_passwd_shell(char *out, size_t capacity) {
    long size = sysconf(_SC_GETPW_R_SIZE_MAX);
    if (size <= 0) size = 16384;
    char *buffer = malloc(size);
    if (buffer == NULL) return 0;
    struct passwd entry, *result = NULL;
    int ok = getpwuid_r(getuid(), &entry, buffer, size, &result) == 0 && result != NULL && result->pw_shell != NULL;
    if (ok) snprintf(out, capacity, "%s", result->pw_shell);
    free(buffer);
    return ok;
}
*/
import "C"

// passwdShell reads the login shell from the account database. On macOS
// that is Directory Services, which /etc/passwd does not reflect.
func passwdShell() string {
	var shell [1024]C.char
	if C.il_passwd_shell(&shell[0], C.size_t(len(shell))) == 0 {
		return ""
	}
	return C.GoString(&shell[0])
}
