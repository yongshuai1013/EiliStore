// Synthetic guest code/data only. This test never opens or executes Apple libraries.
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp"
#include <cassert>
#include <iostream>

static uint64_t call(EmulatorVM &vm, const char *name, std::vector<uint64_t> args = {}) {
    const uint64_t address = vm.register_import(name);
    assert(address);
    run_vm_procedure(&vm, address, args, 1000000, 1000);
    assert(vm.execution_error.empty());
    uint64_t result = 0;
    assert(uc_reg_read(vm.uc, UC_ARM64_REG_X0, &result) == UC_ERR_OK);
    return result;
}
int main() {
    EmulatorVM vm;
    assert(vm.initialization_error == UC_ERR_OK);
    // Failed guest allocations must not wrap padding/multiplication or try
    // to allocate a huge host vector after the bounded guest heap says no.
    assert(call(vm, "malloc", {UINT64_MAX}) == 0);
    assert(call(vm, "malloc", {kHeapSize}) == 0);
    assert(call(vm, "calloc", {UINT64_MAX, 2}) == 0);
    assert(call(vm, "calloc", {1, UINT64_MAX}) == 0);
    assert(call(vm, "calloc", {1, kHeapSize}) == 0);
    const auto allocation = call(vm, "calloc", {3, 4097});
    assert(allocation);
    uint8_t zeroed[3 * 4097];
    assert(uc_mem_read(vm.uc, allocation, zeroed, sizeof zeroed) == UC_ERR_OK);
    for (const auto byte : zeroed) assert(byte == 0);
    const uint8_t oldValue = 0xAB;
    assert(uc_mem_write(vm.uc, allocation, &oldValue, 1) == UC_ERR_OK);
    assert(call(vm, "realloc", {allocation, UINT64_MAX}) == 0);
    assert(call(vm, "realloc", {allocation, kHeapSize}) == 0);
    uint8_t retained = 0;
    assert(uc_mem_read(vm.uc, allocation, &retained, 1) == UC_ERR_OK && retained == oldValue);
    // realloc copies the exact requested allocation size, not padding or the
    // caller's larger request; the bump allocator leaves the original intact.
    const auto small = call(vm, "malloc", {4});
    assert(small);
    const uint8_t initial[] = {0x11, 0x22, 0x33, 0x44};
    assert(uc_mem_write(vm.uc, small, initial, sizeof initial) == UC_ERR_OK);
    uint8_t adjacent = 0xE7;
    assert(uc_mem_write(vm.uc, small + sizeof initial, &adjacent, 1) == UC_ERR_OK);
    const auto expanded = call(vm, "realloc", {small, 12});
    assert(expanded && expanded != small);
    uint8_t expandedBytes[12]{};
    assert(uc_mem_read(vm.uc, expanded, expandedBytes, sizeof expandedBytes) == UC_ERR_OK);
    for (size_t i = 0; i < sizeof initial; ++i) assert(expandedBytes[i] == initial[i]);
    for (size_t i = sizeof initial; i < sizeof expandedBytes; ++i) assert(expandedBytes[i] == 0);
    const auto shrunk = call(vm, "realloc", {expanded, 2});
    assert(shrunk && shrunk != expanded);
    uint8_t shrunkBytes[2]{};
    assert(uc_mem_read(vm.uc, shrunk, shrunkBytes, sizeof shrunkBytes) == UC_ERR_OK);
    assert(shrunkBytes[0] == initial[0] && shrunkBytes[1] == initial[1]);
    assert(call(vm, "realloc", {0x1234, 8}) == 0); // Not a malloc-family pointer.
    assert(call(vm, "realloc", {small, 0}) == 0); // No free support; old data remains.
    assert(vm.malloc_sizes.count(small) && vm.malloc_sizes.at(small) == sizeof initial);
    const uint64_t ioFailure = 0x50000000; // Unmapped guest source, tracked for this failure-path test.
    vm.malloc_sizes[ioFailure] = 4;
    // Force source IO failure while keeping a tracked pointer: realloc returns
    // null and does not discard the old allocation's metadata.
    assert(call(vm, "realloc", {ioFailure, 8}) == 0);
    assert(vm.malloc_sizes.count(ioFailure) && vm.malloc_sizes.at(ioFailure) == 4);
    const uint64_t code = 0x05000000;
    assert(uc_mem_map(vm.uc, code, 0x10000, UC_PROT_ALL) == UC_ERR_OK);
    const uint32_t instructions[] = {0xD2800540, 0xD65F03C0}; // mov x0,#42; ret
    assert(uc_mem_write(vm.uc, code, instructions, sizeof instructions) == UC_ERR_OK);
    EmulatorVM::LibraryInfo module{};
    module.name = "libsynthetic.so";
    module.symbols["synthetic_answer"] = code;
    vm.loaded_libraries.push_back(module);
    const auto path = vm.write_string("/guest/libsynthetic.so");
    const auto handle = call(vm, "dlopen", {path, 2});
    assert(handle == 2);
    const auto symbol = call(vm, "dlsym", {handle, vm.write_string("synthetic_answer")});
    assert(symbol == code);
    assert(run_vm_procedure(&vm, symbol, {}, 1000000, 1000) == 42);
    assert(call(vm, "dlclose", {handle}) == 0);
    const auto libc = call(vm, "dlopen", {vm.write_string("libc.so"), 2});
    assert(libc >= 0x1000);
    assert(call(vm, "dlsym", {libc, vm.write_string("strlen")}));
    assert(call(vm, "strlen", {vm.write_string("synthetic")}) == 9);
    assert(call(vm, "dlsym", {libc, vm.write_string("synthetic_answer")}) == 0);
    assert(call(vm, "dlerror") != 0);
    assert(call(vm, "dlerror") == 0);
    const auto libm = call(vm, "dlopen", {vm.write_string("libm.so"), 2});
    assert(call(vm, "dlsym", {libm, vm.write_string("strlen")}) == 0);
    assert(call(vm, "dlerror") != 0);
    const auto libdl = call(vm, "dlopen", {vm.write_string("libdl.so"), 2});
    assert(call(vm, "dlsym", {libdl, vm.write_string("dlopen")}));
    assert(call(vm, "dlsym", {libdl, vm.write_string("strlen")}) == 0);
    assert(call(vm, "dlerror") != 0);
    assert(call(vm, "dlopen", {vm.write_string("missing.so"), 2}) == 0);
    assert(call(vm, "dlerror") != 0);
    const auto importsBefore = vm.import_stubs.size();
    const auto missing = call(vm, "dlsym", {0, vm.write_string("missing_function")});
    assert(missing && vm.import_stubs.size() == importsBefore + 1);
    assert(vm.fallback_import_calls.at("missing_function") == 0);
    assert(run_vm_procedure(&vm, missing, {UINT64_MAX}, 1000000, 1000) == 0);
    assert(vm.execution_error.empty() && vm.fallback_import_calls.at("missing_function") == 1);
    assert(call(vm, "dlerror") == 0);
    const auto unknownDataLookup = call(vm, "dlsym", {0, vm.write_string("kCFDlsymName")});
    assert(unknownDataLookup && vm.import_stubs.at(unknownDataLookup) == "kCFDlsymName");
    assert(call(vm, "dlerror") == 0);
    assert(call(vm, "dlsym", {0, vm.write_string("synthetic_answer")}) == code);
    assert(call(vm, "dlsym", {999, vm.write_string("strlen")}) == 0);
    assert(call(vm, "dlerror") != 0);
    // Constructor failures must stop setup, not be ignored.
    vm.loaded_libraries[0].init_func = code + 0x20000; // deliberately unmapped
    assert(!run_library_constructors(&vm));
    assert(!vm.execution_error.empty());
    vm.execution_error.clear();
    const auto fallback = vm.register_import("unimplemented_function");
    assert(fallback && vm.execution_error.empty());
    assert(fallback == vm.register_import("unimplemented_function"));
    assert(run_vm_procedure(&vm, fallback, {123}, 1000000, 1000) == 0);
    assert(run_vm_procedure(&vm, fallback, {456}, 1000000, 1000) == 0);
    assert(vm.execution_error.empty() && vm.fallback_import_calls.at("unimplemented_function") == 2);
    assert(!supported_guest_import("unimplemented_function"));

    // Resolve synthetic ELF symbols, without opening or executing any vendor ELF.
    auto resolve = [&](const std::string &name, uint8_t info) {
        EmulatorVM::LibraryInfo synthetic{};
        Elf64_Sym sym{};
        sym.st_info = info;
        sym.st_name = 1;
        const std::string strings = std::string(1, '\0') + name + std::string(1, '\0');
        synthetic.symtab = vm.write_bytes(reinterpret_cast<const uint8_t *>(&sym), sizeof sym);
        synthetic.strtab = vm.write_bytes(reinterpret_cast<const uint8_t *>(strings.data()), strings.size());
        synthetic.strsz = strings.size();
        return vm_resolve_symbol(&vm, synthetic, 0);
    };
    const auto typed_function = resolve("unknown_typed_function", 0x12);
    assert(typed_function && vm.execution_error.empty());
    assert(run_vm_procedure(&vm, typed_function, {}, 1000000, 1000) == 0);
    assert(vm.fallback_import_calls.at("unknown_typed_function") == 1);
    assert(resolve("unknown_notype_function", 0x10) && vm.execution_error.empty());
    assert(resolve("synthetic_answer", 0x12) == code); // Real exports win.
    assert(resolve("weak_function", 0x22) != 0 && vm.execution_error.empty());
    assert(resolve("weak_object", 0x21) != 0 && vm.execution_error.empty());
    const auto functionCount = vm.import_stubs.size();
    const auto object = resolve("unknown_object", 0x11);
    assert(object && vm.execution_error.empty());
    assert(object >= kHeapAddress && object < kHeapAddress + kHeapSize);
    uint8_t placeholder[256];
    assert(uc_mem_read(vm.uc, object, placeholder, sizeof placeholder) == UC_ERR_OK);
    for (const auto value : placeholder) assert(value == 0);
    assert(vm.fallback_data_imports.at("unknown_object") == object);
    assert(!vm.fallback_import_calls.count("unknown_object"));
    assert(vm.import_stubs.size() == functionCount);
    const uint8_t marker = 0xA5;
    assert(uc_mem_write(vm.uc, object + 255, &marker, 1) == UC_ERR_OK);
    assert(resolve("unknown_object", 0x11) == object); // Stable per-VM symbol identity.
    assert(uc_mem_read(vm.uc, object + 255, placeholder, 1) == UC_ERR_OK && placeholder[0] == marker);
    for (const auto info : {0x16, 0x26, 0x13, 0x23, 0x1A}) {
        vm.execution_error.clear();
        const std::string name = "unknown_nonfunction_" + std::to_string(info);
        const auto fallbackSymbol = resolve(name, static_cast<uint8_t>(info));
        assert(fallbackSymbol && vm.execution_error.empty());
        assert(vm.import_stubs.at(fallbackSymbol) == name); // Generic fallback, NOT TLS support.
    }
    for (const auto name : {"_ZTVMissing", "_ZTINope", "_ZTSNope", "kCFMissing", "kAudioMissing",
                            "OBJC_Missing", "__CFConstantStringClassReference", "__sF", "environ",
                            "__stack_chk_guard", "__ctype_"}) {
        vm.execution_error.clear();
        const auto data = resolve(name, 0x10);
        assert(data && vm.execution_error.empty());
        assert(vm.fallback_data_imports.at(name) == data && !vm.import_stubs.count(data));
        uint8_t zeros[256];
        assert(uc_mem_read(vm.uc, data, zeros, sizeof zeros) == UC_ERR_OK);
        for (const auto value : zeros) assert(value == 0);
    }
    vm.execution_error.clear();
    assert(resolve("synthetic_answer", 0x16) == code && vm.execution_error.empty()); // Real exports win, as upstream.
    vm.execution_error.clear();
    const auto namedTLS = resolve("kCFTLS", 0x16);
    assert(namedTLS && namedTLS == vm.fallback_data_imports.at("kCFTLS")); // Heuristic classifies data, not TLS ABI.
    vm.execution_error.clear();
    assert(resolve("unknown_typed_function", 0x11) == typed_function && vm.execution_error.empty()); // First cached import wins.
    vm.execution_error.clear();
    assert(resolve("unknown_object", 0x12) == object && vm.execution_error.empty());
    vm.execution_error.clear();
    // Apply an actual synthetic GLOB_DAT relocation with an addend into a data
    // placeholder; no vendor library is loaded and no guest object is executed.
    EmulatorVM::LibraryInfo relocation{};
    relocation.name = "synthetic-data-relocation";
    relocation.base_address = code;
    Elf64_Sym dataSymbol{};
    dataSymbol.st_info = 0x11;
    dataSymbol.st_name = 1;
    const char dataStrings[] = "\0relocated_data\0";
    relocation.symtab = vm.write_bytes(reinterpret_cast<const uint8_t *>(&dataSymbol), sizeof dataSymbol);
    relocation.strtab = vm.write_bytes(reinterpret_cast<const uint8_t *>(dataStrings), sizeof dataStrings);
    relocation.strsz = sizeof dataStrings;
    Elf64_Rela dataRelocation{};
    dataRelocation.r_offset = 0x100;
    dataRelocation.r_info = R_AARCH64_GLOB_DAT;
    dataRelocation.r_addend = 8;
    relocation.rela = vm.write_bytes(reinterpret_cast<const uint8_t *>(&dataRelocation), sizeof dataRelocation);
    relocation.relasz = sizeof dataRelocation;
    apply_vm_relocations(&vm, relocation);
    assert(vm.execution_error.empty());
    uint64_t relocated = 0;
    assert(uc_mem_read(vm.uc, code + 0x100, &relocated, sizeof relocated) == UC_ERR_OK);
    assert(relocated == vm.fallback_data_imports.at("relocated_data") + 8);
    // Upstream skips unhandled relocations; the target is left untouched.
    const uint64_t canary = 0x123456789ABCDEF0ULL;
    assert(uc_mem_write(vm.uc, code + 0x108, &canary, sizeof canary) == UC_ERR_OK);
    dataRelocation.r_offset = 0x108;
    dataRelocation.r_info = 1028; // R_AARCH64_TLS_DTPMOD64, deliberately not implemented.
    assert(uc_mem_write(vm.uc, relocation.rela, &dataRelocation, sizeof dataRelocation) == UC_ERR_OK);
    apply_vm_relocations(&vm, relocation);
    assert(vm.execution_error.empty());
    assert(uc_mem_read(vm.uc, code + 0x108, &relocated, sizeof relocated) == UC_ERR_OK && relocated == canary);
    // Host allocation/name bounds remain. dlsym-style calls have no ELF type
    // metadata and may register a generic stub even for a data-looking name.
    assert(vm.register_data_import("") == 0 && !vm.execution_error.empty());
    vm.execution_error.clear();
    assert(vm.register_import("environ") == vm.fallback_data_imports.at("environ") && vm.execution_error.empty());
    const auto untypedDataName = vm.register_import("kCFDlsymUnknown");
    assert(untypedDataName && vm.import_stubs.at(untypedDataName) == "kCFDlsymUnknown");
    vm.execution_error.clear();
    vm.next_import_address = kImportAddress + kImportSize;
    assert(vm.register_import("exhausted_function") == 0 && !vm.execution_error.empty());
    std::cout << "PASS: synthetic guest lookup, constructors, SideStore fallbacks, cached symbols and ignored TLS relocations (not TLS support or login proof)\n";
}
