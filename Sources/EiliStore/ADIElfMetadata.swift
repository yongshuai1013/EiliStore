import Foundation

public struct ADIELFMetadata: Equatable, Sendable {
    public let needed: [String]
    public let soname: String?
    public let exportedSymbols: Set<String>
    public let undefinedStrongSymbols: Set<String>
    public let undefinedFunctionSymbols: Set<String>
    public let undefinedDataSymbols: Set<String>
    public let undefinedTLSSymbols: Set<String>
    public let hasThreadLocalSegment: Bool
    public let undefinedUnsupportedSymbols: Set<String>
    public let relocationTypes: Set<UInt32>
    public let unsupportedDynamicTags: Set<UInt64>

    public init(needed: [String], soname: String?, exportedSymbols: Set<String>, undefinedStrongSymbols: Set<String>, relocationTypes: Set<UInt32>, unsupportedDynamicTags: Set<UInt64>, undefinedFunctionSymbols: Set<String> = [], undefinedDataSymbols: Set<String> = [], undefinedTLSSymbols: Set<String> = [], hasThreadLocalSegment: Bool = false, undefinedUnsupportedSymbols: Set<String> = []) {
        self.needed = needed; self.soname = soname; self.exportedSymbols = exportedSymbols
        self.undefinedStrongSymbols = undefinedStrongSymbols; self.relocationTypes = relocationTypes
        self.unsupportedDynamicTags = unsupportedDynamicTags; self.undefinedFunctionSymbols = undefinedFunctionSymbols
        self.undefinedDataSymbols = undefinedDataSymbols; self.undefinedTLSSymbols = undefinedTLSSymbols; self.hasThreadLocalSegment = hasThreadLocalSegment; self.undefinedUnsupportedSymbols = undefinedUnsupportedSymbols
    }

    public enum ParseError: Error, Equatable { case malformed(String) }

    public static func parse(_ data: Data) throws -> Self {
        let b = [UInt8](data)
        func fail(_ s: String) -> ParseError { .malformed(s) }
        func add(_ a: UInt64, _ c: UInt64) throws -> UInt64 {
            let (v, overflow) = a.addingReportingOverflow(c)
            guard !overflow else { throw fail("integer overflow") }; return v
        }
        func mul(_ a: UInt64, _ c: UInt64) throws -> UInt64 {
            let (v, overflow) = a.multipliedReportingOverflow(by: c)
            guard !overflow else { throw fail("integer overflow") }; return v
        }
        func range(_ off: UInt64, _ size: UInt64) throws -> Range<Int> {
            guard off <= UInt64(b.count), size <= UInt64(b.count) - off, off <= UInt64(Int.max), size <= UInt64(Int.max) else { throw fail("out of bounds") }
            return Int(off)..<Int(off + size)
        }
        func u(_ off: UInt64, _ n: Int) throws -> UInt64 {
            let r = try range(off, UInt64(n)); var v: UInt64 = 0
            for (i, x) in b[r].enumerated() { v |= UInt64(x) << (8 * i) }; return v
        }
        guard b.count >= 64, Array(b[0..<4]) == [0x7f,0x45,0x4c,0x46], b[4] == 2, b[5] == 1, b[6] == 1,
              try u(16,2) == 3, try u(18,2) == 183, try u(20,4) == 1, try u(52,2) == 64 else { throw fail("not little-endian ELF64 AArch64 ET_DYN") }
        let phoff=try u(32,8), shoff=try u(40,8), phents=try u(54,2), phnum=try u(56,2), shents=try u(58,2), shnum=try u(60,2)
        guard phents >= 56, shents >= 64, phnum > 0, shnum > 0, phnum <= 4096, shnum <= 65535 else { throw fail("invalid table dimensions") }
        _ = try range(phoff, mul(phents, phnum)); _ = try range(shoff, mul(shents, shnum))
        struct Seg { let va, mem, off, size: UInt64 }
        var loads:[Seg]=[], dynamics:[Seg]=[]
        var hasTLSProgramSegment = false
        for i in 0..<phnum {
            let p=try add(phoff, try mul(i,phents)), typ=try u(p,4), off=try u(try add(p,8),8), va=try u(try add(p,16),8), fs=try u(try add(p,32),8), ms=try u(try add(p,40),8)
            _ = try range(off,fs); guard fs <= ms else { throw fail("invalid program segment") }
            if typ == 1, fs > 0, ms > 0 { loads.append(Seg(va:va,mem:ms,off:off,size:fs)) }
            if typ == 7 { hasTLSProgramSegment = true }
            if typ == 2, fs > 0 { dynamics.append(Seg(va:va,mem:ms,off:off,size:fs)) }
        }
        guard !loads.isEmpty, !dynamics.isEmpty else { throw fail("missing PT_LOAD or PT_DYNAMIC") }
        func vfile(_ va:UInt64,_ n:UInt64) throws -> UInt64 {
            for s in loads where va >= s.va {
                let delta=va-s.va
                if delta <= s.size && n <= s.size-delta { return try add(s.off,delta) }
            }
            throw fail("unmapped virtual address")
        }
        var dyn:[(UInt64,UInt64)]=[]
        for d in dynamics {
            guard d.size % 16 == 0, d.size/16 <= 65536 else { throw fail("invalid dynamic table") }
            var ended=false
            for j in stride(from:UInt64(0),to:d.size,by:16) {
                let pos=try add(d.off,j), tag=try u(pos,8), val=try u(try add(pos,8),8)
                if tag == 0 { ended=true; break }; dyn.append((tag,val))
            }
            guard ended else { throw fail("unterminated dynamic table") }
        }
        let grouped=Dictionary(grouping:dyn,by:{$0.0})
        let singleton:Set<UInt64>=[5,6,10,14, DT_REL, DT_RELA, DT_RELSZ, DT_RELASZ, DT_RELENT, DT_RELAENT, DT_SYMENT]
        for tag in singleton {
            let vals=grouped[tag]?.map{$0.1} ?? []
            guard Set(vals).count <= 1 else { throw fail("conflicting singleton dynamic tag") }
        }
        guard let strVA=grouped[5]?.first?.1, let strsz=grouped[10]?.first?.1, strsz > 0 else { throw fail("missing dynamic string table") }
        let strOff=try vfile(strVA,strsz); _ = try range(strOff,strsz)
        func str(_ index:UInt64) throws -> String {
            guard index < strsz else { throw fail("bad string offset") }
            let absoluteVA=try add(strVA,index), off=try vfile(absoluteVA,strsz-index), r=try range(off,strsz-index)
            guard let end=b[r].firstIndex(of:0), let s=String(bytes:b[Int(off)..<end],encoding:.utf8), !s.isEmpty else { throw fail("invalid/unterminated UTF-8 string") }
            return s
        }
        var needed:[String]=[], soname:String?
        for (tag,val) in dyn {
            if tag == 1 { let s=try str(val); guard Self.safeName(s) else { throw fail("unsafe DT_NEEDED") }; needed.append(s) }
            if tag == 14 { let s=try str(val); guard Self.safeName(s) else { throw fail("unsafe SONAME") }; soname=s }
        }
        var exports:Set<String>=[], undefined:Set<String>=[], functions:Set<String>=[], data:Set<String>=[], tls:Set<String>=[], unsupportedSymbols:Set<String>=[], relocs:Set<UInt32>=[]
        var sawDynsym=false
        for i in 0..<shnum {
            let p=try add(shoff,try mul(i,shents)), typ=try u(try add(p,4),4), off=try u(try add(p,24),8), size=try u(try add(p,32),8), link=try u(try add(p,40),4), ents=try u(try add(p,56),8)
            if typ == 8 { continue } // SHT_NOBITS has no file-backed payload.
            _ = try range(off,size)
            if typ == 4 || typ == 9 {
                let minEnt:UInt64 = typ == 4 ? 24 : 16
                guard ents >= minEnt, size % ents == 0, size/ents <= 1_000_000 else { throw fail("invalid relocation section") }
                for k in 0..<(size/ents) { let item=try add(off,try mul(k,ents)); relocs.insert(UInt32(try u(try add(item,8),4))) }
            }
            if typ == 11 {
                guard !sawDynsym, ents >= 24, size % ents == 0, size/ents <= 1_000_000, link < shnum else { throw fail("invalid dynsym section") }
                sawDynsym=true
                let tp=try add(shoff,try mul(link,shents)), stype=try u(try add(tp,4),4), to=try u(try add(tp,24),8), ts=try u(try add(tp,32),8)
                guard stype == 3 else { throw fail("dynsym link is not SHT_STRTAB") }; _ = try range(to,ts)
                for k in 0..<(size/ents) {
                    let item=try add(off,try mul(k,ents)), no=try u(item,4), info=try u(try add(item,4),1), other=try u(try add(item,5),1), shndx=try u(try add(item,6),2)
                    guard no < ts else { throw fail("bad symbol name offset") }; if no == 0 { continue }
                    let nameOff=try add(to,no), rem=ts-no
                    guard let end=b[try range(nameOff,rem)].firstIndex(of:0), let name=String(bytes:b[Int(nameOff)..<end],encoding:.utf8), !name.isEmpty else { throw fail("bad symbol string") }
                    let bind=info >> 4, vis=other & 3
                    let type = info & 0x0f
                    if type == 6 { tls.insert(name) }
                    if shndx == 0 && (bind == 1 || bind == 2) {
                        if bind == 1 { undefined.insert(name) }
                        if type == 2 || type == 0 { functions.insert(name) }
                        else if type == 1 { data.insert(name) }
                        else if type == 6 { tls.insert(name) }
                        else { unsupportedSymbols.insert(name) }
                    }
                    if shndx != 0 && (bind == 1 || bind == 2) && (vis == 0 || vis == 3) { exports.insert(name) }
                }
            }
        }
        guard sawDynsym else { throw fail("missing SHT_DYNSYM") }
        let unsupported:Set<UInt64>=[0x6000000f,0x60000011,0x6fffe000,36,DT_REL,DT_RELR,DT_ANDROID_REL,DT_ANDROID_RELA]
        return Self(needed:needed,soname:soname,exportedSymbols:exports,undefinedStrongSymbols:undefined,relocationTypes:relocs,unsupportedDynamicTags:Set(dyn.map{$0.0}).intersection(unsupported),undefinedFunctionSymbols:functions,undefinedDataSymbols:data,undefinedTLSSymbols:tls,hasThreadLocalSegment:hasTLSProgramSegment,undefinedUnsupportedSymbols:unsupportedSymbols)
    }

    private static let DT_REL:UInt64=17, DT_RELA:UInt64=7, DT_RELSZ:UInt64=18, DT_RELASZ:UInt64=8, DT_RELENT:UInt64=19, DT_RELAENT:UInt64=9, DT_SYMENT:UInt64=11, DT_RELR:UInt64=36, DT_ANDROID_REL:UInt64=0x6000000f, DT_ANDROID_RELA:UInt64=0x60000011
    private static func safeName(_ s:String)->Bool { s.hasSuffix(".so") && !s.contains("/") && !s.contains("\\") && s != ".so" && s != "..so" && !s.contains("..") }
}
