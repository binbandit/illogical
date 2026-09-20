#include "Bridge.h"

// Opens a private real PTY and observes the child's signal/EOF, never the user's shell.
int il_test_pty_input(const unsigned char *bytes, unsigned long length, int expected_signal);
