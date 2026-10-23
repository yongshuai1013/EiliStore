// Self-authored ARM64 instructions and synthetic guest memory only.
#include "../Packages/AnisetteKit/Native/anisette_core_uc.cpp"
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>

namespace {
constexpr uint64_t kCode = 0x12000000;
constexpr uint64_t kGot = kCode + 0x2a0;
constexpr uint64_t kPc = kCode + 0x100;
constexpr uint64_t kTarget = 0x20000102a0d63;
using VM = EmulatorVM;
void put(VM &vm, uint64_t address, const void *p, size_t n) {
    assert(uc_mem_write(vm.uc, address, p, n) == UC_ERR_OK);
}
void setup(VM &vm) {
    assert(uc_mem_map(vm.uc, kCode, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
    const uint32_t imm12 = 0x2a0 / 8;
    const uint32_t words[] = {0x90000010, 0xF9400211 | (imm12 << 10),
                              0x91000210 | (0x2a0 << 10), 0xD61F0220};
    put(vm, kPc - 12, words, sizeof words);
    put(vm, kGot, &kTarget, sizeof kTarget);
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X17, &kTarget) == UC_ERR_OK);
    vm.constructor_context.active = true;
    vm.constructor_context.library = VM::ConstructorLibrary::storeservicescore;
    vm.execution_depth = 1;
    vm.cxa_atexit_slots.push_back({kGot, kPc - 12, kPc + 4, VM::ResolutionSource::functionStub});
}
void observe_path(VM &vm) {
    vm.observe_pc(kPc - 12); vm.observe_pc(kPc - 8); vm.observe_pc(kPc - 4); vm.observe_pc(kPc);
}
void branch_and_clear() {
    VM vm; setup(vm); observe_path(vm); vm.observe_cxa_atexit_branch(kPc);
    assert(vm.pending_cxa_branch.present && vm.pending_cxa_branch.branch_pc == kPc);
    assert(vm.pending_cxa_branch.got_address == kGot);
    assert(vm.pending_cxa_branch.has_got_value && vm.pending_cxa_branch.got_value == kTarget);
    assert(!vm.pending_cxa_branch.registered_stub && vm.pending_cxa_branch.source == VM::ResolutionSource::functionStub);
    vm.observe_cxa_atexit_branch(kPc + 4); assert(!vm.pending_cxa_branch.present);
    const auto stub = vm.register_import("__cxa_atexit");
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X17, &stub) == UC_ERR_OK);
    vm.observe_cxa_atexit_branch(kPc);
    assert(vm.pending_cxa_branch.present && vm.pending_cxa_branch.registered_stub);
    assert(vm.pending_cxa_branch.target == stub && vm.pending_cxa_branch.got_value == kTarget);
    const auto ordinary = vm.register_import("ordinary_unknown");
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X17, &ordinary) == UC_ERR_OK);
    vm.observe_cxa_atexit_branch(kPc);
    assert(vm.pending_cxa_branch.present && !vm.pending_cxa_branch.registered_stub);
}
void gating_and_malformed_pattern() {
    VM vm; setup(vm); vm.constructor_context.library = VM::ConstructorLibrary::other;
    vm.observe_cxa_atexit_branch(kPc); assert(!vm.pending_cxa_branch.present);
    vm.constructor_context.library = VM::ConstructorLibrary::storeservicescore;
    const uint32_t bad = 0xD503201F; put(vm, kPc - 8, &bad, sizeof bad); observe_path(vm);
    vm.observe_cxa_atexit_branch(kPc); assert(!vm.pending_cxa_branch.present);
    VM isolated; assert(isolated.cxa_atexit_slots.empty() && !isolated.pending_cxa_branch.present);
}

VM::LibraryInfo &library(VM &vm) {
    VM::LibraryInfo lib{};
    lib.name = kADISymbols.lib_ssc; lib.base_address = kCode; lib.min_vaddr = 0;
    lib.max_vaddr = 0x1000; lib.init_func = kPc - 12;
    lib.symtab = kCode + 0x300; lib.strtab = kCode + 0x380; lib.strsz = 32;
    lib.jmprel = kCode + 0x400; lib.pltrelsz = sizeof(Elf64_Rela);
    vm.loaded_libraries.push_back(lib); return vm.loaded_libraries.back();
}
void relocate(VM &vm, VM::LibraryInfo &lib, int64_t addend = 0) {
    const char strings[] = "\0__cxa_atexit\0";
    put(vm, lib.strtab, strings, sizeof strings);
    Elf64_Sym sym{}; sym.st_name = 1; sym.st_info = 0x12;
    put(vm, lib.symtab + sizeof(Elf64_Sym), &sym, sizeof sym);
    Elf64_Rela rela{}; rela.r_offset = 0x2a0;
    rela.r_info = (uint64_t(1) << 32) | R_AARCH64_JUMP_SLOT; rela.r_addend = addend;
    put(vm, lib.jmprel, &rela, sizeof rela);
    apply_vm_relocations(&vm, lib);
}
void actual_valid_relocation_and_constructor() {
    VM vm; setup(vm); auto &lib = library(vm); relocate(vm, lib);
    assert(vm.cxa_atexit_slots.size() == 1);
    assert(vm.cxa_atexit_slots[0].address == kGot && vm.cxa_atexit_slots[0].source == VM::ResolutionSource::functionStub);
    const auto stub = vm.imported_symbols.at("__cxa_atexit");
    uint64_t got = 0; assert(uc_mem_read(vm.uc, kGot, &got, sizeof got) == UC_ERR_OK && got == stub);
    assert(run_library_constructors(&vm));
    assert(vm.fallback_import_calls.at("__cxa_atexit") == 1);
    assert(!vm.fault.present && !vm.fault.fetch.cxa_branch.present);
}
void actual_bad_got_target() {
    VM vm; setup(vm); auto &lib = library(vm); relocate(vm, lib);
    put(vm, kGot, &kTarget, sizeof kTarget);
    assert(!run_library_constructors(&vm));
    assert(vm.fault.present && vm.fault.fetch.present && vm.fault.fetch.address == kTarget);
    const auto &b = vm.fault.fetch.cxa_branch;
    assert(b.present && b.target == kTarget && b.got_address == kGot && b.got_value == kTarget);
    assert(!b.registered_stub && b.source == VM::ResolutionSource::functionStub);
    const auto json = diagnostic_error_json("failure", "libraryConstructors", false, 0, &vm.fault);
    assert(json.find("\"cxa_atexit_branch\"") != std::string::npos);
    assert(json.find("\"branch_pc\"") == std::string::npos);
    assert(diagnostic_error_json("failure", "otherPhase", false, 0, &vm.fault).find("cxa_atexit_branch") == std::string::npos);
}
void malformed_addend_and_unknown_import() {
    VM vm; setup(vm); auto &lib = library(vm); relocate(vm, lib, 0x10000000);
    uint64_t bad = 0; assert(uc_mem_read(vm.uc, kGot, &bad, sizeof bad) == UC_ERR_OK);
    assert(bad == vm.imported_symbols.at("__cxa_atexit") + 0x10000000);
    assert(!run_library_constructors(&vm));
    assert(vm.fault.fetch.cxa_branch.present && !vm.fault.fetch.cxa_branch.registered_stub);
    VM unknown; const auto ordinary = unknown.register_import("ordinary_unknown");
    assert(ordinary && unknown.import_stubs.at(ordinary) == "ordinary_unknown");
    assert(unknown.import_stubs.at(ordinary) != "__cxa_atexit");
}
void provenance_and_snapshot_gating() {
    VM vm; setup(vm);
    VM::LibraryInfo provider{}; provider.symbols["__cxa_atexit"] = kCode + 0x500;
    vm.loaded_libraries.push_back(provider);
    auto &lib = library(vm);
    relocate(vm, lib);
    assert(vm.cxa_atexit_slots[0].source == VM::ResolutionSource::librarySymbol);
    uint64_t got = 0; assert(uc_mem_read(vm.uc, kGot, &got, sizeof got) == UC_ERR_OK && got == kCode + 0x500);
    VM unrelated; setup(unrelated); unrelated.constructor_context.library = VM::ConstructorLibrary::other;
    observe_path(unrelated); unrelated.observe_cxa_atexit_branch(kPc);
    assert(!unrelated.pending_cxa_branch.present);
    const auto no_fault = diagnostic_error_json("ok", "otherPhase", false, 0, nullptr);
    assert(no_fault.find("fetch_address") == std::string::npos && no_fault.find("cxa_atexit_branch") == std::string::npos);
    VM reset; reset.record_fault(VM::FaultReason::engine, true, UC_ERR_FETCH_UNMAPPED, true, kTarget);
    reset.execution_error.clear(); assert(run_library_constructors(&reset));
    assert(!reset.fault.present);
}
}
int main() {
    branch_and_clear(); gating_and_malformed_pattern(); actual_valid_relocation_and_constructor();
    actual_bad_got_target(); malformed_addend_and_unknown_import(); provenance_and_snapshot_gating();
    std::cout << "PASS: relocation-backed synthetic __cxa_atexit constructor paths\n";
}
