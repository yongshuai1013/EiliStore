#!/usr/bin/env bash
set -euo pipefail
# Builds the same pinned TCI interpreter as production, for this host only.
# Executes only self-authored synthetic ARM64 instructions and temporary dummy data.
# Never downloads, packages or executes Apple libraries and never contacts Apple.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REV=a53ddc9ac6d65b24936d4a37917333fcd816cfd0
WORK="${EILI_NATIVE_TEST_WORK:-${TMPDIR:-/tmp}/eilistore-native-tci-a53ddc9}"
SRC="${EILI_UNICORN_SOURCE:-$WORK/src}"
BUILD="${EILI_NATIVE_TEST_BUILD:-$WORK/build}"
CXX="${CXX:-c++}"
for tool in cmake git python3 "$CXX"; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }; done
if [[ ! -d "$SRC/.git" ]]; then
  [[ -z "${EILI_UNICORN_SOURCE:-}" ]] || { echo "Provided Unicorn source is not a checkout" >&2; exit 2; }
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin https://github.com/mahee96/unicorn.git
  GIT_TERMINAL_PROMPT=0 git -C "$SRC" fetch --depth 1 origin "$REV"
  git -C "$SRC" checkout --detach "$REV"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$REV" ]] || { echo "Unicorn revision mismatch" >&2; exit 1; }
HOST_FLAGS=""
case "$(uname -m)" in x86_64|amd64) HOST_FLAGS=-mcx16 ;; esac
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$HOST_FLAGS" \
  -DUNICORN_ARCH=aarch64 -DUNICORN_ENABLE_TCI=ON -DBUILD_SHARED_LIBS=OFF \
  -DUNICORN_LEGACY_STATIC_ARCHIVE=ON -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF
cmake --build "$BUILD" --target unicorn_archive -j 4
LIB="$BUILD/libunicorn.a"
[[ -f "$LIB" ]] || { echo "Missing host Unicorn archive" >&2; exit 1; }
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
INCLUDES=(-I "$SRC/include" -I "$ROOT/Packages/AnisetteKit/Native" -I "$ROOT/Packages/AnisetteKit/Native/include")
LOADER="$ROOT/Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp"
BASE="$ROOT/Packages/AnisetteKit/Native/anisette_base.cpp"
LINK=(-pthread)
[[ "$(uname -s)" != Linux ]] || LINK+=(-ldl -lm)
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/AndroidDynamicLinkerTests.cpp" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/dynamic-linker"
"$OUT/dynamic-linker"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/AndroidLibcStringsTests.cpp" "$LOADER" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/libc-strings"
"$OUT/libc-strings"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeADIOutputTests.cpp" "$LOADER" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/adi-output"
"$OUT/adi-output"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/AndroidPthreadSyncTests.cpp" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/pthread-sync"
"$OUT/pthread-sync"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/AndroidModuleIterationTests.cpp" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/module-iteration"
"$OUT/module-iteration"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeELFProgramHeadersTests.cpp" "$LOADER" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/elf-headers"
"$OUT/elf-headers"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeELFSymbolTests.cpp" "$LOADER" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/elf-symbols"
"$OUT/elf-symbols"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeVMStartupTests.cpp" "$LOADER" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/vm-startup"
"$OUT/vm-startup"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeConstructorFaultTests.cpp" "$LOADER" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/constructor-faults"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeGuestTLSTests.cpp" "$LOADER" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/guest-tls"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeCxaAtexitBranchTests.cpp" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/cxa-atexit-branches"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeOperatorNewTests.cpp" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/operator-new"
"$CXX" -std=c++17 -UNDEBUG "${INCLUDES[@]}" "$ROOT/Tests/NativeReadProtectionTests.cpp" "$BASE" "$LIB" "${LINK[@]}" -o "$OUT/read-protection"
python3 - "$OUT/constructor-faults" "$OUT/guest-tls" "$OUT/cxa-atexit-branches" "$OUT/operator-new" "$OUT/read-protection" <<'PY'
import subprocess
import sys
for executable in sys.argv[1:]:
    subprocess.run([executable], check=True, timeout=90)
PY
echo 'PASS: native TCI synthetic ABI, linker, VM startup, guest stack-guard TLS, scalar operator new, constructor-fault and provisioning-output tests (not Apple login verification)'
