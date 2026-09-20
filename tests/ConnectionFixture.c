#include "ConnectionFixture.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <unistd.h>

int il_test_listen(const char *path) {
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX; address.sun_len = sizeof(address);
    if (strlen(path) >= sizeof(address.sun_path)) { close(descriptor); return -1; }
    strcpy(address.sun_path, path);
    if (bind(descriptor, (struct sockaddr *)&address, sizeof(address)) || listen(descriptor, 1)) {
        close(descriptor); return -1;
    }
    return descriptor;
}

void il_test_serve_handshake(int listener) {
    int peer = accept(listener, NULL, NULL);
    close(listener);
    if (peer < 0) return;
    int enabled = 1; setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    const char *hello = "{\"type\":\"hello\",\"protocol\":1,\"engine\":\"ghostty-27e8b3fa85d9\",\"client\":\"handshake-test\"}\n";
    (void)write(peer, hello, strlen(hello));
    // Neither the hello nor its reply fills the native reader's buffer. The
    // socket stays open throughout, just like the actual multiplexing daemon.
    char request[4096];
    if (read(peer, request, sizeof(request)) > 0) {
        const char *reply = "{\"type\":\"state\"}\n";
        (void)write(peer, reply, strlen(reply));
        while (read(peer, request, sizeof(request)) > 0) { }
    }
    close(peer);
}
