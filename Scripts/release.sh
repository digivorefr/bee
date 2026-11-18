#!/bin/bash
# Packages Bee for download: builds the release application, zips it with the license and writes
# the release notes from CHANGELOG.md. With --publish, also creates the GitHub release.
# Usage: Scripts/release.sh [--publish] [--unsigned]
#   --unsigned  publish without the update signature: copies of Bee will not install this release
#               by themselves, and this version will never install an update by itself either.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH=false
UNSIGNED=false
for argument in "$@"; do
    case "$argument" in
        --publish) PUBLISH=true ;;
        --unsigned) UNSIGNED=true ;;
        *) echo "Unknown option: $argument" >&2; exit 2 ;;
    esac
done
fail() { echo "$1" >&2; exit 1; }

cd "$ROOT"
VERSION="$(Scripts/version.sh)"
TAG="v$VERSION"
NAME="Bee-$VERSION"
STAGE="$ROOT/dist/release"
ZIP="$ROOT/dist/$NAME.zip"
NOTES="$ROOT/dist/$NAME-notes.md"
KEY="$ROOT/Resources/update-key.txt"

if ! $UNSIGNED && [ ! -f "$KEY" ]; then
    $PUBLISH && fail "No release key (Resources/update-key.txt). Create it with: swift Scripts/update-key.swift generate
A release published without it cannot be installed by Bee itself; pass --unsigned to publish anyway."
fi

if $PUBLISH; then
    # A release is cut from what is on GitHub, nothing else.
    [ -z "$(git status --porcelain)" ] || fail "Commit your changes before publishing."
    git fetch --quiet origin
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "Push main before publishing."
    if gh release view "$TAG" >/dev/null 2>&1; then
        fail "Release $TAG already exists. Add a new version at the top of CHANGELOG.md."
    fi
fi

Scripts/build-app.sh --out "$STAGE/$NAME"
cp "$ROOT/LICENSE.md" "$STAGE/$NAME/LICENSE.md"

# ditto keeps the bundle as signed; the archive opens as one folder. Extended attributes are left
# out: the signature does not need them and they would travel as hidden files.
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$STAGE/$NAME" "$ZIP"

# What a person downloads must still be a valid application.
CHECK="$(mktemp -d)"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --strict "$CHECK/$NAME/Bee.app" || fail "The packaged application does not verify."
[ -f "$CHECK/$NAME/LICENSE.md" ] || fail "The license is missing from the archive."
if ! $UNSIGNED && [ -f "$KEY" ]; then
    # The packaged application must carry the key it will check the next update with.
    cmp -s "$KEY" "$CHECK/$NAME/Bee.app/Contents/Resources/update-key.txt" \
        || fail "The packaged application does not carry Resources/update-key.txt."
fi
rm -rf "$CHECK" "$STAGE"

SUM="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"

# Signed with the release key, the archive can be installed by Bee itself (Check for Updates).
# The Keychain asks before the key is used.
ASSETS=("$ZIP")
rm -f "$ZIP.sig"
if ! $UNSIGNED && [ -f "$KEY" ]; then
    SIGNATURE="$ZIP.sig"
    swift Scripts/update-key.swift sign "$ZIP" > "$SIGNATURE" || fail "The archive could not be signed."
    swift Scripts/update-key.swift verify "$ZIP" "$SIGNATURE" "$KEY" \
        || fail "The signature does not match Resources/update-key.txt."
    ASSETS+=("$SIGNATURE")
    echo "Signed   $SIGNATURE"
else
    echo "Not signed: Bee will not install this release by itself."
fi

# The notes are the section of this version in CHANGELOG.md, then how to install.
awk '/^## /{ if (seen) exit; seen = 1; next } seen' CHANGELOG.md | sed -e '/./,$!d' > "$NOTES"
[ -s "$NOTES" ] || fail "CHANGELOG.md has nothing under version $VERSION."
cat >> "$NOTES" <<NOTES

### Install

Bee needs a Mac with Apple silicon and macOS 26 or later.

1. Download \`$NAME.zip\`, open it, and move **Bee** to your Applications folder.
2. Open Bee. It is not notarized by Apple yet, so macOS refuses the first time: open **System Settings › Privacy & Security**, scroll down to **Security** and click **Open Anyway**. This is asked once per version.

SHA-256 of \`$NAME.zip\`: \`$SUM\`
NOTES

echo "Packaged $ZIP"
echo "Notes    $NOTES"

if $PUBLISH; then
    gh release create "$TAG" "${ASSETS[@]}" --target "$(git rev-parse HEAD)" --title "Bee $VERSION" --notes-file "$NOTES"
else
    echo "Publish with: Scripts/release.sh --publish"
fi
