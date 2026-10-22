#ifndef ANDROID_MODULE_ITERATION_H
#define ANDROID_MODULE_ITERATION_H

// Include after elf_loader_emulator.h. The import router dispatches
// dl_iterate_phdr to hook_dl_iterate_phdr(vm); this changes PC and never starts
// a nested emulation run. The guest trampoline executes the callback via BLR.
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

static constexpr size_t kAndroidModuleIterationMaxModules = 64;
static constexpr size_t kAndroidModuleIterationMaxPhdrs = 1024;
static constexpr uint64_t kAndroidModuleIterationTrampolineAddress = 0x6f000000ULL;
static constexpr size_t kAndroidModuleIterationPageSize = 0x1000;

static inline bool android_module_iteration_fail(EmulatorVM *vm, const char *why) {
    if (vm) {
        vm->execution_error = std::string("dl_iterate_phdr: ") + why;
        if (vm->uc) uc_emu_stop(vm->uc);
    }
    return false;
}
static inline bool android_module_iteration_reg(EmulatorVM *vm, int reg, uint64_t &v) {
    if (!vm || !vm->uc || uc_reg_read(vm->uc, reg, &v) != UC_ERR_OK)
        return android_module_iteration_fail(vm, "register read failed");
    return true;
}
static inline bool android_module_iteration_write_guest(EmulatorVM *vm, uint64_t addr,
                                                         const void *src, size_t n) {
    if (!addr || !n || addr > UINT64_MAX - n ||
        uc_mem_write(vm->uc, addr, src, n) != UC_ERR_OK)
        return android_module_iteration_fail(vm, "guest metadata write failed");
    return true;
}

static inline bool android_module_iteration_readable(EmulatorVM *vm, uint64_t address, size_t bytes) {
    if (!address || !bytes || address > UINT64_MAX - bytes) return false;
    uc_mem_region *regions = nullptr;
    uint32_t count = 0;
    if (uc_mem_regions(vm->uc, &regions, &count) != UC_ERR_OK) return false;
    const uint64_t end = address + bytes;
    uint64_t cursor = address;
    while (cursor < end) {
        uint64_t next = cursor;
        for (uint32_t i = 0; i < count; ++i) {
            if (regions[i].begin <= cursor && regions[i].end >= cursor &&
                (regions[i].perms & UC_PROT_READ)) {
                next = regions[i].end == UINT64_MAX ? end : regions[i].end + 1;
                break;
            }
        }
        if (next == cursor) break;
        cursor = std::min(next, end);
    }
    if (regions) uc_free(regions);
    return cursor == end;
}

// Reproducible source: Tests/Fixtures/synthetic-module-iteration.S. The
// trampoline preserves x19-x24, LR, and 16-byte SP alignment; it invokes
// callback(&entry, 32, userdata), stops on any nonzero result, otherwise zero.
static const uint32_t kAndroidModuleIterationTrampolineWords[] = {
    0xA9BC53F3,0xA9015BF5,0xA90263F7,0xF9001BFE,
    0xAA0003F3,0xAA0103F4,0xAA0203F5,0xAA0303F6,
    0xD2800017,0xEB1602FF,0x54000102,0x8B1716A0,
    0xD2800401,0xAA1403E2,0xD63F0260,0x35000080,
    0x910006F7,0x17FFFFF8,0xD2800000,0xF9401BFE,
    0xA94263F7,0xA9415BF5,0xA8C453F3,0xD65F03C0,
};

static void hook_dl_iterate_phdr(EmulatorVM *vm) {
    if (!vm || !vm->uc) { android_module_iteration_fail(vm,"invalid VM"); return; }
    uint64_t callback=0, userdata=0;
    if (!android_module_iteration_reg(vm,UC_ARM64_REG_X0,callback) ||
        !android_module_iteration_reg(vm,UC_ARM64_REG_X1,userdata)) return;
    if (!callback) { android_module_iteration_fail(vm,"null callback"); return; }
    uc_mem_region *regions=nullptr; uint32_t region_count=0;
    if (uc_mem_regions(vm->uc,&regions,&region_count)!=UC_ERR_OK) {
        android_module_iteration_fail(vm,"cannot validate callback mapping"); return;
    }
    bool executable=false;
    for (uint32_t i=0;i<region_count;++i)
        if ((callback & 3) == 0 && callback <= UINT64_MAX - 4 &&
            callback >= regions[i].begin && callback + 3 <= regions[i].end &&
            (regions[i].perms&UC_PROT_EXEC)) {
            executable=true; break;
        }
    if (regions) uc_free(regions);
    if (!executable) { android_module_iteration_fail(vm,"callback is not executable guest memory"); return; }
    if (vm->loaded_libraries.size()>kAndroidModuleIterationMaxModules) {
        android_module_iteration_fail(vm,"module count exceeds 64"); return;
    }
    if (vm->loaded_libraries.empty()) {
        uint64_t zero=0;
        if (uc_reg_write(vm->uc,UC_ARM64_REG_X0,&zero)!=UC_ERR_OK)
            android_module_iteration_fail(vm,"return register write failed");
        return;
    }
    const size_t count=vm->loaded_libraries.size();
    uint64_t list=vm->heap.alloc(count*32);
    if (!list) { android_module_iteration_fail(vm,"entry allocation failed"); return; }
    for (size_t i=0;i<count;++i) {
        const auto &lib=vm->loaded_libraries[i];
        if (!lib.program_header_count || lib.program_header_count>kAndroidModuleIterationMaxPhdrs ||
            lib.program_headers.size()!=size_t(lib.program_header_count)*sizeof(Elf64_Phdr)) {
            android_module_iteration_fail(vm,"invalid ELF program-header metadata"); return;
        }
        if (lib.name.size() >= 4096) { android_module_iteration_fail(vm,"module name exceeds 4095 bytes"); return; }
        uint64_t name=vm->write_string(lib.name.c_str());
        if (!name) { android_module_iteration_fail(vm,"module name allocation failed"); return; }
        uint64_t phdr=lib.program_headers_guest;
        if (!phdr) {
            phdr=vm->write_bytes(lib.program_headers.data(),lib.program_headers.size());
            if (!phdr) { android_module_iteration_fail(vm,"program-header allocation failed"); return; }
        } else {
            std::vector<uint8_t> guest_headers(lib.program_headers.size());
            if (!android_module_iteration_readable(vm, phdr, guest_headers.size()) ||
                uc_mem_read(vm->uc,phdr,guest_headers.data(),guest_headers.size())!=UC_ERR_OK ||
                guest_headers!=lib.program_headers) {
                android_module_iteration_fail(vm,"invalid guest program-header metadata"); return;
            }
        }
        struct Entry { uint64_t addr,name,phdr; uint16_t phnum; uint8_t padding[6]; } entry{};
        static_assert(sizeof(Entry) == 32, "Android LP64 dl_phdr_info prefix");
        entry.addr=lib.base_address-lib.min_vaddr; entry.name=name; entry.phdr=phdr;
        entry.phnum=lib.program_header_count;
        if (!android_module_iteration_write_guest(vm,list+i*sizeof(entry),&entry,sizeof(entry))) return;
    }
    if (!vm->module_iteration_trampoline) {
        if (uc_mem_map(vm->uc,kAndroidModuleIterationTrampolineAddress,kAndroidModuleIterationPageSize,
                       UC_PROT_READ|UC_PROT_WRITE|UC_PROT_EXEC)!=UC_ERR_OK) {
            android_module_iteration_fail(vm,"trampoline mapping failed"); return;
        }
        if (uc_mem_write(vm->uc,kAndroidModuleIterationTrampolineAddress,
                         kAndroidModuleIterationTrampolineWords,sizeof(kAndroidModuleIterationTrampolineWords))!=UC_ERR_OK) {
            android_module_iteration_fail(vm,"trampoline write failed"); return;
        }
        if (uc_mem_protect(vm->uc,kAndroidModuleIterationTrampolineAddress,kAndroidModuleIterationPageSize,
                           UC_PROT_READ|UC_PROT_EXEC)!=UC_ERR_OK) {
            android_module_iteration_fail(vm,"trampoline protection failed"); return;
        }
        vm->module_iteration_trampoline=kAndroidModuleIterationTrampolineAddress;
    }
    uint64_t list_arg=list, count_arg=count, trampoline=vm->module_iteration_trampoline;
    if (uc_reg_write(vm->uc,UC_ARM64_REG_X2,&list_arg)!=UC_ERR_OK ||
        uc_reg_write(vm->uc,UC_ARM64_REG_X3,&count_arg)!=UC_ERR_OK ||
        uc_reg_write(vm->uc,UC_ARM64_REG_PC,&trampoline)!=UC_ERR_OK)
        android_module_iteration_fail(vm,"register write failed");
}
#endif
