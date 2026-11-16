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
VERSION="1.0.0"

cd "$ROOT"
swift build -c "$CONFIG" --arch arm64 --product Bee 2>&1 | grep -v "search path" || true
BINARY="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Bee"
[ -x "$BINARY" ] || { echo "Build failed: $BINARY not found" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Bee"
[ -f "$ROOT/Resources/Bee.icns" ] && cp "$ROOT/Resources/Bee.icns" "$APP/Contents/Resources/Bee.icns"

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
    <key>NSLocalNetworkUsageDescription</key>
    <string>Bee sends the requests you compose to servers on your local network.</string>
    <key>NSHumanReadableCopyright</key><string>Bee</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: no developer identity is required to run locally.
codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --strict "$APP"

echo "Built $APP ($CONFIG)"
if $OPEN_AFTER; then open "$APP"; fi
