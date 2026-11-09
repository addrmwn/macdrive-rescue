/*
 * macfs_bridge.h - API ringkas untuk Flutter FFI (Dart).
 *
 * Membungkus libfsapfs (APFS) dan libfshfs (HFS+) plus akses raw disk
 * Windows agar dapat dipakai dari Flutter tanpa Python.
 *
 * Semua string adalah UTF-8 dan dimiliki oleh konteks (valid sampai
 * macfs_close). ID entry adalah int64 > 0; 0 berarti gagal.
 */

#ifndef MACFS_BRIDGE_H
#define MACFS_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(MACFS_BUILD_DLL)
#define MACFS_API __declspec(dllexport)
#else
#define MACFS_API __declspec(dllimport)
#endif

typedef struct macfs_ctx macfs_ctx;

/* Jenis filesystem */
enum {
    MACFS_KIND_APFS = 0,
    MACFS_KIND_HFS = 1
};

/* Membuka disk fisik (butuh Administrator). offset/length dalam byte. */
MACFS_API macfs_ctx *macfs_open(int disk_number, uint64_t offset, uint64_t length, int kind);

/* Menutup konteks, membebaskan semua handle. */
MACFS_API void macfs_close(macfs_ctx *ctx);

/* Pesan error terakhir (UTF-8, boleh NULL bila tidak ada). */
MACFS_API const char *macfs_error(macfs_ctx *ctx);

/* ------------------------- APFS container ------------------------- */

MACFS_API int macfs_volume_count(macfs_ctx *ctx);            /* untuk HFS: 1 */
MACFS_API int macfs_select_volume(macfs_ctx *ctx, int index); /* 1 sukses */
MACFS_API const char *macfs_volume_name(macfs_ctx *ctx);
MACFS_API int macfs_volume_is_locked(macfs_ctx *ctx);
MACFS_API int macfs_unlock_password(macfs_ctx *ctx, const char *password_utf8);

/* ---------------------------- Entry ------------------------------- */

MACFS_API int64_t macfs_root(macfs_ctx *ctx);
MACFS_API int64_t macfs_open_path(macfs_ctx *ctx, const char *path_utf8);
MACFS_API int macfs_entry_count(macfs_ctx *ctx, int64_t id);
MACFS_API int64_t macfs_entry_child(macfs_ctx *ctx, int64_t id, int index);
MACFS_API void macfs_entry_release(macfs_ctx *ctx, int64_t id);

MACFS_API const char *macfs_entry_name(macfs_ctx *ctx, int64_t id);
MACFS_API uint64_t macfs_entry_size(macfs_ctx *ctx, int64_t id);
MACFS_API uint32_t macfs_entry_mode(macfs_ctx *ctx, int64_t id);     /* POSIX mode */
MACFS_API int64_t macfs_entry_mtime_ns(macfs_ctx *ctx, int64_t id);  /* ns sejak 1970 */
MACFS_API int64_t macfs_entry_ctime_ns(macfs_ctx *ctx, int64_t id);
MACFS_API int64_t macfs_entry_atime_ns(macfs_ctx *ctx, int64_t id);
MACFS_API const char *macfs_entry_link_target(macfs_ctx *ctx, int64_t id);

/* Membaca isi file. Mengembalikan jumlah byte dibaca (>=0) atau -1. */
MACFS_API int64_t macfs_read_at(macfs_ctx *ctx, int64_t id, void *buffer,
                                uint64_t size, uint64_t offset);

/* Versi library (diagnostik). */
MACFS_API const char *macfs_version(void);

/* ------------------------- Partisi disk ---------------------------- */

/* Jumlah partisi pada disk fisik (GPT/MBR). -1 bila gagal. */
MACFS_API int macfs_disk_partition_count(int disk_number);

/* Info partisi ke-index (0-based, urutan di tabel). Mengisi output bila
 * tidak NULL. Mengembalikan 1 sukses, 0 tidak ada, -1 error. */
MACFS_API int macfs_disk_partition_get(int disk_number, int index,
                                       uint64_t *offset, uint64_t *length,
                                       int *kind, char *guid, int guid_len,
                                       char *name, int name_len);

/* Jumlah disk fisik yang ada (probe CreateFile). */
MACFS_API int macfs_disk_count(void);

/* Apakah proses dapat membuka disk fisik (Administrator)? */
MACFS_API int macfs_can_access_disks(void);

#ifdef __cplusplus
}
#endif

#endif /* MACFS_BRIDGE_H */