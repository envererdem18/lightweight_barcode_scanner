#!/usr/bin/env bash
# Builds and runs the host tests for the shared C++ decoder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${LBS_BUILD_DIR:-$ROOT/build/native-test}"

CMAKE_BIN="${CMAKE:-$(command -v cmake || true)}"
if [ -z "$CMAKE_BIN" ]; then
  CMAKE_BIN="$(ls -d "$HOME"/Library/Android/sdk/cmake/*/bin/cmake 2>/dev/null | tail -1 || true)"
fi
if [ -z "$CMAKE_BIN" ]; then
  echo "error: cmake not found (set \$CMAKE)" >&2
  exit 1
fi

"$CMAKE_BIN" -S "$ROOT/test/native" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release "$@"
"$CMAKE_BIN" --build "$BUILD" --parallel
"$BUILD/lbs_decoder_test"
