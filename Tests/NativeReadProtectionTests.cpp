// Synthetic ARM64 read-protection diagnostics only; no Apple binary or account data.
#include "../Packages/AnisetteKit/Native/anisette_core_uc.cpp"
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp"
#include <cassert>
#include <cstdint>
#include <iostream>

namespace {
using VM = EmulatorVM;
constexpr uint64_t code = 0x12000000;
constexpr uint64_t target = 0x13000000;

VM::LibraryInfo scoped_library(uint64_t base = code) {
    VM::LibraryInfo lib{};
    lib.name = kADISymbols.lib_ssc;
    lib.base_address = base;
    return lib;
}

void allow_capture(VM &vm) {
    vm.execution_depth = 1;
    vm.constructor_context.active = true;
    vm.constructor_context.kind = VM::ConstructorKind::initArray;
    vm.constructor_context.library = VM::ConstructorLibrary::storeservicescore;
    vm.constructor_context.index = 47;
    vm.loaded_libraries.push_back(scoped_library());
}

bool callback(VM &vm, uint64_t address) {
    return hook_mem_read_protection(vm.uc, UC_MEM_READ_PROT, address, 8, 0, &vm);
}

void test_direct_callback_scope() {
    {
        VM vm;
        assert(vm.initialization_error == UC_ERR_OK);
        assert(uc_mem_map(vm.uc, target, 0x1000, UC_PROT_WRITE) == UC_ERR_OK);
        allow_capture(vm);
        assert(!callback(vm, target));
        const auto first = vm.pending_read_protection;
        assert(first.present && first.address == target && first.size == 8);
        assert(!callback(vm, target + 8));
        assert(vm.pending_read_protection.address == first.address);
        assert(vm.pending_read_protection.pc == first.pc && vm.pending_read_protection.lr == first.lr);
    }
    {
        VM vm;
        allow_capture(vm);
        vm.fault.present = true;
        assert(!callback(vm, target));
        assert(!vm.pending_read_protection.present);
    }
    for (int exclusion = 0; exclusion < 5; ++exclusion) {
        VM vm;
        allow_capture(vm);
        switch (exclusion) {
            case 0: vm.constructor_context.library = VM::ConstructorLibrary::other; break;
            case 1: vm.constructor_context.kind = VM::ConstructorKind::dtInit; break;
            case 2: vm.constructor_context.index = 46; break;
            case 3: vm.constructor_context.active = false; break;
            case 4: vm.execution_depth = 0; break;
        }
        assert(!callback(vm, target));
        assert(!vm.pending_read_protection.present);
    }
}

void run_case(bool protected_read) {
    VM vm;
    assert(vm.initialization_error == UC_ERR_OK);
    assert(uc_mem_map(vm.uc, code, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
    assert(uc_mem_map(vm.uc, target, 0x1000, protected_read ? UC_PROT_WRITE : UC_PROT_READ) == UC_ERR_OK);
    uint32_t value = 0xfeedbeef;
    assert(uc_mem_write(vm.uc, target, &value, sizeof value) == UC_ERR_OK);
    // Preserve caller LR in X19, load X1, then BL helper. Actual helper LR is code+12.
    // Restore caller LR and zero W0 before returning; never loop on the BL return PC.
    const uint32_t instructions[] = {
        0xAA1E03F3, 0x58000801, 0x94000006, 0xAA1303FE,
        0x52800000, 0xD65F03C0, 0xD503201F, 0xD503201F,
        0xC85F7C20, 0xD65F03C0
    };
    assert(uc_mem_write(vm.uc, code, instructions, sizeof instructions) == UC_ERR_OK);
    assert(uc_mem_write(vm.uc, code + 0x104, &target, sizeof target) == UC_ERR_OK);
    VM::LibraryInfo lib = scoped_library();
    lib.init_array = code + 0x200;
    lib.init_arraysz = 48 * sizeof(uint64_t);
    std::vector<uint64_t> entries(48, 0);
    entries[47] = code;
    assert(uc_mem_write(vm.uc, lib.init_array, entries.data(), entries.size() * sizeof(uint64_t)) == UC_ERR_OK);
    vm.loaded_libraries.push_back(lib);
    const bool ok = run_library_constructors(&vm);
    if (!protected_read) {
        assert(ok && vm.execution_error.empty() && !vm.fault.present);
        assert(!vm.pending_read_protection.present);
        vm.pending_read_protection.present = true;
        vm.pending_read_protection.address = target;
        vm.execution_error.clear();
        assert(run_vm_procedure(&vm, code, {}) == 0);
        assert(!vm.pending_read_protection.present);
        return;
    }
    assert(!ok && vm.fault.present && vm.fault.reason == VM::FaultReason::engine);
    assert(vm.fault.has_unicorn_code && vm.fault.unicorn_code == UC_ERR_READ_PROT);
    const auto snapshot = vm.fault.read_protection;
    assert(snapshot.present && snapshot.address == target && snapshot.size == sizeof(uint64_t));
    assert(snapshot.pc == code + 0x20 && snapshot.x1 == target && snapshot.lr == code + 12);
    assert(snapshot.has_region && snapshot.permissions == UC_PROT_WRITE);
    uc_mem_region *regions = nullptr;
    uint32_t count = 0;
    assert(uc_mem_regions(vm.uc, &regions, &count) == UC_ERR_OK);
    uint32_t index = UINT32_MAX;
    uint32_t mapped_permissions = 0;
    for (uint32_t i = 0; i < count; ++i) if (regions[i].begin == target) {
        index = i;
        mapped_permissions = regions[i].perms;
    }
    uc_free(regions);
    assert(snapshot.region_id == index && mapped_permissions == UC_PROT_WRITE);
    const auto json = diagnostic_error_json("failure", "libraryConstructors", false, 0, &vm.fault);
    assert(json.find("\"read_protection\":{\"address\":" + std::to_string(target)) != std::string::npos);
    assert(json.find("\"size\":8") != std::string::npos);
    assert(json.find("\"pc\":" + std::to_string(code + 0x20)) != std::string::npos);
    assert(json.find("\"x1\":" + std::to_string(target)) != std::string::npos);
    assert(json.find("\"lr\":" + std::to_string(code + 12)) != std::string::npos);
    assert(json.find("\"permissions\":2") != std::string::npos);
    assert(json.find("stack") == std::string::npos && json.find("tls") == std::string::npos && json.find("feedbeef") == std::string::npos);
    uint64_t changed = 0xdeadbeef;
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_PC, &changed) == UC_ERR_OK);
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X1, &changed) == UC_ERR_OK);
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X30, &changed) == UC_ERR_OK);
    const auto after_emulation = diagnostic_error_json("failure", "libraryConstructors", false, 0, &vm.fault);
    assert(after_emulation == json);
    assert(vm.fault.read_protection.pc == snapshot.pc && vm.fault.read_protection.x1 == snapshot.x1 && vm.fault.read_protection.lr == snapshot.lr);
    auto out_of_scope = vm.fault;
    out_of_scope.constructor_index = 46;
    assert(diagnostic_error_json("failure", "libraryConstructors", false, 0, &out_of_scope).find("read_protection") == std::string::npos);
    assert(diagnostic_error_json("failure", "other", false, 0, &vm.fault).find("read_protection") == std::string::npos);
}
}
int main() {
    test_direct_callback_scope();
    run_case(false);
    run_case(true);
    std::cout << "PASS: scoped read-protection hook captures only fault metadata and preserves UC_ERR_READ_PROT\n";
}
