#include "AFCTestFFI/idevice.h"

#include <stdlib.h>
#include <string.h>

struct AfcClientHandle { int unused; };
struct AfcFileHandle { int unused; };

static int32_t next_directory_code;
static int32_t next_directory_sub_code;
static int32_t next_open_code;
static int32_t next_open_sub_code;
static int32_t next_remove_code;
static int32_t next_remove_sub_code;
static int32_t directory_calls;
static int32_t open_calls;
static int32_t remove_calls;
static int32_t error_free_calls;
static char last_remove_path[256];
static const char error_payload[] = "PairingRecordSecret=DO_NOT_EXPOSE";

static IdeviceFfiError *make_error(int32_t code, int32_t sub_code) {
    IdeviceFfiError *error = (IdeviceFfiError *)calloc(1, sizeof(IdeviceFfiError));
    if (error == NULL) return NULL;
    error->code = code;
    error->sub_code = sub_code;
    error->message = strdup(error_payload);
    if (error->message == NULL) {
        free(error);
        return NULL;
    }
    return error;
}

void test_afc_reset(void) {
    next_directory_code = 0;
    next_directory_sub_code = 0;
    next_open_code = 0;
    next_open_sub_code = 0;
    next_remove_code = 0;
    next_remove_sub_code = 0;
    directory_calls = 0;
    open_calls = 0;
    remove_calls = 0;
    error_free_calls = 0;
    last_remove_path[0] = '\0';
}

void test_afc_fail_next_directory(int32_t code, int32_t sub_code) {
    next_directory_code = code;
    next_directory_sub_code = sub_code;
}

void test_afc_fail_next_open(int32_t code, int32_t sub_code) {
    next_open_code = code;
    next_open_sub_code = sub_code;
}

void test_afc_fail_next_remove(int32_t code, int32_t sub_code) {
    next_remove_code = code;
    next_remove_sub_code = sub_code;
}

int32_t test_afc_directory_calls(void) { return directory_calls; }
int32_t test_afc_open_calls(void) { return open_calls; }
int32_t test_afc_remove_calls(void) { return remove_calls; }
const char *test_afc_last_remove_path(void) { return last_remove_path; }
int32_t test_afc_error_free_calls(void) { return error_free_calls; }

void afc_client_free(AfcClientHandle *handle) { (void)handle; }

IdeviceFfiError *afc_make_directory(AfcClientHandle *client, const char *path) {
    (void)client;
    (void)path;
    directory_calls++;
    int32_t code = next_directory_code;
    int32_t sub_code = next_directory_sub_code;
    next_directory_code = 0;
    next_directory_sub_code = 0;
    return code == 0 ? NULL : make_error(code, sub_code);
}

IdeviceFfiError *afc_remove_path(AfcClientHandle *client, const char *path) {
    (void)client;
    remove_calls++;
    if (path == NULL) {
        last_remove_path[0] = '\0';
    } else {
        strncpy(last_remove_path, path, sizeof(last_remove_path) - 1);
        last_remove_path[sizeof(last_remove_path) - 1] = '\0';
    }
    int32_t code = next_remove_code;
    int32_t sub_code = next_remove_sub_code;
    next_remove_code = 0;
    next_remove_sub_code = 0;
    return code == 0 ? NULL : make_error(code, sub_code);
}

IdeviceFfiError *afc_file_open(AfcClientHandle *client, const char *path, AfcFopenMode mode, AfcFileHandle **handle) {
    (void)client;
    (void)path;
    (void)mode;
    open_calls++;
    int32_t code = next_open_code;
    int32_t sub_code = next_open_sub_code;
    next_open_code = 0;
    next_open_sub_code = 0;
    if (code != 0) return make_error(code, sub_code);
    *handle = (AfcFileHandle *)(uintptr_t)1;
    return NULL;
}

IdeviceFfiError *afc_file_close(AfcFileHandle *handle) { (void)handle; return NULL; }
IdeviceFfiError *afc_file_write(AfcFileHandle *handle, const uint8_t *data, size_t length) {
    (void)handle;
    (void)data;
    (void)length;
    return NULL;
}
IdeviceFfiError *afc_get_file_info(AfcClientHandle *client, const char *path, AfcFileInfo *info) {
    (void)client;
    (void)path;
    (void)info;
    return NULL;
}
void afc_file_info_free(AfcFileInfo *info) { (void)info; }
IdeviceFfiError *afc_file_read_entire(AfcFileHandle *handle, uint8_t **data, size_t *length) {
    (void)handle;
    *data = NULL;
    *length = 0;
    return NULL;
}
void afc_file_read_data_free(uint8_t *data, size_t length) { (void)length; free(data); }

void idevice_error_free(IdeviceFfiError *error) {
    if (error == NULL) return;
    error_free_calls++;
    free((void *)error->message);
    free(error);
}
