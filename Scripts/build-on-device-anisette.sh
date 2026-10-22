#!/usr/bin/env bash
set -euo pipefail

# Run on macOS with Xcode command-line tools, CMake, and Git installed.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="${EILI_UNICORN_PACKAGE:-$ROOT/Packages/AnisetteKit}"
WORK="${TMPDIR:-/tmp}/eilistore-unicorn-a53ddc9a"
SRC="$WORK/src"
BUILD="$WORK/build-ios-arm64"
OUT="$PACKAGE/Artifacts/Unicorn.xcframework"
STAGE="$PACKAGE/.Unicorn.xcframework-stage-$$"
REPO="https://github.com/mahee96/unicorn.git"
REV="a53ddc9ac6d65b24936d4a37917333fcd816cfd0"

if [[ "$(uname -s)" != Darwin ]]; then echo "ERROR: this builder requires macOS/Xcode; no download/build attempted." >&2; exit 2; fi
for tool in git cmake xcrun xcodebuild python3; do command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }; done
export IPHONEOS_DEPLOYMENT_TARGET=15.0
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
CXX="$(xcrun --sdk iphoneos --find clang++)"

mkdir -p "$WORK"
if [[ ! -d "$SRC/.git" ]]; then git clone --no-checkout "$REPO" "$SRC"; fi
git -C "$SRC" fetch --depth 1 origin "$REV"
git -C "$SRC" checkout --detach "$REV"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$REV" ]] || { echo "Pinned Unicorn revision mismatch" >&2; exit 1; }

# armv8-a is the conservative A7 baseline. TCI is mandatory: never emit native
# JIT code for iOS. Audit actual machine code as compiler flags are not proof.
rm -rf "$BUILD" "$STAGE"
mkdir -p "$PACKAGE" "$STAGE"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS='-arch arm64 -march=armv8-a -mno-outline-atomics -miphoneos-version-min=15.0' \
  -DCMAKE_CXX_FLAGS='-arch arm64 -march=armv8-a -mno-outline-atomics -miphoneos-version-min=15.0' \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DUNICORN_ARCH=aarch64 -DUNICORN_ENABLE_TCI=ON -DUNICORN_LOGGING=OFF \
  -DBUILD_SHARED_LIBS=OFF -DUNICORN_LEGACY_STATIC_ARCHIVE=ON \
  -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF
# Match the upstream non-macOS workaround: remove this generated host capability.
CONFIG="$BUILD/config-host.h"
if [[ -f "$CONFIG" ]]; then
  sed -i '' 's/#define HAVE_PTHREAD_JIT_PROTECT 1/\/* HAVE_PTHREAD_JIT_PROTECT removed for non-macOS target *\//' "$CONFIG"
fi
cmake --build "$BUILD" --config Release --target unicorn_archive -j "$(sysctl -n hw.ncpu)"
LIB="$(find "$BUILD" -type f -name 'libunicorn.a' -print -quit)"
[[ -n "$LIB" ]] || { echo "Could not locate built Unicorn static archive" >&2; exit 1; }
HEADERS="$SRC/include"

python3 "$ROOT/Scripts/audit-ios-archive.py" "$LIB"

# Decode archives as Mach-O ARM64 with LSE enabled so LSE words are not left
# looking like unknown instructions. Fail closed on tool errors or empty decode.
DIS="$(xcrun --find llvm-objdump)"
AUDIT="$STAGE/unicorn-disassembly.txt"
if ! "$DIS" --arch-name=aarch64 --mattr=+lse --disassemble --no-show-raw-insn "$LIB" >"$AUDIT" 2>&1; then
  echo "ERROR: llvm-objdump could not disassemble archive; refusing to package. See $AUDIT" >&2
  exit 1
fi
# Require decoded instruction records (address and mnemonic), not merely
# archive/member headers or a successful-but-empty disassembler invocation.
if ! grep -Eq '^[[:space:]]*[[:xdigit:]]+:[[:space:]]+[[:alpha:]][[:alnum:].]*([[:space:]]|$)' "$AUDIT"; then
  echo "ERROR: no decoded machine instructions found in archive; refusing to package. See $AUDIT" >&2
  exit 1
fi
if grep -Eiq '(^|[[:space:]])(cas[a-z0-9]*|swp[a-z0-9]*|ld(add|clr|eor|set|smax|smin|umax|umin)[a-z0-9]*|st(add|clr|eor|set)[a-z0-9]*)[[:space:]]' "$AUDIT"; then
  echo "ERROR: direct ARM LSE instruction detected in built archive; refusing to package. See $AUDIT" >&2
  grep -Ein '(^|[[:space:]])(cas[a-z0-9]*|swp[a-z0-9]*|ld(add|clr|eor|set|smax|smin|umax|umin)[a-z0-9]*|st(add|clr|eor|set)[a-z0-9]*)[[:space:]]' "$AUDIT" >&2 || true
  exit 1
fi

# Build and audit in a separate location. Preserve any currently valid output
# until xcframework creation succeeds, then swap it into place.
STAGED_XCFRAMEWORK="$STAGE/Unicorn.xcframework"
xcodebuild -create-xcframework -library "$LIB" -headers "$HEADERS" -output "$STAGED_XCFRAMEWORK"
[[ -d "$STAGED_XCFRAMEWORK" ]] || { echo "ERROR: staged XCFramework was not created" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
BACKUP="$PACKAGE/.Unicorn.xcframework-previous-$$"
if [[ -e "$OUT" ]]; then mv "$OUT" "$BACKUP"; fi
if mv "$STAGED_XCFRAMEWORK" "$OUT"; then
  rm -rf "$BACKUP"
else
  [[ ! -e "$OUT" && -e "$BACKUP" ]] && mv "$BACKUP" "$OUT"
  echo "ERROR: could not install audited XCFramework; previous output restored if present" >&2
  exit 1
fi
echo "Created and audited $OUT"
