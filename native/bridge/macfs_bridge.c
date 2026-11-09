/*
 * macfs_bridge.c - Implementasi API ringkas untuk Flutter FFI.
 *
 * Menyatukan:
 *  - libfsapfs (APFS) dan libfshfs (HFS+), dikompilasi statis ke dalam DLL
 *  - Akses raw disk Windows (CreateFileW + ReadFile, aligned sector read)
 *  - Tabel entry (id -> pointer file_entry) agar Dart cukup memegang int64
 *
 * Catatan penting:
 *  - Semua operasi I/O dilakukan lewat libbfio handle kustom dengan callback
 *    yang membaca dari PhysicalDriveN pada window offset/length tertentu.
 *  - Timestamp APFS: POSIX ns. HFS+: detik HFS (0 = 1904) -> dikonversi ke ns 1970.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MACFS_BUILD_DLL
#include "macfs_bridge.h"

#include <libfsapfs.h>
#include <libfshfs.h>
#include <libbfio_handle.h>
#include <libbfio_types.h>
#include <libcerror_error.h>
#include <libcerror_types.h>

#define HFS_EPOCH_DIFF_SECONDS 2082844800LL

/* ------------------------------------------------------------------ */
/* Struktur konteks                                                    */
/* ------------------------------------------------------------------ */

#define MAX_ENTRIES 65536

typedef struct {
    int64_t id;
    void *entry;       /* libfsapfs_file_entry_t* atau libfshfs_file_entry_t* */
    char *name;        /* nama UTF-8 (dimiliki) */
    char *link_target; /* symlink target UTF-8 (dimiliki, boleh NULL) */
    uint64_t size;
    uint32_t mode;
    int64_t mtime_ns;
    int64_t ctime_ns;
    int64_t atime_ns;
    int used;
} macfs_entry_slot;

struct macfs_ctx {
    HANDLE disk;
    uint64_t base_offset;
    uint64_t length;
    uint64_t sector_size;
    int kind; /* MACFS_KIND_APFS / MACFS_KIND_HFS */

    /* APFS */
    libfsapfs_container_t *container;
    libfsapfs_volume_t *volume;
    int volume_count;
    int selected_volume;

    /* HFS */
    libfshfs_volume_t *hfs_volume;

    /* libbfio custom handle (dipakai oleh fsapfs maupun fshfs) */
    libbfio_handle_t *bfio_handle;

    /* Error terakhir */
    char error_message[1024];

    /* Tabel entry: id = indeks slot + 1 (O(1) lookup). */
    macfs_entry_slot entries[MAX_ENTRIES];
    int32_t free_slots[MAX_ENTRIES];
    int32_t free_count;
    int64_t root_id;
};

/* ------------------------------------------------------------------ */
/* Helper error                                                        */
/* ------------------------------------------------------------------ */

static void macfs_set_error(macfs_ctx *ctx, const char *message) {
    if (ctx == NULL) {
        return;
    }
    strncpy(ctx->error_message, message, sizeof(ctx->error_message) - 1);
    ctx->error_message[sizeof(ctx->error_message) - 1] = '\0';
}

static void macfs_set_error_from_cerror(macfs_ctx *ctx, const char *prefix,
                                        libcerror_error_t *error) {
    char buffer[768];
    buffer[0] = '\0';
    if (error != NULL) {
        libcerror_error_sprint(error, buffer, sizeof(buffer));
    }
    if (ctx != NULL) {
        snprintf(ctx->error_message, sizeof(ctx->error_message), "%s: %s", prefix, buffer);
    }
    if (error != NULL) {
        libcerror_error_free(&error);
    }
}

/* ------------------------------------------------------------------ */
/* Raw disk I/O                                                        */
/* ------------------------------------------------------------------ */

typedef struct {
    HANDLE disk;
    uint64_t base_offset;
    uint64_t length;
    uint64_t sector_size;
    uint64_t position;
    uint8_t *cache;
    uint64_t cache_start;
    uint64_t cache_len;
} macfs_io_t;

static int macfs_io_read_physical(macfs_ctx *ctx, macfs_io_t *io, uint64_t offset,
                                  uint64_t size, uint8_t *buffer) {
    LARGE_INTEGER li;
    DWORD got = 0;
    if (size == 0) {
        return 1;
    }
    li.QuadPart = (LONGLONG)(io->base_offset + offset);
    if (!SetFilePointerEx(io->disk, li, NULL, FILE_BEGIN)) {
        macfs_set_error(ctx, "SetFilePointerEx gagal");
        return -1;
    }
    if (!ReadFile(io->disk, buffer, (DWORD)size, &got, NULL)) {
        snprintf(ctx->error_message, sizeof(ctx->error_message),
                 "ReadFile gagal pada offset %llu (kode %lu)",
                 (unsigned long long)offset, (unsigned long)GetLastError());
        return -1;
    }
    if (got < size) {
        snprintf(ctx->error_message, sizeof(ctx->error_message),
                 "Pembacaan terpotong (%lu dari %llu byte)",
                 (unsigned long)got, (unsigned long long)size);
        return -1;
    }
    return 1;
}

/* libbfio: read pada posisi saat ini */
static ssize_t macfs_io_read(intptr_t *io_handle, uint8_t *buffer, size_t size,
                             libcerror_error_t **error) {
    macfs_io_t *io = (macfs_io_t *)io_handle;
    macfs_ctx *ctx = (macfs_ctx *)(io->position >= 0 ? NULL : NULL);
    (void)ctx;
    if (io == NULL || buffer == NULL) {
        return -1;
    }
    if (size == 0) {
        return 0;
    }
    if (io->position >= io->length) {
        return 0;
    }
    if (io->position + size > io->length) {
        size = (size_t)(io->length - io->position);
    }
    uint64_t sector = io->sector_size ? io->sector_size : 512;
    uint64_t start = (io->position / sector) * sector;
    uint64_t end = ((io->position + size + sector - 1) / sector) * sector;
    if (end > io->length) {
        end = ((io->length + sector - 1) / sector) * sector;
    }
    uint64_t span = end - start;

    if (io->cache == NULL || io->cache_len != span || io->cache_start != start) {
        if (io->cache != NULL) {
            free(io->cache);
            io->cache = NULL;
            io->cache_len = 0;
        }
        io->cache = (uint8_t *)malloc(span);
        if (io->cache == NULL) {
            return -1;
        }
        macfs_ctx *owner = (macfs_ctx *)io->disk; /* placeholder, lihat catatan */
        (void)owner;
        /* Pembacaan fisik butuh ctx untuk pesan error; gunakan NULL-safe path */
        LARGE_INTEGER li;
        DWORD got = 0;
        li.QuadPart = (LONGLONG)(io->base_offset + start);
        if (!SetFilePointerEx(io->disk, li, NULL, FILE_BEGIN)) {
            free(io->cache);
            io->cache = NULL;
            return -1;
        }
        if (!ReadFile(io->disk, io->cache, (DWORD)span, &got, NULL) || got < span) {
            free(io->cache);
            io->cache = NULL;
            return -1;
        }
        io->cache_start = start;
        io->cache_len = span;
    }

    uint64_t relative = io->position - io->cache_start;
    if (relative + size > io->cache_len) {
        return -1;
    }
    memcpy(buffer, io->cache + relative, size);
    io->position += size;
    return (ssize_t)size;
}

static ssize_t macfs_io_write(intptr_t *io_handle, const uint8_t *buffer, size_t size,
                              libcerror_error_t **error) {
    (void)io_handle;
    (void)buffer;
    (void)size;
    (void)error;
    return -1; /* read-only */
}

static off64_t macfs_io_seek(intptr_t *io_handle, off64_t offset, int whence,
                             libcerror_error_t **error) {
    macfs_io_t *io = (macfs_io_t *)io_handle;
    (void)error;
    if (io == NULL) {
        return -1;
    }
    int64_t new_position = 0;
    switch (whence) {
        case SEEK_SET:
            new_position = (int64_t)offset;
            break;
        case SEEK_CUR:
            new_position = (int64_t)io->position + (int64_t)offset;
            break;
        case SEEK_END:
            new_position = (int64_t)io->length + (int64_t)offset;
            break;
        default:
            return -1;
    }
    if (new_position < 0) {
        return -1;
    }
    io->position = (uint64_t)new_position;
    return (off64_t)io->position;
}

static int macfs_io_open(intptr_t *io_handle, int access_flags,
                         libcerror_error_t **error) {
    (void)io_handle;
    (void)access_flags;
    (void)error;
    return 1;
}

static int macfs_io_close(intptr_t *io_handle, libcerror_error_t **error) {
    (void)io_handle;
    (void)error;
    return 0;
}

static int macfs_io_free(intptr_t **io_handle, libcerror_error_t **error) {
    (void)error;
    if (io_handle != NULL && *io_handle != NULL) {
        macfs_io_t *io = (macfs_io_t *)*io_handle;
        if (io->cache != NULL) {
            free(io->cache);
        }
        free(io);
        *io_handle = NULL;
    }
    return 1;
}

static int macfs_io_clone(intptr_t **destination, intptr_t *source,
                          libcerror_error_t **error) {
    (void)error;
    if (destination == NULL) {
        return -1;
    }
    *destination = NULL;
    if (source == NULL) {
        return 1;
    }
    macfs_io_t *src = (macfs_io_t *)source;
    macfs_io_t *copy = (macfs_io_t *)malloc(sizeof(macfs_io_t));
    if (copy == NULL) {
        return -1;
    }
    memcpy(copy, src, sizeof(macfs_io_t));
    copy->cache = NULL;
    copy->cache_len = 0;
    copy->cache_start = 0;
    *destination = (intptr_t *)copy;
    return 1;
}

static int macfs_io_exists(intptr_t *io_handle, libcerror_error_t **error) {
    (void)io_handle;
    (void)error;
    return 1;
}

static int macfs_io_is_open(intptr_t *io_handle, libcerror_error_t **error) {
    (void)io_handle;
    (void)error;
    return 1;
}

static int macfs_io_get_size(intptr_t *io_handle, size64_t *size,
                             libcerror_error_t **error) {
    (void)error;
    if (io_handle == NULL || size == NULL) {
        return -1;
    }
    *size = ((macfs_io_t *)io_handle)->length;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Inisialisasi I/O                                                    */
/* ------------------------------------------------------------------ */

static int macfs_init_io(macfs_ctx *ctx) {
    macfs_io_t *io = (macfs_io_t *)calloc(1, sizeof(macfs_io_t));
    if (io == NULL) {
        macfs_set_error(ctx, "Alokasi I/O gagal");
        return -1;
    }
    io->disk = ctx->disk;
    io->base_offset = ctx->base_offset;
    io->length = ctx->length;
    io->sector_size = ctx->sector_size;

    libcerror_error_t *error = NULL;
    if (libbfio_handle_initialize(&ctx->bfio_handle, (intptr_t *)io, macfs_io_free,
                                  macfs_io_clone, macfs_io_open, macfs_io_close,
                                  macfs_io_read, macfs_io_write, macfs_io_seek,
                                  macfs_io_exists, macfs_io_is_open, macfs_io_get_size,
                                  0, &error) != 1) {
        macfs_set_error_from_cerror(ctx, "libbfio_handle_initialize", error);
        free(io);
        return -1;
    }
    return 1;
}

/* ------------------------------------------------------------------ */
/* Tabel entry                                                         */
/* ------------------------------------------------------------------ */

static macfs_entry_slot *macfs_slot_by_id(macfs_ctx *ctx, int64_t id) {
    if (ctx == NULL || id <= 0 || id > MAX_ENTRIES) {
        return NULL;
    }
    macfs_entry_slot *slot = &ctx->entries[id - 1];
    return slot->used ? slot : NULL;
}

static void macfs_free_slot(macfs_ctx *ctx, macfs_entry_slot *slot) {
    if (slot == NULL) {
        return;
    }
    if (slot->entry != NULL) {
        libcerror_error_t *error = NULL;
        if (ctx->kind == MACFS_KIND_APFS) {
            libfsapfs_file_entry_free((libfsapfs_file_entry_t **)&slot->entry, &error);
        } else {
            libfshfs_file_entry_free((libfshfs_file_entry_t **)&slot->entry, &error);
        }
        if (error != NULL) {
            libcerror_error_free(&error);
        }
    }
    free(slot->name);
    free(slot->link_target);
    memset(slot, 0, sizeof(*slot));
}

static int64_t macfs_register_entry(macfs_ctx *ctx, void *entry) {
    int32_t index = -1;
    if (ctx->free_count > 0) {
        index = ctx->free_slots[--ctx->free_count];
    } else {
        for (int i = 0; i < MAX_ENTRIES; i++) {
            if (!ctx->entries[i].used) {
                index = i;
                break;
            }
        }
    }
    if (index < 0) {
        return 0;
    }
    {
        {
            macfs_entry_slot *slot = &ctx->entries[index];
            memset(slot, 0, sizeof(*slot));
            slot->used = 1;
            slot->id = (int64_t)index + 1;
            slot->entry = entry;

            libcerror_error_t *error = NULL;
            char *name = NULL;
            uint64_t size = 0;
            uint16_t mode = 0;
            int64_t created = 0, modified = 0, accessed = 0;

            if (ctx->kind == MACFS_KIND_APFS) {
                libfsapfs_file_entry_t *fe = (libfsapfs_file_entry_t *)entry;
                size_t name_size = 0;
                if (libfsapfs_file_entry_get_utf8_name_size(fe, &name_size, &error) == 1 &&
                    name_size > 0) {
                    name = (char *)malloc(name_size);
                    if (name != NULL &&
                        libfsapfs_file_entry_get_utf8_name(fe, (uint8_t *)name, name_size,
                                                           &error) != 1) {
                        free(name);
                        name = NULL;
                    }
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                libfsapfs_file_entry_get_size(fe, (size64_t *)&size, &error);
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                libfsapfs_file_entry_get_file_mode(fe, &mode, &error);
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                int64_t value = 0;
                if (libfsapfs_file_entry_get_creation_time(fe, &value, &error) == 1) {
                    created = value;
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                if (libfsapfs_file_entry_get_modification_time(fe, &value, &error) == 1) {
                    modified = value;
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                if (libfsapfs_file_entry_get_access_time(fe, &value, &error) == 1) {
                    accessed = value;
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                /* symlink target */
                size_t link_size = 0;
                if (libfsapfs_file_entry_get_utf8_symbolic_link_target_size(fe, &link_size,
                                                                            &error) == 1 &&
                    link_size > 0) {
                    slot->link_target = (char *)malloc(link_size);
                    if (slot->link_target != NULL &&
                        libfsapfs_file_entry_get_utf8_symbolic_link_target(
                            fe, (uint8_t *)slot->link_target, link_size, &error) != 1) {
                        free(slot->link_target);
                        slot->link_target = NULL;
                    }
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
            } else {
                libfshfs_file_entry_t *fe = (libfshfs_file_entry_t *)entry;
                size_t name_size = 0;
                if (libfshfs_file_entry_get_utf8_name_size(fe, &name_size, &error) == 1 &&
                    name_size > 0) {
                    name = (char *)malloc(name_size);
                    if (name != NULL &&
                        libfshfs_file_entry_get_utf8_name(fe, (uint8_t *)name, name_size,
                                                          &error) != 1) {
                        free(name);
                        name = NULL;
                    }
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                libfshfs_file_entry_get_size(fe, (size64_t *)&size, &error);
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                libfshfs_file_entry_get_file_mode(fe, &mode, &error);
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                uint32_t hfs_time = 0;
                if (libfshfs_file_entry_get_creation_time(fe, &hfs_time, &error) == 1) {
                    created = ((int64_t)hfs_time - HFS_EPOCH_DIFF_SECONDS) * 1000000000LL;
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                if (libfshfs_file_entry_get_modification_time(fe, &hfs_time, &error) == 1) {
                    modified = ((int64_t)hfs_time - HFS_EPOCH_DIFF_SECONDS) * 1000000000LL;
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                if (libfshfs_file_entry_get_access_time(fe, &hfs_time, &error) == 1) {
                    accessed = ((int64_t)hfs_time - HFS_EPOCH_DIFF_SECONDS) * 1000000000LL;
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
                size_t link_size = 0;
                if (libfshfs_file_entry_get_utf8_symbolic_link_target_size(fe, &link_size,
                                                                           &error) == 1 &&
                    link_size > 0) {
                    slot->link_target = (char *)malloc(link_size);
                    if (slot->link_target != NULL &&
                        libfshfs_file_entry_get_utf8_symbolic_link_target(
                            fe, (uint8_t *)slot->link_target, link_size, &error) != 1) {
                        free(slot->link_target);
                        slot->link_target = NULL;
                    }
                }
                if (error != NULL) {
                    libcerror_error_free(&error);
                    error = NULL;
                }
            }

            slot->name = name ? name : _strdup("");
            slot->size = size;
            slot->mode = mode;
            slot->mtime_ns = modified;
            slot->ctime_ns = created;
            slot->atime_ns = accessed;
            return slot->id;
        }
    }
}

/* ------------------------------------------------------------------ */
/* API publik                                                          */
/* ------------------------------------------------------------------ */

MACFS_API const char *macfs_version(void) {
    static char version[128];
    snprintf(version, sizeof(version), "macfs-bridge/1.0 (libfsapfs 20261030, libfshfs 20260922)");
    return version;
}

MACFS_API macfs_ctx *macfs_open(int disk_number, uint64_t offset, uint64_t length,
                                int kind) {
    char path[64];
    snprintf(path, sizeof(path), "\\\\.\\PhysicalDrive%d", disk_number);

    HANDLE disk = CreateFileA(path, GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                              OPEN_EXISTING, 0, NULL);
    if (disk == INVALID_HANDLE_VALUE) {
        return NULL;
    }

    macfs_ctx *ctx = (macfs_ctx *)calloc(1, sizeof(macfs_ctx));
    if (ctx == NULL) {
        CloseHandle(disk);
        return NULL;
    }
    ctx->disk = disk;
    ctx->base_offset = offset;
    ctx->length = length;
    ctx->sector_size = 512;
    ctx->kind = kind;
    ctx->free_count = 0;

    /* Deteksi sector size via IOCTL (fallback 512). */
    DISK_GEOMETRY geometry;
    DWORD returned = 0;
    if (DeviceIoControl(disk, IOCTL_DISK_GET_DRIVE_GEOMETRY, NULL, 0, &geometry,
                        sizeof(geometry), &returned, NULL)) {
        if (geometry.BytesPerSector >= 512) {
            ctx->sector_size = geometry.BytesPerSector;
        }
    }

    if (macfs_init_io(ctx) != 1) {
        macfs_close(ctx);
        return NULL;
    }

    libcerror_error_t *error = NULL;
    if (kind == MACFS_KIND_APFS) {
        if (libfsapfs_container_initialize(&ctx->container, &error) != 1) {
            macfs_set_error_from_cerror(ctx, "libfsapfs_container_initialize", error);
            macfs_close(ctx);
            return NULL;
        }
        if (libfsapfs_container_open_file_io_handle(ctx->container, ctx->bfio_handle,
                                                    LIBFSAPFS_OPEN_READ, &error) != 1) {
            macfs_set_error_from_cerror(ctx, "Bukan container APFS yang valid", error);
            macfs_close(ctx);
            return NULL;
        }
        if (libfsapfs_container_get_number_of_volumes(ctx->container, &ctx->volume_count,
                                                      &error) != 1) {
            macfs_set_error_from_cerror(ctx, "Gagal menghitung volume APFS", error);
            macfs_close(ctx);
            return NULL;
        }
    } else {
        if (libfshfs_volume_initialize(&ctx->hfs_volume, &error) != 1) {
            macfs_set_error_from_cerror(ctx, "libfshfs_volume_initialize", error);
            macfs_close(ctx);
            return NULL;
        }
        if (libfshfs_volume_open_file_io_handle(ctx->hfs_volume, ctx->bfio_handle,
                                                LIBFSHFS_OPEN_READ, &error) != 1) {
            macfs_set_error_from_cerror(ctx, "Bukan volume HFS+ yang valid", error);
            macfs_close(ctx);
            return NULL;
        }
        ctx->volume_count = 1;
    }
    return ctx;
}

MACFS_API void macfs_close(macfs_ctx *ctx) {
    if (ctx == NULL) {
        return;
    }
    for (int i = 0; i < MAX_ENTRIES; i++) {
        if (ctx->entries[i].used) {
            macfs_free_slot(ctx, &ctx->entries[i]);
        }
    }
    libcerror_error_t *error = NULL;
    if (ctx->container != NULL) {
        libfsapfs_container_free(&ctx->container, &error);
        if (error != NULL) {
            libcerror_error_free(&error);
            error = NULL;
        }
    }
    if (ctx->hfs_volume != NULL) {
        libfshfs_volume_free(&ctx->hfs_volume, &error);
        if (error != NULL) {
            libcerror_error_free(&error);
            error = NULL;
        }
    }
    if (ctx->bfio_handle != NULL) {
        libbfio_handle_free(&ctx->bfio_handle, &error);
        if (error != NULL) {
            libcerror_error_free(&error);
        }
    }
    if (ctx->disk != INVALID_HANDLE_VALUE && ctx->disk != NULL) {
        CloseHandle(ctx->disk);
    }
    free(ctx);
}

MACFS_API const char *macfs_error(macfs_ctx *ctx) {
    if (ctx == NULL || ctx->error_message[0] == '\0') {
        return NULL;
    }
    return ctx->error_message;
}

MACFS_API int macfs_volume_count(macfs_ctx *ctx) {
    return ctx ? ctx->volume_count : 0;
}

MACFS_API int macfs_select_volume(macfs_ctx *ctx, int index) {
    if (ctx == NULL || ctx->kind != MACFS_KIND_APFS) {
        return ctx != NULL && ctx->kind == MACFS_KIND_HFS && index == 0 ? 1 : 0;
    }
    if (index < 0 || index >= ctx->volume_count) {
        return 0;
    }
    libcerror_error_t *error = NULL;
    if (ctx->volume != NULL) {
        libfsapfs_volume_free(&ctx->volume, &error);
        if (error != NULL) {
            libcerror_error_free(&error);
            error = NULL;
        }
    }
    if (libfsapfs_container_get_volume_by_index(ctx->container, index, &ctx->volume,
                                                &error) != 1) {
        macfs_set_error_from_cerror(ctx, "Gagal membuka volume", error);
        return 0;
    }
    ctx->selected_volume = index;
    return 1;
}

MACFS_API const char *macfs_volume_name(macfs_ctx *ctx) {
    static char name[512];
    if (ctx == NULL) {
        return NULL;
    }
    libcerror_error_t *error = NULL;
    size_t name_size = 0;
    name[0] = '\0';
    if (ctx->kind == MACFS_KIND_APFS) {
        if (ctx->volume == NULL) {
            return name;
        }
        if (libfsapfs_volume_get_utf8_name_size(ctx->volume, &name_size, &error) == 1 &&
            name_size > 0 && name_size < sizeof(name)) {
            libfsapfs_volume_get_utf8_name(ctx->volume, (uint8_t *)name, name_size, &error);
        }
    } else {
        if (ctx->hfs_volume == NULL) {
            return name;
        }
        if (libfshfs_volume_get_utf8_name_size(ctx->hfs_volume, &name_size, &error) == 1 &&
            name_size > 0 && name_size < sizeof(name)) {
            libfshfs_volume_get_utf8_name(ctx->hfs_volume, (uint8_t *)name, name_size,
                                          &error);
        }
    }
    if (error != NULL) {
        libcerror_error_free(&error);
    }
    return name;
}

MACFS_API int macfs_volume_is_locked(macfs_ctx *ctx) {
    if (ctx == NULL || ctx->kind != MACFS_KIND_APFS || ctx->volume == NULL) {
        return 0;
    }
    return libfsapfs_volume_is_locked(ctx->volume, NULL) == 1 ? 1 : 0;
}

MACFS_API int macfs_unlock_password(macfs_ctx *ctx, const char *password_utf8) {
    if (ctx == NULL || ctx->volume == NULL || password_utf8 == NULL) {
        return 0;
    }
    libcerror_error_t *error = NULL;
    if (libfsapfs_volume_set_utf8_password(ctx->volume, (const uint8_t *)password_utf8,
                                           strlen(password_utf8), &error) != 1) {
        macfs_set_error_from_cerror(ctx, "Gagal set password", error);
        return 0;
    }
    if (libfsapfs_volume_unlock(ctx->volume, &error) != 1) {
        macfs_set_error_from_cerror(ctx, "Password salah", error);
        return 0;
    }
    return 1;
}

MACFS_API int64_t macfs_root(macfs_ctx *ctx) {
    if (ctx == NULL) {
        return 0;
    }
    if (ctx->root_id != 0 && macfs_slot_by_id(ctx, ctx->root_id) != NULL) {
        return ctx->root_id;
    }
    libcerror_error_t *error = NULL;
    void *root_entry = NULL;
    if (ctx->kind == MACFS_KIND_APFS) {
        if (ctx->volume == NULL) {
            macfs_set_error(ctx, "Volume belum dipilih");
            return 0;
        }
        if (libfsapfs_volume_get_root_directory(ctx->volume,
                                                (libfsapfs_file_entry_t **)&root_entry,
                                                &error) != 1) {
            macfs_set_error_from_cerror(ctx, "Gagal membaca root directory", error);
            return 0;
        }
    } else {
        if (ctx->hfs_volume == NULL) {
            macfs_set_error(ctx, "Volume HFS+ belum dibuka");
            return 0;
        }
        if (libfshfs_volume_get_root_directory(ctx->hfs_volume,
                                               (libfshfs_file_entry_t **)&root_entry,
                                               &error) != 1) {
            macfs_set_error_from_cerror(ctx, "Gagal membaca root directory", error);
            return 0;
        }
    }
    ctx->root_id = macfs_register_entry(ctx, root_entry);
    return ctx->root_id;
}

MACFS_API int64_t macfs_open_path(macfs_ctx *ctx, const char *path_utf8) {
    if (ctx == NULL || path_utf8 == NULL) {
        return 0;
    }
    libcerror_error_t *error = NULL;
    void *entry = NULL;
    int result = 0;
    if (ctx->kind == MACFS_KIND_APFS) {
        if (ctx->volume == NULL) {
            macfs_set_error(ctx, "Volume belum dipilih");
            return 0;
        }
        result = libfsapfs_volume_get_file_entry_by_utf8_path(
            ctx->volume, (const uint8_t *)path_utf8, strlen(path_utf8),
            (libfsapfs_file_entry_t **)&entry, &error);
    } else {
        if (ctx->hfs_volume == NULL) {
            macfs_set_error(ctx, "Volume HFS+ belum dibuka");
            return 0;
        }
        result = libfshfs_volume_get_file_entry_by_utf8_path(
            ctx->hfs_volume, (const uint8_t *)path_utf8, strlen(path_utf8),
            (libfshfs_file_entry_t **)&entry, &error);
    }
    if (result != 1 || entry == NULL) {
        if (error != NULL) {
            libcerror_error_free(&error);
        }
        return 0;
    }
    return macfs_register_entry(ctx, entry);
}

MACFS_API int macfs_entry_count(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    if (slot == NULL) {
        return -1;
    }
    libcerror_error_t *error = NULL;
    int count = 0;
    int result = 0;
    if (ctx->kind == MACFS_KIND_APFS) {
        result = libfsapfs_file_entry_get_number_of_sub_file_entries(
            (libfsapfs_file_entry_t *)slot->entry, &count, &error);
    } else {
        result = libfshfs_file_entry_get_number_of_sub_file_entries(
            (libfshfs_file_entry_t *)slot->entry, &count, &error);
    }
    if (result != 1) {
        if (error != NULL) {
            libcerror_error_free(&error);
        }
        return -1;
    }
    return count;
}

MACFS_API int64_t macfs_entry_child(macfs_ctx *ctx, int64_t id, int index) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    if (slot == NULL) {
        return 0;
    }
    libcerror_error_t *error = NULL;
    void *child = NULL;
    int result = 0;
    if (ctx->kind == MACFS_KIND_APFS) {
        result = libfsapfs_file_entry_get_sub_file_entry_by_index(
            (libfsapfs_file_entry_t *)slot->entry, index,
            (libfsapfs_file_entry_t **)&child, &error);
    } else {
        result = libfshfs_file_entry_get_sub_file_entry_by_index(
            (libfshfs_file_entry_t *)slot->entry, index,
            (libfshfs_file_entry_t **)&child, &error);
    }
    if (result != 1 || child == NULL) {
        if (error != NULL) {
            libcerror_error_free(&error);
        }
        return 0;
    }
    return macfs_register_entry(ctx, child);
}

MACFS_API void macfs_entry_release(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    if (slot == NULL) {
        return;
    }
    if (id == ctx->root_id) {
        /* root dicache; jangan dibebaskan sampai close */
        return;
    }
    int32_t index = (int32_t)(id - 1);
    macfs_free_slot(ctx, slot);
    if (ctx->free_count < MAX_ENTRIES) {
        ctx->free_slots[ctx->free_count++] = index;
    }
}

MACFS_API const char *macfs_entry_name(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    return slot ? slot->name : NULL;
}

MACFS_API uint64_t macfs_entry_size(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    return slot ? slot->size : 0;
}

MACFS_API uint32_t macfs_entry_mode(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    return slot ? slot->mode : 0;
}

MACFS_API int64_t macfs_entry_mtime_ns(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    return slot ? slot->mtime_ns : 0;
}

MACFS_API int64_t macfs_entry_ctime_ns(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    return slot ? slot->ctime_ns : 0;
}

MACFS_API int64_t macfs_entry_atime_ns(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    return slot ? slot->atime_ns : 0;
}

MACFS_API const char *macfs_entry_link_target(macfs_ctx *ctx, int64_t id) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    return slot ? slot->link_target : NULL;
}

MACFS_API int64_t macfs_read_at(macfs_ctx *ctx, int64_t id, void *buffer,
                                uint64_t size, uint64_t offset) {
    macfs_entry_slot *slot = macfs_slot_by_id(ctx, id);
    if (slot == NULL || buffer == NULL) {
        return -1;
    }
    libcerror_error_t *error = NULL;
    ssize_t read_count = -1;
    if (ctx->kind == MACFS_KIND_APFS) {
        read_count = libfsapfs_file_entry_read_buffer_at_offset(
            (libfsapfs_file_entry_t *)slot->entry, buffer, (size_t)size, (off64_t)offset,
            &error);
    } else {
        read_count = libfshfs_file_entry_read_buffer_at_offset(
            (libfshfs_file_entry_t *)slot->entry, buffer, (size_t)size, (off64_t)offset,
            &error);
    }
    if (read_count < 0) {
        macfs_set_error_from_cerror(ctx, "Gagal membaca file", error);
        return -1;
    }
    return (int64_t)read_count;
}
/* ------------------------------------------------------------------ */
/* Partisi disk (GPT/MBR)                                              */
/* ------------------------------------------------------------------ */

#define MACFS_PART_UNKNOWN 0
#define MACFS_PART_APFS 1
#define MACFS_PART_HFS 2

typedef struct {
    uint64_t offset;
    uint64_t length;
    int kind;
    char guid[64];
    char name[128];
} macfs_part_info;

static int macfs_guid_string(const uint8_t *raw, char *out, int out_len) {
    snprintf(out, out_len,
             "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6],
             raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]);
    return 1;
}

static int macfs_read_at_aligned(HANDLE disk, uint64_t sector_size,
                                 uint64_t offset, uint32_t size, uint8_t *buffer) {
    uint64_t aligned_start = (offset / sector_size) * sector_size;
    uint64_t aligned_end = ((offset + size + sector_size - 1) / sector_size) * sector_size;
    uint64_t span = aligned_end - aligned_start;
    if (span > 16 * 1024 * 1024) {
        return -1;
    }
    uint8_t *temp = (uint8_t *)malloc((size_t)span);
    if (temp == NULL) {
        return -1;
    }
    LARGE_INTEGER li;
    DWORD got = 0;
    li.QuadPart = (LONGLONG)aligned_start;
    if (!SetFilePointerEx(disk, li, NULL, FILE_BEGIN) ||
        !ReadFile(disk, temp, (DWORD)span, &got, NULL) || got < span) {
        free(temp);
        return -1;
    }
    memcpy(buffer, temp + (offset - aligned_start), size);
    free(temp);
    return 1;
}

static int macfs_collect_partitions(int disk_number, macfs_part_info **out_parts,
                                    int *out_count) {
    char path[64];
    snprintf(path, sizeof(path), "\\\\.\\PhysicalDrive%d", disk_number);
    HANDLE disk = CreateFileA(path, GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                              OPEN_EXISTING, 0, NULL);
    if (disk == INVALID_HANDLE_VALUE) {
        return -1;
    }
    uint64_t sector_size = 512;
    DISK_GEOMETRY geometry;
    DWORD returned = 0;
    if (DeviceIoControl(disk, IOCTL_DISK_GET_DRIVE_GEOMETRY, NULL, 0, &geometry,
                        sizeof(geometry), &returned, NULL)) {
        if (geometry.BytesPerSector >= 512) {
            sector_size = geometry.BytesPerSector;
        }
    }

    macfs_part_info *parts = NULL;
    int count = 0;

    uint8_t header[92];
    if (macfs_read_at_aligned(disk, sector_size, sector_size, 92, header) == 1 &&
        memcmp(header, "EFI PART", 8) == 0) {
        uint64_t entries_lba = 0;
        uint32_t entry_count = 0, entry_size = 0;
        memcpy(&entries_lba, header + 72, 8);
        memcpy(&entry_count, header + 80, 4);
        memcpy(&entry_size, header + 84, 4);
        if (entry_count > 0 && entry_count <= 256 && entry_size >= 128 && entry_size <= 4096) {
            size_t table_size = (size_t)entry_count * entry_size;
            uint8_t *table = (uint8_t *)malloc(table_size);
            if (table != NULL) {
                if (macfs_read_at_aligned(disk, sector_size, entries_lba * sector_size,
                                          (uint32_t)table_size, table) == 1) {
                    parts = (macfs_part_info *)calloc(entry_count, sizeof(macfs_part_info));
                    if (parts != NULL) {
                        for (uint32_t i = 0; i < entry_count; i++) {
                            uint8_t *e = table + (size_t)i * entry_size;
                            int all_zero = 1;
                            for (int b = 0; b < 16; b++) {
                                if (e[b]) { all_zero = 0; break; }
                            }
                            if (all_zero) continue;
                            uint64_t first_lba = 0, last_lba = 0;
                            memcpy(&first_lba, e + 32, 8);
                            memcpy(&last_lba, e + 40, 8);
                            if (last_lba < first_lba) continue;
                            macfs_part_info *p = &parts[count];
                            p->offset = first_lba * sector_size;
                            p->length = (last_lba - first_lba + 1) * sector_size;
                            macfs_guid_string(e, p->guid, sizeof(p->guid));
                            p->kind = MACFS_PART_UNKNOWN;
                            if (strcmp(p->guid, "7c3457ef-0000-11aa-aa11-00306543ecac") == 0) {
                                p->kind = MACFS_PART_APFS;
                            } else if (strcmp(p->guid, "48465300-0000-11aa-aa11-00306543ecac") == 0) {
                                p->kind = MACFS_PART_HFS;
                            }
                            for (int c = 0; c < 64 && c * 2 + 1 < 72; c++) {
                                uint16_t unit = (uint16_t)(e[56 + c * 2] | (e[56 + c * 2 + 1] << 8));
                                if (unit == 0) break;
                                if (unit < 128) {
                                    p->name[c] = (char)unit;
                                } else if (unit < 0x800) {
                                    /* UTF-8 2 byte - lewati, jarang untuk nama partisi */
                                }
                            }
                            count++;
                        }
                    }
                }
                free(table);
            }
        }
    } else {
        /* MBR */
        uint8_t mbr[512];
        if (macfs_read_at_aligned(disk, sector_size, 0, 512, mbr) == 1 &&
            mbr[510] == 0x55 && mbr[511] == 0xAA) {
            parts = (macfs_part_info *)calloc(4, sizeof(macfs_part_info));
            if (parts != NULL) {
                for (int i = 0; i < 4; i++) {
                    uint8_t *e = mbr + 446 + i * 16;
                    uint8_t type = e[4];
                    if (type == 0) continue;
                    uint32_t start = 0, sectors = 0;
                    memcpy(&start, e + 8, 4);
                    memcpy(&sectors, e + 12, 4);
                    if (start == 0 || sectors == 0) continue;
                    macfs_part_info *p = &parts[count];
                    p->offset = (uint64_t)start * sector_size;
                    p->length = (uint64_t)sectors * sector_size;
                    p->kind = MACFS_PART_UNKNOWN;
                    if (type == 0xAF) p->kind = MACFS_PART_HFS;
                    if (type == 0xA8) p->kind = MACFS_PART_APFS;
                    snprintf(p->guid, sizeof(p->guid), "mbr-%02x", type);
                    count++;
                }
            }
        }
    }
    CloseHandle(disk);
    *out_parts = parts;
    *out_count = count;
    return 0;
}

MACFS_API int macfs_disk_count(void) {
    int count = 0;
    for (int n = 0; n < 32; n++) {
        char path[64];
        snprintf(path, sizeof(path), "\\\\.\\PhysicalDrive%d", n);
        HANDLE disk = CreateFileA(path, GENERIC_READ,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                                  OPEN_EXISTING, 0, NULL);
        if (disk != INVALID_HANDLE_VALUE) {
            count++;
            CloseHandle(disk);
        }
    }
    return count;
}

MACFS_API int macfs_can_access_disks(void) {
    HANDLE disk = CreateFileA("\\\\.\\PhysicalDrive0", GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                              OPEN_EXISTING, 0, NULL);
    if (disk == INVALID_HANDLE_VALUE) {
        return 0;
    }
    CloseHandle(disk);
    return 1;
}

MACFS_API int macfs_disk_partition_count(int disk_number) {
    macfs_part_info *parts = NULL;
    int count = 0;
    if (macfs_collect_partitions(disk_number, &parts, &count) != 0) {
        return -1;
    }
    free(parts);
    return count;
}

MACFS_API int macfs_disk_partition_get(int disk_number, int index,
                                       uint64_t *offset, uint64_t *length,
                                       int *kind, char *guid, int guid_len,
                                       char *name, int name_len) {
    macfs_part_info *parts = NULL;
    int count = 0;
    if (macfs_collect_partitions(disk_number, &parts, &count) != 0) {
        return -1;
    }
    if (index < 0 || index >= count) {
        free(parts);
        return 0;
    }
    macfs_part_info *p = &parts[index];
    if (offset) *offset = p->offset;
    if (length) *length = p->length;
    if (kind) *kind = p->kind;
    if (guid && guid_len > 0) {
        strncpy(guid, p->guid, guid_len - 1);
        guid[guid_len - 1] = '\0';
    }
    if (name && name_len > 0) {
        strncpy(name, p->name, name_len - 1);
        name[name_len - 1] = '\0';
    }
    free(parts);
    return 1;
}
