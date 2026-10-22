#!/usr/bin/env bash
set -euo pipefail

# Build only the device slice used by EiliStore's generic/platform=iOS archive.
# No device access, Apple account, provisioning, or code signing is performed.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REV=3e55c8486b2057e40c1f74aaaa1155c82341cf76
TOOLCHAIN=1.94.0
TARGET=aarch64-apple-ios
[[ "$(uname -s)" == Darwin ]] || { echo 'ERROR: macOS/Xcode required' >&2; exit 2; }
for tool in git xcrun xcodebuild rustup python3 cmake; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eilistore-idevice-ios15.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/source"
git init -q "$SRC"
git -C "$SRC" remote add origin https://github.com/SideStore/idevice.git
git -C "$SRC" fetch --depth 1 origin "$REV"
git -C "$SRC" checkout --detach FETCH_HEAD
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$REV" ]] || exit 1
rustup toolchain install "$TOOLCHAIN" --profile minimal --target "$TARGET"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC_aarch64_apple_ios="$(xcrun --sdk iphoneos --find clang)"
export CXX_aarch64_apple_ios="$(xcrun --sdk iphoneos --find clang++)"
export AR_aarch64_apple_ios="$(xcrun --sdk iphoneos --find ar)"
export CFLAGS_aarch64_apple_ios='-miphoneos-version-min=15.0'
export CXXFLAGS_aarch64_apple_ios='-miphoneos-version-min=15.0'
export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SDKROOT -miphoneos-version-min=15.0"
# Fresh isolated output prevents reusing iOS 17 C/Rust objects from a cache.
export CARGO_TARGET_DIR="$WORK/target"
(
  cd "$SRC"
  rustup run "$TOOLCHAIN" cargo build --locked --release -p idevice-ffi \
    --target "$TARGET" --features obfuscate
)
LIB="$CARGO_TARGET_DIR/$TARGET/release/libidevice_ffi.a"
python3 "$ROOT/Scripts/audit-ios-archive.py" "$LIB"
# ffi/build.rs explicitly writes the generated C API to this location.
test -s "$SRC/cpp/include/idevice.h"
cp "$SRC/cpp/include/idevice.h" "$SRC/swift/include/idevice.h"
xcodebuild -create-xcframework -library "$LIB" -headers "$SRC/swift/include" \
  -output "$WORK/IDeviceFFI.xcframework"
# Do not replace a usable framework until build, audit, and packaging succeed.
mkdir -p "$ROOT/Libraries"
OUT="$ROOT/Libraries/IDeviceFFI.xcframework"
BACKUP="$ROOT/Libraries/.IDeviceFFI.previous-$$"
if [[ -e "$OUT" ]]; then mv "$OUT" "$BACKUP"; fi
if mv "$WORK/IDeviceFFI.xcframework" "$OUT"; then
  rm -rf "$BACKUP"
else
  [[ ! -e "$OUT" && -e "$BACKUP" ]] && mv "$BACKUP" "$OUT"
  exit 1
fi
echo "Built and metadata-audited IDevice $REV for iOS 15 (device arm64 only)."
echo 'Runtime availability and iOS 15 device behavior still require separate testing.'
