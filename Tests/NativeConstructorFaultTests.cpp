// Self-generated AArch64 instructions/ELF only. Never opens or executes Apple libraries.
#include "../Packages/AnisetteKit/Native/anisette_core_uc.cpp"
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <unistd.h>

namespace {
constexpr uint64_t kCode = 0x12000000;
constexpr uint64_t kArray = 0x12010000;
constexpr uint64_t kBadCode = 0x13000000; // Not the VM's normal return sentinel.
using Reason = EmulatorVM::FaultReason;
using Kind = EmulatorVM::ConstructorKind;
using Library = EmulatorVM::ConstructorLibrary;

void put(EmulatorVM &vm, uint64_t address, const void *data, size_t size) {
    assert(uc_mem_write(vm.uc, address, data, size) == UC_ERR_OK);
}
void code(EmulatorVM &vm, uint32_t instruction) {
    assert(uc_mem_map(vm.uc, kCode, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
    const uint32_t words[] = {instruction, 0xD65F03C0}; // instruction; ret
    put(vm, kCode, words, sizeof words);
}
EmulatorVM::LibraryInfo &library(EmulatorVM &vm, const char *name) {
    EmulatorVM::LibraryInfo lib{};
    lib.name = name;
    vm.loaded_libraries.push_back(lib);
    return vm.loaded_libraries.back();
}

void dt_init_fault_and_retry() {
    EmulatorVM vm;
    auto &lib = library(vm, "libstoreservicescore.so");
    lib.init_func = kBadCode;
    assert(!run_library_constructors(&vm));
    assert(vm.fault.present && vm.fault.reason == Reason::engine);
    assert(vm.fault.has_unicorn_code && vm.fault.unicorn_code == UC_ERR_FETCH_UNMAPPED);
    assert(vm.fault.has_guest_pc && vm.fault.guest_pc == kBadCode);
    assert(vm.fault.has_constructor && vm.fault.constructor_kind == Kind::dtInit);
    assert(vm.fault.constructor_index == 0 && vm.fault.constructor_library == Library::storeservicescore);
    assert(!vm.constructor_context.active && vm.execution_depth == 0);

    vm.execution_error.clear();
    code(vm, 0xD2800540); // mov x0,#42 -- nonzero constructor result remains success.
    lib.init_func = kCode;
    assert(run_library_constructors(&vm));
    assert(!vm.fault.present && !vm.constructor_context.active);
    assert(run_vm_procedure(&vm, kCode, {}, 1000000, 16) == 42);
    assert(!vm.fault.present);
}

void array_slot_and_engine_faults() {
    EmulatorVM vm;
    code(vm, 0xD65F03C0); // ret, made non-executable below: deterministic engine fault.
    assert(uc_mem_protect(vm.uc, kCode, 0x1000, UC_PROT_READ) == UC_ERR_OK);
    assert(uc_mem_map(vm.uc, kArray, 0x1000, UC_PROT_READ | UC_PROT_WRITE) == UC_ERR_OK);
    const uint64_t slots[] = {0, UINT64_MAX, kCode};
    put(vm, kArray, slots, sizeof slots);
    auto &lib = library(vm, "libCoreADI.so");
    lib.init_array = kArray;
    lib.init_arraysz = sizeof slots;
    assert(!run_library_constructors(&vm));
    assert(vm.fault.has_unicorn_code);
    assert(vm.fault.unicorn_code == UC_ERR_FETCH_PROT);
    assert(vm.fault.has_guest_pc && vm.fault.guest_pc == kCode);
    assert(vm.fault.constructor_kind == Kind::initArray && vm.fault.constructor_index == 2);
    assert(vm.fault.constructor_library == Library::coreadi && !vm.constructor_context.active);

    EmulatorVM read;
    code(read, 0xF9400000); // ldr x0,[x0]; constructor arguments are zero.
    library(read, "synthetic-other").init_func = kCode;
    assert(!run_library_constructors(&read));
    assert(read.fault.reason == Reason::engine && read.fault.unicorn_code == UC_ERR_READ_PROT);
    assert(read.fault.has_guest_pc && read.fault.guest_pc == kCode);
    assert(read.fault.constructor_library == Library::other);

    EmulatorVM array_read;
    auto &bad = library(array_read, "/private/not-for-diagnostics/synthetic");
    bad.init_array = kArray;
    bad.init_arraysz = sizeof(uint64_t);
    assert(!run_library_constructors(&array_read));
    assert(array_read.fault.reason == Reason::constructorRead);
    assert(array_read.fault.has_unicorn_code && array_read.fault.unicorn_code == UC_ERR_READ_UNMAPPED);
    assert(!array_read.fault.has_guest_pc);
    assert(array_read.fault.has_constructor && array_read.fault.constructor_index == 0);
    const auto json = diagnostic_error_json("fixed error", "libraryConstructors", false, 0, &array_read.fault);
    assert(json.find("\"constructor_library\":\"other\"") != std::string::npos);
    assert(json.find("/private") == std::string::npos && json.find("synthetic") == std::string::npos);
}

void callback_fault_codes_and_fixed_sources() {
    EmulatorVM vm;
    const auto strnlen_stub = vm.register_import("strnlen");
    assert(run_vm_procedure(&vm, strnlen_stub, {kBadCode, 1}, 1000000, 16) < 0);
    assert(vm.fault.reason == Reason::libc);
    // The first uc_mem_read code must survive outer uc_emu_start returning UC_ERR_OK.
    assert(vm.fault.has_unicorn_code && vm.fault.unicorn_code == UC_ERR_READ_UNMAPPED);
    assert(vm.fault.has_guest_pc && vm.fault.guest_pc == strnlen_stub);
    assert(!vm.fault.has_constructor);

    vm.execution_error.clear();
    assert(run_vm_procedure(&vm, strnlen_stub, {0, 1}, 1000000, 16) < 0);
    assert(vm.fault.reason == Reason::libc && vm.fault.unicorn_code == UC_ERR_OK);
    // Bounds/null checks do not fabricate an underlying uc_mem_read error.
    vm.execution_error.clear();
    const auto pthread_stub = vm.register_import("pthread_mutex_lock");
    assert(run_vm_procedure(&vm, pthread_stub, {1}, 1000000, 16) < 0);
    assert(vm.fault.reason == Reason::pthread && vm.fault.unicorn_code == UC_ERR_OK);
    vm.execution_error.clear();
    const auto module_stub = vm.register_import("dl_iterate_phdr");
    assert(run_vm_procedure(&vm, module_stub, {0, 0}, 1000000, 16) < 0);
    assert(vm.fault.reason == Reason::moduleIteration && vm.fault.unicorn_code == UC_ERR_OK);

    EmulatorVM imports;
    assert(imports.register_import("") == 0 && imports.fault.reason == Reason::functionImport);
    EmulatorVM data;
    assert(data.register_data_import("") == 0 && data.fault.reason == Reason::dataImport);
    EmulatorVM invalid;
    assert(run_vm_procedure(&invalid, 0, {}) == -1 && invalid.fault.reason == Reason::invalidProcedure);
}

void first_fault_and_shared_reset() {
    EmulatorVM vm;
    vm.record_fault(Reason::constructorRead, true, UC_ERR_READ_UNMAPPED);
    vm.record_fault(Reason::engine, true, UC_ERR_FETCH_UNMAPPED, true, kBadCode);
    vm.complete_fault(UC_ERR_OK, false, 0);
    assert(vm.fault.reason == Reason::constructorRead);
    assert(vm.fault.unicorn_code == UC_ERR_READ_UNMAPPED && !vm.fault.has_guest_pc);
    const auto json = diagnostic_error_json("fixed error", "libraryConstructors", false, 0, &vm.fault);
    assert(json.find("\"fault_reason\":\"constructorRead\"") != std::string::npos);
    assert(json.find("\"unicorn_code\":6") != std::string::npos);
    assert(json.find("guest_pc") == std::string::npos);

    reset_anisette_vm_uc();
    g_shared_vm = new EmulatorVM();
    g_shared_vm->record_fault(Reason::engine, true, UC_ERR_FETCH_UNMAPPED);
    reset_anisette_vm_uc();
    assert(g_shared_vm == nullptr && !g_libraries_initialized);
}

void fetch_target_is_not_returned_pc() {
    EmulatorVM vm;
    vm.constructor_context = {true, Kind::initArray, Library::storeservicescore, 0};
    vm.execution_depth = 1;
    vm.observe_pc(kCode);
    vm.observe_pc(kCode + 4);
    vm.capture_fetch_unmapped(kBadCode);
    vm.observe_pc(kCode + 8); // Later hooks cannot alter the captured trail.
    vm.capture_fetch_unmapped(kBadCode + 4);
    constexpr uint64_t returned_pc = 0x20000102a0d63;
    vm.record_fault(Reason::engine, true, UC_ERR_FETCH_UNMAPPED, true, returned_pc);
    vm.complete_fault(UC_ERR_OK, true, kCode);
    assert(vm.fault.guest_pc == returned_pc);
    assert(vm.fault.fetch.present && vm.fault.fetch.address == kBadCode);
    assert(vm.fault.fetch.count == 2 && vm.fault.fetch.pcs[0] == kCode && vm.fault.fetch.pcs[1] == kCode + 4);
    const auto json = diagnostic_error_json("fixed error", "libraryConstructors", false, 0, &vm.fault);
    assert(json.find("\"fetch_address\":" + std::to_string(kBadCode)) != std::string::npos);
    assert(json.find("\"guest_pc\":" + std::to_string(returned_pc)) != std::string::npos);
    assert(json.find("\"pc_trail\":[" + std::to_string(kCode) + "," + std::to_string(kCode + 4) + "]") != std::string::npos);
    assert(diagnostic_error_json("fixed error", "provisionStart", false, 0, &vm.fault).find("fetch_address") == std::string::npos);
    vm.fault.reason = Reason::libc;
    assert(diagnostic_error_json("fixed error", "libraryConstructors", false, 0, &vm.fault).find("pc_trail") == std::string::npos);
}
bool synthetic_fetch_with_different_return_pc(uc_engine *uc, uc_mem_type type,
                                             uint64_t address, int, int64_t, void *context) {
    assert(type == UC_MEM_FETCH_UNMAPPED);
    static_cast<EmulatorVM *>(context)->capture_fetch_unmapped(address);
    // Test injection only: force a distinct return-time register observation.
    // This does not claim Unicorn naturally reproduces the device's PC behavior.
    const uint64_t returned_pc = 0x20000102a0d63;
    assert(uc_reg_write(uc, UC_ARM64_REG_PC, &returned_pc) == UC_ERR_OK);
    uc_emu_stop(uc);
    return false;
}
void fetch_callback_to_return_pc_separation() {
    EmulatorVM vm;
    assert(uc_hook_del(vm.uc, vm.invalid_hook) == UC_ERR_OK);
    assert(uc_hook_add(vm.uc, &vm.invalid_hook, UC_HOOK_MEM_FETCH_UNMAPPED,
        reinterpret_cast<void *>(synthetic_fetch_with_different_return_pc), &vm, 1, 0) == UC_ERR_OK);
    library(vm, "libstoreservicescore.so").init_func = kBadCode;
    assert(!run_library_constructors(&vm));
    assert(vm.fault.reason == Reason::engine && vm.fault.unicorn_code == UC_ERR_FETCH_UNMAPPED);
    assert(vm.fault.fetch.present && vm.fault.fetch.address == kBadCode && vm.fault.fetch.count == 0);
    assert(vm.fault.has_guest_pc && vm.fault.guest_pc == 0x20000102a0d63);
    assert(vm.fault.guest_pc != vm.fault.fetch.address);
}
void actual_fetch_hook_wrap_reset_isolation() {
    EmulatorVM vm;
    assert(uc_mem_map(vm.uc, kCode, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
    std::vector<uint32_t> words(24, 0xD503201F); // nop, then ldr x16,literal; br x16.
    words.push_back(0x58000050);
    words.push_back(0xD61F0200);
    put(vm, kCode, words.data(), words.size() * sizeof(uint32_t));
    put(vm, kCode + words.size() * sizeof(uint32_t), &kBadCode, sizeof(kBadCode));
    library(vm, "libstoreservicescore.so").init_func = kCode;
    assert(!run_library_constructors(&vm));
    assert(vm.fault.unicorn_code == UC_ERR_FETCH_UNMAPPED && vm.fault.fetch.present);
    assert(vm.fault.fetch.address == kBadCode && vm.fault.fetch.count == 16);
    for (size_t i = 0; i < 16; ++i) assert(vm.fault.fetch.pcs[i] == kCode + (10 + i) * 4);
    assert(vm.observed_pc_count == 16 && vm.observed_pc_next < 16);
    const auto saved = vm.fault;
    assert(run_vm_procedure(&vm, kCode, {}) == -1000);
    assert(vm.fault.fetch.address == saved.fetch.address && vm.fault.fetch.count == saved.fetch.count);
    for (size_t i = 0; i < 16; ++i) assert(vm.fault.fetch.pcs[i] == saved.fetch.pcs[i]);

    EmulatorVM isolated;
    library(isolated, "libCoreADI.so").init_func = kBadCode;
    assert(!run_library_constructors(&isolated));
    assert(isolated.fault.fetch.present && isolated.fault.fetch.count == 0);
    assert(vm.fault.fetch.count == 16); // Same host thread, separate VM.

    vm.execution_error.clear();
    vm.loaded_libraries[0].init_func = kBadCode;
    assert(!run_library_constructors(&vm));
    assert(vm.fault.fetch.present && vm.fault.fetch.count == 0);
    vm.execution_error.clear();
    const uint32_t ret = 0xD65F03C0;
    put(vm, kCode + 0x200, &ret, sizeof ret);
    assert(run_vm_procedure(&vm, kCode + 0x200, {}, 1000000, 16) == 0);
    assert(!vm.fault.present && !vm.pending_fetch.present && vm.observed_pc_count == 1);
    vm.observe_pc(kCode + 0x300);
    vm.execution_depth = 1; // Nested entry retains outer history.
    assert(run_vm_procedure(&vm, kCode + 0x200, {}, 1000000, 16) == 0);
    assert(vm.observed_pc_count == 3 && vm.execution_depth == 1);
    vm.execution_depth = 0;

    EmulatorVM ordinary;
    assert(run_vm_procedure(&ordinary, kBadCode, {}, 1000000, 16) < 0);
    assert(!ordinary.fault.fetch.present);
    assert(diagnostic_error_json("fixed error", "provisionStart", false, 0, &ordinary.fault).find("pc_trail") == std::string::npos);
}
void earlier_fault_blocks_fetch_snapshot() {
    EmulatorVM vm;
    vm.constructor_context = {true, Kind::dtInit, Library::coreadi, 0};
    vm.execution_depth = 1;
    vm.observe_pc(kCode);
    vm.record_fault(Reason::libc, true, UC_ERR_READ_UNMAPPED, true, kCode);
    vm.capture_fetch_unmapped(kBadCode);
    vm.record_fault(Reason::engine, true, UC_ERR_FETCH_UNMAPPED, true, kBadCode);
    vm.complete_fault(UC_ERR_FETCH_UNMAPPED, true, kBadCode);
    assert(vm.fault.reason == Reason::libc && vm.fault.unicorn_code == UC_ERR_READ_UNMAPPED);
    assert(vm.fault.guest_pc == kCode && !vm.fault.fetch.present && !vm.pending_fetch.present);
}

// Two tiny ELF files are generated here, not copied from any vendor. The first
// DT_INIT is a single ldr x0,[x0], guaranteeing failure before any ADI symbols.
void write_synthetic_elf(const std::string &path, bool constructor) {
    std::vector<uint8_t> bytes(512, 0);
    Elf64_Ehdr eh{};
    std::memcpy(eh.e_ident, "\x7f" "ELF\x02\x01\x01", 7);
    eh.e_type = 3; eh.e_machine = 183; eh.e_version = 1;
    eh.e_ehsize = sizeof eh; eh.e_phoff = sizeof eh;
    eh.e_phentsize = sizeof(Elf64_Phdr); eh.e_phnum = 2;
    Elf64_Phdr ph[2]{};
    ph[0].p_type = PT_LOAD; ph[0].p_flags = 7;
    ph[0].p_vaddr = 0x20000; ph[0].p_filesz = bytes.size();
    ph[0].p_memsz = 0x1000; ph[0].p_align = 0x1000;
    ph[1].p_type = PT_DYNAMIC; ph[1].p_offset = 0x100; ph[1].p_vaddr = 0x20100;
    ph[1].p_filesz = ph[1].p_memsz = 2 * sizeof(Elf64_Dyn);
    Elf64_Dyn dyn[2]{};
    if (constructor) { dyn[0].d_tag = DT_INIT; dyn[0].d_un.d_val = 0x20180; }
    const uint32_t instruction = 0xF9400000;
    std::memcpy(bytes.data(), &eh, sizeof eh);
    std::memcpy(bytes.data() + sizeof eh, ph, sizeof ph);
    std::memcpy(bytes.data() + 0x100, dyn, sizeof dyn);
    std::memcpy(bytes.data() + 0x180, &instruction, sizeof instruction);
    std::ofstream output(path, std::ios::binary);
    output.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
    output.close();
    assert(output.good());
}
void actual_c_bridge_setup_propagation() {
    char directory[] = "/tmp/eili-generated-constructor-XXXXXX";
    assert(mkdtemp(directory));
    const std::string first = std::string(directory) + "/" + kADISymbols.lib_ssc;
    const std::string second = std::string(directory) + "/" + kADISymbols.lib_core_adi;
    write_synthetic_elf(first, true);
    write_synthetic_elf(second, false);
    const uint8_t identifier[16]{};
    const uint8_t synthetic[] = {0};
    for (int operation = 0; operation < 3; ++operation) {
        char *out = nullptr;
        int32_t result = operation == 0
            ? start_provision_uc(directory, directory, identifier, synthetic, 1, &out)
            : operation == 1
                ? get_anisette_headers_uc(directory, directory, identifier, synthetic, 1, &out)
                : end_provision_uc(directory, directory, identifier, 0, synthetic, 1, synthetic, 1, &out);
        assert(result == ANISETTE_ERR_LOADER_FAILED && out);
        const std::string json(out);
        free_c_string(out);
        assert(json.find("\"diagnostic_phase\":\"libraryConstructors\"") != std::string::npos);
        assert(json.find("\"unicorn_code\":" + std::to_string(UC_ERR_READ_PROT)) != std::string::npos);
        assert(json.find("\"guest_pc\":") != std::string::npos);
        assert(json.find("\"constructor_kind\":\"dtInit\"") != std::string::npos);
        assert(json.find("\"constructor_library\":\"storeservicescore\"") != std::string::npos);
        assert(json.find("\"fault_reason\":\"engine\"") != std::string::npos);
        assert(json.find(directory) == std::string::npos);
        assert(!g_libraries_initialized); // No ADILoadLibraryWithPath/ADIProvisioningStart.
    }
    reset_anisette_vm_uc();
    assert(unlink(first.c_str()) == 0 && unlink(second.c_str()) == 0);
    assert(rmdir(directory) == 0);
}
}
int main() {
    std::cout << "constructor fault test: DT_INIT and retry" << std::endl;
    dt_init_fault_and_retry();
    std::cout << "constructor fault test: array and engine" << std::endl;
    array_slot_and_engine_faults();
    std::cout << "constructor fault test: ABI callbacks" << std::endl;
    callback_fault_codes_and_fixed_sources();
    std::cout << "constructor fault test: first fault and reset" << std::endl;
    first_fault_and_shared_reset();
    std::cout << "constructor fault test: separate actual fetch target and returned PC" << std::endl;
    fetch_target_is_not_returned_pc();
    fetch_callback_to_return_pc_separation();
    std::cout << "constructor fault test: real fetch hook, wrap, reset and VM isolation" << std::endl;
    actual_fetch_hook_wrap_reset_isolation();
    std::cout << "constructor fault test: first error blocks later fetch snapshot" << std::endl;
    earlier_fault_blocks_fetch_snapshot();
    std::cout << "constructor fault test: actual C bridge" << std::endl;
    actual_c_bridge_setup_propagation();
    std::cout << "PASS: synthetic constructors, raw engine/callback faults, first-fault/reset and all C bridge setup paths\n";
}
