// Self-authored ELF metadata only: no downloaded libraries or guest code execution.
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <unistd.h>
#ifndef DT_GNU_HASH
#define DT_GNU_HASH 0x6ffffef5
#ifndef DT_DEBUG
#define DT_DEBUG 21
#endif
#endif
#define ELF64_R_INFO_TEST(sym, type) (((uint64_t)(sym) << 32) | (uint32_t)(type))
constexpr unsigned kGlobal = 1, kFunc = 2, kObject = 1, kNoType = 0, kDyn = 3, kAarch64 = 183, kCurrent = 1,
                   kAbs = 0xfff1, kUndef = 0;
#define ELF64_ST_INFO_TEST(bind, type) (((bind) << 4) + ((type) & 0xf))
namespace {
constexpr size_t kFileSize = 0x1000, kDynamicOff = 0x100, kSymOff = 0x300, kStrOff = 0x500;
constexpr size_t kHashOff = 0x600, kGnuHashOff = 0x680, kRelaOff = 0x700, kTargetOff = 0x800;
constexpr uint64_t kVaddr = 0x20000;
struct Fixture {
    std::vector<uint8_t> b = std::vector<uint8_t>(kFileSize);
    Elf64_Ehdr eh{};
    Elf64_Phdr ph[2]{};
    std::vector<Elf64_Sym> syms;
    std::string strings = std::string(1, '\0');
    std::vector<Elf64_Dyn> dyn;
    uint64_t base = kVaddr;
    bool use_gnu = false, use_sysv = true;
    Fixture(uint64_t v = kVaddr) : base(v) {
        std::memcpy(eh.e_ident,
                    "\x7f"
                    "ELF\x02\x01\x01",
                    7);
        eh.e_type = kDyn;
        eh.e_machine = kAarch64;
        eh.e_version = kCurrent;
        eh.e_ehsize = sizeof(eh);
        eh.e_phoff = sizeof(eh);
        eh.e_phentsize = sizeof(Elf64_Phdr);
        eh.e_phnum = 2;
        ph[0].p_type = PT_LOAD;
        ph[0].p_flags = PF_R | PF_W;
        ph[0].p_vaddr = base;
        ph[0].p_filesz = kFileSize;
        ph[0].p_memsz = kFileSize;
        ph[0].p_align = 0x10000;
        ph[1].p_type = PT_DYNAMIC;
        ph[1].p_vaddr = base + kDynamicOff;
        ph[1].p_offset = kDynamicOff;
        syms.resize(1);
    }
    uint32_t name(const char *s) {
        auto n = (uint32_t)strings.size();
        strings += s;
        strings.push_back('\0');
        return n;
    }
    size_t symbol(const char *n, unsigned t, uint16_t sec, uint64_t value, uint64_t size = 8) {
        Elf64_Sym s{};
        s.st_name = name(n);
        s.st_info = ELF64_ST_INFO_TEST(kGlobal, t);
        s.st_shndx = sec;
        s.st_value = value;
        s.st_size = size;
        syms.push_back(s);
        return syms.size() - 1;
    }
    void build(bool gnu = false, bool both = false) {
        use_gnu = gnu;
        use_sysv = !gnu || both;
        symbol("defined_fn", kFunc, 1, base + 0x900);
        symbol("zero_fn", kFunc, 1, base);
        symbol("absolute_zero", kObject, kAbs, 0);
        symbol("absolute_value", kObject, kAbs, 0x12345678);
        symbol("object_data", kObject, 1, base + 0x910);
        symbol("notype_data", kNoType, 1, base + 0x920);
        size_t cxa = symbol("__cxa_atexit", kFunc, kUndef, 0x777);
        const uint32_t cxa_name = (uint32_t)(strings.size() - sizeof("__cxa_atexit"));
        // Interior undefined zero-name entry ensures scans do not stop at empty names.
        Elf64_Sym interior{};
        interior.st_info = ELF64_ST_INFO_TEST(kGlobal, kNoType);
        syms.insert(syms.begin() + 2, interior);
        const size_t cxa_index = cxa + 1;
        std::memcpy(b.data(), &eh, sizeof(eh));
        std::memcpy(b.data() + sizeof(eh), ph, sizeof(ph));
        auto add = [&](int64_t tag, uint64_t val) {
            Elf64_Dyn x{};
            x.d_tag = tag;
            x.d_un.d_val = val;
            dyn.push_back(x);
        };
        add(DT_SYMTAB, base + kSymOff);
        add(DT_SYMENT, sizeof(Elf64_Sym));
        add(DT_STRTAB, base + kStrOff);
        add(DT_STRSZ, strings.size());
        if (use_sysv)
            add(DT_HASH, base + kHashOff);
        if (gnu)
            add(DT_GNU_HASH, base + (both ? kGnuHashOff : kHashOff));
        add(DT_JMPREL, base + kRelaOff);
        add(DT_PLTRELSZ, sizeof(Elf64_Rela));
        add(DT_PLTREL, DT_RELA);
        add(DT_NULL, 0);
        ph[1].p_filesz = ph[1].p_memsz = dyn.size() * sizeof(Elf64_Dyn);
        std::memcpy(b.data() + sizeof(eh), ph, sizeof(ph));
        std::memcpy(b.data() + kDynamicOff, dyn.data(), dyn.size() * sizeof(Elf64_Dyn));
        std::memcpy(b.data() + kStrOff, strings.data(), strings.size());
        std::memcpy(b.data() + kSymOff, syms.data(), syms.size() * sizeof(Elf64_Sym));
        const uint32_t count = (uint32_t)syms.size();
        if (use_sysv) {
            uint32_t hash[2] = {1, count};
            std::memcpy(b.data() + kHashOff, hash, sizeof(hash));
            std::vector<uint32_t> table(count + 1, 0);
            std::memcpy(b.data() + kHashOff + sizeof(hash), table.data(), table.size() * 4);
        }
        if (gnu) {
            const size_t goff = both ? kGnuHashOff : kHashOff;
            // A nonempty bucket starts at symoffset=1; its chain covers every
            // remaining dynsym and terminates only at the final entry.
            const uint32_t gh[4] = {1, 1, 1, 5};
            std::memcpy(b.data() + goff, gh, sizeof(gh));
            const uint64_t bloom = 0;
            std::memcpy(b.data() + goff + sizeof(gh), &bloom, sizeof(bloom));
            const uint32_t bucket = 1;
            std::memcpy(b.data() + goff + sizeof(gh) + sizeof(bloom), &bucket, sizeof(bucket));
            std::vector<uint32_t> chains(syms.size() - 1, 0);
            chains.back() = 1;
            std::memcpy(b.data() + goff + sizeof(gh) + sizeof(bloom) + sizeof(bucket), chains.data(),
                        chains.size() * sizeof(uint32_t));
        }
        Elf64_Sym version_need{};
        version_need.st_name = cxa_name;
        version_need.st_info = ELF64_ST_INFO_TEST(kGlobal, kFunc);
        version_need.st_shndx = 1;
        version_need.st_value = 0x777;
        std::memcpy(b.data() + kSymOff + syms.size() * sizeof(Elf64_Sym), &version_need,
                    sizeof(version_need));
        Elf64_Rela r{};
        r.r_offset = base + kTargetOff;
        r.r_info = ELF64_R_INFO_TEST(cxa_index, R_AARCH64_JUMP_SLOT);
        std::memcpy(b.data() + kRelaOff, &r, sizeof(r));
    }
    void tag(int64_t wanted, uint64_t value) {
        auto *p = reinterpret_cast<Elf64_Dyn *>(b.data() + kDynamicOff);
        size_t n = ph[1].p_filesz / sizeof(*p);
        for (size_t i = 0; i < n && p[i].d_tag != DT_NULL; ++i)
            if (p[i].d_tag == wanted)
                p[i].d_un.d_val = value;
    }
};
bool load(EmulatorVM &vm, const std::vector<uint8_t> &b, const char *n = "libsynthetic-symbols.so") {
    char path[] = "/tmp/eili-elf-symbol-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    size_t x = 0;
    while (x < b.size()) {
        auto w = write(fd, b.data() + x, b.size() - x);
        assert(w > 0);
        x += w;
    }
    close(fd);
    bool ok = load_library_to_vm(&vm, path, n);
    unlink(path);
    return ok;
}
void expect_reject(const Fixture &f) {
    EmulatorVM vm;
    assert(!load(vm, f.b));
}
} // namespace
int main() {
    // SysV only, GNU only, and both hash styles.  A nonzero st_value in the
    // version-need bytes after the exact dynsym count must never become an export.
    for (int mode = 0; mode < 3; ++mode) {
        Fixture f;
        f.build(mode == 1 || mode == 2, mode == 2);
        EmulatorVM vm;
        assert(load(vm, f.b, kADISymbols.lib_ssc));
        assert(vm.loaded_libraries.size() == 1);
        const auto &l = vm.loaded_libraries[0];
        assert(l.symbol_count == f.syms.size());
        assert(l.symbols.count("defined_fn") && l.symbols.count("object_data") &&
               l.symbols.count("notype_data"));
        assert(l.symbols.count("absolute_zero") && l.symbols.at("absolute_zero") == 0);
        assert(l.symbols.count("absolute_value") && l.symbols.at("absolute_value") == 0x12345678);
        assert(l.symbols.count("zero_fn") && l.symbols.at("zero_fn") == l.base_address);
        assert(!l.symbols.count("fake_version_need"));
        assert(!l.symbols.count("__cxa_atexit"));
        relocate_all_vm_libraries(&vm);
        assert(vm.execution_error.empty());
        uint64_t got = 1;
        assert(uc_mem_read(vm.uc, l.base_address + kTargetOff, &got, sizeof(got)) == UC_ERR_OK);
        assert(got == vm.register_import("__cxa_atexit"));
        assert(vm.import_stubs.count(got) && vm.import_stubs.at(got) == "__cxa_atexit");
        assert(vm.cxa_atexit_slots.size() == 1);
        assert(vm.cxa_atexit_slots[0].source == EmulatorVM::ResolutionSource::functionStub);
    }
    // A genuine virtual-address-zero image validates defined value zero separately.
    {
        Fixture f(0);
        f.build();
        EmulatorVM vm;
        assert(load(vm, f.b));
        const auto &l = vm.loaded_libraries[0];
        assert(l.symbols.count("zero_fn") && l.symbols.at("zero_fn") == l.base_address);
    }
    // Names beyond the former 255-byte truncation remain distinct and resolvable.
    {
        Fixture f;
        const std::string long_name(300, 'L');
        f.symbol(long_name.c_str(), kFunc, 1, kVaddr + 0x940);
        f.build();
        std::memcpy(f.b.data() + 0xa00, f.strings.data(), f.strings.size());
        f.tag(DT_STRTAB, kVaddr + 0xa00);
        EmulatorVM vm;
        assert(load(vm, f.b));
        assert(vm.loaded_libraries[0].symbols.count(long_name));
    }
    // Defined BSS objects are valid even though their bytes are not file-backed.
    {
        Fixture f;
        f.symbol("bss_object", kObject, 1, kVaddr + 0x1100);
        f.build();
        f.ph[0].p_memsz = 0x1200;
        std::memcpy(f.b.data() + sizeof(Elf64_Ehdr), f.ph, sizeof f.ph);
        EmulatorVM vm;
        assert(load(vm, f.b));
        assert(vm.loaded_libraries[0].symbols.at("bss_object") ==
               vm.loaded_libraries[0].base_address + 0x1100);
    }
    // Undefined relocation resolved to a valid absolute-zero symbol must write zero.
    {
        Fixture f;
        f.build();
        auto *p = reinterpret_cast<Elf64_Rela *>(f.b.data() + kRelaOff);
        p->r_info = ELF64_R_INFO_TEST(4, R_AARCH64_JUMP_SLOT); // absolute_zero index after interior insertion
        EmulatorVM vm;
        assert(load(vm, f.b));
        const uint64_t sentinel = 0xfeedface;
        assert(uc_mem_write(vm.uc, vm.loaded_libraries[0].base_address + kTargetOff,
                            &sentinel, sizeof sentinel) == UC_ERR_OK);
        relocate_all_vm_libraries(&vm);
        uint64_t got = 99;
        assert(uc_mem_read(vm.uc, vm.loaded_libraries[0].base_address + kTargetOff, &got, 8) == UC_ERR_OK &&
               got == 0);
    }
    // Invalid relocation index reports an error without reading outside dynsym.
    {
        Fixture f;
        f.build();
        auto *r = reinterpret_cast<Elf64_Rela *>(f.b.data() + kRelaOff);
        r->r_info = ELF64_R_INFO_TEST(0x7fffffff, R_AARCH64_JUMP_SLOT);
        EmulatorVM vm;
        assert(load(vm, f.b));
        relocate_all_vm_libraries(&vm);
        assert(!vm.execution_error.empty());
    }
    // Bad/missing hash, malformed hash headers/tables, and truncated input.
    {
        Fixture f;
        f.build();
        auto *dynamic = reinterpret_cast<Elf64_Dyn *>(f.b.data() + kDynamicOff);
        dynamic[f.dyn.size() - 1].d_tag = DT_DEBUG;
        expect_reject(f); // No DT_NULL inside PT_DYNAMIC: never scan neighboring bytes.
    }
    {
        Fixture f;
        f.build();
        f.ph[0].p_memsz = 0x1200;
        f.ph[1].p_vaddr = kVaddr + 0x1100;
        f.ph[1].p_offset = 0x1100;
        std::memcpy(f.b.data() + sizeof(Elf64_Ehdr), f.ph, sizeof f.ph);
        expect_reject(f); // A mapped BSS region is not file-backed metadata.
    }
    {
        Fixture f;
        f.build();
        f.tag(DT_HASH, 0);
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.tag(DT_HASH, kVaddr + kFileSize - 4);
        expect_reject(f);
    }
    {
        Fixture f;
        f.build(true);
        uint32_t bad[4] = {1, 0, 0, 0};
        std::memcpy(f.b.data() + kHashOff, bad, sizeof(bad));
        expect_reject(f);
    }
    {
        Fixture f;
        f.build(true);
        uint32_t bad[4] = {1, 1, 1, 0xffffffff};
        std::memcpy(f.b.data() + kHashOff, bad, sizeof(bad));
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.b.resize(sizeof(Elf64_Ehdr));
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.tag(DT_HASH, kVaddr + kFileSize - 1);
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        auto *h = reinterpret_cast<uint32_t *>(f.b.data() + kHashOff);
        h[1]++;
        expect_reject(f);
    }
    {
        Fixture f;
        f.build(true, true);
        uint32_t bad = 2;
        std::memcpy(f.b.data() + kHashOff + 4, &bad, 4);
        expect_reject(f);
    }
    // Empty GNU hash is a distinct valid representation: all dynsyms form an
    // unhashed prefix, with no bucket or chain data.
    {
        Fixture f;
        f.build(true);
        const uint32_t gh[4] = {1, (uint32_t)f.syms.size(), 1, 5};
        std::memcpy(f.b.data() + kHashOff, gh, sizeof(gh));
        uint64_t bloom = 0;
        std::memcpy(f.b.data() + kHashOff + 16, &bloom, 8);
        uint32_t bucket = 0;
        std::memcpy(f.b.data() + kHashOff + 24, &bucket, 4);
        // Remove SysV hash so the GNU table starts at the shared hash offset.
        f.tag(DT_HASH, 0);
        auto *d = reinterpret_cast<Elf64_Dyn *>(f.b.data() + kDynamicOff);
        for (size_t i = 0; d[i].d_tag != DT_NULL; ++i)
            if (d[i].d_tag == DT_HASH)
                d[i].d_tag = DT_DEBUG;
        EmulatorVM vm;
        assert(load(vm, f.b));
        assert(vm.loaded_libraries[0].symbols.count("defined_fn"));
    }
    // A bucket chain with no low-bit terminator before file end must be rejected.
    {
        Fixture f;
        f.build(true);
        f.ph[0].p_filesz = 0x6f8; // Keep defined symbols mapped; truncate only file-backed chain data.
        std::memcpy(f.b.data() + sizeof(Elf64_Ehdr), f.ph, sizeof(f.ph));
        const uint64_t gnu_va = kVaddr + 0x6d8;
        f.tag(DT_GNU_HASH, gnu_va);
        const uint32_t gh[4] = {1, 1, 1, 5};
        std::memcpy(f.b.data() + 0x6d8, gh, sizeof(gh));
        uint64_t bloom = 0;
        std::memcpy(f.b.data() + 0x6e8, &bloom, 8);
        uint32_t bucket = 1;
        std::memcpy(f.b.data() + 0x6f0, &bucket, 4);
        // Only the first chain word fits, and it lacks the terminator bit.
        uint32_t unterminated = 0;
        std::memcpy(f.b.data() + 0x6f4, &unterminated, 4);
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.ph[0].p_filesz = 0x900;
        std::memcpy(f.b.data() + sizeof(Elf64_Ehdr), f.ph, sizeof(f.ph));
        f.tag(DT_HASH, kVaddr + 0x950);
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.ph[0].p_filesz = 0x900;
        std::memcpy(f.b.data() + sizeof(Elf64_Ehdr), f.ph, sizeof(f.ph));
        f.tag(DT_STRTAB, kVaddr + 0x950);
        expect_reject(f);
    }
    // Absent hash and invalid or missing DT_SYMENT must be rejected.
    {
        Fixture f;
        f.build();
        f.tag(DT_HASH, 0);
        auto *p = reinterpret_cast<Elf64_Dyn *>(f.b.data() + kDynamicOff);
        for (size_t i = 0; p[i].d_tag != DT_NULL; ++i)
            if (p[i].d_tag == DT_HASH)
                p[i].d_tag = DT_DEBUG;
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.tag(DT_SYMENT, sizeof(Elf64_Sym) - 1);
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        auto *p = reinterpret_cast<Elf64_Dyn *>(f.b.data() + kDynamicOff);
        for (size_t i = 0; p[i].d_tag != DT_NULL; ++i)
            if (p[i].d_tag == DT_SYMENT)
                p[i].d_tag = DT_DEBUG;
        expect_reject(f);
    }
    // Malformed name offsets, unterminated names, hash/symbol metadata in BSS/padding.
    {
        Fixture f;
        f.build();
        auto *s = reinterpret_cast<Elf64_Sym *>(f.b.data() + kSymOff);
        s[1].st_name = 0xffffffff;
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.b[kStrOff + f.strings.size() - 1] = 'X';
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.tag(DT_SYMTAB, kVaddr + kFileSize - 4);
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.tag(DT_HASH, kVaddr + kFileSize - 4);
        expect_reject(f);
    }
    // A defined symbol beyond PT_LOAD memory bounds is a load error.
    {
        Fixture f;
        f.build();
        auto *s = reinterpret_cast<Elf64_Sym *>(f.b.data() + kSymOff);
        s[1].st_value = kVaddr + kFileSize - 4;
        s[1].st_size = 16;
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.tag(DT_STRTAB, UINT64_MAX - 3);
        expect_reject(f);
    }
    {
        Fixture f;
        f.build();
        f.tag(DT_STRSZ, UINT64_MAX);
        expect_reject(f);
    }
    std::cout << "PASS: synthetic ELF bounded symbol/hash metadata, GNU/SysV variants, malformed cases and "
                 "relocation safety\n";
}
