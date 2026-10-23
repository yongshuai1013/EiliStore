// Synthetic VM startup/execution only; this is not Apple login verification.
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.h"
#include <cassert>
#include <cstdint>
#include <iostream>

#if defined(__linux__)
#include <sys/resource.h>
#include <algorithm>

static void cap_address_space() {
    struct rlimit limit{};
    assert(getrlimit(RLIMIT_AS, &limit) == 0);
    const rlim_t cap = static_cast<rlim_t>(256) * 1024 * 1024;
    if (limit.rlim_cur > cap) {
        limit.rlim_cur = cap;
        // Preserve rlim_max exactly: never raise or otherwise modify the hard limit.
        assert(setrlimit(RLIMIT_AS, &limit) == 0);
    }
}
#endif

int main() {
#if defined(__linux__)
    cap_address_space();
#endif
    EmulatorVM vm;
    assert(vm.uc != nullptr);
    assert(vm.initialization_error == UC_ERR_OK);

    uint32_t tcg_buffer_size = 0;
    assert(uc_ctl_get_tcg_buffer_size(vm.uc, &tcg_buffer_size) == UC_ERR_OK);
    assert(tcg_buffer_size == kTCGBufferSize);
    assert(kHeapSize == 32u * 1024 * 1024);
    assert(kStackSize == 2u * 1024 * 1024);
    uc_mem_region *regions = nullptr;
    uint32_t region_count = 0;
    assert(uc_mem_regions(vm.uc, &regions, &region_count) == UC_ERR_OK);
    bool heap_found = false, stack_found = false;
    for (uint32_t i = 0; i < region_count; ++i) {
        const auto &region = regions[i];
        if (region.begin == kHeapAddress) {
            heap_found = true;
            assert(region.end - region.begin + 1 == kHeapSize);
            assert(region.perms == (UC_PROT_READ | UC_PROT_WRITE));
        }
        if (region.begin == kStackAddress) {
            stack_found = true;
            assert(region.end - region.begin + 1 == kStackSize);
            assert(region.perms == (UC_PROT_READ | UC_PROT_WRITE));
        }
    }
    uc_free(regions);
    assert(heap_found && stack_found);

    constexpr uint64_t code_address = 0x100000;
    assert(uc_mem_map(vm.uc, code_address, 0x1000, UC_PROT_READ | UC_PROT_WRITE | UC_PROT_EXEC) == UC_ERR_OK);
    // mov w0, #42; ret — self-authored ARM64 instructions, no Apple code.
    const uint32_t code[] = {0x52800540u, 0xD65F03C0u};
    assert(uc_mem_write(vm.uc, code_address, code, sizeof(code)) == UC_ERR_OK);
    assert(run_vm_procedure(&vm, code_address, {}) == 42);
    assert(vm.execution_error.empty());
    std::cout << "PASS: synthetic ARM64 VM startup, 8 MiB TCG buffer, 32 MiB heap, 2 MiB stack (not Apple login)\n";
}
