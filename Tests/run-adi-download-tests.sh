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
def make(name, entries, corrupt=None, nonseekable=False):
	p=os.path.join(out,name)
	class Sink:
	 def __init__(self, f): self.f=f
	 def write(self,b): return self.f.write(b)
	 def tell(self): return self.f.tell()
	 def seekable(self): return False
	 def flush(self): return self.f.flush()
	 def close(self): self.f.close()
	f=open(p,'w+b')
	with zipfile.ZipFile(Sink(f) if nonseekable else f,'w',compression=zipfile.ZIP_DEFLATED) as z:
	  for fn,data,mode in entries:
	   i=zipfile.ZipInfo(fn); i.compress_type=zipfile.ZIP_STORED if fn.endswith('/') else zipfile.ZIP_DEFLATED
	   i.external_attr=((mode if mode is not None else (stat.S_IFREG|0o644))&0xffff)<<16
	   z.writestr(i,data)
	if corrupt:
	 raw=bytearray(open(p,'rb').read()); n=raw.find(b'PK\x01\x02')
	 while n >= 0:
	  nl=struct.unpack_from('<H',raw,n+28)[0]; name=raw[n+46:n+46+nl].decode()
	  if name==corrupt: raw[n+16]^=0x01; break
	  n=raw.find(b'PK\x01\x02',n+4)
	 else: raise ValueError('missing central entry '+corrupt)
	 open(p,'wb').write(raw)
entries={'valid.zip':[('libCoreADI.so',elf,None),('libstoreservicescore.so',elf,None)],'traversal.zip':[('../escaped.so',elf,None)],'duplicate.zip':[('libCoreADI.so',elf,None),('libCoreADI.so',elf,None)],'symlink.zip':[('libCoreADI.so',elf,stat.S_IFLNK|0o777),('libstoreservicescore.so',elf,None)],'extra.zip':[('libCoreADI.so',elf,None),('libstoreservicescore.so',elf,None),('unexpected.txt',b'no',None)],'invalid-elf.zip':[('libCoreADI.so',b'not elf'+bytes(200),None),('libstoreservicescore.so',elf,None)],'bomb.zip':[('libCoreADI.so',bytes(256),None),('libstoreservicescore.so',bytes(256),None)]}
for name,items in entries.items(): make(name,items)
make('crc.zip',[('libCoreADI.so',elf,None),('libstoreservicescore.so',elf,None)],corrupt='libCoreADI.so')
two=[('libCoreADI.so',elf,None),('libstoreservicescore.so',elf,None)]
five=[(n,elf,None) for n in ['libCoreADI.so','libCoreFP.so','libCoreLSKD.so','libFPDIFor3P.so','libstoreapi.so']]
def apple(entries): return entries+[("__MACOSX/._"+n,b'fixture metadata',None) for n,_,_ in entries]
make('metadata-two.zip',apple(two),nonseekable=True)
make('metadata-five.zip',apple(five))
make('metadata-dir.zip',[('__MACOSX/',b'',stat.S_IFDIR|0o755)]+apple(two))
for label,items in {
 'metadata-unknown.zip':two+[('__MACOSX/._unexpected',b'x',None)],
 'metadata-traversal.zip':two+[('__MACOSX/../._libCoreADI.so',b'x',None)],
 'metadata-nested.zip':two+[('__MACOSX/sub/._libCoreADI.so',b'x',None)],
 'metadata-duplicate.zip':two+[('__MACOSX/._libCoreADI.so',b'x',None),('__MACOSX/._libCoreADI.so',b'x',None)],
 'metadata-symlink.zip':two+[('__MACOSX/._libCoreADI.so',b'x',stat.S_IFLNK|0o777)],
 'metadata-orphan.zip':two+[('__MACOSX/._libCoreFP.so',b'x',None)],
 'metadata-duplicate-dir.zip':two+[('__MACOSX/',b'',stat.S_IFDIR|0o755),('__MACOSX/',b'',stat.S_IFDIR|0o755)],
 'metadata-nonempty-dir.zip':two+[('__MACOSX/',b'x',stat.S_IFDIR|0o755)],
 'metadata-root-wrapper.zip':[('libs/libCoreADI.so',elf,None),('libs/libstoreservicescore.so',elf,None)],
 'metadata-incomplete.zip':[('libCoreADI.so',elf,None),('__MACOSX/._libCoreADI.so',b'x',None)],
 'metadata-mixed-set.zip':[('libCoreADI.so',elf,None),('libCoreFP.so',elf,None),('libCoreLSKD.so',elf,None),('libFPDIFor3P.so',elf,None),('libstoreservicescore.so',elf,None)],
}.items(): make(label,items)
make('metadata-badcrc.zip',apple(two),corrupt='__MACOSX/._libCoreADI.so')
make('metadata-sized.zip',two+[('__MACOSX/._libCoreADI.so',bytes(301),None)])
make('metadata-total.zip',two+[('__MACOSX/._libCoreADI.so',b'x',None)])
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
