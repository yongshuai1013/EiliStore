//
//  anisette_core_uc.cpp
//  AnisetteKit
//
//  Created by Magesh K on 25/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#include "anisette_core.h"
#include "anisette_base.h"
#include "Loader/elf_loader_emulator.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#if !defined(_WIN32) && !defined(_MSC_VER)
#include <unistd.h>
#endif
#include <sys/stat.h>

#if defined(_WIN32) || defined(_MSC_VER)
#define NOMINMAX
#include <io.h>
#include <direct.h>
#define mkdir(p, m) _mkdir(p)
#define rmdir _rmdir
#define stat _stat64
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#endif
#ifndef S_ISREG
#define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#endif
#endif
#include <string>
#include <vector>
#include <sstream>
#include <mutex>
#include <new>
#include <memory>

static EmulatorVM *g_shared_vm = nullptr;
static std::mutex g_vm_mutex;
static std::string g_current_prov_path = "";
static std::string g_current_android_id = "";
static bool g_libraries_initialized = false;
static const uint32_t kMaxADIDataSize = 64u * 1024u * 1024u;

static bool read_guest_bytes(EmulatorVM *vm, uint64_t pointer_slot,
                             uint64_t length_slot, uint8_t **data, uint32_t *length) {
    uint64_t guest_pointer = 0;
    uint32_t guest_length = 0;
    if (!vm || !vm->uc || !data || !length ||
        uc_mem_read(vm->uc, pointer_slot, &guest_pointer, sizeof(guest_pointer)) != UC_ERR_OK ||
        uc_mem_read(vm->uc, length_slot, &guest_length, sizeof(guest_length)) != UC_ERR_OK ||
        guest_length > kMaxADIDataSize) return false;
    // SideStore accepts empty outputs after ADI returns zero and leaves a
    // zero-initialized vector when a nonempty output has a null guest pointer.
    // Retain only the host allocation/read bounds, not an extra nonempty rule.
    uint8_t *buffer = new (std::nothrow) uint8_t[guest_length ? guest_length : 1]();
    if (!buffer) return false;
    if (guest_length && guest_pointer && uc_mem_read(vm->uc, guest_pointer, buffer, guest_length) != UC_ERR_OK) {
        delete[] buffer;
        return false;
    }
    *data = buffer;
    *length = guest_length;
    return true;
}

static bool setup_vm_and_adi(
    EmulatorVM *&vm,
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    std::string &out_uuid_prov_dir,
    std::string &out_err
) {
    if (!lib_dir) {
        out_err = "Library directory path is null.";
        return false;
    }
    struct stat st;
    if (stat(lib_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        out_err = std::string("Provided library path is not a valid directory: ") + lib_dir;
        return false;
    }

    // Recognition is not ABI support. The legacy unknown-import zero stubs
    // must never be treated as a working Android ABI for a libstoreapi set.
    std::string modern_entry = std::string(lib_dir) + "/libstoreapi.so";
    if (stat(modern_entry.c_str(), &st) == 0) {
        out_err = "The libstoreapi library set requires an Android ABI adapter that this build does not implement. "
                  "Use remote mode or compatible legacy libraries; do not rename libstoreapi.so.";
        return false;
    }

    if (g_shared_vm &&
        (!g_shared_vm->execution_error.empty() ||
         (!g_libraries_initialized && !g_shared_vm->loaded_libraries.empty()))) {
        clear_active_vm();
        delete g_shared_vm;
        g_shared_vm = nullptr;
        g_libraries_initialized = false;
        g_current_prov_path.clear();
        g_current_android_id.clear();
    }

    if (!g_shared_vm) {
        g_shared_vm = new (std::nothrow) EmulatorVM();
        if (!g_shared_vm) {
            out_err = "Failed to allocate VM.";
            return false;
        }
    }
    vm = g_shared_vm;
    if (!vm->uc || vm->initialization_error != UC_ERR_OK) {
        out_err = std::string("Failed to initialize Unicorn VM: ") +
                  uc_strerror(vm->initialization_error);
        return false;
    }

    if (!g_libraries_initialized) {
        std::string lib_path(lib_dir);
        if (!lib_path.empty() && lib_path.back() != '/') lib_path += "/";
        std::string ssc_path     = lib_path + kADISymbols.lib_ssc;
        std::string coreadi_path = lib_path + kADISymbols.lib_core_adi;

        if (!load_library_to_vm(vm, ssc_path, kADISymbols.lib_ssc) ||
            !load_library_to_vm(vm, coreadi_path, kADISymbols.lib_core_adi)) {
            out_err = "Failed to load libraries into VM";
            return false;
        }

        relocate_all_vm_libraries(vm);
        if (!vm->execution_error.empty() || !run_library_constructors(vm)) {
            out_err = "Library constructors failed in VM";
            return false;
        }

        uint64_t load_lib_ptr = get_vm_symbol_address(vm, kADISymbols.load_library);
        if (!load_lib_ptr) {
            out_err = "Required ADI setup symbol missing in VM";
            return false;
        }

        uint64_t lib_path_vm = vm->write_string(lib_path.c_str());
        LOG_UC("[AnisetteKit - UC] Step 1: Calling ADILoadLibraryWithPath (0x%llx, path=\"%s\")...\n",
               (unsigned long long)load_lib_ptr, lib_path.c_str());
        int32_t load_res = run_vm_procedure(vm, load_lib_ptr, {lib_path_vm, 0});
        LOG_UC("[AnisetteKit - UC] Step 1 result: %d\n", load_res);
        if (load_res != 0) {
            out_err = "ADILoadLibraryWithPath failed: " + std::to_string(load_res);
            return false;
        }
        g_libraries_initialized = true;
    }

    std::string uuid = format_uuid_string(identifier);
    out_uuid_prov_dir = std::string(provisioning_dir) + "/" + uuid;
    const bool created_provisioning_dir = mkdir(out_uuid_prov_dir.c_str(), 0755) == 0;
    if (!created_provisioning_dir && errno != EEXIST) {
        out_err = "Failed to create provisioning directory";
        return false;
    }
    if (stat(out_uuid_prov_dir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
        out_err = "Provisioning path is not a directory";
        return false;
    }

    // Memory storage removes the previous directory between fetches. Reapply
    // the path after recreation even if its string is unchanged.
    if (created_provisioning_dir || out_uuid_prov_dir != g_current_prov_path) {
        uint64_t set_prov_ptr = get_vm_symbol_address(vm, kADISymbols.set_provisioning_path);
        if (!set_prov_ptr) {
            out_err = "Symbol ADISetProvisioningPath missing in VM";
            return false;
        }
        uint64_t prov_path_vm = vm->write_string(out_uuid_prov_dir.c_str());
        LOG_UC("[AnisetteKit - UC] Step 2: Calling ADISetProvisioningPath (0x%llx, path=\"%s\")...\n",
               (unsigned long long)set_prov_ptr, out_uuid_prov_dir.c_str());
        int32_t prov_res = run_vm_procedure(vm, set_prov_ptr, {prov_path_vm});
        LOG_UC("[AnisetteKit - UC] Step 2 result: %d\n", prov_res);
        if (prov_res != 0) {
            out_err = "ADISetProvisioningPath failed: " + std::to_string(prov_res);
            return false;
        }
        g_current_prov_path = out_uuid_prov_dir;
    }

    std::string android_id = get_android_id_string(identifier);
    if (android_id != g_current_android_id) {
        uint64_t set_id_ptr = get_vm_symbol_address(vm, kADISymbols.set_android_id);
        if (!set_id_ptr) {
            out_err = "Symbol ADISetAndroidID missing in VM";
            return false;
        }
        uint64_t android_id_vm = vm->write_string(android_id.c_str());
        LOG_UC("[AnisetteKit - UC] Step 3: Calling ADISetAndroidID (0x%llx, id=\"%s\", len=%zu)...\n",
               (unsigned long long)set_id_ptr, android_id.c_str(), android_id.length());
        int32_t id_res = run_vm_procedure(vm, set_id_ptr, {android_id_vm, (uint64_t)android_id.length()});
        LOG_UC("[AnisetteKit - UC] Step 3 result: %d\n", id_res);
        if (id_res != 0) {
            out_err = "ADISetAndroidID failed: " + std::to_string(id_res);
            return false;
        }
        g_current_android_id = android_id;
    }

    return true;
}

// C ABI wrappers below catch allocation/standard-library exceptions.


static int32_t get_anisette_headers_uc_impl(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *adi_pb,
    uint32_t adi_pb_len,
    char **out_json
) {
    LOG_UC("[AnisetteKit - UC] Invoked get_anisette_headers_uc\n");
    if (!lib_dir || !provisioning_dir || !identifier || !adi_pb || !out_json ||
        adi_pb_len > kMaxADIDataSize) {
        return ANISETTE_ERR_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(g_vm_mutex);

    EmulatorVM *vm = nullptr;
    std::string uuid_prov_dir, err;
    if (!setup_vm_and_adi(vm, lib_dir, provisioning_dir, identifier, uuid_prov_dir, err)) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }

    std::string adi_pb_path = uuid_prov_dir + "/" + kADISymbols.adi_pb_filename;
    FILE* f = fopen(adi_pb_path.c_str(), "wb");
    if (!f) {
        *out_json = strdup("{\"error\":\"Failed to write adi.pb\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }
    bool write_ok = fwrite(adi_pb, 1, adi_pb_len, f) == adi_pb_len;
    int write_close_result = fclose(f);
    if (!write_ok || write_close_result != 0) {
        *out_json = strdup("{\"error\":\"Failed to write adi.pb\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }

    uint64_t otp_req_ptr = get_vm_symbol_address(vm, kADISymbols.otp_request);
    if (!otp_req_ptr) {
        *out_json = strdup("{\"error\":\"Symbol ADIOTPRequest missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    uint64_t mid_ptr = vm->heap.alloc(8);
    uint64_t mid_len_ptr = vm->heap.alloc(4);
    uint64_t otp_ptr = vm->heap.alloc(8);
    uint64_t otp_len_ptr = vm->heap.alloc(4);

    uint64_t dsid = (uint64_t)-2;
    LOG_UC("[AnisetteKit - UC] Step 4: Calling ADIOTPRequest (0x%llx)...\n", (unsigned long long)otp_req_ptr);
    int32_t res = run_vm_procedure(vm, otp_req_ptr, {dsid, mid_ptr, mid_len_ptr, otp_ptr, otp_len_ptr});
    LOG_UC("[AnisetteKit - UC] Step 4 result: %d\n", res);

    if (res != 0) {
        std::stringstream ss;
        ss << "{\"error\":\"ADIOTPRequest failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    uint8_t *mid_data = nullptr, *otp_data = nullptr;
    uint32_t final_mid_len = 0, final_otp_len = 0;
    if (!read_guest_bytes(vm, mid_ptr, mid_len_ptr, &mid_data, &final_mid_len) ||
        !read_guest_bytes(vm, otp_ptr, otp_len_ptr, &otp_data, &final_otp_len)) {
        delete[] mid_data; delete[] otp_data;
        *out_json = strdup("{\"error\":\"Incomplete or invalid OTP response\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }
    std::unique_ptr<uint8_t[]> mid_owner(mid_data), otp_owner(otp_data);
    if (!final_mid_len || !final_otp_len) {
        LOG_UC("[SideStore compatibility] ADIOTPRequest returned zero with empty output; preserving response, not verifying Apple login\n");
    }
    std::string mid = base64_encode(mid_owner.get(), final_mid_len);
    std::string otp = base64_encode(otp_owner.get(), final_otp_len);

    std::stringstream ss;
    ss << "{\"X-Apple-I-MD-M\":\"" << mid
       << "\",\"X-Apple-I-MD\":\"" << otp
       << "\",\"X-Apple-I-MD-RINFO\":\"17106176\",\"X-Apple-I-MD-LU\":\"0000000000000000000000000000000000000000000000000000000000000001\"}";
    *out_json = strdup(ss.str().c_str());

    return ANISETTE_OK;
}

static int32_t start_provision_uc_impl(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *spim,
    uint32_t spim_len,
    char **out_json
) {
    LOG_UC("[AnisetteKit - UC] Invoked start_provision_uc\n");
    if (!lib_dir || !provisioning_dir || !identifier || !spim || !out_json ||
        spim_len > kMaxADIDataSize) {
        return ANISETTE_ERR_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(g_vm_mutex);

    EmulatorVM *vm = nullptr;
    std::string uuid_prov_dir, err;
    if (!setup_vm_and_adi(vm, lib_dir, provisioning_dir, identifier, uuid_prov_dir, err)) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }

    uint64_t prov_start_ptr = get_vm_symbol_address(vm, kADISymbols.provisioning_start);
    if (!prov_start_ptr) {
        *out_json = strdup("{\"error\":\"Symbol ADIProvisioningStart missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    uint64_t spim_vm = vm->write_bytes(spim, spim_len);
    uint64_t cpim_ptr = vm->heap.alloc(8);
    uint64_t cpim_len_ptr = vm->heap.alloc(4);
    uint64_t session_ptr = vm->heap.alloc(4);

    uint64_t zero64 = 0;
    uint32_t zero32 = 0;
    uc_mem_write(vm->uc, cpim_ptr, &zero64, sizeof(zero64));
    uc_mem_write(vm->uc, cpim_len_ptr, &zero32, sizeof(zero32));
    uc_mem_write(vm->uc, session_ptr, &zero32, sizeof(zero32));

    uint64_t dsid = (uint64_t)-2;
    LOG_UC("[AnisetteKit - UC] Step 4: Calling ADIProvisioningStart (0x%llx) [spim_len=%u]...\n",
           (unsigned long long)prov_start_ptr, spim_len);
    int32_t res = run_vm_procedure(vm, prov_start_ptr, {dsid, spim_vm, (uint64_t)spim_len, cpim_ptr, cpim_len_ptr, session_ptr});
    LOG_UC("[AnisetteKit - UC] Step 4 result: %d\n", res);

    if (res != 0) {
        rmdir(uuid_prov_dir.c_str());
        std::stringstream ss;
        ss << "{\"error\":\"ADIProvisioningStart failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    uint32_t final_cpim_len = 0;
    uint32_t session = 0;

    if (uc_mem_read(vm->uc, session_ptr, &session, sizeof(session)) != UC_ERR_OK) {
        *out_json = strdup("{\"error\":\"Incomplete provisioning response\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }

    uint8_t *cpim_data = nullptr;
    if (!read_guest_bytes(vm, cpim_ptr, cpim_len_ptr, &cpim_data, &final_cpim_len)) {
        *out_json = strdup("{\"error\":\"Incomplete or invalid CPIM response\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }
    std::unique_ptr<uint8_t[]> cpim_owner(cpim_data);
    std::string cpim_b64 = base64_encode(cpim_owner.get(), final_cpim_len);

    std::stringstream ss;
    ss << "{\"cpim_base64\":\"" << cpim_b64 << "\",\"session\":" << session << "}";
    *out_json = strdup(ss.str().c_str());

    return ANISETTE_OK;
}

static int32_t end_provision_uc_impl(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session,
    const uint8_t *ptm,
    uint32_t ptm_len,
    const uint8_t *tk,
    uint32_t tk_len,
    char **out_json
) {
    LOG_UC("[AnisetteKit - UC] Invoked end_provision_uc\n");
    if (!lib_dir || !provisioning_dir || !identifier || !ptm || !tk || !out_json ||
        ptm_len > kMaxADIDataSize || tk_len > kMaxADIDataSize) {
        return ANISETTE_ERR_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(g_vm_mutex);

    EmulatorVM *vm = nullptr;
    std::string uuid_prov_dir, err;
    if (!setup_vm_and_adi(vm, lib_dir, provisioning_dir, identifier, uuid_prov_dir, err)) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }

    uint64_t prov_end_ptr = get_vm_symbol_address(vm, kADISymbols.provisioning_end);
    if (!prov_end_ptr) {
        *out_json = strdup("{\"error\":\"Symbol ADIProvisioningEnd missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    uint64_t ptm_vm = vm->write_bytes(ptm, ptm_len);
    uint64_t tk_vm  = vm->write_bytes(tk, tk_len);

    LOG_UC("[AnisetteKit - UC] Step 4: Calling ADIProvisioningEnd (0x%llx) [session=%u, ptm_len=%u, tk_len=%u]...\n",
           (unsigned long long)prov_end_ptr, session, ptm_len, tk_len);
    int32_t res = run_vm_procedure(vm, prov_end_ptr, {(uint64_t)session, ptm_vm, (uint64_t)ptm_len, tk_vm, (uint64_t)tk_len});
    LOG_UC("[AnisetteKit - UC] Step 4 result: %d\n", res);

    if (res != 0) {
        std::stringstream ss;
        ss << "{\"error\":\"ADIProvisioningEnd failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    std::string adi_pb_path = uuid_prov_dir + "/" + kADISymbols.adi_pb_filename;
    FILE* f = fopen(adi_pb_path.c_str(), "rb");
    if (!f) {
        *out_json = strdup("{\"error\":\"Failed to read generated adi.pb\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }

    bool io_ok = fseek(f, 0, SEEK_END) == 0;
    long file_size = io_ok ? ftell(f) : -1;
    io_ok = io_ok && file_size >= 0 && (unsigned long)file_size <= kMaxADIDataSize;
    if (io_ok) io_ok = fseek(f, 0, SEEK_SET) == 0;
    std::vector<uint8_t> pb_data;
    if (io_ok) {
        pb_data.resize((size_t)file_size);
        io_ok = fread(pb_data.data(), 1, pb_data.size(), f) == pb_data.size();
    }
    int close_result = fclose(f);
    if (!io_ok || close_result != 0) {
        *out_json = strdup("{\"error\":\"Invalid or incomplete generated adi.pb\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }

    if (pb_data.empty()) {
        LOG_UC("[SideStore compatibility] ADIProvisioningEnd returned zero with an empty adi.pb; preserving response, not verifying provisioning/login\n");
    }
    std::string adi_pb_b64 = base64_encode(pb_data.data(), pb_data.size());

    std::stringstream ss;
    ss << "{\"adi_pb_base64\":\"" << adi_pb_b64 << "\"}";
    *out_json = strdup(ss.str().c_str());

    return ANISETTE_OK;
}

static int32_t cancel_provision_uc_impl(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session
) {
    LOG_UC("[AnisetteKit - UC] Invoked cancel_provision_uc\n");
    if (!lib_dir || !provisioning_dir || !identifier) {
        return ANISETTE_ERR_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(g_vm_mutex);

    if (g_shared_vm) {
        uint64_t destroy_session_ptr = get_vm_symbol_address(g_shared_vm, kADISymbols.destroy_session);
        if (destroy_session_ptr) {
            run_vm_procedure(g_shared_vm, destroy_session_ptr, {session});
        }
    }

    return ANISETTE_OK;
}


extern "C" {
void reset_anisette_vm_uc(void) {
    try {
        std::lock_guard<std::mutex> lock(g_vm_mutex);
        clear_active_vm();
        delete g_shared_vm;
        g_shared_vm = nullptr;
        g_libraries_initialized = false;
        g_current_prov_path.clear();
        g_current_android_id.clear();
    } catch (...) { /* No C++ exception may escape the C ABI. */ }
}
int32_t get_anisette_headers_uc(const char *l, const char *p, const uint8_t *i,
    const uint8_t *a, uint32_t n, char **out) {
    if (out) *out = nullptr;
    try { return get_anisette_headers_uc_impl(l, p, i, a, n, out); }
    catch (...) { return ANISETTE_ERR_LOADER_FAILED; }
}
int32_t start_provision_uc(const char *l, const char *p, const uint8_t *i,
    const uint8_t *s, uint32_t n, char **out) {
    if (out) *out = nullptr;
    try { return start_provision_uc_impl(l, p, i, s, n, out); }
    catch (...) { return ANISETTE_ERR_LOADER_FAILED; }
}
int32_t end_provision_uc(const char *l, const char *p, const uint8_t *i, uint32_t session,
    const uint8_t *ptm, uint32_t pn, const uint8_t *tk, uint32_t tn, char **out) {
    if (out) *out = nullptr;
    try { return end_provision_uc_impl(l, p, i, session, ptm, pn, tk, tn, out); }
    catch (...) { return ANISETTE_ERR_LOADER_FAILED; }
}
int32_t cancel_provision_uc(const char *l, const char *p, const uint8_t *i, uint32_t session) {
    try { return cancel_provision_uc_impl(l, p, i, session); }
    catch (...) { return ANISETTE_ERR_LOADER_FAILED; }
}
}
