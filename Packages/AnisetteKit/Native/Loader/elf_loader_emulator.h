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
// Heap + stack + TCG total 84 MiB (88,080,384 bytes), below 100 decimal MB.
// This is NOT a total-process RSS cap; libraries and other allocations add more.
static const uint32_t kHeapSize      = 64u * 1024u * 1024u;
static const uint32_t kTCGBufferSize = 16u * 1024u * 1024u;
static const uint64_t kStackAddress  = 0x70000000;
static const uint32_t kStackSize     = 4u * 1024u * 1024u;
static_assert(uint64_t(kHeapSize) + kStackSize + kTCGBufferSize <= 100000000ULL,
              "Configured VM startup budgets must stay within 100 MB (not total RSS)");
static const uint64_t kImportAddress = 0x80000000;
static const uint32_t kImportSize    = 0x10000;

// Single emulated thread, stack protector only; not a Bionic TCB/pthread ABI.
// Separate from libraries, heap, stack, errno and module-iteration trampoline.
static const uint64_t kGuestTLSAddress = 0x60000000;
static const uint32_t kGuestTLSSize = 0x1000;
static const uint64_t kGuestTLSStackGuardOffset = 5 * sizeof(uint64_t); // Bionic arm64 +0x28

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
        size_t   symbol_count = 0;
        std::vector<std::pair<uint64_t, uint64_t>> load_ranges; // [vaddr, vaddr+memsz)
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
    enum class FaultReason {
        none, engine, unexpectedReturn, functionImport, dataImport, fallbackReturn,
        libc, pthread, moduleIteration, constructorRead, invalidProcedure, preexistingError
    };
    enum class ConstructorKind { none, dtInit, initArray };
    enum class ConstructorLibrary { other, storeservicescore, coreadi };
    static constexpr size_t kPCTraceCapacity = 16;
    enum class ResolutionSource {
        unresolved, definedSymbol, selfSymbol, librarySymbol, convertedSymbol, functionStub, dataFallback
    };
    struct CxaAtexitSlot {
        uint64_t address = 0;
        uint64_t code_begin = 0;
        uint64_t code_end = 0;
        ResolutionSource source = ResolutionSource::unresolved;
    };
    // Only relocation-identified __cxa_atexit slots in storeservicescore.
    std::vector<CxaAtexitSlot> cxa_atexit_slots;
    struct CxaAtexitBranch {
        bool present = false;
        bool has_got_value = false;
        bool registered_stub = false;
        uint64_t branch_pc = 0;
        uint64_t target = 0;
        uint64_t got_address = 0;
        uint64_t got_value = 0;
        ResolutionSource source = ResolutionSource::unresolved;
    } pending_cxa_branch;
    void observe_cxa_atexit_branch(uint64_t pc);
    static const char *resolution_source_name(ResolutionSource source);
    struct FetchSnapshot {
        bool present = false;
        uint64_t address = 0;
        size_t count = 0;
        uint64_t pcs[kPCTraceCapacity] = {};
        CxaAtexitBranch cxa_branch;
    } pending_fetch;
    struct ReadProtectionSnapshot {
        bool present = false;
        uint64_t address = 0;
        uint32_t size = 0;
        uint64_t pc = 0;
        uint64_t x1 = 0;
        uint64_t lr = 0;
        bool has_region = false;
        uint32_t region_id = 0;
        uint32_t permissions = 0;
    } pending_read_protection;
    struct FaultSnapshot {
        bool present = false;
        bool has_unicorn_code = false;
        bool has_guest_pc = false;
        bool has_constructor = false;
        int32_t unicorn_code = 0;
        uint64_t guest_pc = 0;
        uint64_t constructor_index = 0;
        FaultReason reason = FaultReason::none;
        ConstructorKind constructor_kind = ConstructorKind::none;
        ConstructorLibrary constructor_library = ConstructorLibrary::other;
        FetchSnapshot fetch;
        ReadProtectionSnapshot read_protection;
    } fault;
    struct ConstructorContext {
        bool active = false;
        ConstructorKind kind = ConstructorKind::none;
        ConstructorLibrary library = ConstructorLibrary::other;
        uint64_t index = 0;
    } constructor_context;
    uint32_t execution_depth = 0;

    // Observed hook PCs, not a call stack or proof that an instruction retired.
    // Both indices stay bounded even across arbitrarily long guest procedures.
    uint64_t observed_pcs[kPCTraceCapacity] = {};
    size_t observed_pc_count = 0;
    size_t observed_pc_next = 0;
    void observe_pc(uint64_t pc);
    void capture_fetch_unmapped(uint64_t address);

    // Allocation-free fixed vocabulary. First fault wins across nested execution.
    void record_fault(FaultReason reason, bool has_code = false, int32_t code = 0,
                      bool has_pc = false, uint64_t pc = 0);
    void complete_fault(uc_err code, bool has_pc, uint64_t pc);
    static const char *fault_reason_name(FaultReason reason);
    static const char *constructor_kind_name(ConstructorKind kind);
    static const char *constructor_library_name(ConstructorLibrary library);
    // A guest ABI failure must not be mistaken for a successful X0 == 0.
    std::string execution_error;
    std::string dynamic_link_error;
    PageAllocator heap;
    PageAllocator library_alloc;
    // Exact requested sizes for guest malloc-family pointers only. Other heap
    // users retain the allocator's existing bump-allocation semantics.
    std::unordered_map<uint64_t, uint64_t> malloc_sizes;
    
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
    uc_hook read_protection_hook = 0;
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
