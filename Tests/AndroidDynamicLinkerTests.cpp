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
    assert(call(vm, "dlsym", {0, vm.write_string("missing_function")}) == 0);
    assert(vm.import_stubs.size() == importsBefore);
    assert(call(vm, "dlerror") != 0);
    assert(call(vm, "dlsym", {0, vm.write_string("synthetic_answer")}) == code);
    assert(call(vm, "dlsym", {999, vm.write_string("strlen")}) == 0);
    assert(call(vm, "dlerror") != 0);
    // Constructor failures must stop setup, not be ignored.
    vm.loaded_libraries[0].init_func = code + 0x20000; // deliberately unmapped
    assert(!run_library_constructors(&vm));
    assert(!vm.execution_error.empty());
    vm.execution_error.clear();
    assert(vm.register_import("unimplemented_function") == 0);
    assert(!vm.execution_error.empty());
    // Even a fabricated import stub traps instead of returning fake success.
    vm.execution_error.clear();
    const auto trap = kImportAddress + kImportSize - 8;
    const uint32_t ret = 0xD65F03C0;
    assert(uc_mem_write(vm.uc, trap, &ret, sizeof ret) == UC_ERR_OK);
    vm.import_stubs[trap] = "unimplemented_function";
    assert(run_vm_procedure(&vm, trap, {}, 1000000, 1000) != 0);
    assert(!vm.execution_error.empty());
    std::cout << "PASS: synthetic guest module handles, scoped dlsym, dlerror, constructors and unknown-call failure\n";
}
