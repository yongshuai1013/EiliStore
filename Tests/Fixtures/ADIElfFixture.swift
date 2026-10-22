import Foundation

enum ADIElfFixture {
    static func make(soname: String, needed: [String] = [], exports: [String] = [], imports: [String] = [], weakImports: [String] = [], hiddenExports: [String] = [], protectedExports: [String] = [], relocations: [UInt32] = [1027], dynamicTags: [UInt64] = [], symbolTypes: [String: UInt8] = [:]) -> Data {
        var strings: [UInt8] = [0]
        var indexes: [String: UInt64] = [:]
        func intern(_ value: String) -> UInt64 {
            if let i = indexes[value] { return i }
            let i = UInt64(strings.count); strings += value.utf8; strings.append(0); indexes[value] = i; return i
        }
        let sonameIndex=intern(soname), neededIndexes=needed.map(intern)
        let symbolNames=Array(Set(exports+imports+weakImports+hiddenExports+protectedExports)).sorted()
        for name in symbolNames { _ = intern(name) }
        var dyn: [(UInt64,UInt64)] = [(5,0),(10,0)]
        for i in neededIndexes { dyn.append((1,i)) }; dyn.append((14,sonameIndex)); dyn += dynamicTags.map{($0,0)}; dyn.append((0,0))
        let dynOff=0x100, strOff=0x300, symOff=0x400, relaOff=0x800, shOff=0x900
        let sections=5, total=shOff+sections*64
        var b=[UInt8](repeating:0,count:total)
        func put(_ off:Int,_ value:UInt64,_ n:Int) { for i in 0..<n { b[off+i]=UInt8(truncatingIfNeeded:value >> (8*i)) } }
        func copy(_ off:Int,_ bytes:[UInt8]) { for (i,x) in bytes.enumerated(){b[off+i]=x} }
        b[0...3]=[0x7f,0x45,0x4c,0x46]; b[4]=2;b[5]=1;b[6]=1
        put(16,3,2);put(18,183,2);put(20,1,4);put(52,64,2);put(54,56,2);put(56,2,2);put(58,64,2);put(60,UInt64(sections),2)
        put(32,64,8);put(40,UInt64(shOff),8)
        put(64,1,4);put(96,UInt64(total),8);put(104,UInt64(total),8)
        put(120,2,4);put(128,UInt64(dynOff),8);put(136,UInt64(dynOff),8);put(152,UInt64(dyn.count*16),8);put(160,UInt64(dyn.count*16),8)
        for (i,e) in dyn.enumerated(){ put(dynOff+i*16,e.0,8);put(dynOff+i*16+8,e.1,8) }
        // Update dynamic string table pointer/size after all symbol strings have been interned.
        // Dynamic symbol string table is the same table as DT_STRTAB.
        put(dynOff+8,UInt64(strOff),8); put(dynOff+24,UInt64(strings.count),8)
        // Reset entries that follow the first two tags in case the table's offsets moved (they do not).
        copy(strOff,strings)
        var symbols=[UInt8](repeating:0,count:24*(symbolNames.count+1))
        for (idx,name) in symbolNames.enumerated() {
            let slot=(idx+1)*24, nameIndex=indexes[name]!
            for j in 0..<4 { symbols[slot+j]=UInt8(truncatingIfNeeded:nameIndex >> (j*8)) }
            let isWeak=weakImports.contains(name) || exports.contains(name) && false
            let isDefined=exports.contains(name) || hiddenExports.contains(name) || protectedExports.contains(name)
            symbols[slot+4]=UInt8((isWeak ? 2 : 1) << 4) | ((symbolTypes[name] ?? 2) & 0x0f)
            symbols[slot+5]=hiddenExports.contains(name) ? 2 : (protectedExports.contains(name) ? 3 : 0)
            symbols[slot+6]=isDefined ? 1 : 0
        }
        copy(symOff,symbols)
        for (idx,type) in relocations.enumerated(){put(relaOff+idx*24+8,UInt64(type),4)}
        func sh(_ index:Int,_ type:UInt32,_ off:Int,_ size:Int,_ link:UInt32,_ ents:Int) {
            let p=shOff+index*64;put(p+4,UInt64(type),4);put(p+24,UInt64(off),8);put(p+32,UInt64(size),8);put(p+40,UInt64(link),4);put(p+56,UInt64(ents),8)
        }
        sh(1,11,symOff,symbols.count,2,24);sh(2,3,strOff,strings.count,0,0);sh(3,4,relaOff,relocations.count*24,1,24)
        return Data(b)
    }
}
