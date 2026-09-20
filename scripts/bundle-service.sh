#!/bin/sh
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$SRCROOT/service"
export PKG_CONFIG_PATH="$SRCROOT/.build/ghostty/share/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
export CGO_CFLAGS="${CGO_CFLAGS:--O2 -g} -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O2 -g} -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CGO_LDFLAGS="${CGO_LDFLAGS:--O2 -g} -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin"
go build -trimpath -o "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin/illogical" ./cmd/illogical
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin/illogical"
fi
