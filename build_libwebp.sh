#!/usr/bin/env bash
# build_libwebp.sh
# Builds a universal (armv7 + arm64) static libwebp for iOS 6 on Linux using Theos.
# Usage: ./build_libwebp.sh [path/to/libwebp-source]
set -euo pipefail

# ---------- Locate Theos toolchain and SDK ----------
: "${THEOS:?Set THEOS to your Theos install directory}"

TOOLCHAIN="$THEOS/toolchain/linux/iphone"
BIN="$TOOLCHAIN/bin"
CC="$BIN/clang"
[ -x "$CC" ] || { echo "error: clang not found at $CC"; exit 1; }

find_tool() {
    for t in "$@"; do
        if [ -x "$BIN/$t" ]; then echo "$BIN/$t"; return 0; fi
        if command -v "$t" >/dev/null 2>&1; then command -v "$t"; return 0; fi
    done
    return 1
}
AR=$(find_tool llvm-ar ar) || { echo "error: no ar/llvm-ar found"; exit 1; }
LIPO=$(find_tool lipo llvm-lipo) || { echo "error: no lipo/llvm-lipo found"; exit 1; }

SDK="${SDK:-$THEOS/sdks/iPhoneOS7.1.sdk}"
if [ ! -d "$SDK" ]; then
    SDK=$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | head -n1 || true)
fi
[ -n "${SDK:-}" ] && [ -d "$SDK" ] || { echo "error: no iPhoneOS SDK found in $THEOS/sdks"; exit 1; }
echo "Using SDK:  $SDK"
echo "Using clang: $CC"

# ---------- Get libwebp source ----------
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$PROJECT_DIR/build/libwebp-src}"
if [ ! -f "$SRC/src/webp/decode.h" ]; then
    echo "Cloning libwebp into $SRC ..."
    rm -rf "$SRC"
    git clone --depth 1 https://github.com/webmproject/libwebp.git "$SRC"
fi

# ---------- Decoder sources only (no encoder, no tools) ----------
SOURCES=()
for dir in dec dsp utils; do
    while IFS= read -r f; do SOURCES+=("$f"); done < <(ls "$SRC"/src/$dir/*.c)
done
echo "Compiling ${#SOURCES[@]} source files per architecture"

OUT="$PROJECT_DIR/libwebp"
WORK="$PROJECT_DIR/build/libwebp-obj"
rm -rf "$WORK"
mkdir -p "$OUT/lib" "$OUT/include" "$WORK"

# ---------- Build per architecture ----------
ARCH_TRIPLES=("armv7:armv7-apple-ios7.1" "arm64:arm64-apple-ios7.1")
LIBS=()

for entry in "${ARCH_TRIPLES[@]}"; do
    ARCH="${entry%%:*}"
    TRIPLE="${entry#*:}"
    ODIR="$WORK/$ARCH"
    mkdir -p "$ODIR"
    echo "== Building $ARCH ($TRIPLE)"

    OBJS=()
    for src in "${SOURCES[@]}"; do
        name=$(echo "${src#$SRC/src/}" | tr '/' '_')
        obj="$ODIR/${name%.c}.o"
        "$CC" -target "$TRIPLE" -isysroot "$SDK" -miphoneos-version-min=7.1 \
            -O2 -fPIC -DNDEBUG \
            -I"$SRC" -I"$SRC/src" \
            -c "$src" -o "$obj"
        OBJS+=("$obj")
    done

    LIB="$WORK/libwebp-$ARCH.a"
    rm -f "$LIB"
    "$AR" rcs "$LIB" "${OBJS[@]}"
    LIBS+=("$LIB")
done

# ---------- Combine into a universal library ----------
"$LIPO" -create "${LIBS[@]}" -output "$OUT/lib/libwebp.a"

# ---------- Install headers ----------
rm -rf "$OUT/include/webp"
cp -R "$SRC/src/webp" "$OUT/include/"

echo
echo "Done."
echo "  Library: $OUT/lib/libwebp.a"
echo "  Headers: $OUT/include/webp/"
"$LIPO" -info "$OUT/lib/libwebp.a"
