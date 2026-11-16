#!/bin/bash
# Prints the version of Bee: the first one listed in CHANGELOG.md ("## 1.2.0 — 2026-01-31").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -nE 's/^## \[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*$/\1/p' "$ROOT/CHANGELOG.md" | head -n 1)"
[ -n "$VERSION" ] || { echo "No version heading (## 1.2.3) in CHANGELOG.md" >&2; exit 1; }
echo "$VERSION"
