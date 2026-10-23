//
//  elf_loader_emulator.cpp
//  AnisetteKit
//
//  Created by Magesh K on 17/08/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#include "elf_loader_emulator.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#if defined(_WIN32) || defined(_MSC_VER)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <io.h>
#include <direct.h>
#include <process.h>
#include <winsock2.h>
#include <windows.h>
#define close _close
#define read _read
#define write _write
#define open _open
#define fstat _fstat64
#define lstat _stat64
#define stat _stat64
#define ftruncate _chsize
#define mkdir(p, m) _mkdir(p)
#define rmdir _rmdir
typedef int mode_t;

static inline int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    if (tv) {
        FILETIME ft;
        GetSystemTimeAsFileTime(&ft);
        ULARGE_INTEGER uli;
        uli.LowPart = ft.dwLowDateTime;
        uli.HighPart = ft.dwHighDateTime;
        uint64_t unix_time_100ns = uli.QuadPart - 116444736000000000ULL;
        tv->tv_sec = (long)(unix_time_100ns / 10000000ULL);
        tv->tv_usec = (long)((unix_time_100ns % 10000000ULL) / 10);
    }
    return 0;
}

#ifndef O_NOCTTY
#define O_NOCTTY 0
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 0
#endif
#ifndef O_SYNC
#define O_SYNC 0
#endif
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_BINARY
#ifdef _O_BINARY
#define O_BINARY _O_BINARY
#else
#define O_BINARY 0
#endif
#endif

#else
#include <unistd.h>
#include <sys/time.h>
#ifndef O_BINARY
#define O_BINARY 0
#endif
#endif
#include <string>
#include <vector>
#include <unordered_map>
#include <sstream>
#include <random>
#include <algorithm>

#include <unordered_set>
#include "android_libc_strings.h"
#include "android_pthread_sync.h"
#include "android_module_iteration.h"

const char *EmulatorVM::resolution_source_name(ResolutionSource source) {
    switch (source) {
    case ResolutionSource::definedSymbol: return "definedSymbol";
    case ResolutionSource::selfSymbol: return "selfSymbol";
    case ResolutionSource::librarySymbol: return "librarySymbol";
    case ResolutionSource::convertedSymbol: return "convertedSymbol";
    case ResolutionSource::functionStub: return "functionStub";
    case ResolutionSource::dataFallback: return "dataFallback";
    case ResolutionSource::unresolved: return "unresolved";
    }
    return "unresolved";
}

void EmulatorVM::observe_cxa_atexit_branch(uint64_t pc) {
    // Clear on every observed instruction: a later unrelated fetch must never
    // inherit an earlier PLT observation. No register bank or guest data dump.
    pending_cxa_branch = {};
    if (fault.present || !execution_depth || !constructor_context.active ||
        constructor_context.library != ConstructorLibrary::storeservicescore || pc < 12) return;
    if (observed_pc_count < 4) return;
    for (size_t i = 0; i < 4; ++i) {
        if (observed_pcs[(observed_pc_next + kPCTraceCapacity - 4 + i) % kPCTraceCapacity] != pc - 12 + i * 4) return;
    }
    for (const auto &slot : cxa_atexit_slots) {
        if (pc - 12 < slot.code_begin || pc > slot.code_end || slot.code_end - pc < 4) continue;
        uint32_t branch = 0;
        if (uc_mem_read(uc, pc, &branch, sizeof branch) != UC_ERR_OK || branch != 0xD61F0220) continue; // br x17
        uint32_t words[3]{};
        if (uc_mem_read(uc, pc - 12, words, sizeof words) != UC_ERR_OK) continue;
        // Standard AArch64 PLT only: adrp x16; ldr x17,[x16,#imm]; add x16,x16,#imm; br x17.
        if ((words[0] & 0x9F00001F) != 0x90000010 ||
            (words[1] & 0xFFC003FF) != 0xF9400211 ||
            (words[2] & 0xFFC003FF) != 0x91000210) continue;
        const uint64_t raw = ((uint64_t(words[0] >> 5) & 0x7FFFF) << 2) | ((words[0] >> 29) & 3);
        const int64_t pages = static_cast<int64_t>(raw ^ 0x100000) - 0x100000;
        const uint64_t page = ((pc - 12) & ~uint64_t(0xFFF)) + pages * 4096;
        const uint64_t load_offset = ((words[1] >> 10) & 0xFFF) * 8;
        const uint64_t add_offset = (words[2] >> 10) & 0xFFF;
        if (load_offset != add_offset || page + load_offset != slot.address) continue;
        CxaAtexitBranch result;
        if (uc_reg_read(uc, UC_ARM64_REG_X17, &result.target) != UC_ERR_OK) return;
        result.present = true;
        result.branch_pc = pc;
        result.got_address = slot.address;
        result.has_got_value = uc_mem_read(uc, slot.address, &result.got_value, sizeof result.got_value) == UC_ERR_OK;
        const auto stub = import_stubs.find(result.target);
        result.registered_stub = stub != import_stubs.end() && stub->second == "__cxa_atexit";
        result.source = slot.source; // Resolution provenance, not a guess based on target range.
        pending_cxa_branch = result;
        return;
    }
}

void EmulatorVM::observe_pc(uint64_t pc) {
    observed_pcs[observed_pc_next] = pc;
    observed_pc_next = (observed_pc_next + 1) % kPCTraceCapacity;
    if (observed_pc_count < kPCTraceCapacity) ++observed_pc_count;
}

void EmulatorVM::capture_fetch_unmapped(uint64_t address) {
    if (fault.present || pending_fetch.present || !execution_depth || !constructor_context.active) return;
    pending_fetch.present = true;
    pending_fetch.address = address; // Invalid-fetch callback target, not UC_ARM64_REG_PC.
    pending_fetch.count = observed_pc_count;
    if (pending_cxa_branch.present && observed_pc_count &&
        observed_pcs[(observed_pc_next + kPCTraceCapacity - 1) % kPCTraceCapacity] == pending_cxa_branch.branch_pc) {
        pending_fetch.cxa_branch = pending_cxa_branch;
    }
    const size_t start = (observed_pc_next + kPCTraceCapacity - observed_pc_count) % kPCTraceCapacity;
    for (size_t i = 0; i < observed_pc_count; ++i) {
        pending_fetch.pcs[i] = observed_pcs[(start + i) % kPCTraceCapacity];
    }
}

void EmulatorVM::record_fault(FaultReason reason, bool has_code, int32_t code,
                              bool has_pc, uint64_t pc) {
    if (fault.present) return;
    fault.present = true;
    fault.reason = reason;
    fault.has_unicorn_code = has_code && code >= 0;
    fault.unicorn_code = code;
    // A callback failure captures its actual instruction PC before outer emulation
    // can advance it. Array metadata reads outside execution have no guest PC.
    if (!has_pc && execution_depth && uc) {
        has_pc = uc_reg_read(uc, UC_ARM64_REG_PC, &pc) == UC_ERR_OK;
    }
    fault.has_guest_pc = has_pc;
    fault.guest_pc = pc;
    if (constructor_context.active) {
        fault.has_constructor = true;
        fault.constructor_kind = constructor_context.kind;
        fault.constructor_library = constructor_context.library;
        fault.constructor_index = constructor_context.index;
        if (reason == FaultReason::engine && has_code && code == UC_ERR_FETCH_UNMAPPED) {
            fault.fetch = pending_fetch;
        }
        if (reason == FaultReason::engine && has_code && code == UC_ERR_READ_PROT) {
            fault.read_protection = pending_read_protection;
        }
    }
}

void EmulatorVM::complete_fault(uc_err code, bool has_pc, uint64_t pc) {
    // Supplement a bounds/ABI stop with emulation's actual result, never replace
    // an earlier uc_mem_* error or a nested procedure's more specific snapshot.
    if (!fault.present) return;
    if (!fault.has_unicorn_code) {
        fault.has_unicorn_code = true;
        fault.unicorn_code = static_cast<int32_t>(code);
    }
    if (!fault.has_guest_pc && has_pc) {
        fault.has_guest_pc = true;
        fault.guest_pc = pc;
    }
}

const char *EmulatorVM::fault_reason_name(FaultReason reason) {
    switch (reason) {
    case FaultReason::engine: return "engine";
    case FaultReason::unexpectedReturn: return "unexpectedReturn";
    case FaultReason::functionImport: return "functionImport";
    case FaultReason::dataImport: return "dataImport";
    case FaultReason::fallbackReturn: return "fallbackReturn";
    case FaultReason::libc: return "libc";
    case FaultReason::pthread: return "pthread";
    case FaultReason::moduleIteration: return "moduleIteration";
    case FaultReason::constructorRead: return "constructorRead";
    case FaultReason::invalidProcedure: return "invalidProcedure";
    case FaultReason::preexistingError: return "preexistingError";
    case FaultReason::none: return nullptr;
    }
    return nullptr;
}

const char *EmulatorVM::constructor_kind_name(ConstructorKind kind) {
    switch (kind) {
    case ConstructorKind::dtInit: return "dtInit";
    case ConstructorKind::initArray: return "initArray";
    case ConstructorKind::none: return "dtInit"; // Not emitted without context.
    }
    return "dtInit";
}

const char *EmulatorVM::constructor_library_name(ConstructorLibrary library) {
    switch (library) {
    case ConstructorLibrary::storeservicescore: return "storeservicescore";
    case ConstructorLibrary::coreadi: return "coreadi";
    case ConstructorLibrary::other: return "other";
    }
    return "other";
}

static bool supported_guest_import(const std::string &name) {
    static const std::unordered_set<std::string> names = {
        "_Znwm",
        "__android_log_print",
        "__cxa_allocate_exception",
        "__cxa_begin_catch",
        "__cxa_guard_acquire",
        "__cxa_guard_release",
        "__dynamic_cast",
        "__errno",
        "__errno_location",
        "__memchr_chk",
        "__system_property_get",
        "arc4random",
        "atof",
        "atoi",
        "atoll",
        "calloc",
        "chmod",
        "close",
        "dl_iterate_phdr",
        "dlclose",
        "dlerror",
        "dlopen",
        "dlsym",
        "free",
        "fstat",
        "ftruncate",
        "getauxval",
        "gettimeofday",
        "lstat",
        "malloc",
        "memchr",
        "memcmp",
        "memcpy",
        "memmem",
        "memmove",
        "memset",
        "mkdir",
        "open",
        "pthread_mutex_destroy",
        "pthread_mutex_init",
        "pthread_mutex_lock",
        "pthread_mutex_trylock",
        "pthread_mutex_unlock",
        "pthread_rwlock_destroy",
        "pthread_rwlock_init",
        "pthread_rwlock_rdlock",
        "pthread_rwlock_tryrdlock",
        "pthread_rwlock_trywrlock",
        "pthread_rwlock_unlock",
        "pthread_rwlock_wrlock",
        "read",
        "realloc",
        "strcat",
        "strchr",
        "strcmp",
        "strcpy",
        "strcspn",
        "strlen",
        "strncat",
        "strncmp",
        "strncpy",
        "strnlen",
        "strpbrk",
        "strrchr",
        "strspn",
        "strstr",
        "strtod",
        "strtol",
        "strtoll",
        "strtoull",
        "umask",
        "write",
    };
    return names.count(name) != 0;
}

// Match SideStore's data-name classification. Other unresolved types use the
// generic function fallback; neither that nor an object placeholder implements TLS.
static bool guest_data_symbol_name(const std::string &symbol) {
    return symbol.rfind("_ZTV", 0) == 0 || symbol.rfind("_ZTI", 0) == 0 ||
        symbol.rfind("_ZTS", 0) == 0 || symbol.rfind("kCF", 0) == 0 ||
        symbol.rfind("kAudio", 0) == 0 || symbol.rfind("OBJC_", 0) == 0 ||
        symbol == "__CFConstantStringClassReference" || symbol == "__sF" ||
        symbol == "environ" || symbol == "__stack_chk_guard" || symbol == "__ctype_";
}

const AndroidSystemProperties kAndroidProperties;

static void trace_pc_hook(uc_engine *uc, uint64_t address, uint32_t size, void *user_data) {
    (void)uc; (void)size;
    static_cast<EmulatorVM *>(user_data)->observe_pc(address);
    static_cast<EmulatorVM *>(user_data)->observe_cxa_atexit_branch(address);
}

static bool hook_mem_read_protection(uc_engine *uc, uc_mem_type type,
                                     uint64_t address, int size, int64_t value,
                                     void *user_data) {
    (void)value;
    auto *vm = static_cast<EmulatorVM *>(user_data);
    if (type == UC_MEM_READ_PROT && vm && !vm->fault.present &&
        !vm->pending_read_protection.present &&
        vm->execution_depth && vm->constructor_context.active &&
        vm->constructor_context.kind == EmulatorVM::ConstructorKind::initArray &&
        vm->constructor_context.library == EmulatorVM::ConstructorLibrary::storeservicescore &&
        vm->constructor_context.index == 47 && size >= 0 &&
        static_cast<uint64_t>(size) <= UINT32_MAX) {
        EmulatorVM::ReadProtectionSnapshot snapshot{};
        snapshot.address = address;
        snapshot.size = static_cast<uint32_t>(size);
        if (uc_reg_read(uc, UC_ARM64_REG_PC, &snapshot.pc) == UC_ERR_OK &&
            uc_reg_read(uc, UC_ARM64_REG_X1, &snapshot.x1) == UC_ERR_OK &&
            uc_reg_read(uc, UC_ARM64_REG_X30, &snapshot.lr) == UC_ERR_OK) {
            uc_mem_region *regions = nullptr;
            uint32_t count = 0;
            if (uc_mem_regions(uc, &regions, &count) == UC_ERR_OK) {
                for (uint32_t i = 0; i < count; ++i) {
                    if (address >= regions[i].begin && address <= regions[i].end) {
                        snapshot.has_region = true;
                        snapshot.region_id = i;
                        snapshot.permissions = regions[i].perms;
                        break;
                    }
                }
                uc_free(regions);
            }
            snapshot.present = true;
            vm->pending_read_protection = snapshot;
        }
    }
    return false;
}

static bool hook_mem_invalid(uc_engine *uc, uc_mem_type type,
                             uint64_t address, int size, int64_t value,
                             void *user_data) {
    (void)size;
    (void)value;
    uint64_t page_addr = address & ~0xFFFFULL;

    if (type == UC_MEM_FETCH_UNMAPPED) {
        // Never write this trail to general logs. The fixed constructor fault
        // allowlist is its only export, after emulation returns its error code.
        static_cast<EmulatorVM *>(user_data)->capture_fetch_unmapped(address);
        uc_emu_stop(uc);
        return false;
    }

    if (page_addr == 0 && type == UC_MEM_WRITE_UNMAPPED) {
        LOG_UC("[Emulator - UC] Null pointer write to address 0x%llx - stopping VM safely\n",
               (unsigned long long)address);
        fflush(stdout);
        uc_emu_stop(uc);
        return false;
    }

    uint64_t crash_pc = 0;
    uc_reg_read(uc, UC_ARM64_REG_PC, &crash_pc);
    LOG_UC("[Emulator - UC] Dynamically mapping page at 0x%llx (type %d, target=0x%llx) PC=0x%llx\n",
           (unsigned long long)page_addr, (int)type, (unsigned long long)address, (unsigned long long)crash_pc);
    fflush(stdout);

    uc_err err = uc_mem_map(uc, page_addr, 0x10000, UC_PROT_ALL);
    if (err == UC_ERR_OK || err == UC_ERR_MAP) {
        return true;
    }

    uc_emu_stop(uc);
    return false;
}

uint64_t PageAllocator::alloc(uint64_t bytes) {
    // Reject malformed arenas/alignment before rounding or address arithmetic.
    // Failure never advances the bump pointer or terminates the host process.
    if (!alignment || (alignment & (alignment - 1)) || !base ||
        (base & (alignment - 1)) || size > UINT64_MAX - base) return 0;
    uint64_t align_mask = alignment - 1;
    if (bytes > UINT64_MAX - align_mask) return 0;
    uint64_t aligned_size = (bytes + align_mask) & ~align_mask;
    if (aligned_size == 0) aligned_size = alignment;

    if (offset > size || aligned_size > size - offset) {
        LOG_UC("[Emulator] Error: Out of virtual memory heap allocation range (needed %llu, offset %llu / %llu)!\n",
               (unsigned long long)aligned_size, (unsigned long long)offset, (unsigned long long)size);
        return 0;
    }
    uint64_t addr = base + offset;
    offset += aligned_size;
    return addr;
}

static void import_callback_router(uc_engine *uc, uint64_t address, uint32_t size, void *user_data);
static void hook_intr(uc_engine *uc, uint32_t intno, void *user_data);

EmulatorVM::EmulatorVM()
    : uc(nullptr),
      heap(kHeapAddress, kHeapSize, 64),
      library_alloc(0x10000000, 0x30000000, 0x10000),
      next_import_address(kImportAddress),
      next_guest_fd(10),
      initialization_error(UC_ERR_OK)
{
    uc_err err = uc_open(UC_ARCH_ARM64, UC_MODE_ARM, &uc);
    if (err != UC_ERR_OK) {
        LOG_UC("[Emulator] Failed on uc_open() with error returned: %u (%s)\n", err, uc_strerror(err));
        initialization_error = err;
        return;
    }
    auto initialized = [this](uc_err result) {
        if (result != UC_ERR_OK) initialization_error = result;
        return result == UC_ERR_OK;
    };
    // uc_open is lazy. The FIRST uc_mem_map initializes TCG, whose pinned
    // upstream default is 1 GiB on a 64-bit host and calls exit(1) if its
    // buffer cannot be mapped. Set the budget before any initializing API;
    // doing this after uc_mem_map only changes the reported setting.
    if (!initialized(uc_ctl_set_tcg_buffer_size(uc, kTCGBufferSize))) return;
    if (!initialized(uc_mem_map(uc, kHeapAddress, kHeapSize, UC_PROT_READ | UC_PROT_WRITE))) return;
    if (!initialized(uc_mem_map(uc, kStackAddress, kStackSize, UC_PROT_READ | UC_PROT_WRITE))) return;
    if (!initialized(uc_mem_map(uc, kImportAddress, kImportSize, UC_PROT_ALL))) return;
    if (!initialized(uc_mem_map(uc, 0x0, 0x10000, UC_PROT_NONE))) return;
    errno_addr = 0x3FF00000;
    if (!initialized(uc_mem_map(uc, errno_addr, 0x10000, UC_PROT_READ | UC_PROT_WRITE))) return;
    uint32_t zero = 0;
    if (!initialized(uc_mem_write(uc, errno_addr, &zero, sizeof(zero)))) return;
    // Bionic arm64 compiler-generated stack protectors load TPIDR_EL0 + 0x28.
    // Initialize once per VM, before any library constructor. Do not reset on
    // procedure entry, derive from host TLS, or repair invalid guest accesses.
    uint64_t stack_guard = 0;
    try {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
        arc4random_buf(&stack_guard, sizeof(stack_guard));
#elif defined(__linux__)
        int result;
        do { result = getentropy(&stack_guard, sizeof(stack_guard)); } while (result != 0 && errno == EINTR);
        if (result != 0) { initialization_error = UC_ERR_RESOURCE; return; }
#else
        std::random_device entropy;
        stack_guard = std::uniform_int_distribution<uint64_t>{}(entropy);
#endif
    } catch (...) {
        initialization_error = UC_ERR_RESOURCE;
        return;
    }
    if (!stack_guard) { initialization_error = UC_ERR_RESOURCE; return; }
    if (!initialized(uc_mem_map(uc, kGuestTLSAddress, kGuestTLSSize, UC_PROT_READ | UC_PROT_WRITE))) return;
    if (!initialized(uc_mem_write(uc, kGuestTLSAddress + kGuestTLSStackGuardOffset,
                                   &stack_guard, sizeof(stack_guard)))) return;
    if (!initialized(uc_reg_write(uc, UC_ARM64_REG_TPIDR_EL0, &kGuestTLSAddress))) return;
    if (!initialized(uc_hook_add(uc, &invalid_hook, UC_HOOK_MEM_UNMAPPED, (void *)hook_mem_invalid, this, 1, 0))) return;
    if (!initialized(uc_hook_add(uc, &read_protection_hook, UC_HOOK_MEM_READ_PROT,
                                 (void *)hook_mem_read_protection, this, 1, 0))) return;
    uc_hook intr_hook = 0;
    if (!initialized(uc_hook_add(uc, &intr_hook, UC_HOOK_INTR, (void *)hook_intr, this, 1, 0))) return;
    if (!initialized(uc_hook_add(uc, &import_hook, UC_HOOK_CODE, (void *)import_callback_router, this,
                kImportAddress, kImportAddress + kImportSize - 1))) return;
    if (!initialized(uc_hook_add(uc, &pc_trace_hook, UC_HOOK_CODE, (void *)trace_pc_hook, this, 1, 0))) return;
}

EmulatorVM::~EmulatorVM() {
    for (const auto &entry : fd_map) {
        if (entry.second >= 0) close(entry.second);
    }
    fd_map.clear();
    if (uc) {
        uc_close(uc);
        uc = nullptr;
    }
}

uint64_t EmulatorVM::register_import(const std::string &name) {
    auto it = imported_symbols.find(name);
    if (it != imported_symbols.end()) {
        return it->second;
    }

    if (name.empty() || name.size() >= 4096 ||
        next_import_address > kImportAddress + kImportSize - 8) {
        record_fault(FaultReason::functionImport);
        execution_error = "Invalid guest function import or exhausted import area: " + name;
        return 0;
    }
    uint64_t stub_addr = next_import_address;
    uint32_t ret_insn = 0xD65F03C0;
    const uc_err stub_error = uc ? uc_mem_write(uc, stub_addr, &ret_insn, sizeof(ret_insn)) : UC_ERR_HANDLE;
    if (!uc || stub_error != UC_ERR_OK) {
        record_fault(FaultReason::functionImport, uc != nullptr, stub_error);
        execution_error = "Cannot write guest import stub: " + name;
        return 0;
    }
    next_import_address += 8;
    if (!supported_guest_import(name)) {
        fallback_import_calls.emplace(name, 0);
        LOG_UC("[SideStore compatibility] Created unresolved-function guest stub: %s (not an implemented ABI)\n", name.c_str());
    }

    imported_symbols[name] = stub_addr;
    import_stubs[stub_addr] = name;

    return stub_addr;
}

uint64_t EmulatorVM::register_data_import(const std::string &name) {
    // Upstream uses one imported-symbol cache: the first resolution wins even
    // when another library declares the same name with a different symbol type.
    auto cached = imported_symbols.find(name);
    if (cached != imported_symbols.end()) return cached->second;
    if (name.empty() || name.size() >= 4096) {
        record_fault(FaultReason::dataImport);
        execution_error = "Invalid guest data import: " + name;
        return 0;
    }
    // Bionic copies the global guard value into its TLS stack-guard slot.
    // For our single guest thread, alias that one guest word so both access
    // forms agree. Never expose a host pointer or classify this as a dummy ABI.
    if (name == "__stack_chk_guard") {
        if (!uc || initialization_error != UC_ERR_OK) {
            record_fault(FaultReason::dataImport);
            execution_error = "Guest stack guard is not initialized";
            return 0;
        }
        const uint64_t address = kGuestTLSAddress + kGuestTLSStackGuardOffset;
        imported_symbols[name] = address;
        return address;
    }
    // Deliberately match upstream's fixed-size placeholder. This does not supply
    // a real vtable, CF object or Android runtime, and must not imply login success.
    const uint8_t zeros[256] = {};
    const uint64_t address = heap.alloc(sizeof zeros);
    const bool tried_write = uc && address;
    const uc_err data_error = tried_write ? uc_mem_write(uc, address, zeros, sizeof zeros) : UC_ERR_OK;
    if (!tried_write || data_error != UC_ERR_OK) {
        record_fault(FaultReason::dataImport, tried_write, data_error);
        execution_error = "Cannot allocate guest data placeholder: " + name;
        return 0;
    }
    imported_symbols[name] = address;
    fallback_data_imports[name] = address;
    LOG_UC("[SideStore compatibility] Created 256-byte zero-filled guest data placeholder: %s (not an implemented ABI)\n", name.c_str());
    return address;
}

uint64_t EmulatorVM::write_bytes(const uint8_t *data, size_t len) {
    if (!data || len == 0) return 0;
    uint64_t addr = heap.alloc(len + 16);
    if (!uc || !addr || uc_mem_write(uc, addr, data, len) != UC_ERR_OK) return 0;
    return addr;
}

uint64_t EmulatorVM::write_string(const char *str) {
    if (!str) return 0;
    size_t len = strlen(str) + 1;
    return write_bytes((const uint8_t *)str, len);
}

static EmulatorVM *g_active_vm = nullptr;
void clear_active_vm() { g_active_vm = nullptr; }

static void hook_intr(uc_engine *uc, uint32_t intno, void *user_data) {
    (void)user_data;
    uint64_t pc = 0;
    uc_reg_read(uc, UC_ARM64_REG_PC, &pc);
    LOG_UC("[Emulator] Interrupt %u at PC=0x%llx\n", intno, (unsigned long long)pc);
}

static void hook_malloc(EmulatorVM *vm) {
    uint64_t size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &size);
    uint64_t ptr = size > UINT64_MAX - 16 ? 0 : vm->heap.alloc(size + 16);
    if (ptr) vm->malloc_sizes[ptr] = size;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ptr);
}

static void hook_operator_new(EmulatorVM *vm) {
    // AArch64 _Znwm: unsigned long size in X0, guest pointer result in X0.
    // The mapped guest bump heap already provides >= max_align_t alignment.
    // alloc(0) reserves one aligned unit, preserving scalar new(0) semantics.
    // No host allocation, host pointer, array/delete or exception-runtime shim.
    auto fail = [vm](uc_err error, const char *message) {
        vm->record_fault(EmulatorVM::FaultReason::libc, error != UC_ERR_OK, error);
        vm->execution_error = message;
        uc_emu_stop(vm->uc);
    };
    uint64_t size = 0;
    const uc_err read_error = uc_reg_read(vm->uc, UC_ARM64_REG_X0, &size);
    if (read_error != UC_ERR_OK) {
        fail(read_error, "Cannot read guest operator new size");
        return;
    }
    const uint64_t ptr = vm->heap.alloc(size);
    if (!ptr) {
        // No guest C++ unwinder/new_handler contract exists here. Use the VM's
        // established provider-error path instead of returning null from throwing
        // new or throwing a host exception across the Unicorn callback boundary.
        fail(UC_ERR_OK, "Guest operator new allocation failed");
        return;
    }
    const uc_err write_error = uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ptr);
    if (write_error != UC_ERR_OK) fail(write_error, "Cannot return guest operator new pointer");
}

static void hook_calloc(EmulatorVM *vm) {
    uint64_t num = 0, size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &num);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &size);
    uint64_t ptr = 0;
    if (size == 0 || num <= (UINT64_MAX - 16) / size) {
        const uint64_t total = num * size;
        ptr = vm->heap.alloc(total + 16);
        if (ptr) vm->malloc_sizes[ptr] = total;
        // A failed guest allocation must not allocate a host vector anyway.
        // Zero in fixed chunks so temporary host memory stays bounded.
        const uint8_t zeros[4096] = {};
        for (uint64_t offset = 0; ptr && offset < total;) {
            const size_t count = static_cast<size_t>(std::min<uint64_t>(sizeof zeros, total - offset));
            if (uc_mem_write(vm->uc, ptr + offset, zeros, count) != UC_ERR_OK) {
                ptr = 0;
                break;
            }
            offset += count;
        }
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ptr);
}

static void hook_realloc(EmulatorVM *vm) {
    uint64_t ptr = 0, new_size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &new_size);
    uint64_t new_ptr = 0;
    if (new_size == 0) {
        // The heap is a bump allocator and cannot release the old block.
    } else if (ptr == 0) {
        if (new_size <= UINT64_MAX - 16) {
            new_ptr = vm->heap.alloc(new_size + 16);
            if (new_ptr) vm->malloc_sizes[new_ptr] = new_size;
        }
    } else {
        const auto old = vm->malloc_sizes.find(ptr);
        if (old != vm->malloc_sizes.end() && new_size <= UINT64_MAX - 16) {
            const uint64_t old_size = old->second;
            const uint64_t copy_size = std::min(old_size, new_size);
            new_ptr = vm->heap.alloc(new_size + 16);
            if (new_ptr) {
                uint8_t chunk[4096];
                bool copied = true;
                for (uint64_t offset = 0; offset < copy_size;) {
                    const size_t count = static_cast<size_t>(std::min<uint64_t>(sizeof chunk, copy_size - offset));
                    if (uc_mem_read(vm->uc, ptr + offset, chunk, count) != UC_ERR_OK ||
                        uc_mem_write(vm->uc, new_ptr + offset, chunk, count) != UC_ERR_OK) {
                        copied = false;
                        break;
                    }
                    offset += count;
                }
                if (copied) vm->malloc_sizes[new_ptr] = new_size;
                else new_ptr = 0; // Old allocation and its metadata remain valid.
            }
        }
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &new_ptr);
}

static void hook_free(EmulatorVM *vm) {
    uint64_t ret = 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_strlen(EmulatorVM *vm) {
    uint64_t str_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &str_ptr);
    if (!str_ptr) {
        uint64_t zero = 0;
        uc_reg_write(vm->uc, UC_ARM64_REG_X0, &zero);
        return;
    }
    uint64_t len = 0;
    char c = 0;
    while (true) {
        if (uc_mem_read(vm->uc, str_ptr + len, &c, 1) != UC_ERR_OK || c == '\0') break;
        len++;
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &len);
}

static void hook_strcmp(EmulatorVM *vm) {
    uint64_t s1_ptr = 0, s2_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &s1_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &s2_ptr);
    std::string s1, s2;
    char c = 0;
    if (s1_ptr) {
        while (uc_mem_read(vm->uc, s1_ptr++, &c, 1) == UC_ERR_OK && c != '\0') s1.push_back(c);
    }
    if (s2_ptr) {
        while (uc_mem_read(vm->uc, s2_ptr++, &c, 1) == UC_ERR_OK && c != '\0') s2.push_back(c);
    }
    int64_t cmp_res = (int64_t)s1.compare(s2);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &cmp_res);
}

static void hook_strncmp(EmulatorVM *vm) {
    uint64_t s1_ptr = 0, s2_ptr = 0, n = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &s1_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &s2_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &n);
    std::string s1, s2;
    char c = 0;
    if (s1_ptr) {
        for (uint64_t i = 0; i < n && uc_mem_read(vm->uc, s1_ptr + i, &c, 1) == UC_ERR_OK && c != '\0'; i++) s1.push_back(c);
    }
    if (s2_ptr) {
        for (uint64_t i = 0; i < n && uc_mem_read(vm->uc, s2_ptr + i, &c, 1) == UC_ERR_OK && c != '\0'; i++) s2.push_back(c);
    }
    int64_t cmp_res = (int64_t)s1.compare(s2);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &cmp_res);
}

static void hook_strcpy(EmulatorVM *vm) {
    uint64_t dst = 0, src = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &dst);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &src);
    char c = 0;
    uint64_t offset = 0;
    if (src && dst) {
        do {
            if (uc_mem_read(vm->uc, src + offset, &c, 1) != UC_ERR_OK) break;
            uc_mem_write(vm->uc, dst + offset, &c, 1);
            offset++;
        } while (c != '\0');
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &dst);
}

static void hook_strncpy(EmulatorVM *vm) {
    uint64_t dst = 0, src = 0, n = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &dst);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &src);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &n);
    char c = 0;
    bool null_reached = false;
    for (uint64_t i = 0; i < n; i++) {
        if (!null_reached) {
            if (uc_mem_read(vm->uc, src + i, &c, 1) == UC_ERR_OK) {
                if (c == '\0') null_reached = true;
            } else {
                null_reached = true;
                c = '\0';
            }
        } else {
            c = '\0';
        }
        uc_mem_write(vm->uc, dst + i, &c, 1);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &dst);
}

static void hook_memcpy(EmulatorVM *vm) {
    uint64_t dst = 0, src = 0, size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &dst);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &src);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &size);
    if (size > 0 && dst != 0 && src != 0) {
        std::vector<uint8_t> buf(size);
        uc_mem_read(vm->uc, src, buf.data(), size);
        uc_mem_write(vm->uc, dst, buf.data(), size);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &dst);
}

static void hook_memset(EmulatorVM *vm) {
    uint64_t dst = 0, val = 0, size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &dst);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &val);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &size);
    if (size > 0 && dst != 0) {
        std::vector<uint8_t> buf(size, (uint8_t)val);
        uc_mem_write(vm->uc, dst, buf.data(), size);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &dst);
}

static void hook_memcmp(EmulatorVM *vm) {
    uint64_t s1 = 0, s2 = 0, n = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &s1);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &s2);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &n);
    int64_t res = 0;
    if (n > 0 && s1 && s2) {
        std::vector<uint8_t> b1(n), b2(n);
        uc_mem_read(vm->uc, s1, b1.data(), n);
        uc_mem_read(vm->uc, s2, b2.data(), n);
        res = memcmp(b1.data(), b2.data(), n);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_memchr(EmulatorVM *vm) {
    uint64_t s = 0, c = 0, n = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &s);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &c);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &n);
    uint64_t res = 0;
    uint8_t target = (uint8_t)c;
    for (uint64_t i = 0; i < n; i++) {
        uint8_t byte = 0;
        if (uc_mem_read(vm->uc, s + i, &byte, 1) != UC_ERR_OK) break;
        if (byte == target) {
            res = s + i;
            break;
        }
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static int linux_to_darwin_open_flags(int linux_flags) {
    int darwin_flags = 0;
    int acc_mode = linux_flags & 3;
    if (acc_mode == 0) darwin_flags |= O_RDONLY;
    else if (acc_mode == 1) darwin_flags |= O_WRONLY;
    else if (acc_mode == 2) darwin_flags |= O_RDWR;

    if (linux_flags & 0x0040)  darwin_flags |= O_CREAT;
    if (linux_flags & 0x0080)  darwin_flags |= O_EXCL;
    if (linux_flags & 0x0100)  darwin_flags |= O_NOCTTY;
    if (linux_flags & 0x0200)  darwin_flags |= O_TRUNC;
    if (linux_flags & 0x0400)  darwin_flags |= O_APPEND;
    if (linux_flags & 0x0800)  darwin_flags |= O_NONBLOCK;
    if (linux_flags & 0x1000)  darwin_flags |= O_SYNC;
    if (linux_flags & 0x80000) darwin_flags |= O_CLOEXEC;

    return darwin_flags;
}

static void hook_open(EmulatorVM *vm) {
    uint64_t path_ptr = 0, flags = 0, mode = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &flags);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &mode);

    std::string path;
    char c = 0;
    if (path_ptr) {
        while (uc_mem_read(vm->uc, path_ptr++, &c, 1) == UC_ERR_OK && c != '\0') path.push_back(c);
    }

    int host_flags = linux_to_darwin_open_flags((int)flags);
    int host_fd = open(path.c_str(), host_flags, (mode_t)mode);
    int64_t guest_fd = -1;
    if (host_fd >= 0) {
        guest_fd = vm->next_guest_fd++;
        vm->fd_map[guest_fd] = host_fd;
        uint32_t zero_err = 0;
        uc_mem_write(vm->uc, vm->errno_addr, &zero_err, sizeof(zero_err));
    } else {
        uint32_t err = (uint32_t)errno;
        uc_mem_write(vm->uc, vm->errno_addr, &err, sizeof(err));
    }
    LOG_UC("[Hook] open('%s', linux=0x%x, mac=0x%x, mode=0%o) -> fd %lld (errno=%d)\n",
           path.c_str(), (int)flags, host_flags, (int)mode, (long long)guest_fd, errno);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &guest_fd);
}

static void hook_close(EmulatorVM *vm) {
    uint64_t guest_fd = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    int64_t res = 0;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end()) {
        close(it->second);
        vm->fd_map.erase(it);
    } else {
        res = -1;
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_read(EmulatorVM *vm) {
    uint64_t guest_fd = 0, buf_ptr = 0, count = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &buf_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &count);
    int64_t res = -1;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end()) {
        std::vector<uint8_t> tmp(count);
        ssize_t bytes_read = read(it->second, tmp.data(), count);
        if (bytes_read > 0) {
            uc_mem_write(vm->uc, buf_ptr, tmp.data(), bytes_read);
        }
        res = (int64_t)bytes_read;
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_write(EmulatorVM *vm) {
    uint64_t guest_fd = 0, buf_ptr = 0, count = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &buf_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &count);
    int64_t res = -1;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end()) {
        std::vector<uint8_t> tmp(count);
        uc_mem_read(vm->uc, buf_ptr, tmp.data(), count);
        res = (int64_t)write(it->second, tmp.data(), count);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_ftruncate(EmulatorVM *vm) {
    uint64_t guest_fd = 0, length = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &length);
    int64_t res = -1;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end()) {
        res = (int64_t)ftruncate(it->second, (off_t)length);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_mkdir(EmulatorVM *vm) {
    uint64_t path_ptr = 0, mode = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &mode);
    std::string path;
    char c = 0;
    if (path_ptr) {
        while (uc_mem_read(vm->uc, path_ptr++, &c, 1) == UC_ERR_OK && c != '\0') path.push_back(c);
    }
    int res = mkdir(path.c_str(), (mode_t)mode);
    if (res != 0 && errno == EEXIST) {
        res = 0;
        uint32_t zero_err = 0;
        uc_mem_write(vm->uc, vm->errno_addr, &zero_err, sizeof(zero_err));
    } else if (res != 0) {
        uint32_t err = (uint32_t)errno;
        uc_mem_write(vm->uc, vm->errno_addr, &err, sizeof(err));
    } else {
        uint32_t zero_err = 0;
        uc_mem_write(vm->uc, vm->errno_addr, &zero_err, sizeof(zero_err));
    }
    int64_t ret = res;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_umask(EmulatorVM *vm) {
    uint64_t mask = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &mask);
    int64_t old_mask = (int64_t)umask((mode_t)mask);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &old_mask);
}

static void hook_chmod(EmulatorVM *vm) {
    uint64_t path_ptr = 0, mode = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &mode);
    std::string path;
    char c = 0;
    if (path_ptr) {
        while (uc_mem_read(vm->uc, path_ptr++, &c, 1) == UC_ERR_OK && c != '\0') path.push_back(c);
    }
    int64_t res = (int64_t)chmod(path.c_str(), (mode_t)mode);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_lstat(EmulatorVM *vm) {
    uint64_t path_ptr = 0, stat_buf_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &stat_buf_ptr);
    std::string path;
    char c = 0;
    if (path_ptr) {
        while (uc_mem_read(vm->uc, path_ptr++, &c, 1) == UC_ERR_OK && c != '\0') path.push_back(c);
    }
    struct stat host_st;
    int res = lstat(path.c_str(), &host_st);
    if (res == 0 && stat_buf_ptr != 0) {
        StatLinux linux_st = {0};
        linux_st.st_dev = (uint64_t)host_st.st_dev;
        linux_st.st_ino = (uint64_t)host_st.st_ino;
        linux_st.st_mode = (uint32_t)host_st.st_mode;
        linux_st.st_nlink = (uint32_t)host_st.st_nlink;
        linux_st.st_uid = (uint32_t)host_st.st_uid;
        linux_st.st_gid = (uint32_t)host_st.st_gid;
        linux_st.st_rdev = (uint64_t)host_st.st_rdev;
        linux_st.st_size = (int64_t)host_st.st_size;
#if defined(_WIN32)
        linux_st.st_blksize = 4096;
        linux_st.st_blocks = (linux_st.st_size + 511) / 512;
#else
        linux_st.st_blksize = (int32_t)host_st.st_blksize;
        linux_st.st_blocks = (int64_t)host_st.st_blocks;
#endif
#if defined(__APPLE__) || defined(__MACH__)
        linux_st.st_atime = (int64_t)host_st.st_atimespec.tv_sec;
        linux_st.st_atime_nsec = (uint64_t)host_st.st_atimespec.tv_nsec;
        linux_st.st_mtime = (int64_t)host_st.st_mtimespec.tv_sec;
        linux_st.st_mtime_nsec = (uint64_t)host_st.st_mtimespec.tv_nsec;
        linux_st.st_ctime = (int64_t)host_st.st_ctimespec.tv_sec;
        linux_st.st_ctime_nsec = (uint64_t)host_st.st_ctimespec.tv_nsec;
#elif defined(_WIN32)
        linux_st.st_atime = (int64_t)host_st.st_atime;
        linux_st.st_atime_nsec = 0;
        linux_st.st_mtime = (int64_t)host_st.st_mtime;
        linux_st.st_mtime_nsec = 0;
        linux_st.st_ctime = (int64_t)host_st.st_ctime;
        linux_st.st_ctime_nsec = 0;
#else
        linux_st.st_atime = (int64_t)host_st.st_atim.tv_sec;
        linux_st.st_atime_nsec = (uint64_t)host_st.st_atim.tv_nsec;
        linux_st.st_mtime = (int64_t)host_st.st_mtim.tv_sec;
        linux_st.st_mtime_nsec = (uint64_t)host_st.st_mtim.tv_nsec;
        linux_st.st_ctime = (int64_t)host_st.st_ctim.tv_sec;
        linux_st.st_ctime_nsec = (uint64_t)host_st.st_ctim.tv_nsec;
#endif
        uc_mem_write(vm->uc, stat_buf_ptr, &linux_st, sizeof(linux_st));
        uint32_t zero_err = 0;
        uc_mem_write(vm->uc, vm->errno_addr, &zero_err, sizeof(zero_err));
    } else {
        uint32_t err = (uint32_t)errno;
        uc_mem_write(vm->uc, vm->errno_addr, &err, sizeof(err));
    }
    LOG_UC("[Hook] lstat('%s') -> res %d (errno=%d)\n", path.c_str(), res, errno);
    int64_t ret = res;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_fstat(EmulatorVM *vm) {
    uint64_t guest_fd = 0, stat_buf_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &stat_buf_ptr);
    int64_t res = -1;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end() && stat_buf_ptr != 0) {
        struct stat host_st;
        if (fstat(it->second, &host_st) == 0) {
            StatLinux linux_st = {0};
            linux_st.st_dev = (uint64_t)host_st.st_dev;
            linux_st.st_ino = (uint64_t)host_st.st_ino;
            linux_st.st_mode = (uint32_t)host_st.st_mode;
            linux_st.st_nlink = (uint32_t)host_st.st_nlink;
            linux_st.st_uid = (uint32_t)host_st.st_uid;
            linux_st.st_gid = (uint32_t)host_st.st_gid;
            linux_st.st_rdev = (uint64_t)host_st.st_rdev;
            linux_st.st_size = (int64_t)host_st.st_size;
#if defined(_WIN32) || defined(_MSC_VER)
            linux_st.st_blksize = 4096;
            linux_st.st_blocks = (linux_st.st_size + 511) / 512;
#else
            linux_st.st_blksize = (int32_t)host_st.st_blksize;
            linux_st.st_blocks = (int64_t)host_st.st_blocks;
#endif
#if defined(__APPLE__) || defined(__MACH__)
            linux_st.st_atime = (int64_t)host_st.st_atimespec.tv_sec;
            linux_st.st_atime_nsec = (uint64_t)host_st.st_atimespec.tv_nsec;
            linux_st.st_mtime = (int64_t)host_st.st_mtimespec.tv_sec;
            linux_st.st_mtime_nsec = (uint64_t)host_st.st_mtimespec.tv_nsec;
            linux_st.st_ctime = (int64_t)host_st.st_ctimespec.tv_sec;
            linux_st.st_ctime_nsec = (uint64_t)host_st.st_ctimespec.tv_nsec;
#elif defined(_WIN32)
            linux_st.st_atime = (int64_t)host_st.st_atime;
            linux_st.st_atime_nsec = 0;
            linux_st.st_mtime = (int64_t)host_st.st_mtime;
            linux_st.st_mtime_nsec = 0;
            linux_st.st_ctime = (int64_t)host_st.st_ctime;
            linux_st.st_ctime_nsec = 0;
#else
            linux_st.st_atime = (int64_t)host_st.st_atim.tv_sec;
            linux_st.st_atime_nsec = (uint64_t)host_st.st_atim.tv_nsec;
            linux_st.st_mtime = (int64_t)host_st.st_mtim.tv_sec;
            linux_st.st_mtime_nsec = (uint64_t)host_st.st_mtim.tv_nsec;
            linux_st.st_ctime = (int64_t)host_st.st_ctim.tv_sec;
            linux_st.st_ctime_nsec = (uint64_t)host_st.st_ctim.tv_nsec;
#endif
            uc_mem_write(vm->uc, stat_buf_ptr, &linux_st, sizeof(linux_st));
            res = 0;
        }
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_errno_location(EmulatorVM *vm) {
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &vm->errno_addr);
}

static void hook_system_property_get(EmulatorVM *vm) {
    uint64_t name_ptr = 0, val_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &name_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &val_ptr);
    std::string name;
    char c = 0;
    if (name_ptr) {
        while (uc_mem_read(vm->uc, name_ptr++, &c, 1) == UC_ERR_OK && c != '\0') name.push_back(c);
    }
    std::string prop_val = "";
    if (name == "ro.build.version.sdk") prop_val = kAndroidProperties.sdk_version;
    else if (name == "ro.build.version.release") prop_val = kAndroidProperties.release;
    else if (name == "ro.product.model") prop_val = kAndroidProperties.model;
    else if (name == "ro.product.brand") prop_val = kAndroidProperties.brand;
    else if (name == "ro.product.name") prop_val = kAndroidProperties.name;
    else if (name == "ro.product.device") prop_val = kAndroidProperties.device;
    else if (name == "ro.product.manufacturer") prop_val = kAndroidProperties.manufacturer;
    else if (name == "ro.build.fingerprint") prop_val = kAndroidProperties.fingerprint;

    if (val_ptr != 0) {
        std::vector<uint8_t> buf(92, 0);
        memcpy(buf.data(), prop_val.c_str(), (std::min)((size_t)91, prop_val.length()));
        uc_mem_write(vm->uc, val_ptr, buf.data(), 92);
    }
    int64_t ret = (int64_t)prop_val.length();
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_arc4random(EmulatorVM *vm) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    uint64_t rnd = (uint64_t)arc4random();
#else
    static thread_local std::random_device rd;
    static thread_local std::mt19937 gen(rd());
    uint64_t rnd = (uint64_t)gen();
#endif
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &rnd);
}

static void hook_gettimeofday(EmulatorVM *vm) {
    uint64_t tv_ptr = 0, tz_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &tv_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &tz_ptr);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (tv_ptr) {
        uint64_t tv_sec = (uint64_t)tv.tv_sec;
        uint64_t tv_usec = (uint64_t)tv.tv_usec;
        uc_mem_write(vm->uc, tv_ptr, &tv_sec, 8);
        uc_mem_write(vm->uc, tv_ptr + 8, &tv_usec, 8);
    }
    int64_t ret = 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_getauxval(EmulatorVM *vm) {
    uint64_t type = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &type);
    uint64_t val = 0;
    if (type == 6  ) val = 4096;
    else if (type == 16  ) val = 0xff;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &val);
}

// Handles refer only to mapped guest modules or the explicitly implemented
// system ABI. Never pass an ELF path/symbol to the host dlopen/dlsym.
static const std::vector<std::string> guest_system_modules = {
    "libc.so", "libdl.so", "liblog.so", "libm.so", "libz.so", "libstdc++.so", "libandroid.so"
};
static bool read_linker_string(EmulatorVM *vm, uint64_t address, std::string &out) {
    out.clear();
    for (size_t i = 0; i < 4096 && address <= UINT64_MAX - i; ++i) {
        char c = 0;
        if (uc_mem_read(vm->uc, address + i, &c, 1) != UC_ERR_OK) break;
        if (c == 0) return true;
        out.push_back(c);
    }
    vm->dynamic_link_error = "Invalid or oversized guest linker string";
    return false;
}
static bool valid_guest_handle(EmulatorVM *vm, uint64_t handle) {
    return handle == 1 || (handle >= 2 && handle - 2 < vm->loaded_libraries.size()) ||
        (handle >= 0x1000 && handle - 0x1000 < guest_system_modules.size());
}
static bool system_module_has_import(uint64_t handle, const std::string &symbol) {
    if (handle < 0x1000 || handle - 0x1000 >= guest_system_modules.size()) return false;
    const std::string &module = guest_system_modules[handle - 0x1000];
    const bool linker = symbol == "dlopen" || symbol == "dlsym" || symbol == "dlclose" || symbol == "dlerror" || symbol == "dl_iterate_phdr";
    const bool logging = symbol == "__android_log_print";
    const bool cxx = symbol.rfind("__cxa_", 0) == 0 || symbol == "__dynamic_cast";
    if (module == "libdl.so") return linker;
    if (module == "liblog.so") return logging;
    if (module == "libstdc++.so") return cxx && supported_guest_import(symbol);
    if (module == "libc.so") return !linker && !logging && !cxx && supported_guest_import(symbol);
    // No math, zlib or libandroid symbol implementation is supplied here.
    return false;
}
static void hook_dlopen(EmulatorVM *vm) {
    uint64_t path = 0, handle = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path);
    if (!path) handle = 1; // dlopen(NULL): global guest scope
    else {
        std::string name;
        if (read_linker_string(vm, path, name)) {
            const auto slash = name.find_last_of('/');
            if (slash != std::string::npos) name.erase(0, slash + 1);
            for (size_t i = 0; i < vm->loaded_libraries.size(); ++i)
                if (vm->loaded_libraries[i].name == name) { handle = i + 2; break; }
            for (size_t i = 0; !handle && i < guest_system_modules.size(); ++i)
                if (guest_system_modules[i] == name) { handle = 0x1000 + i; break; }
            if (!handle) vm->dynamic_link_error = "Guest module not loaded: " + name;
        }
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &handle);
}
static void hook_dlsym(EmulatorVM *vm) {
    uint64_t handle = 0, pointer = 0, result = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &handle);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &pointer);
    std::string name;
    // Android arm64 RTLD_DEFAULT is NULL, RTLD_NEXT is deliberately unsupported.
    if (!valid_guest_handle(vm, handle) && handle != 0) vm->dynamic_link_error = "Invalid guest module handle";
    else if (read_linker_string(vm, pointer, name)) {
        if (handle == 0 || handle == 1) result = get_vm_symbol_address(vm, name);
        else if (handle < 0x1000) {
            const auto &symbols = vm->loaded_libraries[handle - 2].symbols;
            auto it = symbols.find(name);
            if (it != symbols.end()) result = it->second;
        }
        if (!result && (handle == 0 || handle == 1 || system_module_has_import(handle, name)) && supported_guest_import(name))
            result = vm->register_import(name);
        // dlsym has no ELF type metadata. Match SideStore's generic fallback,
        // including data-style names, while preserving explicit module lookup.
        if (!result && !supported_guest_import(name) &&
            !get_vm_symbol_address(vm, name)) result = vm->register_import(name);
        if (!result) vm->dynamic_link_error = "Guest symbol not found: " + name;
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &result);
}
static void hook_dlclose(EmulatorVM *vm) {
    uint64_t handle = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &handle);
    int64_t result = valid_guest_handle(vm, handle) ? 0 : -1;
    if (result) vm->dynamic_link_error = "Invalid guest module handle";
    // Mapped ADI modules are pinned for the VM lifetime, as with RTLD_NODELETE.
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &result);
}
static void hook_dlerror(EmulatorVM *vm) {
    uint64_t result = 0;
    if (!vm->dynamic_link_error.empty()) {
        result = vm->write_string(vm->dynamic_link_error.c_str());
        vm->dynamic_link_error.clear();
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &result);
}

static void hook_cxa_guard_acquire(EmulatorVM *vm) {
    uint64_t guard_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guard_ptr);
    uint8_t first_byte = 0;
    if (guard_ptr) {
        uc_mem_read(vm->uc, guard_ptr, &first_byte, 1);
    }
    int64_t ret = (first_byte == 0) ? 1 : 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_cxa_guard_release(EmulatorVM *vm) {
    uint64_t guard_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guard_ptr);
    uint8_t one = 1;
    if (guard_ptr) {
        uc_mem_write(vm->uc, guard_ptr, &one, 1);
    }
    int64_t ret = 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_cxa_allocate_exception(EmulatorVM *vm) {
    uint64_t size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &size);
    uint64_t ptr = vm->heap.alloc(size + 128);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ptr);
}

static void hook_dynamic_cast(EmulatorVM *vm) {
    uint64_t sub = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &sub);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &sub);
}

static void hook_strtoll(EmulatorVM *vm) {
    uint64_t nptr = 0, endptr = 0, base = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &nptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &endptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &base);

    std::string str;
    char c = 0;
    if (nptr) {
        while (uc_mem_read(vm->uc, nptr++, &c, 1) == UC_ERR_OK && c != '\0') str.push_back(c);
    }

    char *host_end = nullptr;
    int64_t val = strtoll(str.c_str(), &host_end, (int)base);
    if (endptr != 0 && host_end != nullptr) {
        size_t consumed = host_end - str.c_str();
        uint64_t final_end_addr = (nptr - str.length() - 1) + consumed;
        uc_mem_write(vm->uc, endptr, &final_end_addr, sizeof(final_end_addr));
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &val);
}

static void hook_strtod(EmulatorVM *vm) {
    uint64_t nptr = 0, endptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &nptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &endptr);

    std::string str;
    char c = 0;
    if (nptr) {
        while (uc_mem_read(vm->uc, nptr++, &c, 1) == UC_ERR_OK && c != '\0') str.push_back(c);
    }

    char *host_end = nullptr;
    double val = strtod(str.c_str(), &host_end);
    if (endptr != 0 && host_end != nullptr) {
        size_t consumed = host_end - str.c_str();
        uint64_t final_end_addr = (nptr - str.length() - 1) + consumed;
        uc_mem_write(vm->uc, endptr, &final_end_addr, sizeof(final_end_addr));
    }
    uint8_t d0_val[16] = {0};
    memcpy(d0_val, &val, sizeof(double));
    uc_reg_write(vm->uc, UC_ARM64_REG_Q0, d0_val);
}

static void hook_android_log_print(EmulatorVM *vm) {
    uint64_t prio = 0, tag_ptr = 0, fmt_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &prio);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &tag_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &fmt_ptr);
    std::string tag, fmt;
    char c = 0;
    if (tag_ptr) {
        while (uc_mem_read(vm->uc, tag_ptr++, &c, 1) == UC_ERR_OK && c != '\0') tag.push_back(c);
    }
    if (fmt_ptr) {
        while (uc_mem_read(vm->uc, fmt_ptr++, &c, 1) == UC_ERR_OK && c != '\0') fmt.push_back(c);
    }
    LOG_UC("[Android Log %lld][%s] %s\n", (long long)prio, tag.c_str(), fmt.c_str());
    int64_t ret = 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void import_callback_router(uc_engine *uc, uint64_t address, uint32_t size, void *user_data) {
    (void)size;
    EmulatorVM *vm = (EmulatorVM *)user_data;
    if (!vm) vm = g_active_vm;
    if (!vm) return;

    auto it = vm->import_stubs.find(address);
    if (it == vm->import_stubs.end()) {
        return;
    }

    const std::string &name = it->second;

    if (name == "malloc") hook_malloc(vm);
    else if (name == "_Znwm") hook_operator_new(vm);
    else if (name == "calloc") hook_calloc(vm);
    else if (name == "realloc") hook_realloc(vm);
    else if (name == "free") hook_free(vm);
    else if (name == "strlen") hook_strlen(vm);
    else if (name == "strcmp") hook_strcmp(vm);
    else if (name == "strncmp") hook_strncmp(vm);
    else if (name == "strcpy") hook_strcpy(vm);
    else if (name == "strncpy") hook_strncpy(vm);
    else if (name == "memcpy") hook_memcpy(vm);
    else if (name == "memset") hook_memset(vm);
    else if (name == "memcmp") hook_memcmp(vm);
    else if (name == "memchr") hook_memchr(vm);
    else if (name == "open") hook_open(vm);
    else if (name == "close") hook_close(vm);
    else if (name == "read") hook_read(vm);
    else if (name == "write") hook_write(vm);
    else if (name == "ftruncate") hook_ftruncate(vm);
    else if (name == "mkdir") hook_mkdir(vm);
    else if (name == "umask") hook_umask(vm);
    else if (name == "chmod") hook_chmod(vm);
    else if (name == "lstat") hook_lstat(vm);
    else if (name == "fstat") hook_fstat(vm);
    else if (name == "__errno" || name == "__errno_location") hook_errno_location(vm);
    else if (name == "__system_property_get") hook_system_property_get(vm);
    else if (name == "arc4random") hook_arc4random(vm);
    else if (name == "gettimeofday") hook_gettimeofday(vm);
    else if (name == "getauxval") hook_getauxval(vm);
    else if (name == "dlopen") hook_dlopen(vm);
    else if (name == "dlsym") hook_dlsym(vm);
    else if (name == "dlclose") hook_dlclose(vm);
    else if (name == "dlerror") hook_dlerror(vm);
    else if (name == "__cxa_guard_acquire") hook_cxa_guard_acquire(vm);
    else if (name == "__cxa_guard_release") hook_cxa_guard_release(vm);
    else if (name == "__cxa_allocate_exception") hook_cxa_allocate_exception(vm);
    else if (name == "__cxa_begin_catch" || name == "__dynamic_cast") hook_dynamic_cast(vm);
    else if (name == "strtoll" || name == "strtol" || name == "strtoull") hook_strtoll(vm);
    else if (name == "strtod" || name == "atof") hook_strtod(vm);
    else if (name == "dl_iterate_phdr") hook_dl_iterate_phdr(vm);
    else if (dispatch_android_pthread_sync(vm, name)) { }
    else if (name == "__android_log_print") hook_android_log_print(vm);
    else if (dispatch_android_libc_string(vm, name)) { }
    else {
        // SideStore's unresolved-function fallback: return zero through the guest
        // stub. This is compatibility behavior, not evidence of ABI/login success.
        auto &calls = vm->fallback_import_calls[name];
        if (calls++ == 0)
            LOG_UC("[SideStore compatibility] Unimplemented function returned zero: %s\n", name.c_str());
        uint64_t ret = 0;
        const uc_err write_error = uc_reg_write(uc, UC_ARM64_REG_X0, &ret);
        if (write_error != UC_ERR_OK) {
            vm->record_fault(EmulatorVM::FaultReason::fallbackReturn, true, write_error);
            vm->execution_error = "Cannot return from guest fallback: " + name;
            uc_emu_stop(uc);
        }
    }
}

// Resolve only ordinary mapped definitions as image-relative addresses. Absolute
// values are not rebased; TLS/COMMON/XINDEX require semantics this VM lacks.
static bool defined_symbol_address(const EmulatorVM::LibraryInfo &lib,
                                   const Elf64_Sym &sym, uint64_t &address) {
    if (sym.st_shndx == 0xfff1) { address = sym.st_value; return true; } // SHN_ABS
    if (!sym.st_shndx || sym.st_shndx == 0xfff2 || sym.st_shndx == 0xffff ||
        (sym.st_info & 0xf) == 6) return false;
    for (const auto &range : lib.load_ranges) {
        // A zero-sized linker marker may legally denote the segment endpoint.
        if (sym.st_value < range.first || sym.st_value > range.second ||
            sym.st_size > range.second - sym.st_value ||
            (sym.st_size && sym.st_value == range.second)) continue;
        if (sym.st_value < lib.min_vaddr ||
            sym.st_value - lib.min_vaddr > UINT64_MAX - lib.base_address) return false;
        address = lib.base_address + (sym.st_value - lib.min_vaddr);
        return true;
    }
    return false;
}

static bool symbol_name(EmulatorVM *vm, const EmulatorVM::LibraryInfo &lib,
                        const Elf64_Sym &sym, std::string &name) {
    if (sym.st_name >= lib.strsz || lib.strsz > UINT64_MAX - lib.strtab) return false;
    // Bounded chunks avoid copying the entire string table for every symbol.
    for (size_t offset = sym.st_name; offset < lib.strsz;) {
        char bytes[256];
        const size_t n = std::min(sizeof bytes, lib.strsz - offset);
        if (uc_mem_read(vm->uc, lib.strtab + offset, bytes, n) != UC_ERR_OK) return false;
        const char *end = std::find(bytes, bytes + n, '\0');
        name.append(bytes, static_cast<size_t>(end - bytes));
        if (end != bytes + n) return true;
        offset += n;
    }
    return false;
}

static uint64_t vm_resolve_symbol(EmulatorVM *vm, const EmulatorVM::LibraryInfo &current_lib, uint32_t sym_idx,
    EmulatorVM::ResolutionSource *source = nullptr, bool *is_cxa_atexit = nullptr,
    bool preflight = false) {
    using Source = EmulatorVM::ResolutionSource;
    if (source) *source = Source::unresolved;
    if (is_cxa_atexit) *is_cxa_atexit = false;
    auto resolved = [&](uint64_t address, Source from) {
        if (source) *source = from;
        return address;
    };
    auto invalid = [&]() -> uint64_t {
        vm->execution_error = "Invalid or unsupported ELF relocation symbol in " + current_lib.name;
        return 0;
    };
    if (!current_lib.symtab || !current_lib.strtab || sym_idx >= current_lib.symbol_count ||
        sym_idx > (UINT64_MAX - current_lib.symtab) / sizeof(Elf64_Sym)) return invalid();
    Elf64_Sym sym;
    if (uc_mem_read(vm->uc, current_lib.symtab + uint64_t(sym_idx) * sizeof sym,
                    &sym, sizeof sym) != UC_ERR_OK) return invalid();
    std::string sym_name;
    if (!symbol_name(vm, current_lib, sym, sym_name)) return invalid();
    if (is_cxa_atexit) *is_cxa_atexit = sym_name == "__cxa_atexit";
    if (sym.st_shndx != 0) {
        uint64_t address = 0;
        if (!defined_symbol_address(current_lib, sym, address)) return invalid();
        return resolved(address, Source::definedSymbol);
    }
    // The null symbol denotes zero, not an import named "" or the image base.
    if (sym_name.empty()) return resolved(0, Source::definedSymbol);

    auto self_it = current_lib.symbols.find(sym_name);
    if (self_it != current_lib.symbols.end()) return resolved(self_it->second, Source::selfSymbol);

    for (const auto &lib : vm->loaded_libraries) {
        auto it = lib.symbols.find(sym_name);
        if (it != lib.symbols.end()) return resolved(it->second, Source::librarySymbol);
    }

    std::string converted = sym_name;
    size_t pos = converted.find("6__ndk1");
    if (pos != std::string::npos) {
        converted.replace(pos, 7, "3__1");
    } else {
        pos = converted.find("__ndk1");
        if (pos != std::string::npos) {
            converted.replace(pos, 6, "__1");
        }
    }
    if (converted != sym_name) {
        for (const auto &lib : vm->loaded_libraries) {
            auto it = lib.symbols.find(converted);
            if (it != lib.symbols.end()) return resolved(it->second, Source::convertedSymbol);
        }
    }

    // Preflight never creates a stub or data placeholder. A relocation-created
    // zero-return stub is NOT an implementation and cannot satisfy this gate.
    // Weak undefined symbols are optional; this does not prove they are callable.
    const uint8_t type = sym.st_info & 0xf;
    if (preflight) {
        if ((sym.st_info >> 4) != 2 &&
            ((type != 0 && type != 2) || guest_data_symbol_name(sym_name) ||
             !supported_guest_import(sym_name))) {
            vm->record_fault(EmulatorVM::FaultReason::functionImport);
            // Fixed vocabulary only: never export arbitrary file/symbol strings.
            vm->execution_error = "Unsupported required guest import before constructors";
        }
        return 0;
    }
    // Keep legacy relocation diagnostics, but required fallbacks cannot pass
    // the constructor gate below. Data must never become an executable stub.
    if (type == 1 || guest_data_symbol_name(sym_name)) return resolved(vm->register_data_import(sym_name), Source::dataFallback);
    return resolved(vm->register_import(sym_name), Source::functionStub);
}

static void apply_vm_relocations(EmulatorVM *vm, EmulatorVM::LibraryInfo &lib) {
    auto apply_table = [&](uint64_t rela_ptr, size_t sz, const char *label) {
        if (!rela_ptr || !sz) return;
        size_t count = sz / sizeof(Elf64_Rela);
        size_t applied = 0;
        Elf64_Rela r;
        for (size_t offset = 0; offset < sz; offset += sizeof(r)) {
            if (uc_mem_read(vm->uc, rela_ptr + offset, &r, sizeof(r)) != UC_ERR_OK) break;

            uint32_t type = (uint32_t)ELF64_R_TYPE(r.r_info);
            uint32_t sym_idx = (uint32_t)ELF64_R_SYM(r.r_info);
            uint64_t target_addr = lib.base_address + (r.r_offset - lib.min_vaddr);

            if (type == R_AARCH64_RELATIVE) {
                uint64_t final_val = lib.base_address + (r.r_addend - lib.min_vaddr);
                uc_mem_write(vm->uc, target_addr, &final_val, sizeof(final_val));
                applied++;
            } else if (type == R_AARCH64_JUMP_SLOT || type == R_AARCH64_GLOB_DAT || type == R_AARCH64_ABS64) {
                if (sym_idx >= lib.symbol_count) {
                    vm->execution_error = "Relocation symbol index outside validated dynsym in " + lib.name;
                    return;
                }
                EmulatorVM::ResolutionSource source;
                bool is_cxa_atexit = false;
                uint64_t sym_addr = vm_resolve_symbol(vm, lib, sym_idx, &source, &is_cxa_atexit);
                if (is_cxa_atexit && type == R_AARCH64_JUMP_SLOT && lib.name == kADISymbols.lib_ssc &&
                    lib.max_vaddr >= lib.min_vaddr && lib.base_address <= UINT64_MAX - (lib.max_vaddr - lib.min_vaddr)) {
                    // Fixed upper bound; no arbitrary symbol names or library paths retained.
                    auto it = std::find_if(vm->cxa_atexit_slots.begin(), vm->cxa_atexit_slots.end(),
                        [&](const EmulatorVM::CxaAtexitSlot &slot) { return slot.address == target_addr; });
                    EmulatorVM::CxaAtexitSlot slot{target_addr, lib.base_address,
                        lib.base_address + (lib.max_vaddr - lib.min_vaddr), source};
                    if (it != vm->cxa_atexit_slots.end()) *it = slot;
                    else if (vm->cxa_atexit_slots.size() < 8) vm->cxa_atexit_slots.push_back(slot);
                }
                if (!vm->execution_error.empty()) return;
                if (source != EmulatorVM::ResolutionSource::unresolved) {
                    uint64_t final_val = sym_addr + r.r_addend;
                    uc_mem_write(vm->uc, target_addr, &final_val, sizeof(final_val));
                    applied++;
                }
            } else if (type != 0) {
                // SideStore only applies the four cases above. Keep its skip
                // behavior, but report it honestly: this is NOT TLS support.
                LOG_UC("[SideStore compatibility] Ignored unimplemented guest relocation %u in '%s' (not implemented ABI)\n", type, lib.name.c_str());
            }
        }
        LOG_UC("[Emulator] Applied %zu / %zu relocations for %s in '%s'\n",
               applied, count, label, lib.name.c_str());
    };

    apply_table(lib.rela, lib.relasz, "RELA");
    apply_table(lib.jmprel, lib.pltrelsz, "PLT/JMPREL");
}

bool load_library_to_vm(EmulatorVM *vm, const std::string &file_path, const std::string &so_name) {
    if (!vm || !vm->uc || vm->loaded_libraries.size() >= 64) return false;
    LOG_UC("[Emulator] Loading ELF library '%s' from '%s'...\n", so_name.c_str(), file_path.c_str());
    FILE *f = fopen(file_path.c_str(), "rb");
    if (!f) {
        LOG_UC("[Emulator] Failed to open ELF file: %s\n", file_path.c_str());
        return false;
    }

    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return false; }
    const long measured_size = ftell(f);
    if (measured_size < 0 || measured_size > 64L * 1024 * 1024 ||
        fseek(f, 0, SEEK_SET) != 0) { fclose(f); return false; }
    const size_t file_size = static_cast<size_t>(measured_size);

    std::vector<uint8_t> buffer(file_size);
    if (fread(buffer.data(), 1, file_size, f) != file_size) {
        fclose(f);
        return false;
    }
    fclose(f);

    if (file_size < sizeof(Elf64_Ehdr)) return false;
    Elf64_Ehdr header;
    memcpy(&header, buffer.data(), sizeof(header));
    const Elf64_Ehdr *ehdr = &header;

    if (memcmp(ehdr->e_ident, "\x7f\x45\x4c\x46\x02\x01\x01", 7) != 0) {
        LOG_UC("[Emulator] Invalid ELF magic or not 64-bit ELF: %s\n", so_name.c_str());
        return false;
    }
    if (ehdr->e_type != 3 || ehdr->e_machine != 183 || ehdr->e_version != 1 ||
        ehdr->e_ehsize != sizeof(Elf64_Ehdr) || ehdr->e_phoff < sizeof(Elf64_Ehdr) ||
        ehdr->e_phentsize != sizeof(Elf64_Phdr) || ehdr->e_phnum == 0 ||
        ehdr->e_phnum > 1024 || ehdr->e_phoff > file_size ||
        ehdr->e_phnum > (file_size - ehdr->e_phoff) / sizeof(Elf64_Phdr)) return false;
    // Copy instead of casting untrusted, possibly unaligned file offsets.
    std::vector<Elf64_Phdr> headers(ehdr->e_phnum);
    memcpy(headers.data(), buffer.data() + ehdr->e_phoff, headers.size() * sizeof(Elf64_Phdr));

    uint64_t min_vaddr = UINT64_MAX;
    uint64_t max_vaddr = 0;
    const Elf64_Phdr *phdrs = headers.data();

    for (int i = 0; i < ehdr->e_phnum; i++) {
        if (phdrs[i].p_type == PT_LOAD) {
            if (phdrs[i].p_offset > file_size || phdrs[i].p_filesz > file_size - phdrs[i].p_offset ||
                phdrs[i].p_filesz > phdrs[i].p_memsz || phdrs[i].p_memsz > UINT64_MAX - phdrs[i].p_vaddr ||
                phdrs[i].p_vaddr + phdrs[i].p_memsz > UINT64_MAX - 0xFFFFULL) return false;
            if (!phdrs[i].p_memsz) continue;
            uint64_t seg_start = phdrs[i].p_vaddr & ~0xFFFFULL;
            uint64_t seg_end   = (phdrs[i].p_vaddr + phdrs[i].p_memsz + 0xFFFFULL) & ~0xFFFFULL;
            if (seg_start < min_vaddr) min_vaddr = seg_start;
            if (seg_end > max_vaddr) max_vaddr = seg_end;
        }
    }

    if (min_vaddr >= max_vaddr) return false;
    uint64_t total_span = max_vaddr - min_vaddr;

    uint64_t base_address = vm->library_alloc.alloc(total_span);
    if (!base_address) return false;
    LOG_UC("[Emulator] Mapped library '%s' span 0x%llx at base address: 0x%llx\n",
           so_name.c_str(), (unsigned long long)total_span, (unsigned long long)base_address);

    uc_err err = uc_mem_map(vm->uc, base_address, total_span, UC_PROT_ALL);
    if (err != UC_ERR_OK) {
        LOG_UC("[Emulator] uc_mem_map failed for library span: %u (%s)\n", err, uc_strerror(err));
        return false;
    }

    EmulatorVM::LibraryInfo lib;
    lib.name = so_name;
    lib.base_address = base_address;
    lib.min_vaddr = min_vaddr;
    lib.max_vaddr = max_vaddr;
    lib.dynamic_address = 0;
    lib.symtab = 0;
    lib.strtab = 0;
    lib.strsz = 0;
    lib.rel = 0;
    lib.relsz = 0;
    lib.rela = 0;
    lib.relasz = 0;
    lib.jmprel = 0;
    lib.pltrelsz = 0;
    lib.init_func = 0;
    lib.init_array = 0;
    lib.init_arraysz = 0;
    lib.program_header_count = ehdr->e_phnum;
    for (const auto &ph : headers) {
        if (ph.p_type == PT_LOAD && ph.p_memsz)
            lib.load_ranges.push_back({ph.p_vaddr, ph.p_vaddr + ph.p_memsz});
    }
    const auto phdr_bytes = reinterpret_cast<const uint8_t *>(headers.data());
    lib.program_headers.assign(phdr_bytes, phdr_bytes + headers.size() * sizeof(Elf64_Phdr));
    lib.program_headers_guest = vm->write_bytes(lib.program_headers.data(), lib.program_headers.size());
    if (!lib.program_headers_guest) return false;

    for (int i = 0; i < ehdr->e_phnum; i++) {
        if (phdrs[i].p_type == PT_LOAD) {
            uint64_t dest = base_address + (phdrs[i].p_vaddr - min_vaddr);
            if (phdrs[i].p_filesz > 0) {
                if (uc_mem_write(vm->uc, dest, buffer.data() + phdrs[i].p_offset, phdrs[i].p_filesz) != UC_ERR_OK) return false;
            }
            if (phdrs[i].p_memsz > phdrs[i].p_filesz) {
                uint64_t bss_size = phdrs[i].p_memsz - phdrs[i].p_filesz;
                const std::vector<uint8_t> bss_zeros(0x10000, 0);
                for (uint64_t offset = 0; offset < bss_size;) {
                    const size_t chunk = static_cast<size_t>(std::min<uint64_t>(bss_zeros.size(), bss_size - offset));
                    if (uc_mem_write(vm->uc, dest + phdrs[i].p_filesz + offset, bss_zeros.data(), chunk) != UC_ERR_OK) return false;
                    offset += chunk;
                }
            }
        } else if (phdrs[i].p_type == PT_DYNAMIC) {
            if (phdrs[i].p_vaddr < min_vaddr || phdrs[i].p_vaddr >= max_vaddr ||
                phdrs[i].p_memsz > max_vaddr - phdrs[i].p_vaddr) return false;
            lib.dynamic_address = base_address + (phdrs[i].p_vaddr - min_vaddr);
        }
    }

    // Metadata must come from actual file-backed PT_LOAD bytes, never the
    // zero-filled BSS or the VM's page-alignment padding.
    auto file_span = [&](uint64_t va, uint64_t size, size_t &off) {
        for (const auto &ph : headers) {
            if (ph.p_type != PT_LOAD || va < ph.p_vaddr) continue;
            const uint64_t delta = va - ph.p_vaddr;
            if (delta <= ph.p_filesz && size <= ph.p_filesz - delta) {
                off = static_cast<size_t>(ph.p_offset + delta);
                return true;
            }
        }
        return false;
    };
    auto file_available = [&](uint64_t va) -> uint64_t {
        uint64_t available = 0;
        for (const auto &ph : headers) if (ph.p_type == PT_LOAD && va >= ph.p_vaddr &&
            va - ph.p_vaddr < ph.p_filesz)
            available = std::max(available, ph.p_filesz - (va - ph.p_vaddr));
        return available;
    };
    auto guest_pointer = [&](uint64_t va, uint64_t &ptr) {
        if (va < min_vaddr || va >= max_vaddr || va - min_vaddr > UINT64_MAX - base_address) return false;
        ptr = base_address + (va - min_vaddr);
        return true;
    };
    uint64_t hash_va = 0, gnu_va = 0, sym_va = 0, str_va = 0;
    bool syment_seen = false;
    std::vector<uint64_t> metadata_starts;
    size_t dynamic_count = 0;
    for (const auto &ph : headers) {
        if (ph.p_type != PT_DYNAMIC) continue;
        if (++dynamic_count > 1 || !ph.p_filesz || ph.p_filesz > ph.p_memsz ||
            ph.p_filesz % sizeof(Elf64_Dyn)) return false;
        size_t dynamic_off;
        if (!file_span(ph.p_vaddr, ph.p_filesz, dynamic_off) ||
            ph.p_offset != dynamic_off) return false;
        bool terminated = false;
        for (uint64_t off = 0; off < ph.p_filesz; off += sizeof(Elf64_Dyn)) {
            Elf64_Dyn dyn;
            memcpy(&dyn, buffer.data() + dynamic_off + off, sizeof dyn);
            if (dyn.d_tag == DT_NULL) { terminated = true; break; }
            const uint64_t val = dyn.d_un.d_val;
            uint64_t *ptr = nullptr;
            switch (dyn.d_tag) {
                case DT_HASH: hash_va = val; metadata_starts.push_back(val); break;
                case 0x6ffffef5: gnu_va = val; metadata_starts.push_back(val); break; // DT_GNU_HASH
                case DT_SYMTAB: sym_va = val; ptr = &lib.symtab; break;
                case DT_STRTAB: str_va = val; ptr = &lib.strtab; break;
                case DT_STRSZ: if (val > SIZE_MAX) return false; lib.strsz = size_t(val); break;
                case DT_SYMENT: if (val != sizeof(Elf64_Sym)) return false; syment_seen = true; break;
                case DT_REL: ptr = &lib.rel; break;
                case DT_RELSZ: lib.relsz = size_t(val); break;
                case DT_RELA: ptr = &lib.rela; break;
                case DT_RELASZ: lib.relasz = size_t(val); break;
                case DT_JMPREL: ptr = &lib.jmprel; break;
                case DT_PLTRELSZ: lib.pltrelsz = size_t(val); break;
                case DT_INIT: ptr = &lib.init_func; break;
                case DT_INIT_ARRAY: ptr = &lib.init_array; break;
                case DT_INIT_ARRAYSZ: lib.init_arraysz = size_t(val); break;
                // Bound GNU chain reads before neighboring version metadata too.
                case 0x6ffffffe: case 0x6ffffffc: case 0x6ffffff0:
                    metadata_starts.push_back(val); break;
                default: break;
            }
            if (ptr) {
                if (!guest_pointer(val, *ptr)) return false;
                metadata_starts.push_back(val);
            }
        }
        if (!terminated) return false;
    }
    if (lib.symtab) {
        if (!lib.strtab || !lib.strsz || !syment_seen || (!hash_va && !gnu_va)) return false;
        size_t strings_off;
        if (!file_span(str_va, lib.strsz, strings_off)) return false;
        uint64_t capacity = file_available(sym_va) / sizeof(Elf64_Sym);
        for (uint64_t next : metadata_starts) if (next > sym_va)
            capacity = std::min(capacity, (next - sym_va) / sizeof(Elf64_Sym));
        if (!capacity) return false;
        auto word = [&](uint64_t va, uint32_t &value) {
            size_t off;
            if (!file_span(va, sizeof value, off)) return false;
            memcpy(&value, buffer.data() + off, sizeof value);
            return true;
        };
        size_t sysv_count = 0, gnu_count = 0;
        bool gnu_nonempty = false;
        if (hash_va) {
            uint32_t nbucket, nchain;
            if (hash_va > UINT64_MAX - 8 || !word(hash_va, nbucket) ||
                !word(hash_va + 4, nchain) || !nbucket || !nchain || nchain > capacity) return false;
            const uint64_t words = uint64_t(nbucket) + nchain;
            size_t off;
            if (!file_span(hash_va, 8 + words * 4, off)) return false;
            for (uint64_t i = 0; i < words; ++i) {
                uint32_t index;
                memcpy(&index, buffer.data() + off + 8 + i * 4, 4);
                if (index >= nchain) return false;
            }
            sysv_count = nchain;
        }
        if (gnu_va) {
            uint32_t h[4]; size_t off;
            if (!file_span(gnu_va, sizeof h, off)) return false;
            memcpy(h, buffer.data() + off, sizeof h);
            const uint64_t nbucket = h[0], first = h[1], bloom = h[2];
            if (!nbucket || !first || first > capacity || !bloom ||
                (bloom & (bloom - 1)) || h[3] >= 64) return false;
            const uint64_t prefix = 16 + bloom * 8 + nbucket * 4;
            if (!file_span(gnu_va, prefix, off) || gnu_va > UINT64_MAX - prefix) return false;
            const uint64_t chains = gnu_va + prefix;
            uint64_t chain_bytes = file_available(chains);
            for (uint64_t next : metadata_starts) if (next > gnu_va) {
                if (next < chains) return false;
                chain_bytes = std::min(chain_bytes, next - chains);
            }
            std::vector<uint32_t> buckets;
            for (uint64_t i = 0; i < nbucket; ++i) {
                uint32_t bucket;
                memcpy(&bucket, buffer.data() + off + 16 + bloom * 8 + i * 4, 4);
                if (!bucket) continue;
                if (bucket < first || bucket >= capacity) return false;
                buckets.push_back(bucket);
            }
            std::sort(buckets.begin(), buckets.end());
            if (std::adjacent_find(buckets.begin(), buckets.end()) != buckets.end()) return false;
            gnu_count = size_t(first);
            for (size_t b = 0; b < buckets.size(); ++b) {
                gnu_nonempty = true;
                uint64_t index = buckets[b];
                while (true) {
                    const uint64_t delta = index - first;
                    uint32_t hash;
                    if (index >= capacity || delta >= chain_bytes / 4 ||
                        !word(chains + delta * 4, hash)) return false;
                    ++index;
                    if (hash & 1) break;
                    if (b + 1 < buckets.size() && index >= buckets[b + 1]) return false;
                }
                if (b + 1 < buckets.size() && index != buckets[b + 1]) return false;
                gnu_count = size_t(index);
            }
        }
        // SysV carries an explicit total count. An entirely empty GNU hash may
        // describe only an unhashed prefix, so do not reject that valid case.
        if (hash_va && gnu_va && (gnu_count > sysv_count ||
            (gnu_nonempty && gnu_count != sysv_count))) return false;
        lib.symbol_count = hash_va ? sysv_count : gnu_count;
        size_t symbols_off;
        if (!file_span(sym_va, uint64_t(lib.symbol_count) * sizeof(Elf64_Sym), symbols_off)) return false;
        for (size_t idx = 0; idx < lib.symbol_count; ++idx) {
            Elf64_Sym sym;
            memcpy(&sym, buffer.data() + symbols_off + idx * sizeof sym, sizeof sym);
            if (sym.st_name >= lib.strsz) return false;
            const char *name = reinterpret_cast<const char *>(buffer.data() + strings_off + sym.st_name);
            const void *nul = memchr(name, 0, lib.strsz - sym.st_name);
            if (!nul) return false;
            // Undefined values are never exports, even if st_value is nonzero.
            if (!sym.st_shndx || !*name) continue;
            if (sym.st_shndx == 0xfff2 || sym.st_shndx == 0xffff || (sym.st_info & 0xf) == 6) continue;
            uint64_t address;
            if (!defined_symbol_address(lib, sym, address)) return false;
            lib.symbols[std::string(name, static_cast<const char *>(nul))] = address;
        }
    } else if (hash_va || gnu_va) return false;
    vm->loaded_libraries.push_back(lib);
    return true;
}

void relocate_all_vm_libraries(EmulatorVM *vm) {
    LOG_UC("[Emulator] Relocating all %zu loaded libraries...\n", vm->loaded_libraries.size());
    for (auto &lib : vm->loaded_libraries) {
        apply_vm_relocations(vm, lib);
        if (!vm->execution_error.empty()) return;
    }
}

bool preflight_vm_libraries(EmulatorVM *vm) {
    if (!vm || !vm->uc || !vm->execution_error.empty()) return false;
    // Check the entire validated dynsym, not just referenced PLT/GOT slots, and
    // check EVERY image before the first image's DT_INIT or DT_INIT_ARRAY.
    // No recursive DT_NEEDED loading or Android capability emulation is implied.
    for (const auto &lib : vm->loaded_libraries) {
        for (size_t i = 1; i < lib.symbol_count; ++i) {
            if (i > UINT32_MAX) {
                vm->execution_error = "Invalid ELF symbol count before constructors";
                return false;
            }
            vm_resolve_symbol(vm, lib, static_cast<uint32_t>(i), nullptr, nullptr, true);
            if (!vm->execution_error.empty()) return false;
        }
    }
    return true;
}

bool run_library_constructors(EmulatorVM *vm) {
    if (!vm) return false;
    if (!vm->execution_error.empty()) {
        vm->record_fault(EmulatorVM::FaultReason::preexistingError);
        return false;
    }
    vm->fault = {};
    vm->constructor_context = {};
    if (!preflight_vm_libraries(vm)) return false;
    for (const auto &lib : vm->loaded_libraries) {
        const auto library = lib.name == kADISymbols.lib_ssc
            ? EmulatorVM::ConstructorLibrary::storeservicescore
            : (lib.name == kADISymbols.lib_core_adi
                ? EmulatorVM::ConstructorLibrary::coreadi : EmulatorVM::ConstructorLibrary::other);
        if (lib.init_func) {
            vm->constructor_context = {true, EmulatorVM::ConstructorKind::dtInit, library, 0};
            LOG_UC("[Emulator] Calling DT_INIT at 0x%llx for '%s'...\n",
                   (unsigned long long)lib.init_func, lib.name.c_str());
            run_vm_procedure(vm, lib.init_func, {});
            vm->constructor_context = {};
            if (!vm->execution_error.empty()) return false;
        }
        if (lib.init_array && lib.init_arraysz) {
            size_t count = lib.init_arraysz / 8;
            for (size_t i = 0; i < count; i++) {
                vm->constructor_context = {true, EmulatorVM::ConstructorKind::initArray, library, i};
                uint64_t ctor_ptr = 0;
                const uc_err read_error = uc_mem_read(vm->uc, lib.init_array + i * 8, &ctor_ptr, 8);
                if (read_error != UC_ERR_OK) {
                    vm->record_fault(EmulatorVM::FaultReason::constructorRead, true, read_error);
                    vm->execution_error = "Unreadable guest constructor array";
                    vm->constructor_context = {};
                    return false;
                }
                if (ctor_ptr != 0 && ctor_ptr != UINT64_MAX) {
                    LOG_UC("[Emulator] Calling DT_INIT_ARRAY[%zu] at 0x%llx for '%s'...\n",
                           i, (unsigned long long)ctor_ptr, lib.name.c_str());
                    run_vm_procedure(vm, ctor_ptr, {});
                    vm->constructor_context = {};
                    if (!vm->execution_error.empty()) return false;
                }
                vm->constructor_context = {};
            }
        }
    }
    return true;
}

uint64_t get_vm_symbol_address(EmulatorVM *vm, const std::string &name) {
    for (const auto &lib : vm->loaded_libraries) {
        auto it = lib.symbols.find(name);
        if (it != lib.symbols.end()) return it->second;
    }
    return 0;
}

int32_t run_vm_procedure(EmulatorVM *vm, uint64_t proc_addr, const std::vector<uint64_t> &args, uint64_t timeout_us, size_t max_count) {
    if (!vm) return -1;
    if (!vm->execution_depth) {
        vm->observed_pc_count = 0;
        vm->observed_pc_next = 0;
        std::fill(std::begin(vm->observed_pcs), std::end(vm->observed_pcs), 0);
    }
    if (!vm->execution_error.empty()) {
        vm->record_fault(EmulatorVM::FaultReason::preexistingError);
        return -1000;
    }
    if (!vm->execution_depth) {
        vm->fault = {};
        vm->pending_fetch = {};
        vm->pending_read_protection = {};
        vm->pending_cxa_branch = {};
    }
    if (vm->initialization_error != UC_ERR_OK) {
        vm->record_fault(EmulatorVM::FaultReason::engine, true, vm->initialization_error);
        vm->execution_error = "Guest VM initialization failed";
        return -1000 - static_cast<int32_t>(vm->initialization_error);
    }
    if (!vm->uc || !proc_addr) {
        vm->record_fault(EmulatorVM::FaultReason::invalidProcedure);
        vm->execution_error = "Invalid guest procedure";
        return -1;
    }
    struct ExecutionDepth {
        EmulatorVM *vm;
        explicit ExecutionDepth(EmulatorVM *value) : vm(value) { ++vm->execution_depth; }
        ~ExecutionDepth() { --vm->execution_depth; }
    } depth(vm);
    g_active_vm = vm;

    if (timeout_us == 0) timeout_us = 0;
    if (max_count == 0) max_count = 0;

    static const int arm64_arg_regs[8] = {
        UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3,
        UC_ARM64_REG_X4, UC_ARM64_REG_X5, UC_ARM64_REG_X6, UC_ARM64_REG_X7
    };
    for (int i = 0; i < 8; i++) {
        uint64_t zero = 0;
        uc_reg_write(vm->uc, arm64_arg_regs[i], &zero);
    }
    static const int arm64_vregs[32] = {
        UC_ARM64_REG_V0,  UC_ARM64_REG_V1,  UC_ARM64_REG_V2,  UC_ARM64_REG_V3,
        UC_ARM64_REG_V4,  UC_ARM64_REG_V5,  UC_ARM64_REG_V6,  UC_ARM64_REG_V7,
        UC_ARM64_REG_V8,  UC_ARM64_REG_V9,  UC_ARM64_REG_V10, UC_ARM64_REG_V11,
        UC_ARM64_REG_V12, UC_ARM64_REG_V13, UC_ARM64_REG_V14, UC_ARM64_REG_V15,
        UC_ARM64_REG_V16, UC_ARM64_REG_V17, UC_ARM64_REG_V18, UC_ARM64_REG_V19,
        UC_ARM64_REG_V20, UC_ARM64_REG_V21, UC_ARM64_REG_V22, UC_ARM64_REG_V23,
        UC_ARM64_REG_V24, UC_ARM64_REG_V25, UC_ARM64_REG_V26, UC_ARM64_REG_V27,
        UC_ARM64_REG_V28, UC_ARM64_REG_V29, UC_ARM64_REG_V30, UC_ARM64_REG_V31
    };
    uint8_t zero16[16] = {0};
    for (int i = 0; i < 32; i++) {
        uc_reg_write(vm->uc, arm64_vregs[i], zero16);
    }

    for (size_t i = 0; i < args.size() && i < 8; i++) {
        uc_reg_write(vm->uc, arm64_arg_regs[i], &args[i]);
    }

    uint64_t stack_top = kStackAddress + kStackSize - 16;
    uc_reg_write(vm->uc, UC_ARM64_REG_SP, &stack_top);
    uc_reg_write(vm->uc, UC_ARM64_REG_LR, &kReturnAddress);
    uc_reg_write(vm->uc, UC_ARM64_REG_PC, &proc_addr);

    uint32_t first_insn = 0;
    uc_mem_read(vm->uc, proc_addr, &first_insn, 4);
    LOG_UC("[Emulator] Starting emu at 0x%llx (insn=0x%08x), SP=0x%llx, LR=0x%llx...\n",
           (unsigned long long)proc_addr, first_insn, (unsigned long long)stack_top, (unsigned long long)kReturnAddress);

    uc_err err = uc_emu_start(vm->uc, proc_addr, kReturnAddress, timeout_us, max_count);

    uint64_t pc = 0;
    bool has_pc = uc_reg_read(vm->uc, UC_ARM64_REG_PC, &pc) == UC_ERR_OK;
    if (err != UC_ERR_OK || pc != kReturnAddress || !vm->execution_error.empty()) {
        vm->record_fault(err != UC_ERR_OK ? EmulatorVM::FaultReason::engine
            : (!vm->execution_error.empty() ? EmulatorVM::FaultReason::preexistingError
                                            : EmulatorVM::FaultReason::unexpectedReturn),
            true, err, has_pc, pc);
        vm->complete_fault(err, has_pc, pc);
        if (vm->execution_error.empty()) vm->execution_error = "Guest execution did not return normally";
        LOG_UC("[Emulator] Execution stopped with status %d: %s at PC=0x%llx (expected 0x%llx)\n",
               (int)err, uc_strerror(err), (unsigned long long)pc, (unsigned long long)kReturnAddress);
        return -1000 - (int32_t)err;
    }

    uint32_t w0_val = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_W0, &w0_val);
    int32_t ret_val = (int32_t)w0_val;
    LOG_UC("[Emulator] run_vm_procedure exit: proc=0x%llx PC=0x%llx W0=%d err=%d\n",
           (unsigned long long)proc_addr, (unsigned long long)pc, ret_val, (int)err);
    return ret_val;
}
