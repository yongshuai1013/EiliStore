// Only generated ELF metadata/data is read; no guest code or Apple library is executed.
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.h"
#include <cassert>
#include <cstring>
#include <functional>
#include <iostream>
#include <unistd.h>

struct Fixture {
    Elf64_Ehdr header{};
    Elf64_Phdr headers[2]{};
    Fixture() {
        std::memcpy(header.e_ident, "\x7f" "ELF\x02\x01\x01", 7);
        header.e_type = 3;
        header.e_machine = 183;
        header.e_version = 1;
        header.e_ehsize = sizeof header;
        header.e_phoff = sizeof header;
        header.e_phentsize = sizeof(Elf64_Phdr);
        header.e_phnum = 2;
        headers[0].p_type = PT_LOAD;
        headers[0].p_flags = 6;
        headers[0].p_vaddr = 0x20000;
        headers[0].p_filesz = 512;
        headers[0].p_memsz = 0x10200;
        headers[0].p_align = 0x10000;
        headers[1].p_type = 4; // PT_NOTE, preserves a second real header.
        headers[1].p_offset = 0x180;
        headers[1].p_filesz = 16;
    }
    std::vector<uint8_t> bytes() const {
        std::vector<uint8_t> result(512, 0);
        std::memcpy(result.data(), &header, sizeof header);
        // Keep the real table in bounds even when a test corrupts e_phoff.
        std::memcpy(result.data() + sizeof header, headers, sizeof headers);
        return result;
    }
};

static bool load(EmulatorVM &vm, const std::vector<uint8_t> &bytes) {
    char path[] = "/tmp/eili-synthetic-elf-XXXXXX";
    const int fd = mkstemp(path);
    assert(fd >= 0);
    size_t written = 0;
    while (written < bytes.size()) {
        const auto count = write(fd, bytes.data() + written, bytes.size() - written);
        assert(count > 0);
        written += static_cast<size_t>(count);
    }
    assert(close(fd) == 0);
    const bool result = load_library_to_vm(&vm, path, "libsynthetic-headers.so");
    assert(unlink(path) == 0);
    return result;
}

static void reject(const std::function<void(Fixture &)> &mutate) {
    Fixture fixture;
    mutate(fixture);
    EmulatorVM vm;
    assert(!load(vm, fixture.bytes()));
    assert(vm.loaded_libraries.empty());
}

int main() {
    Fixture fixture;
    EmulatorVM vm;
    assert(load(vm, fixture.bytes()));
    assert(vm.loaded_libraries.size() == 1);
    const auto &lib = vm.loaded_libraries.front();
    assert(lib.min_vaddr == 0x20000 && lib.program_header_count == 2);
    assert(lib.program_headers.size() == sizeof fixture.headers);
    assert(std::memcmp(lib.program_headers.data(), fixture.headers, sizeof fixture.headers) == 0);
    Elf64_Phdr guest_headers[2]{};
    assert(uc_mem_read(vm.uc, lib.program_headers_guest, guest_headers, sizeof guest_headers) == UC_ERR_OK);
    assert(std::memcmp(guest_headers, fixture.headers, sizeof guest_headers) == 0);
    uint8_t bss[64];
    std::memset(bss, 0xFF, sizeof bss);
    assert(uc_mem_read(vm.uc, lib.base_address + 0x101C0, bss, sizeof bss) == UC_ERR_OK);
    for (uint8_t value : bss) assert(value == 0);

    // SideStore loads only the selected ADI pair, not the DT_NEEDED closure.
    // Synthetic absent dependencies must not be opened or cause loader failure.
    Fixture dependencies;
    dependencies.headers[1].p_type = PT_DYNAMIC;
    dependencies.headers[1].p_offset = 0x100;
    dependencies.headers[1].p_vaddr = 0x20100;
    dependencies.headers[1].p_filesz = dependencies.headers[1].p_memsz = 6 * sizeof(Elf64_Dyn);
    auto dependency_bytes = dependencies.bytes();
    const char names[] = "\0libmediaplatform.so\0libCoreFoundation.so\0libc++_shared.so\0";
    Elf64_Dyn dynamic[6]{};
    dynamic[0].d_tag = DT_STRTAB; dynamic[0].d_un.d_val = 0x20180;
    dynamic[1].d_tag = DT_STRSZ; dynamic[1].d_un.d_val = sizeof names;
    dynamic[2].d_tag = DT_NEEDED; dynamic[2].d_un.d_val = 1;
    dynamic[3].d_tag = DT_NEEDED; dynamic[3].d_un.d_val = 21;
    dynamic[4].d_tag = DT_NEEDED; dynamic[4].d_un.d_val = 42;
    std::memcpy(dependency_bytes.data() + 0x100, dynamic, sizeof dynamic);
    std::memcpy(dependency_bytes.data() + 0x180, names, sizeof names);
    EmulatorVM dependency_vm;
    assert(load(dependency_vm, dependency_bytes));
    assert(dependency_vm.execution_error.empty() && dependency_vm.loaded_libraries.size() == 1);
    relocate_all_vm_libraries(&dependency_vm);
    assert(dependency_vm.execution_error.empty());

    Fixture unaligned;
    unaligned.header.e_phoff = sizeof(Elf64_Ehdr) + 1;
    auto unaligned_bytes = unaligned.bytes();
    std::memcpy(unaligned_bytes.data() + unaligned.header.e_phoff, unaligned.headers, sizeof unaligned.headers);
    EmulatorVM unaligned_vm;
    assert(load(unaligned_vm, unaligned_bytes));
    reject([](Fixture &f) { f.header.e_machine = 62; });
    reject([](Fixture &f) { f.header.e_version = 0; });
    reject([](Fixture &f) { f.header.e_ehsize = 0; });
    reject([](Fixture &f) { f.header.e_phoff = 1; });
    reject([](Fixture &f) { f.header.e_type = 2; });
    reject([](Fixture &f) { f.header.e_phentsize = 1; });
    reject([](Fixture &f) { f.header.e_phnum = 0; });
    reject([](Fixture &f) { f.header.e_phnum = 1025; });
    reject([](Fixture &f) { f.header.e_phoff = UINT64_MAX; });
    reject([](Fixture &f) { f.header.e_phoff = 500; });
    reject([](Fixture &f) { f.headers[0].p_offset = 513; });
    reject([](Fixture &f) { f.headers[0].p_filesz = 513; });
    reject([](Fixture &f) { f.headers[0].p_memsz = 1; });
    reject([](Fixture &f) { f.headers[0].p_vaddr = UINT64_MAX - 4; });
    reject([](Fixture &f) { f.headers[0].p_memsz = UINT64_MAX; });
    reject([](Fixture &f) { f.headers[0].p_filesz = f.headers[0].p_memsz = 0; });
    reject([](Fixture &f) { f.headers[1].p_type = PT_DYNAMIC; f.headers[1].p_vaddr = UINT64_MAX; });
    Fixture tls;
    tls.headers[1].p_type = 7; // PT_TLS is ignored like SideStore, not implemented.
    EmulatorVM tls_vm;
    assert(load(tls_vm, tls.bytes()) && tls_vm.execution_error.empty());
    EmulatorVM empty;
    assert(!load(empty, {}));
    assert(!load(empty, std::vector<uint8_t>(sizeof(Elf64_Ehdr) - 1, 0)));
    std::cout << "PASS: generated ELF bounds, exact headers, BSS and SideStore DT_NEEDED/PT_TLS ignore policy (not TLS support)\n";
}
