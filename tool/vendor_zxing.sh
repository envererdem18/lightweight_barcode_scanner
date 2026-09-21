#!/usr/bin/env bash
#
# Vendors a minimal subset of ZXing-C++ into third_party/zxing-cpp.
#
# Why a script instead of a git submodule:
#   * the package must build with CocoaPods (iOS) and CMake (Android) from the
#     same source tree, and CocoaPods cannot run CMake to select source files;
#   * we only want the *reader* code for QR + 1D, which is roughly a third of
#     upstream. Pruning on disk keeps the published package (and every consumer
#     checkout) small and makes the podspec a plain glob.
#
# The exact file list is not hand-maintained: we configure upstream's own CMake
# with our feature flags and ask the ZXing target which sources it would build.
#
# Usage: tool/vendor_zxing.sh [tag]
set -euo pipefail

ZXING_TAG="${1:-v3.1.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/third_party/zxing-cpp"

CMAKE_BIN="${CMAKE:-$(command -v cmake || true)}"
if [ -z "$CMAKE_BIN" ]; then
  CMAKE_BIN="$(ls -d "$HOME"/Library/Android/sdk/cmake/*/bin/cmake 2>/dev/null | tail -1 || true)"
fi
if [ -z "$CMAKE_BIN" ]; then
  echo "error: cmake not found (set \$CMAKE)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> cloning zxing-cpp $ZXING_TAG"
git clone --quiet --depth 1 --branch "$ZXING_TAG" https://github.com/zxing-cpp/zxing-cpp.git "$WORK/src"
COMMIT="$(git -C "$WORK/src" rev-parse HEAD)"

# Ask upstream's CMake for the resolved source list of the configuration we ship.
cat >> "$WORK/src/core/CMakeLists.txt" <<'EOF'

# --- appended by lightweight_barcode_scanner/tool/vendor_zxing.sh ---
get_target_property(_LBS_SRCS ZXing SOURCES)
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/lbs_sources.txt" CONTENT "$<JOIN:${_LBS_SRCS},\n>\n")
EOF

echo "==> configuring (readers only, QR + 1D)"
"$CMAKE_BIN" -S "$WORK/src/core" -B "$WORK/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DZXING_READERS=ON \
  -DZXING_WRITERS=OFF \
  -DZXING_C_API=OFF \
  -DZXING_EXPERIMENTAL_API=OFF \
  -DZXING_ENABLE_1D=ON \
  -DZXING_ENABLE_QRCODE=ON \
  -DZXING_ENABLE_AZTEC=OFF \
  -DZXING_ENABLE_DATAMATRIX=OFF \
  -DZXING_ENABLE_MAXICODE=OFF \
  -DZXING_ENABLE_PDF417=OFF > "$WORK/configure.log" 2>&1 || { cat "$WORK/configure.log"; exit 1; }

echo "==> copying sources"
rm -rf "$DEST"
mkdir -p "$DEST/core/src" "$DEST/core/generated"

# 1. the translation units upstream selected for our flags.
count=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    /*) rel="${f#"$WORK/src/core/"}" ;;
    *)  rel="$f" ;;
  esac
  [ -f "$WORK/src/core/$rel" ] || { echo "warn: missing $rel" >&2; continue; }
  mkdir -p "$DEST/core/$(dirname "$rel")"
  cp "$WORK/src/core/$rel" "$DEST/core/$rel"
  count=$((count + 1))
done < "$WORK/build/lbs_sources.txt"

# 2. every header except the disabled symbologies and the (writer-only) zint
#    bundle. Sources that are compiled out of the build still #include headers
#    of features they guard at runtime, so headers cannot be pruned per file.
#    They cost nothing in the binary.
headers=0
while IFS= read -r rel; do
  mkdir -p "$DEST/core/$(dirname "$rel")"
  if [ ! -f "$DEST/core/$rel" ]; then
    cp "$WORK/src/core/$rel" "$DEST/core/$rel"
    headers=$((headers + 1))
  fi
done < <(cd "$WORK/src/core" && find src -type f \( -name '*.h' -o -name '*.hpp' \) \
  -not -path 'src/aztec/*' -not -path 'src/datamatrix/*' \
  -not -path 'src/maxicode/*' -not -path 'src/pdf417/*' \
  -not -path 'src/libzint/*' | sort)
count=$((count + headers))

# Version.h is normally generated into the build tree. We ship it pre-generated
# so that CocoaPods (which never runs CMake) sees the same feature flags.
cp "$WORK/build/Version.h" "$DEST/core/generated/Version.h"
cp "$WORK/src/LICENSE" "$DEST/LICENSE"

cat > "$DEST/VENDORING.md" <<EOF
# Vendored ZXing-C++

    upstream : https://github.com/zxing-cpp/zxing-cpp
    tag      : $ZXING_TAG
    commit   : $COMMIT
    files    : $count
    license  : Apache-2.0 (see LICENSE)

Configuration baked into \`core/generated/Version.h\`:

    ZXING_READERS            ON
    ZXING_WRITERS            OFF
    ZXING_C_API              OFF
    ZXING_EXPERIMENTAL_API   OFF
    ZXING_ENABLE_1D          ON
    ZXING_ENABLE_QRCODE      ON
    ZXING_ENABLE_AZTEC       OFF
    ZXING_ENABLE_DATAMATRIX  OFF
    ZXING_ENABLE_MAXICODE    OFF
    ZXING_ENABLE_PDF417      OFF

Do not edit these files by hand. Re-run \`tool/vendor_zxing.sh [tag]\` instead.
EOF

"$ROOT/tool/generate_ios_sources.sh"

echo "==> vendored $count files into third_party/zxing-cpp ($ZXING_TAG)"
