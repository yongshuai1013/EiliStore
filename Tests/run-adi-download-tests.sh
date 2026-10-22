#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/Downloader" "$work/Tests/DownloaderTests" "$work/fixtures"
cat > "$work/Package.swift" <<'PKG'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ADIDownloadTests", platforms: [.macOS(.v12)], dependencies: [
 .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
 .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.0.0")
], targets: [
 .target(name: "Downloader", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "Crypto", package: "swift-crypto")]),
 .testTarget(name: "DownloaderTests", dependencies: ["Downloader"])
])
PKG
cp "$root/Sources/EiliStore/ADIRuntimeLibraryDownloader.swift" "$work/Sources/Downloader/"
cp "$root/Tests/ADIRuntimeLibraryDownloaderTests.swift" "$work/Tests/DownloaderTests/"
python3 - "$work/fixtures" <<'PY'
import os,sys,zipfile,stat,struct,hashlib
out=sys.argv[1]
b=bytearray(256); b[:4]=b'\x7fELF'; b[4:7]=bytes([2,1,1]); b[16:18]=struct.pack('<H',3); b[18:20]=struct.pack('<H',183); b[20:24]=struct.pack('<I',1); elf=bytes(b)
open(os.path.join(out,'valid.elf'),'wb').write(elf)
def make(name, entries, corrupt=False):
 p=os.path.join(out,name)
 with zipfile.ZipFile(p,'w',compression=zipfile.ZIP_DEFLATED) as z:
  for fn,data,mode in entries:
   i=zipfile.ZipInfo(fn); i.compress_type=zipfile.ZIP_DEFLATED
   i.external_attr=((mode if mode is not None else (stat.S_IFREG|0o644))&0xffff)<<16
   z.writestr(i,data)
 if corrupt:
  raw=bytearray(open(p,'rb').read()); n=raw.find(b'PK\x01\x02'); raw[n+16]^=0x01; open(p,'wb').write(raw)
entries={'valid.zip':[('libCoreADI.so',elf,None),('libstoreservicescore.so',elf,None)],'traversal.zip':[('../escaped.so',elf,None)],'duplicate.zip':[('libCoreADI.so',elf,None),('libCoreADI.so',elf,None)],'symlink.zip':[('libCoreADI.so',elf,stat.S_IFLNK|0o777),('libstoreservicescore.so',elf,None)],'extra.zip':[('libCoreADI.so',elf,None),('libstoreservicescore.so',elf,None),('unexpected.txt',b'no',None)],'invalid-elf.zip':[('libCoreADI.so',b'not elf'+bytes(200),None),('libstoreservicescore.so',elf,None)],'bomb.zip':[('libCoreADI.so',bytes(256),None),('libstoreservicescore.so',bytes(256),None)]}
for name,items in entries.items(): make(name,items)
make('crc.zip',[('libCoreADI.so',elf,None),('libstoreservicescore.so',elf,None)],True)
for name in os.listdir(out):
 if name.endswith('.zip'):
  with open(os.path.join(out,name)+'.sha256','w') as f: f.write(hashlib.sha256(open(os.path.join(out,name),'rb').read()).hexdigest())
PY
export PATH="/workspace/tooling/swift603/usr/bin:$PATH" ADI_TEST_FIXTURES="$work/fixtures"
cd "$work"
swift package resolve
# Linux test-only compatibility for this older dependency and Swift 6/glibc.
# Apple CI compiles the original dependency, without these disposable edits.
python3 - "$work/.build/checkouts/ZIPFoundation/Sources/ZIPFoundation" <<'PY'
import pathlib,sys
if sys.platform == 'linux':
 root=pathlib.Path(sys.argv[1])
 path=root/'Archive+MemoryFile.swift'
 path.chmod(path.stat().st_mode | 0o200)
 text=path.read_text()
 text=text.replace('if append {\n            fseeko(result, 0, SEEK_END)', 'if append, let result {\n            fseeko(result, 0, SEEK_END)')
 path.write_text(text)
 path=root/'Data+Serialization.swift'
 path.chmod(path.stat().st_mode | 0o200)
 path.write_text(path.read_text().replace('$0.load(as: T.self)', '$0.loadUnaligned(as: T.self)'))
 print('Linux-only test dependency compatibility applied; production source unchanged.')
PY
swift test -q --jobs 8
