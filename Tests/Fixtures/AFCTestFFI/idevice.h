#ifndef EILISTORE_AFC_TEST_IDEVICE_H
#define EILISTORE_AFC_TEST_IDEVICE_H

#include <stddef.h>
#include <stdint.h>

typedef enum AfcFopenMode {
    AfcRdOnly = 1,
    AfcRw = 2,
    AfcWrOnly = 3,
    AfcWr = 4,
    AfcAppend = 5,
    AfcRdAppend = 6,
} AfcFopenMode;

typedef struct IdeviceFfiError {
    int32_t code;
    int32_t sub_code;
    const char *message;
} IdeviceFfiError;

typedef struct AfcClientHandle AfcClientHandle;
typedef struct AfcFileHandle AfcFileHandle;

typedef struct AfcFileInfo {
    size_t size;
    size_t blocks;
    int64_t creation;
    int64_t modified;
    char *st_nlink;
    char *st_ifmt;
    char *st_link_target;
} AfcFileInfo;

void afc_client_free(AfcClientHandle *handle);
IdeviceFfiError *afc_make_directory(AfcClientHandle *client, const char *path);
IdeviceFfiError *afc_remove_path(AfcClientHandle *client, const char *path);
IdeviceFfiError *afc_file_open(AfcClientHandle *client, const char *path, AfcFopenMode mode, AfcFileHandle **handle);
IdeviceFfiError *afc_file_close(AfcFileHandle *handle);
IdeviceFfiError *afc_file_write(AfcFileHandle *handle, const uint8_t *data, size_t length);
IdeviceFfiError *afc_get_file_info(AfcClientHandle *client, const char *path, AfcFileInfo *info);
void afc_file_info_free(AfcFileInfo *info);
IdeviceFfiError *afc_file_read_entire(AfcFileHandle *handle, uint8_t **data, size_t *length);
void afc_file_read_data_free(uint8_t *data, size_t length);
void idevice_error_free(IdeviceFfiError *error);

void test_afc_reset(void);
void test_afc_fail_next_directory(int32_t code, int32_t sub_code);
void test_afc_fail_next_open(int32_t code, int32_t sub_code);
void test_afc_fail_next_remove(int32_t code, int32_t sub_code);
int32_t test_afc_directory_calls(void);
int32_t test_afc_open_calls(void);
int32_t test_afc_remove_calls(void);
const char *test_afc_last_remove_path(void);
int32_t test_afc_error_free_calls(void);

#endif
