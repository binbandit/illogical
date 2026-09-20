#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void record(const char *text) {
    int file = open(getenv("ILLOGICAL_CONNECTION_TEST_LOG"), O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (file >= 0) { (void)write(file, text, strlen(text)); close(file); }
}

static void serve(int input, int output, const char *transport) {
    char hello[256];
    int length = snprintf(hello, sizeof(hello), "{\"type\":\"hello\",\"protocol\":1,\"engine\":\"ghostty-27e8b3fa85d9\",\"client\":\"%s\"}\n", transport);
    (void)write(output, hello, (size_t)length);
    char line[4096]; size_t used = 0;
    while (used < sizeof(line) - 1 && read(input, line + used, 1) == 1) {
        if (line[used++] != '\n') continue;
        line[used] = 0;
        char *id = strstr(line, "\"id\":\"");
        if (!id) { record(line); break; }
        id += strlen("\"id\":\""); char *end = strchr(id, '"');
        if (!end) break;
        *end = 0;
        char entry[128];
        snprintf(entry, sizeof(entry), "%s:%s\n", transport, strstr(end + 1, "\"early\"") || strstr(line, "\"early\"") ? "early" : "watch");
        record(entry);
        char reply[512];
        length = snprintf(reply, sizeof(reply), "{\"type\":\"state\",\"id\":\"%s\",\"client\":\"%s\"}\n", id, transport);
        (void)write(output, reply, (size_t)length);
        used = 0;
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    const char *path = getenv("ILLOGICAL_SOCKET");
    const char *mode = getenv("ILLOGICAL_CONNECTION_TEST_MODE");
    if (!path || !mode) { fprintf(stderr, "fixture environment missing\n"); return 2; }
    if (strcmp(mode, "unavailable") != 0) {
        int listener = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX; address.sun_len = sizeof(address);
        if (strlen(path) >= sizeof(address.sun_path)) return 3;
        strcpy(address.sun_path, path);
        if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 1)) { perror("fixture socket"); return 4; }
        int ready[2];
        if (pipe(ready) != 0) return 5;
        pid_t child = fork();
        if (child == 0) {
            // The bootstrap process may exit as soon as the real socket opens.
            close(ready[0]);
            (void)setsid();
            close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
            (void)write(ready[1], "1", 1); close(ready[1]);
            struct pollfd ready = {.fd = listener, .events = POLLIN};
            if (poll(&ready, 1, 5000) > 0) {
                int peer = accept(listener, NULL, NULL);
                close(listener);
                if (peer >= 0) { serve(peer, peer, "direct"); close(peer); }
            }
            _exit(0);
        }
        close(listener);
        close(ready[1]);
        if (child < 0) { close(ready[0]); return 6; }
        char started;
        if (read(ready[0], &started, 1) != 1) { close(ready[0]); return 7; }
        close(ready[0]);
        char entry[64]; snprintf(entry, sizeof(entry), "daemon:%d\n", child); record(entry);
    }
    serve(STDIN_FILENO, STDOUT_FILENO, "helper");
    return 0;
}
