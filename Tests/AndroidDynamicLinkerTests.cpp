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
    assert(call(vm, "dlsym", {0, vm.write_string("environ")}) == 0);
    assert(call(vm, "dlerror") != 0);
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
        assert(resolve(name, static_cast<uint8_t>(info)) == 0 && !vm.execution_error.empty());
        assert(!vm.imported_symbols.count(name));
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
    assert(resolve("synthetic_answer", 0x16) == 0 && !vm.execution_error.empty()); // Export cannot hide TLS.
    vm.execution_error.clear();
    assert(resolve("kCFTLS", 0x16) == 0 && !vm.execution_error.empty()); // Name heuristic cannot hide TLS.
    vm.execution_error.clear();
    assert(!resolve("unknown_typed_function", 0x11) && !vm.execution_error.empty()); // Function/data conflict.
    vm.execution_error.clear();
    assert(!resolve("unknown_object", 0x12) && !vm.execution_error.empty());
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
    // Invalid allocation and direct function requests for data still fail closed.
    assert(vm.register_data_import("") == 0 && !vm.execution_error.empty());
    vm.execution_error.clear();
    assert(vm.register_import("environ") == 0 && !vm.execution_error.empty());
    vm.execution_error.clear();
    vm.next_import_address = kImportAddress + kImportSize;
    assert(vm.register_import("exhausted_function") == 0 && !vm.execution_error.empty());
    std::cout << "PASS: synthetic guest lookup, constructors, SideStore function/data fallbacks, relocations and TLS rejection (not login proof)\n";
}
