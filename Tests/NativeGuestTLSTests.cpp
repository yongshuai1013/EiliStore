// Self-authored AArch64 only. No Apple binary, device or service is used.
#include "../Packages/AnisetteKit/Native/anisette_core_uc.cpp"
#include <cassert>
#include <iostream>

namespace {
constexpr uint64_t kCode = 0x12000000;
constexpr uint64_t kArray = 0x12010000;

void install_constructor(EmulatorVM &vm) {
    assert(vm.initialization_error == UC_ERR_OK);
    assert(uc_mem_map(vm.uc, kCode, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
    // Assembled independently with clang --target=aarch64-linux-gnu:
    // mrs x21,tpidr_el0; ldr x8,[x21,#0x28]; mov w0,#42; ret
    const uint32_t code[] = {0xD53BD055, 0xF94016A8, 0x52800540, 0xD65F03C0};
    assert(uc_mem_write(vm.uc, kCode, code, sizeof code) == UC_ERR_OK);
    assert(uc_mem_map(vm.uc, kArray, 0x1000, UC_PROT_READ | UC_PROT_WRITE) == UC_ERR_OK);
    assert(uc_mem_write(vm.uc, kArray, &kCode, sizeof kCode) == UC_ERR_OK);
    EmulatorVM::LibraryInfo lib{};
    lib.name = "libstoreservicescore.so"; // Synthetic context label, not an opened library.
    lib.init_array = kArray;
    lib.init_arraysz = sizeof(uint64_t);
    vm.loaded_libraries.push_back(lib);
}
uint64_t read_word(EmulatorVM &vm, uint64_t address) {
    uint64_t value = 0;
    assert(uc_mem_read(vm.uc, address, &value, sizeof value) == UC_ERR_OK);
    return value;
}
void valid_guard_and_isolation() {
    EmulatorVM vm;
    install_constructor(vm);
    uint64_t thread_pointer = 0;
    assert(uc_reg_read(vm.uc, UC_ARM64_REG_TPIDR_EL0, &thread_pointer) == UC_ERR_OK);
    assert(thread_pointer == kGuestTLSAddress);
    const uint64_t guard_address = thread_pointer + kGuestTLSStackGuardOffset;
    const uint64_t guard = read_word(vm, guard_address);
    assert(guard != 0 && kGuestTLSStackGuardOffset == 0x28);
    assert(vm.register_data_import("__stack_chk_guard") == guard_address);
    assert(vm.register_data_import("__stack_chk_guard") == guard_address);
    assert(!vm.fallback_data_imports.count("__stack_chk_guard"));
    assert(read_word(vm, guard_address) == guard);
    uc_mem_region *regions = nullptr;
    uint32_t count = 0;
    assert(uc_mem_regions(vm.uc, &regions, &count) == UC_ERR_OK);
    bool found = false;
    for (uint32_t i = 0; i < count; ++i) {
        if (regions[i].begin != kGuestTLSAddress) continue;
        found = true;
        assert(regions[i].end - regions[i].begin + 1 == kGuestTLSSize);
        assert(regions[i].perms == (UC_PROT_READ | UC_PROT_WRITE)); // Never executable.
    }
    uc_free(regions);
    assert(found);
    for (int i = 0; i < 2; ++i) {
        assert(run_library_constructors(&vm));
        uint64_t loaded = 0;
        assert(uc_reg_read(vm.uc, UC_ARM64_REG_X8, &loaded) == UC_ERR_OK && loaded == guard);
        assert(!vm.fault.present && vm.execution_error.empty());
        assert(run_vm_procedure(&vm, kCode, {}, 1000000, 16) == 42);
        assert(read_word(vm, guard_address) == guard);
    }
    EmulatorVM other;
    assert(other.initialization_error == UC_ERR_OK);
    const uint64_t other_guard = read_word(other, guard_address);
    const uint64_t marker = other_guard ^ UINT64_MAX;
    assert(uc_mem_write(vm.uc, guard_address, &marker, sizeof marker) == UC_ERR_OK);
    assert(read_word(other, guard_address) == other_guard); // Per-VM memory, no host TLS pointer.
}
void invalid_tls_retains_constructor_fault(bool protected_slot) {
    EmulatorVM vm;
    install_constructor(vm);
    if (protected_slot) {
        assert(uc_mem_protect(vm.uc, kGuestTLSAddress, kGuestTLSSize, UC_PROT_NONE) == UC_ERR_OK);
    } else {
        const uint64_t invalid_pointer = 0; // Deliberate synthetic input; NOT a claim about the phone.
        assert(uc_reg_write(vm.uc, UC_ARM64_REG_TPIDR_EL0, &invalid_pointer) == UC_ERR_OK);
    }
    assert(!run_library_constructors(&vm));
    assert(!vm.execution_error.empty());
    const auto &fault = vm.fault;
    assert(fault.present && fault.reason == EmulatorVM::FaultReason::engine);
    assert(fault.has_unicorn_code && fault.unicorn_code == UC_ERR_READ_PROT);
    assert(fault.has_guest_pc && fault.guest_pc == kCode + sizeof(uint32_t));
    assert(fault.has_constructor && fault.constructor_kind == EmulatorVM::ConstructorKind::initArray);
    assert(fault.constructor_index == 0);
    assert(fault.constructor_library == EmulatorVM::ConstructorLibrary::storeservicescore);
    assert(!vm.constructor_context.active && vm.execution_depth == 0);
    const auto json = diagnostic_error_json("fixed error", "libraryConstructors", false, 0, &fault);
    assert(json.find("\"fault_reason\":\"engine\"") != std::string::npos);
    assert(json.find("\"unicorn_code\":" + std::to_string(UC_ERR_READ_PROT)) != std::string::npos);
    assert(json.find("\"constructor_kind\":\"initArray\"") != std::string::npos);
    assert(json.find("\"constructor_index\":0") != std::string::npos);
    assert(json.find("\"guest_pc\":") != std::string::npos);
    uint64_t pointer = UINT64_MAX;
    assert(uc_reg_read(vm.uc, UC_ARM64_REG_TPIDR_EL0, &pointer) == UC_ERR_OK);
    assert(pointer == (protected_slot ? kGuestTLSAddress : 0)); // No silent repair at procedure entry.
}
void failed_initialization_cannot_execute() {
    EmulatorVM vm;
    install_constructor(vm);
    // Simulate a failed map/write/register/entropy initialization result.
    vm.initialization_error = UC_ERR_RESOURCE;
    assert(!run_library_constructors(&vm));
    assert(vm.execution_error == "Guest VM initialization failed");
    assert(vm.fault.reason == EmulatorVM::FaultReason::engine);
    assert(vm.fault.has_unicorn_code && vm.fault.unicorn_code == UC_ERR_RESOURCE);
    assert(!vm.fault.has_guest_pc);
}
}
int main() {
    valid_guard_and_isolation();
    invalid_tls_retains_constructor_fault(false);
    invalid_tls_retains_constructor_fault(true);
    failed_initialization_cannot_execute();
    std::cout << "PASS: single-guest TPIDR_EL0 stack guard, import consistency, isolation and preserved constructor faults (not full TLS or Apple login)\n";
}
