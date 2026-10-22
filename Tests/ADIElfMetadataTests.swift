import Foundation

@main struct ADIElfMetadataTests {
    static func main() throws {
        let data=ADIElfFixture.make(soname:"libmain.so",needed:["libdep.so"],exports:["global"],imports:["strong"],weakImports:["weak"],hiddenExports:["hidden"],protectedExports:["protected"],relocations:[1,1027],dynamicTags:[0x6000000f,36])
        let parsed=try ADIELFMetadata.parse(data)
        precondition(parsed.needed == ["libdep.so"] && parsed.soname == "libmain.so")
        precondition(parsed.exportedSymbols == ["global","protected"])
        precondition(parsed.undefinedStrongSymbols == ["strong"])
        precondition(parsed.relocationTypes == [1,1027])
        precondition(parsed.unsupportedDynamicTags == [0x6000000f,36])
        for name in ["../evil.so","path/libevil.so","bad\\evil.so"] {
            let bad=ADIElfFixture.make(soname:"libok.so",needed:[name])
            do { _=try ADIELFMetadata.parse(bad); fatalError("accepted unsafe DT_NEEDED") } catch is ADIELFMetadata.ParseError {}
        }
        let unsafe=ADIElfFixture.make(soname:"../evil.so")
        do { _=try ADIELFMetadata.parse(unsafe); fatalError("accepted unsafe SONAME") } catch is ADIELFMetadata.ParseError {}
        let duplicate=ADIElfFixture.make(soname:"libx.so",dynamicTags:[14])
        do { _=try ADIELFMetadata.parse(duplicate); fatalError("accepted conflicting singleton tag") } catch is ADIELFMetadata.ParseError {}
        let base=ADIElfFixture.make(soname:"libx.so")
        for size in [0,63,100] {
            do { _=try ADIELFMetadata.parse(Data(base.prefix(size))); fatalError("accepted truncated ELF") } catch is ADIELFMetadata.ParseError {}
        }
        var conflict=[UInt8](base); let dynOff=0x100
        // Add a conflicting DT_SONAME before the terminator (the normal fixture has spare space).
        // Overwrite the string-table address with an unmapped high address to exercise safe arithmetic.
        for i in 0..<8 { conflict[dynOff+8+i]=0xff }
        do { _=try ADIELFMetadata.parse(Data(conflict)); fatalError("accepted overflowing virtual address") } catch is ADIELFMetadata.ParseError {}
        print("PASS ADIElfMetadataTests")
    }
}
