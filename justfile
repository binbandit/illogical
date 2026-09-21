default:
    @just --list

# Build the native Release app and bundled service.
build:
    CONFIGURATION=Release ./scripts/build.sh

# Run the maintained terminal, service, rendering, and resource checks.
test:
    ./scripts/test.sh

# Build and run the native Debug app in the foreground.
dev:
    CONFIGURATION=Debug ./scripts/build.sh
    ./.build/xcode/Build/Products/Debug/illogical.app/Contents/MacOS/illogical

# Install the Release app and CLI without interrupting terminal processes.
install:
    ./scripts/install.sh

# Build the Release app and write the downloadable archives to .build/release.
package:
    CONFIGURATION=Release ./scripts/build.sh
    ./scripts/package-macos.sh
