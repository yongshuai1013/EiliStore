#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/build/Dependencies/AnisetteKit"
REV=db8b41022697b6c19be8a5f01a1ce834145a2a26
[[ ! -e "$PACKAGE" ]] || { echo "Refusing to overwrite existing $PACKAGE" >&2; exit 2; }
mkdir -p "$(dirname "$PACKAGE")"
git init -q "$PACKAGE"
git -C "$PACKAGE" remote add origin https://github.com/mahee96/AnisetteKit.git
git -C "$PACKAGE" fetch --depth 1 origin "$REV"
git -C "$PACKAGE" checkout --detach FETCH_HEAD
[[ "$(git -C "$PACKAGE" rev-parse HEAD)" == "$REV" ]] || exit 1
python3 - "$PACKAGE/Package.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = '''url: "https://github.com/mahee96/unicorn/releases/download/2.1.4-xcf-a53ddc9/Unicorn.xcframework.zip#AnisetteKit",
        checksum: "52e4ac9e2d704c4941adc2c381df8706aabf673dc843611a90b33ad349d562db"'''
if text.count(old) != 1 or text.count('"README.md",') != 1:
    raise SystemExit('Pinned manifest does not match expected binary declaration')
text = text.replace(old, 'path: "Artifacts/Unicorn.xcframework"')
text = text.replace('"README.md",', '"README.md",\n                "Artifacts",')
path.write_text(text)
PY
# Keep every tracked Swift/native implementation identical to the pinned upstream.
git -C "$PACKAGE" diff --exit-code -- . ':!Package.swift'
echo "AnisetteKit source remains pinned at $REV; only manifest binary location changed."
EILI_UNICORN_PACKAGE="$PACKAGE" bash "$ROOT/Scripts/build-on-device-anisette.sh"
