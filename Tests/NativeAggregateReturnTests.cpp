// Self-authored AArch64 ET_DYN fixtures exercise the real loader and relocation path.
// No vendor binaries, Apple files, imports, devices, credentials, or network access.
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
constexpr uint64_t kBase = 0x20000;
constexpr size_t kSize = 0x1000, kDynOff = 0x100, kSymOff = 0x300,
                 kStrOff = 0x500, kHashOff = 0x600, kRelaOff = 0x700;
constexpr size_t kGotOff = 0x800, kCallerOff = 0x900, kProviderOff = 0xa00;
constexpr uint64_t kGuardLo = 0x1122334455667788ULL;
constexpr uint64_t kGuardHi = 0x8877665544332211ULL;

struct Image {
    std::vector<uint8_t> bytes = std::vector<uint8_t>(kSize);
    Elf64_Ehdr eh{};
    Elf64_Phdr ph[2]{};
    Image() {
        std::memcpy(eh.e_ident, "\x7f" "ELF\x02\x01\x01", 7);
        eh.e_type = 3; eh.e_machine = 183; eh.e_version = 1;
        eh.e_ehsize = sizeof(eh); eh.e_phoff = sizeof(eh);
        eh.e_phentsize = sizeof(Elf64_Phdr); eh.e_phnum = 2;
        ph[0].p_type = PT_LOAD; ph[0].p_flags = PF_R | PF_W | PF_X;
        ph[0].p_vaddr = kBase; ph[0].p_filesz = kSize; ph[0].p_memsz = kSize;
        ph[0].p_align = 0x10000;
        ph[1].p_type = PT_DYNAMIC; ph[1].p_vaddr = kBase + kDynOff;
        ph[1].p_offset = kDynOff;
    }
    std::string save(const char *pattern) {
        char path[64]; std::snprintf(path, sizeof(path), "%s", pattern);
        int fd = mkstemp(path); assert(fd >= 0);
        size_t at = 0;
        while (at < bytes.size()) {
            ssize_t n = ::write(fd, bytes.data() + at, bytes.size() - at);
            assert(n > 0); at += static_cast<size_t>(n);
        }
        assert(close(fd) == 0);
        return path;
    }
};

void put_word(std::vector<uint8_t>& b, size_t off, uint32_t word) {
    std::memcpy(b.data() + off, &word, sizeof(word));
}
std::string build_provider() {
    Image im;
    const char strings[] = "\0aggregate_provider\0";
    Elf64_Sym syms[2]{};
    syms[1].st_name = 1;
    syms[1].st_info = ((1 << 4) + 2);
    syms[1].st_shndx = 1; syms[1].st_value = kBase + kProviderOff; syms[1].st_size = 12;
    Elf64_Dyn dyn[7]{};
    dyn[0].d_tag = DT_SYMTAB; dyn[0].d_un.d_ptr = kBase + kSymOff;
    dyn[1].d_tag = DT_SYMENT; dyn[1].d_un.d_val = sizeof(Elf64_Sym);
    dyn[2].d_tag = DT_STRTAB; dyn[2].d_un.d_ptr = kBase + kStrOff;
    dyn[3].d_tag = DT_STRSZ; dyn[3].d_un.d_val = sizeof(strings);
    dyn[4].d_tag = DT_HASH; dyn[4].d_un.d_ptr = kBase + kHashOff;
    dyn[5].d_tag = DT_NULL;
    im.ph[1].p_filesz = im.ph[1].p_memsz = 6 * sizeof(Elf64_Dyn);
    std::memcpy(im.bytes.data(), &im.eh, sizeof(im.eh));
    std::memcpy(im.bytes.data() + sizeof(im.eh), im.ph, sizeof(im.ph));
    std::memcpy(im.bytes.data() + kDynOff, dyn, 6 * sizeof(Elf64_Dyn));
    std::memcpy(im.bytes.data() + kSymOff, syms, sizeof(syms));
    std::memcpy(im.bytes.data() + kStrOff, strings, sizeof(strings));
    const uint32_t hash[2] = {1, 2}, chains[3] = {0, 0, 0};
    std::memcpy(im.bytes.data() + kHashOff, hash, sizeof(hash));
    std::memcpy(im.bytes.data() + kHashOff + sizeof(hash), chains, sizeof(chains));
    // Models a nontrivial C++ 16-byte aggregate's INDIRECT result convention.
    // An ordinary trivial 16-byte AAPCS64 aggregate uses x0/x1, NOT x8.
    // stp x0,x1,[x8]; ret. x8 is the indirect aggregate-result pointer.
    put_word(im.bytes, kProviderOff, 0xa9000500); // STP X0, X1, [X8]
    put_word(im.bytes, kProviderOff + 4, 0xd65f03c0); // RET
    put_word(im.bytes, kProviderOff + 8, 0xd503201f); // NOP
    return im.save("/tmp/eili-aggregate-provider-XXXXXX");
}
std::string build_caller() {
    Image im;
    const char strings[] = "\0aggregate_provider\0";
    Elf64_Sym syms[2]{};
    syms[1].st_name = 1;
    syms[1].st_info = ((1 << 4) + 2);
    syms[1].st_shndx = 0;
    Elf64_Dyn dyn[10]{};
    dyn[0].d_tag = DT_SYMTAB; dyn[0].d_un.d_ptr = kBase + kSymOff;
    dyn[1].d_tag = DT_SYMENT; dyn[1].d_un.d_val = sizeof(Elf64_Sym);
    dyn[2].d_tag = DT_STRTAB; dyn[2].d_un.d_ptr = kBase + kStrOff;
    dyn[3].d_tag = DT_STRSZ; dyn[3].d_un.d_val = sizeof(strings);
    dyn[4].d_tag = DT_HASH; dyn[4].d_un.d_ptr = kBase + kHashOff;
    dyn[5].d_tag = DT_JMPREL; dyn[5].d_un.d_ptr = kBase + kRelaOff;
    dyn[6].d_tag = DT_PLTRELSZ; dyn[6].d_un.d_val = sizeof(Elf64_Rela);
    dyn[7].d_tag = DT_PLTREL; dyn[7].d_un.d_val = DT_RELA;
    dyn[8].d_tag = DT_NULL;
    im.ph[1].p_filesz = im.ph[1].p_memsz = 9 * sizeof(Elf64_Dyn);
    std::memcpy(im.bytes.data(), &im.eh, sizeof(im.eh));
    std::memcpy(im.bytes.data() + sizeof(im.eh), im.ph, sizeof(im.ph));
    std::memcpy(im.bytes.data() + kDynOff, dyn, 9 * sizeof(Elf64_Dyn));
    std::memcpy(im.bytes.data() + kSymOff, syms, sizeof(syms));
    std::memcpy(im.bytes.data() + kStrOff, strings, sizeof(strings));
    const uint32_t hash[2] = {1, 2}, chains[3] = {0, 0, 0};
    std::memcpy(im.bytes.data() + kHashOff, hash, sizeof(hash));
    std::memcpy(im.bytes.data() + kHashOff + sizeof(hash), chains, sizeof(chains));
    Elf64_Rela rela{};
    rela.r_offset = kBase + kGotOff;
    rela.r_info = (((uint64_t)1 << 32) | R_AARCH64_JUMP_SLOT);
    std::memcpy(im.bytes.data() + kRelaOff, &rela, sizeof(rela));
    // Standard aligned stack frame preserves callee-saved FP and LR across BLR.
    put_word(im.bytes, kCallerOff, 0xa9bf7bfd); // STP X29, X30, [SP,#-16]!
    put_word(im.bytes, kCallerOff + 4, 0x910003fd); // MOV X29, SP
    put_word(im.bytes, kCallerOff + 8, 0xaa0203e8); // MOV X8, X2
    const int64_t displacement = int64_t(kGotOff) - int64_t(kCallerOff + 12);
    assert(displacement % 4 == 0);
    const uint32_t ldr = 0x58000010 | ((uint32_t(displacement / 4) & 0x7ffff) << 5);
    put_word(im.bytes, kCallerOff + 12, ldr); // LDR X16, literal GOT
    put_word(im.bytes, kCallerOff + 16, 0xd63f0200); // BLR X16
    put_word(im.bytes, kCallerOff + 20, 0xa8c17bfd); // LDP X29, X30, [SP],#16
    put_word(im.bytes, kCallerOff + 24, 0xd65f03c0); // RET
    return im.save("/tmp/eili-aggregate-caller-XXXXXX");
}
} // namespace

int main() {
    const std::string provider = build_provider();
    const std::string caller = build_caller();
    EmulatorVM vm;
    assert(load_library_to_vm(&vm, caller, "synthetic-aggregate-caller.so"));
    assert(load_library_to_vm(&vm, provider, "synthetic-aggregate-provider.so"));
    relocate_all_vm_libraries(&vm);
    assert(vm.execution_error.empty());
    assert(preflight_vm_libraries(&vm));
    const auto &root = vm.loaded_libraries[0];
    const auto &impl = vm.loaded_libraries[1];
    assert(root.symbols.count("aggregate_provider") == 0);
    assert(impl.symbols.count("aggregate_provider") == 1);
    uint64_t slot = 0;
    assert(uc_mem_read(vm.uc, root.base_address + kGotOff, &slot, sizeof(slot)) == UC_ERR_OK);
    assert(slot == impl.base_address + kProviderOff);

    // Guarded 16-byte aggregate storage: the arguments must be copied intact
    // through x0/x1, and the provider must write via x8 without touching guards.
    constexpr uint64_t arg0 = 0x0123456789abcdefULL;
    constexpr uint64_t arg1 = 0xfedcba9876543210ULL;
    const uint64_t buffer = 0x71001000;
    assert(uc_mem_map(vm.uc, buffer, 0x1000, UC_PROT_READ | UC_PROT_WRITE) == UC_ERR_OK);
    const uint64_t initial[4] = {kGuardLo, 0, 0, kGuardHi};
    assert(uc_mem_write(vm.uc, buffer, initial, sizeof(initial)) == UC_ERR_OK);
    // Caller-provided arguments x0, x1, x2; caller instruction copies x2 -> x8
    // before making the relocated indirect call. MOV X8,X2 = 0xaa0203e8.
    const std::vector<uint64_t> args = {arg0, arg1, buffer + sizeof(uint64_t)};
    const uint64_t saved_fp = 0x3141592653589793ULL;
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X29, &saved_fp) == UC_ERR_OK);
    const int32_t result = run_vm_procedure(&vm, root.base_address + kCallerOff, args, 1000000, 64);
    assert(result == static_cast<int32_t>(arg0));
    assert(vm.execution_error.empty());
    uint64_t actual[4]{};
    assert(uc_mem_read(vm.uc, buffer, actual, sizeof(actual)) == UC_ERR_OK);
    assert(actual[0] == kGuardLo);
    assert(actual[1] == arg0 && actual[2] == arg1);
    assert(actual[3] == kGuardHi);
    uint64_t fp = 0, sp = 0;
    assert(uc_reg_read(vm.uc, UC_ARM64_REG_X29, &fp) == UC_ERR_OK && fp == saved_fp);
    assert(uc_reg_read(vm.uc, UC_ARM64_REG_SP, &sp) == UC_ERR_OK && sp == kStackAddress + kStackSize - 16);

    // Trivial 16-byte aggregate control: a RET callee leaves both full-width
    // values in x0/x1. Merely setting x8 must NOT write an indirect result.
    assert(uc_mem_write(vm.uc, buffer, initial, sizeof(initial)) == UC_ERR_OK);
    assert(run_vm_procedure(&vm, impl.base_address + kProviderOff + 4,
        {arg0, arg1}, 1000000, 8) == static_cast<int32_t>(arg0));
    uint64_t x0 = 0, x1 = 0;
    assert(uc_reg_read(vm.uc, UC_ARM64_REG_X0, &x0) == UC_ERR_OK && x0 == arg0);
    assert(uc_reg_read(vm.uc, UC_ARM64_REG_X1, &x1) == UC_ERR_OK && x1 == arg1);
    assert(uc_mem_read(vm.uc, buffer, actual, sizeof(actual)) == UC_ERR_OK);
    assert(std::memcmp(actual, initial, sizeof initial) == 0);
    assert(vm.execution_error.empty() && vm.fallback_import_calls.empty());
    assert(unlink(caller.c_str()) == 0 && unlink(provider.c_str()) == 0);
    std::cout << "PASS: relocated AArch64 JUMP_SLOT indirect 16-byte aggregate return via x8; arguments, guards, and LR preserved\n";
    return 0;
}
