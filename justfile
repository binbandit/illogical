default:
    @just --list

# Build the native Release app and bundled service.
build:
    CONFIGURATION=Release ./scripts/build.sh

# Run the maintained terminal, service, rendering, and resource checks.
test:
    ./scripts/test.sh

# Install the Release app and CLI without interrupting terminal processes.
install:
    ./scripts/install.sh
