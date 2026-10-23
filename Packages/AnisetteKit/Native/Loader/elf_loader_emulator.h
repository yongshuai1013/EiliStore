//
//  elf_loader_emulator.h
//  AnisetteKit
//
//  Created by Magesh K on 17/08/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#ifndef ELF_LOADER_EMULATOR_H
#define ELF_LOADER_EMULATOR_H

#if defined(_WIN32) || defined(_MSC_VER)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <windows.h>
#endif

#include <stdint.h>
#include <stddef.h>
#include <string>
#include <vector>
#include <unordered_map>
#include <unicorn/unicorn.h>
#include "anisette_base.h"
#include "android_pthread_sync_types.h"

#define LOG_UC(...) anisetteCoreLog(__VA_ARGS__)

static const uint64_t kReturnAddress = 0xDEAD0000;
static const uint64_t kHeapAddress   = 0x48000000;
// Mobile budgets, not the desktop Unicorn defaults. Exhaustion must return
// an error/null guest allocation instead of growing the host without bounds.
static const uint32_t kHeapSize      = 32u * 1024u * 1024u;
static const uint32_t kTCGBufferSize = 8u * 1024u * 1024u;
static const uint64_t kStackAddress  = 0x70000000;
static const uint32_t kStackSize     = 2u * 1024u * 1024u;
static const uint64_t kImportAddress = 0x80000000;
static const uint32_t kImportSize    = 0x10000;

struct AndroidSystemProperties {
    const char *sdk_version  = "30";
    const char *release      = "11";
    const char *model        = "Pixel 5";
    const char *brand        = "google";
    const char *name         = "redfin";
    const char *device       = "redfin";
    const char *manufacturer = "Google";
    const char *fingerprint  = "google/redfin/redfin:11/RQ3A.211001.001/7641976:user/release-keys";
};

extern const AndroidSystemProperties kAndroidProperties;

class PageAllocator {
private:
    uint64_t base;
    uint64_t size;
    uint64_t offset;
    uint64_t alignment;

public:
    PageAllocator(uint64_t base_addr, uint64_t total_size, uint64_t align_bytes = 16)
        : base(base_addr), size(total_size), offset(0), alignment(align_bytes) {}

    uint64_t alloc(uint64_t bytes);
};

struct EmulatorVM {
    struct LibraryInfo {
        std::string name;
        uint64_t base_address;
        uint64_t min_vaddr;
        uint64_t max_vaddr;
        uint64_t dynamic_address;
        uint64_t symtab;
        uint64_t strtab;
        size_t   strsz;
        uint64_t rel;
        size_t   relsz;
        uint64_t rela;
        size_t   relasz;
        uint64_t jmprel;
        size_t   pltrelsz;
        uint64_t init_func;
        uint64_t init_array;
        size_t   init_arraysz;
        std::unordered_map<std::string, uint64_t> symbols;
        std::vector<std::string> needed_libs;
        std::vector<uint8_t> program_headers;
        uint16_t program_header_count = 0;
        uint64_t program_headers_guest = 0;
    };

    uc_engine *uc;
    uc_err initialization_error;
    // A guest ABI failure must not be mistaken for a successful X0 == 0.
    std::string execution_error;
    std::string dynamic_link_error;
    PageAllocator heap;
    PageAllocator library_alloc;
    
    std::unordered_map<std::string, uint64_t> imported_symbols;
    std::unordered_map<uint64_t, std::string> import_stubs;
    // Compatibility stubs are intentionally not counted as implemented ABI hooks.
    std::unordered_map<std::string, uint64_t> fallback_import_calls;
    // SideStore-style zero-filled guest objects, not real Android/C++ data ABIs.
    std::unordered_map<std::string, uint64_t> fallback_data_imports;
    uint64_t next_import_address;

    std::unordered_map<int, int> fd_map;
    int next_guest_fd;

    uint64_t errno_addr;
    uc_hook invalid_hook = 0;
    uc_hook import_hook = 0;
    uc_hook pc_trace_hook = 0;

    std::vector<LibraryInfo> loaded_libraries;
    AndroidGuestSyncState guest_sync;
    uint64_t module_iteration_trampoline = 0;

    EmulatorVM();
    ~EmulatorVM();

    uint64_t register_import(const std::string &name);
    uint64_t register_data_import(const std::string &name);
    uint64_t write_bytes(const uint8_t *data, size_t len);
    uint64_t write_string(const char *str);
};

void clear_active_vm();
bool load_library_to_vm(EmulatorVM *vm, const std::string &file_path, const std::string &so_name);
void relocate_all_vm_libraries(EmulatorVM *vm);
bool run_library_constructors(EmulatorVM *vm);
uint64_t get_vm_symbol_address(EmulatorVM *vm, const std::string &name);

int32_t run_vm_procedure(EmulatorVM *vm, uint64_t proc_addr, const std::vector<uint64_t> &args, uint64_t timeout_us = 0, size_t max_count = 0);

#endif /* ELF_LOADER_EMULATOR_H */
