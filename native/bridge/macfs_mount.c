/*
 * macfs_mount.c - WinFsp user-mode filesystem (read-only) untuk MacVolume.
 *
 * Menampilkan volume Mac (APFS/HFS+) sebagai huruf drive di Windows Explorer.
 * Operasi baca diteruskan ke macfs_bridge (libfsapfs/libfshfs).
 *
 * PENTING: WinFsp di-load secara DINAMIS (LoadLibrary "winfsp-x64.dll").
 * Jika WinFsp belum terpasang di sistem, macfs.dll tetap berfungsi normal
 * (fitur mount saja yang tidak tersedia).
 */

#define WIN32_LEAN_AND_MEAN
/* winfsp.h membutuhkan NTSTATUS & PNTSTATUS. Header WinFsp dibuat untuk
 * SDK lama; sediakan typedef yang hilang sebelum include. */
#include <windows.h>
#include <winternl.h>
#ifndef PNTSTATUS
typedef NTSTATUS *PNTSTATUS;
#endif
#include "winfsp/winfsp.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "macfs_bridge.h"

/* ------------------------------------------------------------------ */
/* Bagian 1: ekspor API publik                                        */
/* ------------------------------------------------------------------ */

#define MACFS_MOUNT_API __declspec(dllexport)

typedef struct macfs_mount_handle macfs_mount_handle;

MACFS_MOUNT_API int macfs_winfsp_available(void);
MACFS_MOUNT_API macfs_mount_handle *macfs_mount_volume(
    int disk_number, uint64_t offset, uint64_t length, int kind,
    int volume_index, const char *mount_point_utf8);
MACFS_MOUNT_API void macfs_unmount(macfs_mount_handle *handle);
MACFS_MOUNT_API const char *macfs_mount_error(macfs_mount_handle *handle);
MACFS_MOUNT_API const char *macfs_mount_point(macfs_mount_handle *handle);
MACFS_MOUNT_API int macfs_mount_is_active(macfs_mount_handle *handle);
int macfs_mount_start(macfs_mount_handle *handle, macfs_ctx *ctx,
                      const WCHAR *mount_point);

/* ------------------------------------------------------------------ */
/* Bagian 2: dynamic loading WinFsp                                   */
/* ------------------------------------------------------------------ */

typedef struct {
    HMODULE module;
    NTSTATUS (WINAPI *Create)(
        PWSTR DevicePath, FSP_FSCTL_VOLUME_PARAMS *VolumeParams,
        const FSP_FILE_SYSTEM_INTERFACE *Interface, FSP_FILE_SYSTEM **PFileSystem);
    VOID (WINAPI *Delete)(FSP_FILE_SYSTEM *FileSystem);
    NTSTATUS (WINAPI *SetMountPoint)(FSP_FILE_SYSTEM *FileSystem, PWSTR MountPoint);
    NTSTATUS (WINAPI *StartDispatcher)(FSP_FILE_SYSTEM *FileSystem, ULONG ThreadCount);
    VOID (WINAPI *StopDispatcher)(FSP_FILE_SYSTEM *FileSystem);
    BOOLEAN (WINAPI *AddDirInfo)(
        FSP_FSCTL_DIR_INFO *DirInfo, PVOID Buffer, ULONG Length,
        PULONG PBytesTransferred);
} macfs_winfsp_api;

static macfs_winfsp_api g_winfsp;
static int g_winfsp_state = 0; /* 0=belum dicoba, 1=ok, -1=gagal */

static int macfs_winfsp_load(void) {
    if (g_winfsp_state > 0) return 1;
    if (g_winfsp_state < 0) return 0;

    /* Coba dari folder instalasi WinFsp (DLL tidak ada di PATH aplikasi). */
    HMODULE module = LoadLibraryW(L"winfsp-x64.dll");
    if (module == NULL) {
        module = LoadLibraryW(L"C:\\Program Files (x86)\\WinFsp\\bin\\winfsp-x64.dll");
    }
    if (module == NULL) {
        module = LoadLibraryW(L"C:\\Program Files\\WinFsp\\bin\\winfsp-x64.dll");
    }
    if (module == NULL) {
        g_winfsp_state = -1;
        return 0;
    }

    g_winfsp.module = module;
    g_winfsp.Create = (void *)GetProcAddress(module, "FspFileSystemCreate");
    g_winfsp.Delete = (void *)GetProcAddress(module, "FspFileSystemDelete");
    g_winfsp.SetMountPoint = (void *)GetProcAddress(module, "FspFileSystemSetMountPoint");
    g_winfsp.StartDispatcher =
        (void *)GetProcAddress(module, "FspFileSystemStartDispatcher");
    g_winfsp.StopDispatcher =
        (void *)GetProcAddress(module, "FspFileSystemStopDispatcher");
    g_winfsp.AddDirInfo = (void *)GetProcAddress(module, "FspFileSystemAddDirInfo");

    if (g_winfsp.Create == NULL || g_winfsp.Delete == NULL ||
        g_winfsp.SetMountPoint == NULL || g_winfsp.StartDispatcher == NULL ||
        g_winfsp.StopDispatcher == NULL || g_winfsp.AddDirInfo == NULL) {
        g_winfsp_state = -1;
        return 0;
    }
    g_winfsp_state = 1;
    return 1;
}

MACFS_MOUNT_API int macfs_winfsp_available(void) {
    return macfs_winfsp_load();
}

/* ------------------------------------------------------------------ */
/* Bagian 3: konteks filesystem                                       */
/* ------------------------------------------------------------------ */

/* Mode POSIX dari bridge. */
#define MACFS_S_IFMT 0xF000
#define MACFS_S_IFDIR 0x4000

struct macfs_mount_handle {
    FSP_FILE_SYSTEM *file_system;
    macfs_ctx *ctx;
    int64_t root_id;
    char mount_point[1024];
    char error[512];
    int mounted;
};

static void macfs_set_mount_error(macfs_mount_handle *handle, const char *message) {
    if (handle == NULL) return;
    strncpy(handle->error, message, sizeof(handle->error) - 1);
    handle->error[sizeof(handle->error) - 1] = '\0';
}

static void macfs_fill_file_info(macfs_ctx *ctx, int64_t id,
                                 FSP_FSCTL_FILE_INFO *info) {
    uint32_t mode = macfs_entry_mode(ctx, id);
    uint64_t size = macfs_entry_size(ctx, id);
    int64_t mtime = macfs_entry_mtime_ns(ctx, id);
    int is_dir = (mode & MACFS_S_IFMT) == MACFS_S_IFDIR;

    memset(info, 0, sizeof(*info));
    info->FileAttributes = is_dir
        ? (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_READONLY)
        : (FILE_ATTRIBUTE_NORMAL | FILE_ATTRIBUTE_READONLY);
    info->FileSize = size;
    info->AllocationSize = size;
    if (mtime > 0) {
        UINT64 ft = (UINT64)(mtime / 100) + 116444736000000000ULL;
        info->CreationTime = ft;
        info->LastAccessTime = ft;
        info->LastWriteTime = ft;
        info->ChangeTime = ft;
    }
}

static int64_t macfs_find_child_utf8(macfs_ctx *ctx, int64_t parent_id,
                                     const char *name_utf8) {
    int count = macfs_entry_count(ctx, parent_id);
    if (count < 0) return 0;
    for (int i = 0; i < count; i++) {
        int64_t child = macfs_entry_child(ctx, parent_id, i);
        if (child == 0) continue;
        const char *child_name = macfs_entry_name(ctx, child);
        if (child_name != NULL && strcmp(child_name, name_utf8) == 0) {
            return child;
        }
        macfs_entry_release(ctx, child);
    }
    return 0;
}

/* Resolusi path UTF-8 (dengan pemisah '/') dari root volume. */
static int64_t macfs_resolve_path(macfs_ctx *ctx, int64_t root_id,
                                  const char *path_utf8) {
    char buffer[2048];
    strncpy(buffer, path_utf8, sizeof(buffer) - 1);
    buffer[sizeof(buffer) - 1] = '\0';

    int64_t current = root_id;
    int owns_current = 0;
    char *token = strtok(buffer, "/");
    while (token != NULL) {
        int64_t child = macfs_find_child_utf8(ctx, current, token);
        if (owns_current) {
            macfs_entry_release(ctx, current);
            owns_current = 0;
        }
        if (child == 0) return 0;
        current = child;
        owns_current = 1;
        token = strtok(NULL, "/");
    }
    if (!owns_current) {
        /* Path kosong (root) — kembalikan root apa adanya. */
        return root_id;
    }
    return current;
}

/* ------------------------------------------------------------------ */
/* Bagian 4: interface WinFsp                                         */
/* ------------------------------------------------------------------ */

/* Logging diagnostik ke %TEMP%\\macfs_mount_log.txt */
static void macfs_log(const char *fmt, ...) {
    const char *temp = getenv("TEMP");
    if (temp == NULL) return;
    char path[512];
    _snprintf(path, sizeof(path), "%s\\macfs_mount_log.txt", temp);
    FILE *file = fopen(path, "a");
    if (file == NULL) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(file, fmt, args);
    va_end(args);
    fprintf(file, "\n");
    fclose(file);
}

static macfs_mount_handle *macfs_handle_from_fs(FSP_FILE_SYSTEM *fs) {
    return (macfs_mount_handle *)fs->UserContext;
}

/* GetVolumeInfo(FileSystem, VolumeInfo) */
static NTSTATUS macfs_fs_get_volume_info(FSP_FILE_SYSTEM *fs,
                                         FSP_FSCTL_VOLUME_INFO *info) {
    macfs_log("GetVolumeInfo");
    (void)fs;
    memset(info, 0, sizeof(*info));
    static const WCHAR label[] = L"Mac Volume";
    info->VolumeLabelLength = (UINT16)((sizeof(label) / sizeof(WCHAR) - 1) * sizeof(WCHAR));
    memcpy(info->VolumeLabel, label, sizeof(label) - sizeof(WCHAR));
    info->TotalSize = 0;
    info->FreeSize = 0;
    return STATUS_SUCCESS;
}

/* GetSecurityByName(FileSystem, FileName, PFileAttributes, Security, PSecuritySize) */
static NTSTATUS macfs_fs_get_security_by_name(FSP_FILE_SYSTEM *fs, PWSTR file_name,
                                              PUINT32 file_attributes,
                                              PSECURITY_DESCRIPTOR security,
                                              SIZE_T *security_size) {
    (void)fs;
    if (security_size != NULL) *security_size = 0;
    if (file_attributes != NULL) {
        *file_attributes = FILE_ATTRIBUTE_READONLY;
        if (file_name != NULL && file_name[0] == L'\0') {
            *file_attributes |= FILE_ATTRIBUTE_DIRECTORY;
            *file_attributes &= ~FILE_ATTRIBUTE_READONLY;
        }
    }
    return STATUS_SUCCESS;
}

/* Open(FileSystem, FileName, CreateOptions, GrantedAccess, PFileContext, FileInfo) */
static NTSTATUS macfs_fs_open(FSP_FILE_SYSTEM *fs, PWSTR file_name,
                              UINT32 create_options, UINT32 granted_access,
                              PVOID *file_context, FSP_FSCTL_FILE_INFO *file_info) {
    (void)create_options;
    (void)granted_access;

    macfs_mount_handle *handle = macfs_handle_from_fs(fs);
    if (handle == NULL || handle->ctx == NULL) return STATUS_DEVICE_NOT_READY;

    /* Konversi path UTF-16 -> UTF-8, '\' -> '/'. */
    char path_utf8[2048];
    int length = WideCharToMultiByte(CP_UTF8, 0, file_name, -1, path_utf8,
                                     sizeof(path_utf8), NULL, NULL);
    if (length <= 0) return STATUS_OBJECT_NAME_INVALID;
    for (char *p = path_utf8; *p != '\0'; p++) {
        if (*p == '\\') *p = '/';
    }

    int64_t id;
    if (path_utf8[0] == '\0') {
        id = handle->root_id;
    } else {
        id = macfs_resolve_path(handle->ctx, handle->root_id, path_utf8);
        if (id == 0) return STATUS_OBJECT_NAME_NOT_FOUND;
    }

    *file_context = (PVOID)(intptr_t)id;
    macfs_fill_file_info(handle->ctx, id, file_info);
    macfs_log("Open ok: path='%s' id=%lld", path_utf8, (long long)id);
    return STATUS_SUCCESS;
}

/* Cleanup(FileSystem, FileContext, FileName, Flags) */
static VOID macfs_fs_cleanup(FSP_FILE_SYSTEM *fs, PVOID file_context,
                             PWSTR file_name, ULONG flags) {
    (void)fs;
    (void)file_context;
    (void)file_name;
    (void)flags;
}

/* Close(FileSystem, FileContext) */
static VOID macfs_fs_close(FSP_FILE_SYSTEM *fs, PVOID file_context) {
    macfs_mount_handle *handle = macfs_handle_from_fs(fs);
    if (handle == NULL || handle->ctx == NULL) return;
    int64_t id = (int64_t)(intptr_t)file_context;
    if (id != 0 && id != handle->root_id) {
        macfs_entry_release(handle->ctx, id);
    }
}

/* Read(FileSystem, FileContext, Buffer, Offset, Length, PBytesTransferred) */
static NTSTATUS macfs_fs_read(FSP_FILE_SYSTEM *fs, PVOID file_context,
                              PVOID buffer, UINT64 offset, ULONG length,
                              PULONG bytes_transferred) {
    macfs_mount_handle *handle = macfs_handle_from_fs(fs);
    if (handle == NULL || handle->ctx == NULL) return STATUS_DEVICE_NOT_READY;
    int64_t id = (int64_t)(intptr_t)file_context;
    int64_t read = macfs_read_at(handle->ctx, id, buffer, length, offset);
    if (read < 0) return STATUS_DEVICE_DATA_ERROR;
    *bytes_transferred = (ULONG)read;
    return STATUS_SUCCESS;
}

/* Write -> read-only */
static NTSTATUS macfs_fs_write(FSP_FILE_SYSTEM *fs, PVOID file_context,
                               PVOID buffer, UINT64 offset, ULONG length,
                               PULONG bytes_transferred) {
    (void)fs; (void)file_context; (void)buffer; (void)offset; (void)length;
    (void)bytes_transferred;
    return STATUS_MEDIA_WRITE_PROTECTED;
}

/* GetFileInfo(FileSystem, FileContext, FileInfo) */
static NTSTATUS macfs_fs_get_file_info(FSP_FILE_SYSTEM *fs, PVOID file_context,
                                       FSP_FSCTL_FILE_INFO *file_info) {
    macfs_mount_handle *handle = macfs_handle_from_fs(fs);
    if (handle == NULL || handle->ctx == NULL) return STATUS_DEVICE_NOT_READY;
    int64_t id = (int64_t)(intptr_t)file_context;
    macfs_fill_file_info(handle->ctx, id, file_info);
    return STATUS_SUCCESS;
}

/* SetBasicInfo -> read-only */
static NTSTATUS macfs_fs_set_basic_info(FSP_FILE_SYSTEM *fs, PVOID file_context,
                                        UINT32 file_attributes,
                                        UINT64 creation_time,
                                        UINT64 last_access_time,
                                        UINT64 last_write_time,
                                        UINT64 change_time,
                                        FSP_FSCTL_FILE_INFO *file_info) {
    (void)fs; (void)file_context; (void)file_attributes; (void)creation_time;
    (void)last_access_time; (void)last_write_time; (void)change_time;
    (void)file_info;
    return STATUS_MEDIA_WRITE_PROTECTED;
}

/* SetFileSize -> read-only */
static NTSTATUS macfs_fs_set_file_size(FSP_FILE_SYSTEM *fs, PVOID file_context,
                                       UINT64 new_size, BOOLEAN set_allocation_size,
                                       FSP_FSCTL_FILE_INFO *file_info) {
    (void)fs; (void)file_context; (void)new_size; (void)set_allocation_size;
    (void)file_info;
    return STATUS_MEDIA_WRITE_PROTECTED;
}

/* CanDelete -> false */
static NTSTATUS macfs_fs_can_delete(FSP_FILE_SYSTEM *fs, PVOID file_context,
                                    PWSTR file_name) {
    (void)fs; (void)file_context; (void)file_name;
    return STATUS_MEDIA_WRITE_PROTECTED;
}

/* Rename -> read-only */
static NTSTATUS macfs_fs_rename(FSP_FILE_SYSTEM *fs, PVOID file_context,
                                PWSTR file_name, PWSTR new_file_name,
                                BOOLEAN replace_if_exists) {
    (void)fs; (void)file_context; (void)file_name; (void)new_file_name;
    (void)replace_if_exists;
    return STATUS_MEDIA_WRITE_PROTECTED;
}

/* SetDelete -> read-only */
static NTSTATUS macfs_fs_set_delete(FSP_FILE_SYSTEM *fs, PVOID file_context,
                                    PWSTR file_name, BOOLEAN delete_file) {
    (void)fs; (void)file_context; (void)file_name; (void)delete_file;
    return STATUS_MEDIA_WRITE_PROTECTED;
}

/* ReadDirectory(FileSystem, FileContext, Pattern, Marker, Buffer, Length, PBytesTransferred) */
static NTSTATUS macfs_fs_read_directory(FSP_FILE_SYSTEM *fs, PVOID file_context,
                                        PWSTR pattern, PWSTR marker,
                                        PVOID buffer, ULONG buffer_length,
                                        PULONG bytes_transferred) {
    (void)pattern;
    macfs_mount_handle *handle = macfs_handle_from_fs(fs);
    if (handle == NULL || handle->ctx == NULL) return STATUS_DEVICE_NOT_READY;

    int64_t dir_id = (int64_t)(intptr_t)file_context;
    int count = macfs_entry_count(handle->ctx, dir_id);
    macfs_log("ReadDirectory dir_id=%lld count=%d", (long long)dir_id, count);
    if (count < 0) return STATUS_INVALID_DEVICE_REQUEST;

    *bytes_transferred = 0;
    int skip_until_marker = marker != NULL && marker[0] != L'\0';

    for (int i = 0; i < count; i++) {
        int64_t child = macfs_entry_child(handle->ctx, dir_id, i);
        if (child == 0) continue;

        const char *name_utf8 = macfs_entry_name(handle->ctx, child);
        if (name_utf8 == NULL) {
            macfs_entry_release(handle->ctx, child);
            continue;
        }
        WCHAR name_wide[512];
        int name_length = MultiByteToWideChar(CP_UTF8, 0, name_utf8, -1,
                                              name_wide,
                                              sizeof(name_wide) / sizeof(WCHAR));
        if (name_length <= 0) {
            macfs_entry_release(handle->ctx, child);
            continue;
        }

        if (skip_until_marker) {
            if (wcscmp(name_wide, marker) == 0) {
                skip_until_marker = 0;
            }
            macfs_entry_release(handle->ctx, child);
            continue;
        }

        ULONG name_bytes = (ULONG)((name_length - 1) * sizeof(WCHAR));
        ULONG entry_size = (ULONG)(sizeof(FSP_FSCTL_DIR_INFO) + name_bytes +
                                   sizeof(WCHAR));
        FSP_FSCTL_DIR_INFO *dir_info = (FSP_FSCTL_DIR_INFO *)calloc(1, entry_size);
        if (dir_info == NULL) {
            macfs_entry_release(handle->ctx, child);
            return STATUS_INSUFFICIENT_RESOURCES;
        }
        dir_info->Size = (UINT16)entry_size;
        macfs_fill_file_info(handle->ctx, child, &dir_info->FileInfo);
        memcpy(dir_info->FileNameBuf, name_wide, name_bytes);

        BOOLEAN added = g_winfsp.AddDirInfo(dir_info, buffer, buffer_length,
                                            bytes_transferred);
        free(dir_info);
        macfs_entry_release(handle->ctx, child);
        if (!added) break;
    }
    return STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ */
/* Bagian 5: mount / unmount                                          */
/* ------------------------------------------------------------------ */

static const FSP_FILE_SYSTEM_INTERFACE g_interface = {
    .GetVolumeInfo = macfs_fs_get_volume_info,
    .GetSecurityByName = macfs_fs_get_security_by_name,
    .Open = macfs_fs_open,
    .Cleanup = macfs_fs_cleanup,
    .Close = macfs_fs_close,
    .Read = macfs_fs_read,
    .Write = macfs_fs_write,
    .GetFileInfo = macfs_fs_get_file_info,
    .SetBasicInfo = macfs_fs_set_basic_info,
    .SetFileSize = macfs_fs_set_file_size,
    .CanDelete = macfs_fs_can_delete,
    .Rename = macfs_fs_rename,
    .SetDelete = macfs_fs_set_delete,
    .ReadDirectory = macfs_fs_read_directory,
};

MACFS_MOUNT_API macfs_mount_handle *macfs_mount_volume(
    int disk_number, uint64_t offset, uint64_t length, int kind,
    int volume_index, const char *mount_point_utf8) {
    macfs_mount_handle *handle =
        (macfs_mount_handle *)calloc(1, sizeof(macfs_mount_handle));
    if (handle == NULL) return NULL;

    if (!macfs_winfsp_load()) {
        macfs_set_mount_error(handle,
                              "WinFsp belum terpasang. Unduh dari winfsp.dev");
        return handle;
    }
    /* Kosong ("") diperbolehkan: WinFsp akan memilih huruf drive otomatis
     * dari Z: ke bawah. Ini lebih andal daripada huruf yang ditentukan. */
    if (mount_point_utf8 == NULL) {
        macfs_set_mount_error(handle, "Mount point tidak valid");
        return handle;
    }

    /* Handle memiliki konteks sendiri agar siklus hidup mount independen. */
    macfs_ctx *ctx = macfs_open(disk_number, offset, length, kind);
    if (ctx == NULL) {
        macfs_set_mount_error(handle,
                              "Gagal membuka volume (butuh Administrator?)");
        return handle;
    }
    if (kind == 0 && volume_index >= 0) {
        if (!macfs_select_volume(ctx, volume_index)) {
            macfs_set_mount_error(handle, "Gagal memilih volume");
            macfs_close(ctx);
            return handle;
        }
    }

    /* Buffer harus cukup untuk path folder (bukan hanya "X:").
     * Sebelumnya 32 karakter, sehingga path panjang terpotong dan mount
     * ke folder selalu gagal. */
    WCHAR mount_point_wide[1024];
    int mount_point_length = MultiByteToWideChar(
        CP_UTF8, 0, mount_point_utf8, -1, mount_point_wide,
        (int)(sizeof(mount_point_wide) / sizeof(WCHAR)));
    macfs_log("mount request: '%s' (len=%d)", mount_point_utf8,
              mount_point_length);
    if (mount_point_length <= 0) {
        macfs_set_mount_error(handle, "Mount point tidak valid");
        macfs_close(ctx);
        return handle;
    }

    if (!macfs_mount_start(handle, ctx, mount_point_wide)) {
        macfs_close(ctx);
        return handle;
    }
    return handle;
}

/* Mount sesungguhnya — dipanggil bridge setelah konteks volume siap. */
int macfs_mount_start(macfs_mount_handle *handle, macfs_ctx *ctx,
                      const WCHAR *mount_point) {
    if (handle == NULL || ctx == NULL || mount_point == NULL) return 0;

    handle->ctx = ctx;
    handle->root_id = macfs_root(ctx);
    if (handle->root_id == 0) {
        macfs_set_mount_error(handle, "Root volume tidak bisa dibaca");
        return 0;
    }

    FSP_FSCTL_VOLUME_PARAMS params;
    memset(&params, 0, sizeof(params));
    params.Version = sizeof(FSP_FSCTL_VOLUME_PARAMS);
    params.SectorSize = 512;
    params.SectorsPerAllocationUnit = 8;
    params.MaxComponentLength = 255;

    /* VolumeCreationTime wajib berupa nilai waktu yang valid (sample resmi
     * memfs mengisinya). Nilai 0 membuat mounting gagal melayani I/O. */
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    params.VolumeCreationTime = ((UINT64)now.dwHighDateTime << 32) | now.dwLowDateTime;
    params.VolumeSerialNumber = (UINT32)(GetTickCount());

    /* IrpTimeout HARUS dalam rentang 1 menit - 10 menit (60000-600000 ms).
     * IrpCapacity HARUS dalam rentang 100 - 1000.
     * Nilai 0 membuat driver menolak IRP -> mount sukses tetapi semua I/O
     * gagal, persis gejala yang terjadi. */
    params.TransactTimeout = 0; /* deprecated, biarkan 0 */
    params.IrpTimeout = 60000;  /* 1 menit (batas bawah) */
    params.IrpCapacity = 1000;  /* maksimum */
    params.FileInfoTimeout = 1000;
    params.CaseSensitiveSearch = 0;
    params.CasePreservedNames = 1;
    params.UnicodeOnDisk = 1;
    params.PersistentAcls = 0;
    params.ReparsePoints = 0;
    params.NamedStreams = 0;
    params.HardLinks = 0;
    params.ExtendedAttributes = 0;
    params.ReadOnlyVolume = 1;
    params.PostCleanupWhenModifiedOnly = 1;
    params.PassQueryDirectoryFileName = 1;

    macfs_log("mount_start: version=%u size=%u root_id=%lld",
              (unsigned)params.Version,
              (unsigned)sizeof(FSP_FSCTL_VOLUME_PARAMS),
              (long long)handle->root_id);

    FSP_FILE_SYSTEM *file_system = NULL;
    NTSTATUS status = g_winfsp.Create(L"WinFsp.Disk", &params, &g_interface,
                                      &file_system);
    macfs_log("Create -> 0x%08lX file_system=%p", (unsigned long)status,
              (void *)file_system);
    if (status != STATUS_SUCCESS) {
        snprintf(handle->error, sizeof(handle->error),
                 "FspFileSystemCreate gagal (0x%08lX)", (unsigned long)status);
        return 0;
    }
    file_system->UserContext = handle;

    /* Bersihkan sisa mount point sebelumnya (folder kosong sisa crash). */
    if (mount_point[0] != L'\0' && mount_point[1] != L':') {
        RemoveDirectoryW(mount_point);
    }

    /* Mount point kosong ("") = biarkan WinFsp memilih huruf drive dari Z:
     * ke bawah (parameter NULL). Ini lebih andal daripada huruf eksplisit. */
    PWSTR requested = (mount_point[0] == L'\0') ? NULL : (PWSTR)mount_point;
    status = g_winfsp.SetMountPoint(file_system, requested);
    macfs_log("SetMountPoint('%ls') -> 0x%08lX", mount_point,
              (unsigned long)status);
    if (status != STATUS_SUCCESS) {
        snprintf(handle->error, sizeof(handle->error),
                 "SetMountPoint gagal (0x%08lX) - huruf drive dipakai?",
                 (unsigned long)status);
        g_winfsp.Delete(file_system);
        return 0;
    }
    status = g_winfsp.StartDispatcher(file_system, 1);
    macfs_log("StartDispatcher -> 0x%08lX", (unsigned long)status);
    if (status != STATUS_SUCCESS) {
        snprintf(handle->error, sizeof(handle->error),
                 "StartDispatcher gagal (0x%08lX)", (unsigned long)status);
        g_winfsp.SetMountPoint(file_system, NULL);
        g_winfsp.Delete(file_system);
        return 0;
    }

    WideCharToMultiByte(CP_UTF8, 0, mount_point, -1, handle->mount_point,
                        sizeof(handle->mount_point), NULL, NULL);
    handle->file_system = file_system;

    /* Verifikasi hanya untuk huruf drive eksplisit. Untuk mode otomatis
     * (mount_point kosong), WinFsp sudah memilih huruf sendiri; verifikasi
     * tambahan memicu crash pada sebagian konfigurasi driver. */
    int verified = 1;
    if (mount_point[0] != L'\0') {
        verified = 0;
        DWORD last_error = 0;
        for (int attempt = 0; attempt < 12; attempt++) {
            wchar_t probe_path[16];
            _snwprintf(probe_path, 16, L"\\\\?\\%c:", mount_point[0]);
            HANDLE probe = CreateFileW(probe_path, 0,
                                       FILE_SHARE_READ | FILE_SHARE_WRITE |
                                           FILE_SHARE_DELETE,
                                       NULL, OPEN_EXISTING,
                                       FILE_FLAG_BACKUP_SEMANTICS, NULL);
            if (probe != INVALID_HANDLE_VALUE) {
                CloseHandle(probe);
                verified = 1;
                break;
            }
            last_error = GetLastError();
            Sleep(200);
        }
        macfs_log("verifikasi '%ls': verified=%d error=%lu", mount_point,
                  verified, (unsigned long)last_error);
        if (!verified) {
            snprintf(handle->error, sizeof(handle->error),
                     "Drive tidak dapat diakses (error %lu). Restart PC lalu "
                     "coba lagi.",
                     (unsigned long)last_error);
            g_winfsp.SetMountPoint(file_system, NULL);
            g_winfsp.StopDispatcher(file_system);
            g_winfsp.Delete(file_system);
            handle->file_system = NULL;
            return 0;
        }
    } else {
        macfs_log("mode huruf otomatis: mount point ditentukan WinFsp");
    }

    handle->mounted = 1;
    return 1;
}

MACFS_MOUNT_API void macfs_unmount(macfs_mount_handle *handle) {
    if (handle == NULL) return;
    if (handle->file_system != NULL) {
        g_winfsp.StopDispatcher(handle->file_system);
        g_winfsp.SetMountPoint(handle->file_system, NULL);
        g_winfsp.Delete(handle->file_system);
        handle->file_system = NULL;
    }
    if (handle->ctx != NULL) {
        macfs_close(handle->ctx);
        handle->ctx = NULL;
    }
    handle->mounted = 0;
    free(handle);
}

MACFS_MOUNT_API const char *macfs_mount_error(macfs_mount_handle *handle) {
    if (handle == NULL || handle->error[0] == '\0') return NULL;
    return handle->error;
}

MACFS_MOUNT_API const char *macfs_mount_point(macfs_mount_handle *handle) {
    return handle == NULL ? NULL : handle->mount_point;
}

MACFS_MOUNT_API int macfs_mount_is_active(macfs_mount_handle *handle) {
    return handle == NULL ? 0 : handle->mounted;
}