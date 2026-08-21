#!/bin/sh
set -eu

PLUGIN_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$PLUGIN_ROOT/native/build"
OUTPUT="$BUILD_DIR/reminders-helper"
CACHE_DIR="$BUILD_DIR/module-cache"

mkdir -p "$BUILD_DIR" "$CACHE_DIR"

CLANG_MODULE_CACHE_PATH="$CACHE_DIR" xcrun clang \
  -fobjc-arc \
  -fblocks \
  -Wall \
  -Wextra \
  -mmacosx-version-min=14.0 \
  -O \
  "$PLUGIN_ROOT/native/RemindersHelper.m" \
  -framework AppKit \
  -framework CoreLocation \
  -framework Foundation \
  -framework EventKit \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "$PLUGIN_ROOT/native/Info.plist" \
  -o "$OUTPUT"

codesign --force --sign - \
  --identifier com.jm.codex.apple-reminders-helper \
  "$OUTPUT"

echo "Built $OUTPUT"
