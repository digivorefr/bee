#!/bin/bash
# Builds dist/Bee.app from the Swift package (no Xcode required, Command Line Tools only).
# Usage: Scripts/build-app.sh [--debug] [--open] [--out <directory>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="release"
OPEN_AFTER=false
OUT="$ROOT/dist"
while [ $# -gt 0 ]; do
    case "$1" in
        --debug) CONFIG="debug" ;;
        --open) OPEN_AFTER=true ;;
        --out) shift; [ $# -gt 0 ] || { echo "--out needs a directory" >&2; exit 2; }; OUT="$1" ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

APP="$OUT/Bee.app"
# The version is the first one listed in CHANGELOG.md.
VERSION="$("$ROOT/Scripts/version.sh")"

cd "$ROOT"
# A failed build stops here: the binary of an earlier build must never be packaged under a new version.
if ! BUILD_LOG="$(swift build -c "$CONFIG" --arch arm64 --product Bee 2>&1 && swift build -c "$CONFIG" --arch arm64 --product bee-mcp 2>&1)"; then
    echo "$BUILD_LOG" | grep -v "search path" >&2 || true
    echo "Build failed" >&2
    exit 1
fi
echo "$BUILD_LOG" | grep -v "search path" || true
BINARY="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Bee"
[ -x "$BINARY" ] || { echo "Build failed: $BINARY not found" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Bee"
# The relay AI agents start to reach Bee (MCP).
RELAY="$(dirname "$BINARY")/bee-mcp"
[ -x "$RELAY" ] || { echo "Build failed: $RELAY not found" >&2; exit 1; }
cp "$RELAY" "$APP/Contents/MacOS/bee-mcp"
[ -f "$ROOT/Resources/Bee.icns" ] && cp "$ROOT/Resources/Bee.icns" "$APP/Contents/Resources/Bee.icns"
# Shown in the application under Help > What's New in Bee.
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"
# The public half of the key releases are signed with: what lets Bee install an update by itself.
if [ -f "$ROOT/Resources/update-key.txt" ]; then
    cp "$ROOT/Resources/update-key.txt" "$APP/Contents/Resources/update-key.txt"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Bee</string>
    <key>CFBundleIconFile</key><string>Bee</string>
    <key>CFBundleIdentifier</key><string>com.digivore.bee</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Bee</string>
    <key>CFBundleDisplayName</key><string>Bee</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- An API client must reach plain-HTTP and self-signed development servers. -->
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Bee keeps a file for each of your collections in Documents/Bee, so you can share them.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Bee sends the requests you compose to servers on your local network.</string>
    <key>NSHumanReadableCopyright</key><string>Copyright 2026 Pierre Bonnin. PolyForm Noncommercial License 1.0.0.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: no developer identity is required to run locally.
codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --strict "$APP"

echo "Built $APP ($CONFIG, version $VERSION)"
if $OPEN_AFTER; then open "$APP"; fi
