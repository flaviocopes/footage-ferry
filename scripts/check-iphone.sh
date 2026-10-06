#!/bin/sh
# Runs scripts/check-iphone.swift against the iPhone plugged in over USB. It compiles the app's
# sources with the check in place of the @main file. Pass a clip name to read that clip instead
# of the smallest, and --write to also test writing and deleting a scratch file in Blackmagic
# Cam's Documents.
# Usage: scripts/check-iphone.sh [clip name] [--write]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
MACOS=$(sed -n 's/^ *macOS: *"\(.*\)"$/\1/p' project.yml | head -1)
mkdir -p build/check
find BlackmagicCamImporter -name '*.swift' ! -exec grep -q '^@main' {} \; -exec \
  swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos$MACOS" \
  -o build/check/check-iphone scripts/check-iphone.swift {} +
build/check/check-iphone "$@"
