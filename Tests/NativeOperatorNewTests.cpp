// Self-authored synthetic ARM64 only: no Apple library or account data.
#include "../Packages/AnisetteKit/Native/anisette_core_uc.cpp"
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp"
#include <cassert>
#include <cstdint>
#include <iostream>

namespace {
using VM = EmulatorVM;
constexpr uint64_t code = 0x12000000;
constexpr uint64_t marker = code + 0x800;
constexpr uint32_t untouched = 0x11223344;
uint64_t reg(VM &vm, int id) {
    uint64_t value = 0;
    assert(uc_reg_read(vm.uc, id, &value) == UC_ERR_OK);
    return value;
}
uint32_t read_marker(VM &vm) {
    uint32_t value = 0;
    assert(uc_mem_read(vm.uc, marker, &value, sizeof value) == UC_ERR_OK);
    return value;
}
void setup(VM &vm) {
    assert(vm.initialization_error == UC_ERR_OK);
    assert(uc_mem_map(vm.uc, code, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
    assert(uc_mem_write(vm.uc, marker, &untouched, sizeof untouched) == UC_ERR_OK);
    const uint32_t words[] = {
        0xAA1E03F3, // mov x19,x30
        0xD63F0020, // blr x1 (_Znwm)
        0x3900681F, // strb wzr,[x0,#0x1a] -- observed constructor pattern
        0xB9000043, // str w3,[x2] -- proves continuation only on success
        0xAA1303FE, // mov x30,x19
        0xD65F03C0  // ret (leave guest allocation in X0)
    };
    assert(uc_mem_write(vm.uc, code, words, sizeof words) == UC_ERR_OK);
}
void writable_guest(VM &vm, uint64_t ptr, uint64_t size) {
    assert(ptr >= kHeapAddress && ptr < kHeapAddress + kHeapSize);
    assert(size <= kHeapAddress + kHeapSize - ptr);
    assert(ptr % 64 == 0);
    uc_mem_region *regions = nullptr;
    uint32_t count = 0;
    assert(uc_mem_regions(vm.uc, &regions, &count) == UC_ERR_OK);
    bool found = false;
    for (uint32_t i = 0; i < count; ++i) {
        if (ptr >= regions[i].begin && ptr + size - 1 <= regions[i].end) {
            assert(regions[i].perms == (UC_PROT_READ | UC_PROT_WRITE));
            found = true;
        }
        if (regions[i].begin == 0) assert(regions[i].perms == UC_PROT_NONE);
    }
    uc_free(regions);
    assert(found);
}
void success_and_zero() {
    VM vm; setup(vm);
    const auto stub = vm.register_import("_Znwm");
    assert(stub && !vm.fallback_import_calls.count("_Znwm"));
    // Seed the future object so the guest strb, not initial zero memory, clears it.
    const uint8_t seed = 0x7f;
    assert(uc_mem_write(vm.uc, kHeapAddress + 0x1a, &seed, 1) == UC_ERR_OK);
    assert(run_vm_procedure(&vm, code, {0x20, stub, marker, 0xa5}, 0, 100) >= 0);
    const uint64_t ptr = reg(vm, UC_ARM64_REG_X0);
    writable_guest(vm, ptr, 0x20);
    assert(ptr == kHeapAddress && read_marker(vm) == 0xa5);
    uint8_t byte = 0xff;
    assert(uc_mem_read(vm.uc, ptr + 0x1a, &byte, 1) == UC_ERR_OK && byte == 0);
    assert(vm.execution_error.empty() && !vm.fault.present);
    assert(run_vm_procedure(&vm, stub, {0}, 0, 100) >= 0);
    const auto zero1 = reg(vm, UC_ARM64_REG_X0);
    assert(run_vm_procedure(&vm, stub, {0}, 0, 100) >= 0);
    const auto zero2 = reg(vm, UC_ARM64_REG_X0);
    writable_guest(vm, zero1, 1); writable_guest(vm, zero2, 1);
    assert(zero1 != zero2 && zero1 != ptr && zero2 != ptr);
    assert(uc_mem_write(vm.uc, zero1, &seed, 1) == UC_ERR_OK);
    assert(uc_mem_write(vm.uc, zero2, &seed, 1) == UC_ERR_OK);
    assert(!vm.fallback_import_calls.count("_Znwm"));
    // Do not silently claim overloads or array/delete ABI support.
    const auto other = vm.register_import("_Znam");
    assert(run_vm_procedure(&vm, other, {0x20}, 0, 100) == 0);
    assert(vm.fallback_import_calls.at("_Znam") == 1);
}
void failure(uint64_t size, bool exhaust) {
    VM vm; setup(vm);
    const auto stub = vm.register_import("_Znwm");
    if (exhaust) assert(vm.heap.alloc(kHeapSize) == kHeapAddress);
    const auto result = run_vm_procedure(&vm, code, {size, stub, marker, 0xa5}, 0, 100);
    assert(result == -1000);
    assert(vm.execution_error == "Guest operator new allocation failed");
    assert(vm.fault.present && vm.fault.reason == VM::FaultReason::libc);
    assert(vm.fault.has_guest_pc && vm.fault.guest_pc == stub);
    assert(vm.fault.has_unicorn_code && vm.fault.unicorn_code == UC_ERR_OK);
    assert(reg(vm, UC_ARM64_REG_PC) == stub && reg(vm, UC_ARM64_REG_X0) == size);
    assert(read_marker(vm) == untouched); // Neither offset-write nor continuation ran.
    assert(!vm.fallback_import_calls.count("_Znwm"));
    assert(run_vm_procedure(&vm, code, {0x20, stub, marker, 0xa5}, 0, 100) == -1000);
    assert(read_marker(vm) == untouched); // Sticky VM/provider failure prevents reuse.
    if (!exhaust) assert(vm.heap.alloc(0x20) == kHeapAddress);
}
void constructor_failure() {
    VM vm; setup(vm);
    const auto stub = vm.register_import("_Znwm");
    assert(vm.heap.alloc(kHeapSize) == kHeapAddress);
    // Literal loads make this constructor independent of procedure-entry args.
    const uint32_t prefix[] = {
        0x58000800, // ldr x0, [pc + 0x100]
        0x58000821, // ldr x1, [pc + 0x104] (literal at +0x108)
        0x58000842, // ldr x2, [pc + 0x108] (literal at +0x110)
        0x528014A3  // mov w3,#0xa5
    };
    uint32_t body[6]{};
    assert(uc_mem_read(vm.uc, code, body, sizeof body) == UC_ERR_OK);
    assert(uc_mem_write(vm.uc, code + sizeof prefix, body, sizeof body) == UC_ERR_OK);
    assert(uc_mem_write(vm.uc, code, prefix, sizeof prefix) == UC_ERR_OK);
    const uint64_t literals[] = {0x20, stub, marker};
    assert(uc_mem_write(vm.uc, code + 0x100, literals, sizeof literals) == UC_ERR_OK);
    VM::LibraryInfo lib{};
    lib.name = kADISymbols.lib_ssc; lib.base_address = code;
    lib.init_array = code + 0x200; lib.init_arraysz = sizeof(uint64_t);
    assert(uc_mem_write(vm.uc, lib.init_array, &code, sizeof code) == UC_ERR_OK);
    vm.loaded_libraries.push_back(lib);
    assert(!run_library_constructors(&vm));
    assert(vm.execution_error == "Guest operator new allocation failed");
    assert(vm.fault.reason == VM::FaultReason::libc && vm.fault.has_constructor);
    assert(vm.fault.constructor_kind == VM::ConstructorKind::initArray);
    assert(vm.fault.constructor_library == VM::ConstructorLibrary::storeservicescore);
    assert(read_marker(vm) == untouched);
    const auto json = diagnostic_error_json("failure", "libraryConstructors", false, 0, &vm.fault);
    assert(json.find("\"fault_reason\":\"libc\"") != std::string::npos);
}
void allocator_boundaries() {
    PageAllocator good(0x1000, 128, 64);
    assert(good.alloc(UINT64_MAX) == 0);
    assert(good.alloc(UINT64_MAX - 62) == 0);
    assert(good.alloc(129) == 0);
    assert(good.alloc(0) == 0x1000);
    assert(good.alloc(64) == 0x1040);
    assert(good.alloc(1) == 0 && good.alloc(0) == 0);
    PageAllocator exact(0x1000, 128, 64);
    assert(exact.alloc(128) == 0x1000 && exact.alloc(1) == 0);
    for (const auto alignment : {uint64_t(0), uint64_t(3), UINT64_MAX}) {
        PageAllocator invalid(0x1000, 128, alignment);
        assert(invalid.alloc(1) == 0 && invalid.alloc(0) == 0);
    }
    PageAllocator overflow(UINT64_MAX - 63, 128, 64);
    assert(overflow.alloc(1) == 0 && overflow.alloc(64) == 0);
    PageAllocator unaligned(0x1001, 128, 64);
    assert(unaligned.alloc(1) == 0);
    PageAllocator null_base(0, 128, 64);
    assert(null_base.alloc(1) == 0 && null_base.alloc(0) == 0);
    PageAllocator empty(0x1000, 0, 64);
    assert(empty.alloc(0) == 0);
}
}
int main() {
    allocator_boundaries(); success_and_zero();
    failure(UINT64_MAX, false); failure(UINT64_MAX - 62, false);
    failure(uint64_t(kHeapSize) + 1, false); failure(0x20, true); failure(0, true);
    constructor_failure();
    std::cout << "PASS: scalar guest _Znwm ABI, new(0), constructor offset-write and controlled allocation failure\n";
}
