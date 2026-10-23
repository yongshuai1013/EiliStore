// Self-authored, runtime-generated AArch64 ELF fixtures ONLY.
// The bounded dependency planner below is TEST-ONLY. Production does not recurse
// DT_NEEDED or promise dependency ordering; we explicitly load its planned order.
// No Apple binaries, WorkQueue emulation, credentials, devices or network calls.
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.h"
#include <algorithm>
#include <cassert>
#include <cstring>
#include <functional>
#include <iostream>
#include <string>
#include <unordered_map>
#include <vector>
#include <unistd.h>

namespace {
constexpr uint64_t kVA = 0x20000;
constexpr size_t kSize = 0x2000, kDyn = 0x100, kSym = 0x300, kStr = 0x500;
constexpr size_t kHash = 0x700, kRela = 0x740, kInit = 0x900, kArrayCode = 0x940;
constexpr size_t kFunction = 0xa00, kArray = 0xa80, kTraceSlot = 0xb00;
constexpr size_t kFunctionSlot = 0xb08, kExtraSlot = 0xb10, kTrace = 0xc00;
constexpr size_t kMaxNodes = 4, kMaxDepth = 4, kMaxBytes = kSize * kMaxNodes;
constexpr uint32_t kGlobal = 1, kWeak = 2, kFunctionType = 2, kObjectType = 1;
struct Trace { uint64_t count = 0; uint64_t events[16]{}; };
struct Image {
    std::string name;
    std::vector<uint8_t> bytes;
};
struct Options {
    std::string name;
    std::vector<std::string> needed;
    uint64_t id = 0;
    bool owns_trace = false;
    std::string exported_function;
    std::string required_function;
    std::string extra_import;
    bool extra_relocated = false;
    uint32_t extra_bind = kGlobal;
    uint32_t extra_type = kFunctionType;
};

template<class T> void put(std::vector<uint8_t> &b, size_t off, const T &value) {
    assert(off <= b.size() && sizeof(T) <= b.size() - off);
    std::memcpy(b.data() + off, &value, sizeof value);
}
void put_bytes(std::vector<uint8_t> &b, size_t off, const void *data, size_t n) {
    assert(off <= b.size() && n <= b.size() - off);
    std::memcpy(b.data() + off, data, n);
}
uint32_t literal_load(unsigned reg, size_t pc, size_t target) {
    const int64_t displacement = static_cast<int64_t>(target) - static_cast<int64_t>(pc);
    assert(displacement % 4 == 0 && displacement >= -(1 << 20) && displacement < (1 << 20));
    return 0x58000000u | ((uint32_t(displacement / 4) & 0x7ffffu) << 5) | reg;
}
void constructor(std::vector<uint8_t> &b, size_t off, uint64_t event) {
    assert(event < 65536);
    const uint32_t code[] = {
        literal_load(9, off, kTraceSlot),  // ldr x9, relocated trace GOT literal
        0xf940012a,                      // ldr x10,[x9] -- event count
        0xd280000b | (uint32_t(event) << 5), // mov x11,#event
        0x9100212c,                      // add x12,x9,#8
        0xf82a798b,                      // str x11,[x12,x10,lsl #3]
        0x9100054a,                      // add x10,x10,#1
        0xf900012a,                      // str x10,[x9]
        0xd65f03c0                       // ret
    };
    put_bytes(b, off, code, sizeof code);
}
Image make_image(const Options &o) {
    Image image{o.name, std::vector<uint8_t>(kSize)};
    auto &b = image.bytes;
    Elf64_Ehdr eh{};
    std::memcpy(eh.e_ident, "\x7f" "ELF\x02\x01\x01", 7);
    eh.e_type = 3; eh.e_machine = 183; eh.e_version = 1;
    eh.e_ehsize = sizeof eh; eh.e_phoff = sizeof eh;
    eh.e_phentsize = sizeof(Elf64_Phdr); eh.e_phnum = 2;
    Elf64_Phdr ph[2]{};
    ph[0].p_type = PT_LOAD; ph[0].p_flags = PF_R | PF_W | PF_X;
    ph[0].p_vaddr = kVA; ph[0].p_filesz = ph[0].p_memsz = kSize; ph[0].p_align = 0x10000;
    ph[1].p_type = PT_DYNAMIC; ph[1].p_offset = kDyn; ph[1].p_vaddr = kVA + kDyn;
    std::string strings(1, '\0');
    auto name = [&](const std::string &s) {
        const uint32_t off = static_cast<uint32_t>(strings.size());
        strings += s; strings.push_back('\0'); return off;
    };
    std::vector<Elf64_Sym> symbols(1);
    auto symbol = [&](const std::string &n, uint32_t bind, uint32_t type,
                      bool defined, uint64_t value, uint64_t size) {
        Elf64_Sym s{};
        s.st_name = name(n); s.st_info = uint8_t((bind << 4) | type);
        s.st_shndx = defined ? 1 : 0; s.st_value = value; s.st_size = size;
        symbols.push_back(s); return uint32_t(symbols.size() - 1);
    };
    const uint32_t trace = symbol("synthetic_trace", kGlobal, kObjectType,
        o.owns_trace, o.owns_trace ? kVA + kTrace : 0, o.owns_trace ? sizeof(Trace) : 0);
    if (!o.exported_function.empty())
        symbol(o.exported_function, kGlobal, kFunctionType, true, kVA + kFunction, 4);
    uint32_t imported_function = 0, extra = 0;
    if (!o.required_function.empty())
        imported_function = symbol(o.required_function, kGlobal, kFunctionType, false, 0, 0);
    if (!o.extra_import.empty())
        extra = symbol(o.extra_import, o.extra_bind, o.extra_type, false, 0, 0);
    std::vector<uint32_t> needed;
    for (const auto &n : o.needed) needed.push_back(name(n));
    std::vector<Elf64_Rela> relocs;
    auto relocation = [&](size_t off, uint32_t sym, uint32_t type, uint64_t addend = 0) {
        Elf64_Rela r{}; r.r_offset = kVA + off;
        r.r_info = (uint64_t(sym) << 32) | type; r.r_addend = addend; relocs.push_back(r);
    };
    relocation(kTraceSlot, trace, R_AARCH64_GLOB_DAT);
    relocation(kArray, 0, R_AARCH64_RELATIVE, kVA + kArrayCode);
    if (imported_function) relocation(kFunctionSlot, imported_function, R_AARCH64_JUMP_SLOT);
    if (extra && o.extra_relocated) relocation(kExtraSlot, extra, R_AARCH64_GLOB_DAT);
    std::vector<Elf64_Dyn> dyn;
    auto tag = [&](int64_t t, uint64_t value) {
        Elf64_Dyn d{}; d.d_tag = t; d.d_un.d_val = value; dyn.push_back(d);
    };
    tag(DT_SYMTAB, kVA + kSym); tag(DT_SYMENT, sizeof(Elf64_Sym));
    tag(DT_STRTAB, kVA + kStr); tag(DT_STRSZ, strings.size()); tag(DT_HASH, kVA + kHash);
    tag(DT_RELA, kVA + kRela); tag(DT_RELASZ, relocs.size() * sizeof(Elf64_Rela));
    tag(DT_INIT, kVA + kInit); tag(DT_INIT_ARRAY, kVA + kArray); tag(DT_INIT_ARRAYSZ, 8);
    for (uint32_t offset : needed) tag(DT_NEEDED, offset);
    tag(DT_NULL, 0);
    assert(kDyn + dyn.size() * sizeof(Elf64_Dyn) <= kSym);
    assert(kSym + symbols.size() * sizeof(Elf64_Sym) <= kStr);
    assert(kStr + strings.size() <= kHash);
    assert(kRela + relocs.size() * sizeof(Elf64_Rela) <= kInit);
    ph[1].p_filesz = ph[1].p_memsz = dyn.size() * sizeof(Elf64_Dyn);
    put(b, 0, eh); put_bytes(b, sizeof eh, ph, sizeof ph);
    put_bytes(b, kDyn, dyn.data(), dyn.size() * sizeof(Elf64_Dyn));
    put_bytes(b, kSym, symbols.data(), symbols.size() * sizeof(Elf64_Sym));
    put_bytes(b, kStr, strings.data(), strings.size());
    const uint32_t hash[] = {1, uint32_t(symbols.size())};
    put_bytes(b, kHash, hash, sizeof hash);
    // Zero buckets/chains already present; nchain supplies the exact dynsym count.
    put_bytes(b, kRela, relocs.data(), relocs.size() * sizeof(Elf64_Rela));
    const uint32_t ret = 0xd65f03c0; put(b, kFunction, ret);
    constructor(b, kInit, o.id * 10 + 1);
    constructor(b, kArrayCode, o.id * 10 + 2);
    return image;
}

// This parser is intentionally restricted to OUR tiny generated fixture layout,
// not an alternative production ELF parser or an arbitrary file/path resolver.
// Names only select an in-memory image in the explicit <=4-image allowlist.
std::vector<std::string> needed_names(const Image &image, bool &ok) {
    ok = false;
    const auto &b = image.bytes;
    if (b.size() != kSize) return {};
    Elf64_Phdr dynamic{}; std::memcpy(&dynamic, b.data() + sizeof(Elf64_Ehdr) + sizeof(Elf64_Phdr), sizeof dynamic);
    if (dynamic.p_type != PT_DYNAMIC || dynamic.p_offset != kDyn ||
        dynamic.p_filesz > kSym - kDyn || dynamic.p_filesz % sizeof(Elf64_Dyn)) return {};
    uint64_t strtab = 0, strsz = 0;
    bool terminated = false;
    std::vector<uint64_t> offsets;
    for (size_t off = kDyn; off < kDyn + dynamic.p_filesz; off += sizeof(Elf64_Dyn)) {
        Elf64_Dyn d{}; std::memcpy(&d, b.data() + off, sizeof d);
        if (d.d_tag == DT_NULL) { terminated = true; break; }
        if (d.d_tag == DT_STRTAB) strtab = d.d_un.d_val;
        if (d.d_tag == DT_STRSZ) strsz = d.d_un.d_val;
        if (d.d_tag == DT_NEEDED) offsets.push_back(d.d_un.d_val);
    }
    if (!terminated || strtab != kVA + kStr || !strsz || strsz > kHash - kStr || offsets.size() > kMaxNodes) return {};
    std::vector<std::string> names;
    for (uint64_t off : offsets) {
        if (off >= strsz) return {};
        const char *start = reinterpret_cast<const char *>(b.data() + kStr + off);
        const char *end = static_cast<const char *>(std::memchr(start, 0, strsz - off));
        if (!end || start == end) return {};
        names.emplace_back(start, end);
    }
    ok = true; return names;
}
bool plan(const std::vector<Image> &images, std::vector<size_t> &order,
          size_t max_depth = kMaxDepth, size_t max_bytes = kMaxBytes) {
    order.clear();
    if (images.empty() || images.size() > kMaxNodes) return false;
    std::unordered_map<std::string, size_t> indices;
    std::vector<std::vector<std::string>> dependencies;
    size_t bytes = 0;
    for (size_t i = 0; i < images.size(); ++i) {
        if (images[i].bytes.size() > kSize || bytes > max_bytes ||
            images[i].bytes.size() > max_bytes - bytes ||
            !indices.emplace(images[i].name, i).second) return false;
        bytes += images[i].bytes.size();
        bool ok; dependencies.push_back(needed_names(images[i], ok));
        if (!ok) return false;
    }
    std::vector<int> state(images.size());
    std::function<bool(size_t, size_t)> visit = [&](size_t i, size_t depth) {
        if (depth > max_depth || state[i] == 1) return false;
        if (state[i] == 2) return true;
        state[i] = 1;
        for (const auto &n : dependencies[i]) {
            const auto found = indices.find(n);
            if (found == indices.end() || !visit(found->second, depth + 1)) return false;
        }
        state[i] = 2; order.push_back(i); return true;
    };
    for (size_t i = 0; i < images.size(); ++i) {
        if (!visit(i, 1)) { order.clear(); return false; }
    }
    return true;
}
bool load(EmulatorVM &vm, const Image &image) {
    char path[] = "/tmp/eili-synthetic-graph-XXXXXX";
    const int fd = mkstemp(path); assert(fd >= 0);
    size_t done = 0;
    while (done < image.bytes.size()) {
        const ssize_t n = write(fd, image.bytes.data() + done, image.bytes.size() - done);
        assert(n > 0); done += size_t(n);
    }
    assert(close(fd) == 0);
    const bool ok = load_library_to_vm(&vm, path, image.name);
    assert(unlink(path) == 0);
    return ok;
}
bool load_graph(EmulatorVM &vm, const std::vector<Image> &images,
                size_t max_depth = kMaxDepth, size_t max_bytes = kMaxBytes) {
    std::vector<size_t> order;
    if (!plan(images, order, max_depth, max_bytes)) return false;
    for (size_t i : order) if (!load(vm, images[i])) return false;
    return true;
}
Trace trace(EmulatorVM &vm) {
    Trace t;
    const auto address = get_vm_symbol_address(&vm, "synthetic_trace"); assert(address);
    assert(uc_mem_read(vm.uc, address, &t, sizeof t) == UC_ERR_OK);
    return t;
}
void expect_trace(EmulatorVM &vm, const std::vector<uint64_t> &events) {
    const Trace t = trace(vm); assert(t.count == events.size());
    assert(std::equal(events.begin(), events.end(), t.events));
    for (size_t i = events.size(); i < 16; ++i) assert(t.events[i] == 0);
}
void dependency_order_and_relocations() {
    // Root is presented FIRST; its diamond has one shared dependency, loaded once.
    const std::vector<Image> images = {
        make_image({"root.so", {"left.so", "right.so"}, 3, false, "", "left_fn"}),
        make_image({"right.so", {"shared.so"}, 2, false, "right_fn", "shared_fn"}),
        make_image({"left.so", {"shared.so"}, 1, false, "left_fn", "shared_fn"}),
        make_image({"shared.so", {}, 0, true, "shared_fn"})
    };
    EmulatorVM vm; assert(load_graph(vm, images));
    assert(vm.loaded_libraries.size() == 4);
    const char *expected[] = {"shared.so", "left.so", "right.so", "root.so"};
    for (size_t i = 0; i < 4; ++i) assert(vm.loaded_libraries[i].name == expected[i]);
    relocate_all_vm_libraries(&vm); assert(vm.execution_error.empty());
    const uint64_t trace_address = get_vm_symbol_address(&vm, "synthetic_trace");
    for (const auto &lib : vm.loaded_libraries) {
        uint64_t slot = 0;
        assert(uc_mem_read(vm.uc, lib.base_address + kTraceSlot, &slot, 8) == UC_ERR_OK);
        assert(slot == trace_address); // cross-library GLOB_DAT / local definition
    }
    for (size_t i = 1; i < 4; ++i) {
        uint64_t slot = 0;
        assert(uc_mem_read(vm.uc, vm.loaded_libraries[i].base_address + kFunctionSlot, &slot, 8) == UC_ERR_OK);
        assert(slot == get_vm_symbol_address(&vm, i == 3 ? "left_fn" : "shared_fn"));
        assert(!vm.import_stubs.count(slot));
    }
    expect_trace(vm, {});
    assert(run_library_constructors(&vm));
    expect_trace(vm, {1, 2, 11, 12, 21, 22, 31, 32});
    assert(vm.execution_error.empty() && vm.fallback_import_calls.empty());
}
void invalid_graphs_never_load_or_construct() {
    const auto valid = make_image({"valid.so", {}, 0, true});
    auto reject = [&](const std::vector<Image> &images, size_t depth = kMaxDepth,
                      size_t bytes = kMaxBytes) {
        EmulatorVM vm;
        assert(!load_graph(vm, images, depth, bytes));
        assert(vm.loaded_libraries.empty() && vm.observed_pc_count == 0);
        assert(vm.imported_symbols.empty() && vm.fallback_import_calls.empty());
    };
    reject({make_image({"missing.so", {"absent.so"}, 0, true})});
    reject({make_image({"a.so", {"b.so"}, 0, true}), make_image({"b.so", {"a.so"}, 1})});
    reject({valid, valid}); // ambiguous duplicate names
    reject({valid, valid, valid, valid, valid}); // node bound
    auto oversized = valid; oversized.bytes.push_back(0); reject({oversized});
    reject({valid}, kMaxDepth, kSize - 1); // aggregate byte bound, no unsigned wrap
    reject({make_image({"a.so", {"b.so"}, 0}), make_image({"b.so", {}, 1, true})}, 1);
    auto malformed = valid;
    // DT_NEEDED offset outside bounded DT_STRSZ, even in a generated image.
    Elf64_Dyn bad{}; bad.d_tag = DT_NEEDED; bad.d_un.d_val = kSize;
    put(malformed.bytes, kDyn, bad); reject({malformed});
}
void preflight_blocks_all_constructors() {
    for (const std::string &name : {std::string("pthread_create"), std::string("synthetic_unknown_required"), std::string("synthetic_unknown_data")}) {
        for (bool relocated : {false, true}) {
            Options bad{"bad.so", {}, 1};
            bad.extra_import = name; bad.extra_relocated = relocated;
            bad.extra_type = name == "synthetic_unknown_data" ? kObjectType : kFunctionType;
            EmulatorVM vm;
            assert(load(vm, make_image({"earlier-valid.so", {}, 0, true})));
            assert(load(vm, make_image(bad)));
            relocate_all_vm_libraries(&vm); assert(vm.execution_error.empty());
            expect_trace(vm, {});
            assert(!run_library_constructors(&vm));
            assert(vm.execution_error == "Unsupported required guest import before constructors");
            expect_trace(vm, {}); // neither earlier DT_INIT nor ANY DT_INIT_ARRAY ran
            assert(vm.observed_pc_count == 0 && !vm.constructor_context.active);
            assert(vm.fault.present && vm.fault.reason == EmulatorVM::FaultReason::functionImport);
            assert(!vm.fault.has_constructor && !vm.fault.has_guest_pc);
            for (const auto &calls : vm.fallback_import_calls) assert(calls.second == 0);
            if (relocated && bad.extra_type == kFunctionType) {
                assert(vm.imported_symbols.count(name));
                assert(vm.fallback_import_calls.at(name) == 0); // registered is NOT implemented
            }
            if (!relocated) assert(!vm.imported_symbols.count(name));
            assert(!run_library_constructors(&vm)); // sticky refusal, no retry execution
            expect_trace(vm, {});
        }
    }
}
void optional_and_supported_import_controls() {
    for (bool weak : {false, true}) {
        Options o{"control.so", {}, 0, true};
        o.extra_import = weak ? "pthread_create" : "malloc";
        o.extra_bind = weak ? kWeak : kGlobal;
        o.extra_relocated = true;
        EmulatorVM vm; assert(load(vm, make_image(o)));
        relocate_all_vm_libraries(&vm); assert(vm.execution_error.empty());
        assert(run_library_constructors(&vm)); expect_trace(vm, {1, 2});
        // Weak optional symbols are not exercised or claimed implemented.
        for (const auto &calls : vm.fallback_import_calls) assert(calls.second == 0);
    }
}
} // namespace
int main() {
    dependency_order_and_relocations();
    invalid_graphs_never_load_or_construct();
    preflight_blocks_all_constructors();
    optional_and_supported_import_controls();
    std::cout << "PASS: bounded TEST-ONLY DT_NEEDED diamond planning, real relocations/DT_INIT/init-array order, and whole-VM required-import preflight (not production recursive loading or Apple login)\n";
}
