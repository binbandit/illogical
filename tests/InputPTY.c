#include "InputPTY.h"
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static int result_descriptor;
static void received_signal(int value) {
    unsigned char result = (unsigned char)value;
    (void)write(result_descriptor, &result, 1);
    _exit(0);
}

static int read_with_timeout(int descriptor, unsigned char *value) {
    fd_set descriptors;
    FD_ZERO(&descriptors); FD_SET(descriptor, &descriptors);
    struct timeval timeout = { .tv_sec = 2 };
    return select(descriptor + 1, &descriptors, NULL, NULL, &timeout) == 1 &&
        read(descriptor, value, 1) == 1;
}

int il_test_pty_input(const unsigned char *bytes, unsigned long length, int expected_signal) {
    int master, slave, result_pipe[2];
    if (openpty(&master, &slave, NULL, NULL, NULL) || pipe(result_pipe)) return 0;
    pid_t child = fork();
    if (child == 0) {
        close(master); close(result_pipe[0]); result_descriptor = result_pipe[1];
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0) _exit(2);
        if (tcsetpgrp(slave, getpgrp()) < 0) _exit(2);
        struct termios terminal;
        if (tcgetattr(slave, &terminal) < 0) _exit(2);
        terminal.c_lflag |= ISIG | ICANON;
        terminal.c_lflag &= ~(ECHO | ECHONL);
        terminal.c_cc[VINTR] = 3; terminal.c_cc[VEOF] = 4; terminal.c_cc[VSUSP] = 26;
        if (tcsetattr(slave, TCSANOW, &terminal) < 0) _exit(2);
        struct sigaction action = { .sa_handler = received_signal };
        sigemptyset(&action.sa_mask);
        sigaction(SIGINT, &action, NULL); sigaction(SIGTSTP, &action, NULL);
        unsigned char ready = 255;
        (void)write(result_descriptor, &ready, 1);
        unsigned char buffer[256];
        for (;;) {
            ssize_t count = read(slave, buffer, sizeof(buffer));
            if (count == 0) { unsigned char eof = 0; (void)write(result_descriptor, &eof, 1); _exit(0); }
            if (count < 0 && errno != EINTR) _exit(2);
        }
    }
    close(slave); close(result_pipe[1]);
    if (child < 0) { close(master); close(result_pipe[0]); return 0; }
    unsigned char result = 255;
    int passed = read_with_timeout(result_pipe[0], &result) && result == 255;
    if (passed) passed = write(master, bytes, length) == (ssize_t)length &&
        read_with_timeout(result_pipe[0], &result) && result == expected_signal;
    kill(child, SIGKILL); waitpid(child, NULL, 0);
    close(master); close(result_pipe[0]);
    return passed;
}
