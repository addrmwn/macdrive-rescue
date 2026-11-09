"""Utilitas umum: konversi waktu, long path Windows, set timestamp file."""

from __future__ import annotations

import ctypes
import os
import re
import time
from ctypes import wintypes

NS_PER_SEC = 1_000_000_000
FILETIME_EPOCH_DIFF = 11644473600  # detik antara 1601-01-01 dan 1970-01-01

k32 = ctypes.WinDLL("kernel32", use_last_error=True)

FILE_WRITE_ATTRIBUTES = 0x0100
FILE_SHARE_READ = 0x00000001
FILE_SHARE_WRITE = 0x00000002
FILE_SHARE_DELETE = 0x00000004
OPEN_EXISTING = 3
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000

k32.CreateFileW.restype = wintypes.HANDLE
k32.CreateFileW.argtypes = [
    wintypes.LPCWSTR,
    wintypes.DWORD,
    wintypes.DWORD,
    wintypes.LPVOID,
    wintypes.DWORD,
    wintypes.DWORD,
    wintypes.HANDLE,
]
k32.SetFileTime.restype = wintypes.BOOL
k32.SetFileTime.argtypes = [
    wintypes.HANDLE,
    ctypes.POINTER(ctypes.c_int64),
    ctypes.POINTER(ctypes.c_int64),
    ctypes.POINTER(ctypes.c_int64),
]
k32.CloseHandle.argtypes = [wintypes.HANDLE]


def long_path(path: str) -> str:
    """Ubah path absolut menjadi bentuk \\\\?\\ agar tidak dibatasi 260 karakter."""
    path = os.path.abspath(path)
    if path.startswith("\\\\?\\"):
        return path
    if path.startswith("\\\\"):
        return "\\\\?\\UNC\\" + path[2:]
    return "\\\\?\\" + path


def _plausible_year(seconds: float) -> bool:
    return 1970 <= time.gmtime(seconds).tm_year <= 2100 if seconds >= 0 else False


HFS_EPOCH_DIFF = 2082844800  # detik antara 1904-01-01 dan 1970-01-01


def detect_unix_ns(value: int | None, hint: str = "auto") -> int | None:
    """Terima timestamp dari libyal (berbagai epoch/satuan) -> ns sejak 1970.

    `hint`:
      - "apfs_ns"      : nanodetik sejak 1970 (APFS)
      - "hfs_seconds"  : detik sejak 1904 (HFS+)
      - "filetime"     : 100 ns sejak 1601
      - "auto"         : tebak dari besaran nilai
    """
    if value is None:
        return None
    v = int(value)
    if v == 0:
        return 0
    if hint == "apfs_ns":
        return v
    if hint == "hfs_seconds":
        return (v - HFS_EPOCH_DIFF) * NS_PER_SEC
    if hint == "filetime":
        return (v - FILETIME_EPOCH_DIFF * 10_000_000) * 100

    # Heuristik berdasarkan besaran. Rentang realistis 1970-2035:
    #   ns   : 0 .. ~2.0e18
    #   us   : ~1e14 .. 2e15
    #   ms   : ~1e11 .. 2e12
    #   detik: ~1e8  .. 2e9
    #   HFS (detik sejak 1904): ~2.1e9 .. 4.2e9
    #   FILETIME: ~1.2e17 .. 1.4e17
    if v >= 5e17:
        return v  # ns sejak 1970
    if v >= 1e16:
        return (v - FILETIME_EPOCH_DIFF * 10_000_000) * 100  # FILETIME
    if v >= 1e13:
        return v * 1_000  # mikrodetik sejak 1970
    if v >= 1e11:
        return v * 1_000_000  # milidetik sejak 1970
    if v >= 3.2e9:
        return (v - HFS_EPOCH_DIFF) * NS_PER_SEC  # HFS (1904)
    if v >= 1e8:
        return v * NS_PER_SEC  # detik sejak 1970
    return None


def filetime_from_unix_ns(unix_ns: int) -> int:
    return int(unix_ns // 100) + FILETIME_EPOCH_DIFF * 10_000_000


def set_file_times(path: str, mtime_ns: int | None, atime_ns: int | None = None,
                   creation_ns: int | None = None, is_dir: bool = False) -> None:
    """Set waktu modifikasi/akses/pembuatan file atau folder (Windows)."""
    p = long_path(path)
    flags = FILE_FLAG_BACKUP_SEMANTICS if is_dir else 0
    handle = k32.CreateFileW(
        p,
        FILE_WRITE_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        None,
        OPEN_EXISTING,
        flags,
        None,
    )
    if not handle or handle == ctypes.c_void_p(-1).value:
        raise OSError(ctypes.get_last_error(), "Tidak bisa membuka file untuk set waktu: %s" % path)
    try:
        if creation_ns is not None:
            ft_creation = ctypes.c_int64(filetime_from_unix_ns(creation_ns))
            ft_access = ctypes.c_int64(
                filetime_from_unix_ns(atime_ns if atime_ns is not None else mtime_ns)
            )
            ft_write = ctypes.c_int64(filetime_from_unix_ns(mtime_ns))
            k32.SetFileTime(
                handle, ctypes.byref(ft_creation), ctypes.byref(ft_access), ctypes.byref(ft_write)
            )
        else:
            if mtime_ns is not None:
                os.utime(long_path(path), ns=(atime_ns or mtime_ns, mtime_ns))
    finally:
        k32.CloseHandle(handle)


_ILLEGAL_XML = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def human_size(num: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(num) < 1024.0 or unit == "TB":
            if unit == "B":
                return "%d %s" % (int(num), unit)
            return "%.1f %s" % (num, unit)
        num /= 1024.0
    return "%.1f TB" % num


def human_speed(bytes_per_sec: float) -> str:
    return human_size(bytes_per_sec) + "/s"


def human_eta(seconds: float | None) -> str:
    if seconds is None or seconds < 0 or seconds != seconds or seconds > 86400 * 7:
        return "--:--"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return "%d:%02d:%02d" % (h, m, s)
    return "%02d:%02d" % (m, s)


def free_space(path: str) -> int:
    try:
        usage = __import__("shutil").disk_usage(os.path.splitdrive(os.path.abspath(path))[0] + "\\")
        return usage.free
    except Exception:
        return -1