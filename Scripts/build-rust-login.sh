#!/usr/bin/env bash
# 構建 RustLogin Rust 靜態庫（aarch64-apple-ios，部署目標 15.0）
# 佈局比照 ODATest／Apparition 上游：
#   build/rust-login-out/include/apparition_anisette.h
#   build/rust-login-out/lib/iphoneos/libapparition_anisette.a
# project.yml 以 $(PLATFORM_NAME) 挑 lib 目錄、以 include 目錄找標頭。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export IPHONEOS_DEPLOYMENT_TARGET=15.0

# GitHub macOS images ship rustup; make sure the iOS target is present.
if command -v rustup >/dev/null 2>&1; then
  rustup target add aarch64-apple-ios
fi

cd "$root/RustLogin"
cargo build --release --target aarch64-apple-ios

out="$root/build/rust-login-out"
mkdir -p "$out/include" "$out/lib/iphoneos"
cp include/apparition_anisette.h "$out/include/"
cp target/aarch64-apple-ios/release/libapparition_anisette.a "$out/lib/iphoneos/"
echo "staged -> $out"
