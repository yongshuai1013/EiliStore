// Host-side regression tests for native Anisette output validation.
// Compile with anisette_core_uc.cpp included here, plus elf_loader_emulator.cpp
// and anisette_base.cpp; these tests never load an Apple-provided library.
#include "../Packages/AnisetteKit/Native/anisette_core_uc.cpp"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {

std::string make_temp_dir() {
    char pattern[] = "/tmp/native-adi-output-tests-XXXXXX";
    char *p = mkdtemp(pattern);
    assert(p != nullptr);
    return p;
}

std::string child(const std::string &p, const std::string &name) {
    return p + "/" + name;
}

void put_guest(EmulatorVM *vm, uint64_t addr, const void *p, size_t n) {
    assert(uc_mem_write(vm->uc, addr, p, n) == UC_ERR_OK);
}

void map_code_and_stub(EmulatorVM *vm, uint64_t addr) {
    assert(uc_mem_map(vm->uc, addr, 0x1000, UC_PROT_ALL) == UC_ERR_OK);
    // AArch64: mov x0, #0; ret. The only executed guest code is this local stub.
    const uint32_t code[] = {0xD2800000u, 0xD65F03C0u};
    put_guest(vm, addr, code, sizeof(code));
}

void inject_symbol(EmulatorVM *vm, const char *symbol, uint64_t addr) {
    if (vm->loaded_libraries.empty()) {
        EmulatorVM::LibraryInfo lib{};
        lib.name = "synthetic-local-test-library";
        vm->loaded_libraries.push_back(lib);
    }
    vm->loaded_libraries.front().symbols[symbol] = addr;
}

void reset_synthetic_vm() {
    reset_anisette_vm_uc();
}

void prepare_initialized_vm(const std::string &provdir, const uint8_t id[16]) {
    reset_synthetic_vm();
    g_shared_vm = new EmulatorVM();
    assert(g_shared_vm->uc != nullptr);
    assert(g_shared_vm->initialization_error == UC_ERR_OK);
    g_libraries_initialized = true; // skip all library loading and ADISet calls
    g_current_prov_path = child(provdir, format_uuid_string(id));
    assert(mkdir(g_current_prov_path.c_str(), 0700) == 0 || errno == EEXIST);
    g_current_android_id = get_android_id_string(id);
}

void test_read_guest_bytes() {
    EmulatorVM vm;
    assert(vm.uc != nullptr && vm.initialization_error == UC_ERR_OK);
    constexpr uint64_t slots = 0x10000;
    constexpr uint64_t payload = 0x11000;
    assert(uc_mem_map(vm.uc, slots, 0x3000, UC_PROT_ALL) == UC_ERR_OK);
    const uint8_t bytes[] = {0x41, 0x00, 0xFE, 0x7F};
    uint64_t pointer = payload;
    uint32_t length = sizeof(bytes);
    put_guest(&vm, slots, &pointer, sizeof(pointer));
    put_guest(&vm, slots + 8, &length, sizeof(length));
    put_guest(&vm, payload, bytes, sizeof(bytes));
    uint8_t *out = nullptr;
    uint32_t out_len = 0;
    assert(read_guest_bytes(&vm, slots, slots + 8, &out, &out_len));
    assert(out_len == sizeof(bytes) && std::memcmp(out, bytes, sizeof(bytes)) == 0);
    delete[] out;

    // An exact-limit length is accepted by the bound check, but an unmapped payload
    // still fails the read and releases the temporary host allocation.
    pointer = 0x90000000;
    length = 64u * 1024u * 1024u;
    put_guest(&vm, slots, &pointer, sizeof(pointer));
    put_guest(&vm, slots + 8, &length, sizeof(length));
    out = nullptr; out_len = 0;
    assert(!read_guest_bytes(&vm, slots, slots + 8, &out, &out_len));
    assert(out == nullptr && out_len == 0);

    // Above-limit length must be rejected before reading/allocating its payload.
    length = 64u * 1024u * 1024u + 1u;
    put_guest(&vm, slots + 8, &length, sizeof(length));
    assert(!read_guest_bytes(&vm, slots, slots + 8, &out, &out_len));
    assert(out == nullptr && out_len == 0);

    pointer = 0;
    length = sizeof(bytes);
    put_guest(&vm, slots, &pointer, sizeof(pointer));
    put_guest(&vm, slots + 8, &length, sizeof(length));
    assert(!read_guest_bytes(&vm, slots, slots + 8, &out, &out_len));
    pointer = payload;
    length = 0;
    put_guest(&vm, slots, &pointer, sizeof(pointer));
    put_guest(&vm, slots + 8, &length, sizeof(length));
    assert(!read_guest_bytes(&vm, slots, slots + 8, &out, &out_len));
    assert(!read_guest_bytes(nullptr, slots, slots + 8, &out, &out_len));
    assert(!read_guest_bytes(&vm, 0xdead0000, slots + 8, &out, &out_len));
    assert(!read_guest_bytes(&vm, slots, 0xdead0000, &out, &out_len));
    assert(!read_guest_bytes(&vm, slots, slots + 8, nullptr, &out_len));
    assert(!read_guest_bytes(&vm, slots, slots + 8, &out, nullptr));
}

void test_capi_invalid_and_oversize() {
    const uint8_t id[16] = {};
    const uint8_t tiny[] = {1};
    char *json = reinterpret_cast<char *>(1);
    assert(get_anisette_headers_uc("x", "y", id, tiny, 0, &json) == ANISETTE_ERR_INVALID_ARGUMENT && json == nullptr);
    json = reinterpret_cast<char *>(1);
    assert(get_anisette_headers_uc("x", "y", id, tiny, 64u * 1024u * 1024u + 1u, &json) == ANISETTE_ERR_INVALID_ARGUMENT && json == nullptr);
    json = reinterpret_cast<char *>(1);
    assert(start_provision_uc("x", "y", id, tiny, 64u * 1024u * 1024u + 1u, &json) == ANISETTE_ERR_INVALID_ARGUMENT && json == nullptr);
    json = reinterpret_cast<char *>(1);
    assert(end_provision_uc("x", "y", id, 1, tiny, 1, tiny, 64u * 1024u * 1024u + 1u, &json) == ANISETTE_ERR_INVALID_ARGUMENT && json == nullptr);
}

void test_synthetic_otp_and_file_io() {
    const uint8_t id[16] = {};
    const uint8_t pb[] = {0x08, 0x01};
    const uint8_t ptm[] = {0x01};
    const uint8_t tk[] = {0x02};
    const std::string root = make_temp_dir();
    const std::string libs = child(root, "local-libs");
    const std::string prov = child(root, "provisioning");
    assert(mkdir(libs.c_str(), 0700) == 0 && mkdir(prov.c_str(), 0700) == 0);
    const std::string uuid_dir = child(prov, format_uuid_string(id));
    char *json = nullptr;

    // OTP stub returns success but leaves all output slots untouched (zero): never accept as success.
    prepare_initialized_vm(prov, id);
    const uint64_t otp = 0x10000000;
    map_code_and_stub(g_shared_vm, otp);
    inject_symbol(g_shared_vm, kADISymbols.otp_request, otp);
    int32_t rc = get_anisette_headers_uc(libs.c_str(), prov.c_str(), id, pb, sizeof(pb), &json);
    assert(rc == ANISETTE_ERR_READ_FILE_FAILED);
    assert(json != nullptr && std::strstr(json, "Incomplete or invalid OTP response") != nullptr);
    free_c_string(json); json = nullptr;
    reset_synthetic_vm();
    assert(std::remove(child(uuid_dir, kADISymbols.adi_pb_filename).c_str()) == 0);

    // A directory at adi.pb makes fopen("wb") fail without relying on permissions/root behavior.
    prepare_initialized_vm(prov, id);
    map_code_and_stub(g_shared_vm, otp);
    inject_symbol(g_shared_vm, kADISymbols.otp_request, otp);
    assert(mkdir(child(uuid_dir, kADISymbols.adi_pb_filename).c_str(), 0700) == 0);
    rc = get_anisette_headers_uc(libs.c_str(), prov.c_str(), id, pb, sizeof(pb), &json);
    assert(rc == ANISETTE_ERR_READ_FILE_FAILED);
    assert(json != nullptr && std::strstr(json, "Failed to write adi.pb") != nullptr);
    free_c_string(json); json = nullptr;
    reset_synthetic_vm();
    assert(rmdir(child(uuid_dir, kADISymbols.adi_pb_filename).c_str()) == 0);

    // End stub success cannot imply a generated provisioning file exists or is valid.
    const uint64_t end = 0x10001000;
    prepare_initialized_vm(prov, id);
    map_code_and_stub(g_shared_vm, end);
    inject_symbol(g_shared_vm, kADISymbols.provisioning_end, end);
    rc = end_provision_uc(libs.c_str(), prov.c_str(), id, 7, ptm, sizeof(ptm), tk, sizeof(tk), &json);
    assert(rc == ANISETTE_ERR_READ_FILE_FAILED);
    assert(json != nullptr && std::strstr(json, "Failed to read generated adi.pb") != nullptr);
    free_c_string(json); json = nullptr;
    reset_synthetic_vm();

    FILE *f = std::fopen(child(uuid_dir, kADISymbols.adi_pb_filename).c_str(), "wb");
    assert(f != nullptr && std::fclose(f) == 0);
    prepare_initialized_vm(prov, id);
    map_code_and_stub(g_shared_vm, end);
    inject_symbol(g_shared_vm, kADISymbols.provisioning_end, end);
    rc = end_provision_uc(libs.c_str(), prov.c_str(), id, 7, ptm, sizeof(ptm), tk, sizeof(tk), &json);
    assert(rc == ANISETTE_ERR_READ_FILE_FAILED);
    assert(json != nullptr && std::strstr(json, "Invalid or incomplete generated adi.pb") != nullptr);
    free_c_string(json); json = nullptr;
    reset_synthetic_vm();

    f = std::fopen(child(uuid_dir, kADISymbols.adi_pb_filename).c_str(), "wb");
    assert(f != nullptr && std::fwrite(pb, 1, sizeof(pb), f) == sizeof(pb) && std::fclose(f) == 0);
    prepare_initialized_vm(prov, id);
    map_code_and_stub(g_shared_vm, end);
    inject_symbol(g_shared_vm, kADISymbols.provisioning_end, end);
    rc = end_provision_uc(libs.c_str(), prov.c_str(), id, 7, ptm, sizeof(ptm), tk, sizeof(tk), &json);
    assert(rc == ANISETTE_OK);
    assert(json != nullptr && std::strstr(json, "adi_pb_base64") != nullptr && std::strstr(json, "CAE=") != nullptr);
    free_c_string(json);
    reset_synthetic_vm();

    assert(std::remove(child(uuid_dir, kADISymbols.adi_pb_filename).c_str()) == 0);
    assert(rmdir(uuid_dir.c_str()) == 0);
    assert(rmdir(libs.c_str()) == 0 && rmdir(prov.c_str()) == 0 && rmdir(root.c_str()) == 0);
}

void test_recreated_provisioning_directory() {
    const uint8_t id[16] = {}, pb[] = {1};
    const std::string root = make_temp_dir();
    const std::string libs = child(root, "libs"), prov = child(root, "provisioning");
    assert(mkdir(libs.c_str(), 0700) == 0 && mkdir(prov.c_str(), 0700) == 0);
    prepare_initialized_vm(prov, id);
    const std::string uuid_dir = g_current_prov_path;
    const uint64_t stub = 0x10000000;
    map_code_and_stub(g_shared_vm, stub);
    inject_symbol(g_shared_vm, kADISymbols.otp_request, stub);
    assert(rmdir(uuid_dir.c_str()) == 0);
    char *json = nullptr;
    assert(get_anisette_headers_uc(libs.c_str(), prov.c_str(), id, pb, sizeof pb, &json) == ANISETTE_ERR_LOADER_FAILED);
    assert(json && std::strstr(json, "ADISetProvisioningPath missing"));
    free_c_string(json); json = nullptr;
    inject_symbol(g_shared_vm, kADISymbols.set_provisioning_path, stub);
    assert(rmdir(uuid_dir.c_str()) == 0);
    assert(get_anisette_headers_uc(libs.c_str(), prov.c_str(), id, pb, sizeof pb, &json) == ANISETTE_ERR_READ_FILE_FAILED);
    assert(json && std::strstr(json, "Incomplete or invalid OTP response"));
    free_c_string(json);
    reset_synthetic_vm();
    assert(std::remove(child(uuid_dir, kADISymbols.adi_pb_filename).c_str()) == 0);
    assert(rmdir(uuid_dir.c_str()) == 0 && rmdir(libs.c_str()) == 0 && rmdir(prov.c_str()) == 0 && rmdir(root.c_str()) == 0);
}

} // namespace

int main() {
    test_read_guest_bytes();
    test_capi_invalid_and_oversize();
    test_synthetic_otp_and_file_io();
    test_recreated_provisioning_directory();
    std::puts("PASS: synthetic native output bounds, file errors, provisioning directory recreation");
    return 0;
}
