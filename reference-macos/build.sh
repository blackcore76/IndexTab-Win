#!/bin/bash
set -e

APP_NAME="IndexTab"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"

DEPLOY_TARGET="11"

rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS}"

cp Resources/Info.plist "${CONTENTS}/"

mkdir -p "${CONTENTS}/Resources"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${CONTENTS}/Resources/"
fi

# 번들 폰트 (영문 세로 표기용 Noto Sans Display Italic, OFL 라이선스)
if [ -f "Resources/NotoSansDisplay-Italic.ttf" ]; then
    cp Resources/NotoSansDisplay-Italic.ttf "${CONTENTS}/Resources/"
fi
if [ -f "Resources/NotoSansDisplay-OFL.txt" ]; then
    cp Resources/NotoSansDisplay-OFL.txt "${CONTENTS}/Resources/"
fi

SOURCES="Sources/main.swift Sources/AppDelegate.swift Sources/WindowTracker.swift Sources/IndexBar.swift Sources/WindowActivator.swift Sources/Settings.swift Sources/PrivateAPIs.swift"

# Apple Silicon (arm64) slice
swiftc \
    -o "${BUILD_DIR}/${APP_NAME}-arm64" \
    -framework Cocoa \
    -framework ApplicationServices \
    -target arm64-apple-macos${DEPLOY_TARGET} \
    -O \
    ${SOURCES}

# Intel (x86_64) slice
swiftc \
    -o "${BUILD_DIR}/${APP_NAME}-x86_64" \
    -framework Cocoa \
    -framework ApplicationServices \
    -target x86_64-apple-macos${DEPLOY_TARGET} \
    -O \
    ${SOURCES}

# Combine into a universal binary
lipo -create \
    "${BUILD_DIR}/${APP_NAME}-arm64" \
    "${BUILD_DIR}/${APP_NAME}-x86_64" \
    -output "${MACOS}/${APP_NAME}"

rm -f "${BUILD_DIR}/${APP_NAME}-arm64" "${BUILD_DIR}/${APP_NAME}-x86_64"

codesign --force --sign "IndexTab Dev" "${APP_BUNDLE}"

echo "Build complete: ${APP_BUNDLE}"
lipo -info "${MACOS}/${APP_NAME}"
