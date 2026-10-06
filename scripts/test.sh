#!/bin/sh
# Runs scripts/test.swift against the importer and the app model, with made-up iPhone files.
# It compiles the app's sources with the test in place of the @main file, and only writes to a
# temporary folder. No iPhone needed: scripts/check-iphone.sh is the one that talks to the phone.
# Usage: scripts/test.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
MACOS=$(sed -n 's/^ *macOS: *"\(.*\)"$/\1/p' project.yml | head -1)
mkdir -p build/test
find BlackmagicCamImporter -name '*.swift' ! -exec grep -q '^@main' {} \; -exec \
  swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos$MACOS" \
  -o build/test/test scripts/test.swift {} +
build/test/test
