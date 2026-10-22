// Exercises only self-authored ARM64 guest code and synthetic ELF metadata.
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp"
#include "Fixtures/module-iteration-callbacks.h"
#include <cassert>
#include <cstring>
#include <iostream>

namespace {
constexpr uint64_t kCode = 0x05000000;
constexpr uint64_t kCallback = kCode + kSyntheticIterationCallbackOffset;
struct Context {
    uint64_t calls = 0, entry = 0, size = 0, userdata = 0;
    uint64_t strlen_stub = 0, unused_text = 0, strlen_result = 0;
    uint64_t int_result = 0, high_bits = 0, nested_iterate = 0;
    uint64_t callback = 0, depth = 0, unused = 0, nested_result = 0;
};
static_assert(offsetof(Context, strlen_stub) == 32 && offsetof(Context, int_result) == 56);
static_assert(offsetof(Context, high_bits) == 64 && offsetof(Context, nested_result) == 104);
struct Entry { uint64_t bias, name, phdr; uint16_t phnum; uint8_t padding[6]; };
static_assert(sizeof(Entry) == 32);

template<class T> T read(EmulatorVM &vm, uint64_t pointer) {
    T value{};
    assert(uc_mem_read(vm.uc, pointer, &value, sizeof value) == UC_ERR_OK);
    return value;
}
struct Setup { uint64_t context, iterate; };
Setup setup(EmulatorVM &vm, int32_t result = 0, bool high_bits = false, bool nested = false) {
    assert(vm.initialization_error == UC_ERR_OK);
    assert(uc_mem_map(vm.uc, kCode, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
    assert(uc_mem_write(vm.uc, kCode, kSyntheticModuleCallbackWords, sizeof kSyntheticModuleCallbackWords) == UC_ERR_OK);
    assert(uc_mem_protect(vm.uc, kCode, 0x1000, UC_PROT_READ | UC_PROT_EXEC) == UC_ERR_OK);
    const uint64_t iterate = vm.register_import("dl_iterate_phdr");
    Context context;
    context.strlen_stub = vm.register_import("strlen");
    context.int_result = static_cast<uint32_t>(result);
    context.high_bits = high_bits ? 1 : 0;
    context.nested_iterate = nested ? iterate : 0;
    context.callback = kCallback;
    assert(iterate && context.strlen_stub);
    const uint64_t pointer = vm.write_bytes(reinterpret_cast<const uint8_t *>(&context), sizeof context);
    assert(pointer);
    return {pointer, iterate};
}
void add_module(EmulatorVM &vm, const char *name, uint64_t base) {
    EmulatorVM::LibraryInfo lib{};
    lib.name = name;
    lib.base_address = base;
    lib.min_vaddr = 0x1000;
    lib.program_header_count = 1;
    Elf64_Phdr header{};
    header.p_type = PT_LOAD;
    header.p_vaddr = lib.min_vaddr;
    const auto data = reinterpret_cast<const uint8_t *>(&header);
    lib.program_headers.assign(data, data + sizeof header);
    vm.loaded_libraries.push_back(lib);
}
void add_pair(EmulatorVM &vm) {
    add_module(vm, "first.so", 0x10001000);
    add_module(vm, "second.so", 0x20001000);
}
int32_t invoke(EmulatorVM &vm, Setup s, uint64_t callback = kCallback) {
    return run_vm_procedure(&vm, kCode, {callback, s.context, s.iterate}, 1000000, 10000);
}
void require_failure(EmulatorVM &vm, Setup s, uint64_t callback = kCallback) {
    assert(invoke(vm, s, callback) < 0 && !vm.execution_error.empty());
}
}

int main() {
    {
        EmulatorVM vm;
        const auto s = setup(vm);
        add_pair(vm);
        const int registers[] = {UC_ARM64_REG_X19, UC_ARM64_REG_X20, UC_ARM64_REG_X21,
                                 UC_ARM64_REG_X22, UC_ARM64_REG_X23, UC_ARM64_REG_X24};
        for (size_t i = 0; i < 6; ++i) {
            uint64_t seed = 0x19190000 + i;
            assert(uc_reg_write(vm.uc, registers[i], &seed) == UC_ERR_OK);
        }
        assert(invoke(vm, s) == 0 && vm.execution_error.empty());
        for (size_t i = 0; i < 6; ++i) {
            uint64_t value = 0;
            assert(uc_reg_read(vm.uc, registers[i], &value) == UC_ERR_OK);
            assert(value == 0x19190000 + i);
        }
        uint64_t sp = 0, lr = 0;
        assert(uc_reg_read(vm.uc, UC_ARM64_REG_SP, &sp) == UC_ERR_OK);
        assert(uc_reg_read(vm.uc, UC_ARM64_REG_LR, &lr) == UC_ERR_OK);
        assert(sp == kStackAddress + kStackSize - 16 && lr == kReturnAddress);
        const auto observed = read<Context>(vm, s.context);
        assert(observed.calls == vm.loaded_libraries.size());
        assert(observed.size == sizeof(Entry) && observed.userdata == s.context);
        assert(observed.strlen_result == std::strlen("second.so"));
        const auto entry = read<Entry>(vm, observed.entry);
        const auto &last = vm.loaded_libraries.back();
        assert(entry.bias == last.base_address - last.min_vaddr && entry.phnum == 1);
        char name[32]{};
        assert(uc_mem_read(vm.uc, entry.name, name, sizeof name) == UC_ERR_OK);
        assert(std::strcmp(name, "second.so") == 0);
        const auto header = read<Elf64_Phdr>(vm, entry.phdr);
        assert(header.p_type == PT_LOAD && header.p_vaddr == last.min_vaddr);
        // The linker exposes the implemented adapter through libdl, not libc.
        const uint64_t module = vm.write_string("libdl.so"), symbol = vm.write_string("dl_iterate_phdr");
        const auto import64 = [&](const char *name, std::vector<uint64_t> args) {
            const auto stub = vm.register_import(name);
            assert(stub);
            (void)run_vm_procedure(&vm, stub, args, 1000000, 10000);
            assert(vm.execution_error.empty());
            uint64_t value = 0;
            assert(uc_reg_read(vm.uc, UC_ARM64_REG_X0, &value) == UC_ERR_OK);
            return value;
        };
        const auto handle = import64("dlopen", {module, 2});
        assert(handle && import64("dlsym", {handle, symbol}) == s.iterate);
    }
    for (int32_t result : {37, -7}) {
        EmulatorVM vm;
        const auto s = setup(vm, result);
        add_pair(vm);
        assert(invoke(vm, s) == result && vm.execution_error.empty());
        assert(read<Context>(vm, s.context).calls == 1);
    }
    {
        EmulatorVM vm;
        const auto s = setup(vm, 0, true);
        add_pair(vm);
        assert(invoke(vm, s) == 0 && vm.execution_error.empty());
        assert(read<Context>(vm, s.context).calls == vm.loaded_libraries.size());
    }
    {
        EmulatorVM vm;
        const auto s = setup(vm, 0, false, true);
        add_pair(vm);
        assert(invoke(vm, s) == 0 && vm.execution_error.empty());
        const auto context = read<Context>(vm, s.context);
        assert(context.calls == vm.loaded_libraries.size() * (1 + vm.loaded_libraries.size()));
        assert(context.depth == 0 && context.nested_result == 0);
    }
    {
        EmulatorVM vm;
        const auto s = setup(vm);
        assert(invoke(vm, s) == 0 && vm.execution_error.empty());
        assert(read<Context>(vm, s.context).calls == 0);
    }
    for (uint64_t callback : {uint64_t(0), kCallback + 1, uint64_t(0x090000000), kHeapAddress}) {
        EmulatorVM vm;
        const auto s = setup(vm);
        require_failure(vm, s, callback);
    }
    {
        EmulatorVM vm;
        const auto s = setup(vm);
        add_pair(vm);
        vm.loaded_libraries[0].program_headers.clear();
        require_failure(vm, s);
    }
    {
        EmulatorVM vm;
        const auto s = setup(vm);
        add_pair(vm);
        vm.loaded_libraries[0].program_headers_guest = 0x090000000;
        require_failure(vm, s);
    }
    {
        EmulatorVM vm;
        const auto s = setup(vm);
        add_pair(vm);
        auto &lib = vm.loaded_libraries[0];
        constexpr uint64_t unreadable = 0x05200000;
        assert(uc_mem_map(vm.uc, unreadable, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
        assert(uc_mem_write(vm.uc, unreadable, lib.program_headers.data(), lib.program_headers.size()) == UC_ERR_OK);
        assert(uc_mem_protect(vm.uc, unreadable, 0x1000, UC_PROT_NONE) == UC_ERR_OK);
        lib.program_headers_guest = unreadable;
        require_failure(vm, s);
    }
    {
        EmulatorVM vm;
        const auto s = setup(vm);
        for (size_t i = 0; i <= kAndroidModuleIterationMaxModules; ++i)
            add_module(vm, "bounded.so", 0x10001000);
        require_failure(vm, s);
    }
    {
        EmulatorVM vm;
        const auto s = setup(vm);
        add_pair(vm);
        vm.loaded_libraries[0].name.assign(4096, 'x');
        require_failure(vm, s);
    }
    std::cout << "PASS: real guest module callbacks, nested imports/iteration, int returns, ABI preservation and invalid metadata\n";
}
