#include "ResourceConnectionFixture.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int il_resource_listen(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX, .sun_len = sizeof(address)};
    if (fd < 0 || strlen(path) >= sizeof(address.sun_path)) return -1;
    strcpy(address.sun_path, path);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || listen(fd, 4)) {
        close(fd); return -1;
    }
    return fd;
}

void il_resource_serve_retries(int listener) {
    for (int attempt = 1; attempt <= 5; attempt++) {
        int peer = accept(listener, NULL, NULL);
        if (peer < 0) break;
        if (attempt == 3) {
            const char *hello = "{\"type\":\"hello\",\"protocol\":1,\"engine\":\"ghostty-27e8b3fa85d9\"}\n";
            int enabled = 1;
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
            (void)write(peer, hello, strlen(hello));
        }
        close(peer);
    }
    close(listener);
}

void il_resource_serve_workspace(int listener) {
    int peer = accept(listener, NULL, NULL);
    close(listener);
    if (peer < 0) return;
    int enabled = 1;
    setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    const char *initial = "{\"type\":\"hello\",\"protocol\":1,\"engine\":\"ghostty-27e8b3fa85d9\"}\n"
        "{\"type\":\"state\",\"state\":{\"revision\":1,\"sessions\":[{\"id\":\"s\",\"name\":\"fixture\",\"windows\":[{\"id\":\"w\",\"name\":\"fixture\",\"root\":{\"id\":\"r\",\"block\":\"gone\"}}]}],\"blocks\":[{\"id\":\"gone\",\"title\":\"fixture\",\"cwd\":\"/tmp\",\"pid\":1,\"cols\":80,\"rows\":24,\"parked\":false,\"keepOpen\":true,\"command\":[\"fixture\"]}],\"clients\":1}}\n";
    (void)write(peer, initial, strlen(initial));
    FILE *input = fdopen(peer, "r");
    if (!input) { close(peer); return; }
    char *line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, input) > 0) {
        if (strstr(line, "block.viewport")) {
            const char *unsupported = "{\"type\":\"reply\",\"error\":\"unknown method block.viewport\"}\n";
            (void)write(peer, unsupported, strlen(unsupported));
        }
        if (strstr(line, "test.compatibility")) {
            const char *barrier = "{\"id\":\"compatibility\",\"type\":\"reply\"}\n";
            (void)write(peer, barrier, strlen(barrier));
        }
        if (!strstr(line, "test.drop")) continue;
        const char *removed = "{\"type\":\"state\",\"state\":{\"revision\":2,\"sessions\":[],\"blocks\":[],\"clients\":1}}\n";
        (void)write(peer, removed, strlen(removed));
    }
    free(line); fclose(input);
}
