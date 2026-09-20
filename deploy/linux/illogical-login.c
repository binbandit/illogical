#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* Installed explicitly by an administrator. The target is always the caller's
 * real UID, never a request parameter or environment value. PAM policy name is
 * fixed so a caller cannot choose a permissive service. */
static int conversation(int count, const struct pam_message **messages,
                        struct pam_response **reply, void *unused) {
    (void)unused;
    struct pam_response *responses = calloc((size_t)count, sizeof(*responses));
    if (!responses) return PAM_BUF_ERR;
    for (int i = 0; i < count; i++) {
        if (messages[i]->msg_style != PAM_TEXT_INFO && messages[i]->msg_style != PAM_ERROR_MSG) {
            free(responses);
            return PAM_CONV_ERR;
        }
    }
    *reply = responses;
    return PAM_SUCCESS;
}

static void fatal(const char *message) { fprintf(stderr, "illogical-login: %s\n", message); exit(1); }
static void set_env(const char *key, const char *value) { if (setenv(key, value, 1) != 0) fatal("environment allocation failed"); }

int main(int argc, char **argv) {
    uid_t caller = getuid();
    if (argc < 4 || strcmp(argv[1], "--") || argv[2][0] != '/') fatal("expected -- absolute-executable argv0 [arguments]");
    if (caller == 0 || geteuid() != 0) fatal("requires an administrator-installed setuid helper invoked by a non-root user");
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) fatal("requires a terminal");
    struct stat input, output;
    if (fstat(0, &input) || fstat(1, &output) || input.st_rdev != output.st_rdev || input.st_uid != caller) fatal("terminal is not owned by the invoking user");
    const char *tty = ttyname(STDIN_FILENO);
    if (!tty) fatal("terminal has no name");
    char *terminal = strdup(tty);
    struct passwd *account = getpwuid(caller);
    if (!account || !account->pw_name || !account->pw_dir || !account->pw_shell || account->pw_shell[0] != '/') fatal("invalid invoking Unix account");
    char *user = strdup(account->pw_name), *home = strdup(account->pw_dir), *shell = strdup(account->pw_shell);
    gid_t group = account->pw_gid;
    if (!terminal || !user || !home || !shell) fatal("allocation failed");
    /* Preserve only terminal metadata while privileged. In particular no
     * LD_*, language runtime startup hooks, PAM variables or caller PATH. */
    const char *keys[] = {"TERM", "COLORTERM", "TERM_PROGRAM", "LANG", "LC_CTYPE", "ILLOGICAL_BLOCK", "ILLOGICAL_SOCKET", "ILLOGICAL_HOME", NULL};
    char *values[sizeof(keys)/sizeof(keys[0])] = {0};
    for (size_t i = 0; keys[i]; i++) {
        const char *value = getenv(keys[i]);
        if (value) { values[i] = strdup(value); if (!values[i]) fatal("allocation failed"); }
    }
    char *user_path = getenv("PATH") ? strdup(getenv("PATH")) : NULL;
    if (clearenv() != 0) fatal("cannot clear environment");
    set_env("PATH", "/usr/bin:/bin");
    set_env("HOME", home); set_env("USER", user); set_env("LOGNAME", user); set_env("SHELL", shell);
    for (size_t i = 0; keys[i]; i++) if (values[i]) { set_env(keys[i], values[i]); free(values[i]); }
    sigset_t signals, previous_signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGHUP); sigaddset(&signals, SIGTERM);
    sigaddset(&signals, SIGINT); sigaddset(&signals, SIGQUIT);
    sigaddset(&signals, SIGCHLD);
    if (sigprocmask(SIG_BLOCK, &signals, &previous_signals)) fatal("cannot block session signals");
    struct pam_conv conv = {.conv = conversation};
    pam_handle_t *pam = NULL;
    int result = pam_start("illogical", user, &conv, &pam);
    if (result != PAM_SUCCESS) fatal("cannot start PAM");
    int credentials = 0, session = 0, status = 1 << 8;
    if ((result = pam_set_item(pam, PAM_TTY, terminal)) != PAM_SUCCESS) goto cleanup;
    if ((result = pam_set_item(pam, PAM_RUSER, user)) != PAM_SUCCESS) goto cleanup;
    if ((result = pam_acct_mgmt(pam, 0)) != PAM_SUCCESS) goto cleanup;
    if ((result = pam_setcred(pam, PAM_ESTABLISH_CRED)) != PAM_SUCCESS) goto cleanup;
    credentials = 1;
    if ((result = pam_open_session(pam, 0)) != PAM_SUCCESS) goto cleanup;
    session = 1;
    /* Parent stays to close PAM, including on HUP when the terminal is closed.
     * Child returns to normal signal semantics in the same foreground group. */
    int gate[2];
    if (pipe2(gate, O_CLOEXEC)) { result = PAM_SYSTEM_ERR; goto cleanup; }
    pid_t child = fork();
    if (child == -1) { close(gate[0]); close(gate[1]); result = PAM_SYSTEM_ERR; goto cleanup; }
    if (child == 0) {
        close(gate[1]);
        if (setpgid(0, 0)) _exit(126);
        char ready;
        ssize_t received;
        do { received = read(gate[0], &ready, 1); } while (received == -1 && errno == EINTR);
        close(gate[0]);
        if (received != 1) _exit(126);
        if (sigprocmask(SIG_SETMASK, &previous_signals, NULL)) _exit(126);
        if (initgroups(user, group) || setresgid(group, group, group) || setresuid(caller, caller, caller)) _exit(126);
        char **environment = pam_getenvlist(pam);
        if (environment) for (char **entry = environment; *entry; entry++) {
            if (putenv(*entry) != 0) _exit(126);
        }
        if (user_path) set_env("PATH", user_path);
        /* Account identity wins over module-supplied or inherited values. */
        set_env("HOME", home); set_env("USER", user); set_env("LOGNAME", user); set_env("SHELL", shell);
        execv(argv[2], &argv[3]);
        perror("illogical-login: exec");
        _exit(127);
    }
    close(gate[0]);
    (void)signal(SIGTTOU, SIG_IGN);
    (void)signal(SIGPIPE, SIG_IGN);
    if ((setpgid(child, child) != 0 && getpgid(child) != child) || tcsetpgrp(STDIN_FILENO, child) != 0) {
        close(gate[1]);
        kill(child, SIGKILL);
        while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
        result = PAM_SYSTEM_ERR;
        goto cleanup;
    }
    if (write(gate[1], "x", 1) != 1) kill(child, SIGKILL);
    close(gate[1]);
    for (;;) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) break;
        if (waited == -1 && errno == EINTR) continue;
        if (waited == -1) { result = PAM_SYSTEM_ERR; status = 1 << 8; break; }
        int received = 0;
        // Signals remain blocked between the status check and sigwait. A HUP
        // or TERM in this interval cannot get lost while the parent sleeps.
        if (sigwait(&signals, &received)) {
            kill(child, SIGKILL);
            while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
            result = PAM_SYSTEM_ERR;
            break;
        }
        if (received != SIGCHLD) kill(-child, received);
    }

cleanup:
    (void)tcsetpgrp(STDIN_FILENO, getpgrp());
    if (result != PAM_SUCCESS) fprintf(stderr, "illogical-login: %s\n", pam_strerror(pam, result));
    if (session) { int closed = pam_close_session(pam, 0); if (closed != PAM_SUCCESS) fprintf(stderr, "illogical-login: closing PAM session: %s\n", pam_strerror(pam, closed)); }
    if (credentials) (void)pam_setcred(pam, PAM_DELETE_CRED);
    (void)pam_end(pam, result);
    free(terminal); free(user); free(home); free(shell); free(user_path);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
