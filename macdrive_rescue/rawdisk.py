"""Akses baca langsung (raw) ke perangkat disk Windows.

Windows + driver MacDrive trial yang sudah kedaluwarsa memblokir pembacaan isi
file (hanya nama folder yang bisa dilihat). Modul ini membuka disk fisik secara
mentah dan menyediakan objek file-like agar filesystem APFS/HFS+ bisa dibaca
tanpa driver MacDrive sama sekali.

Memerlukan hak Administrator (UAC).
"""

from __future__ import annotations

import ctypes
import string
from ctypes import wintypes

k32 = ctypes.WinDLL("kernel32", use_last_error=True)

GENERIC_READ = 0x80000000
FILE_SHARE_READ = 0x00000001
FILE_SHARE_WRITE = 0x00000002
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C
IOCTL_DISK_GET_DRIVE_GEOMETRY = 0x00070000
IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400
IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x00560000

ERROR_ACCESS_DENIED = 5

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
k32.CloseHandle.restype = wintypes.BOOL
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.SetFilePointerEx.restype = wintypes.BOOL
k32.SetFilePointerEx.argtypes = [
    wintypes.HANDLE,
    ctypes.c_int64,
    ctypes.POINTER(ctypes.c_int64),
    wintypes.DWORD,
]
k32.ReadFile.restype = wintypes.BOOL
k32.ReadFile.argtypes = [
    wintypes.HANDLE,
    wintypes.LPVOID,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
    wintypes.LPVOID,
]
k32.DeviceIoControl.restype = wintypes.BOOL
k32.DeviceIoControl.argtypes = [
    wintypes.HANDLE,
    wintypes.DWORD,
    wintypes.LPVOID,
    wintypes.DWORD,
    wintypes.LPVOID,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
    wintypes.LPVOID,
]
k32.GetVolumeInformationW.restype = wintypes.BOOL
k32.GetVolumeInformationW.argtypes = [
    wintypes.LPCWSTR,
    wintypes.LPWSTR,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
    ctypes.POINTER(wintypes.DWORD),
    ctypes.POINTER(wintypes.DWORD),
    wintypes.LPWSTR,
    wintypes.DWORD,
]


class DISK_GEOMETRY(ctypes.Structure):
    _fields_ = [
        ("Cylinders", ctypes.c_int64),
        ("MediaType", wintypes.DWORD),
        ("TracksPerCylinder", wintypes.DWORD),
        ("SectorsPerTrack", wintypes.DWORD),
        ("BytesPerSector", wintypes.DWORD),
    ]


class DISK_EXTENT(ctypes.Structure):
    _fields_ = [
        ("DiskNumber", wintypes.DWORD),
        ("_pad", wintypes.DWORD),
        ("StartingOffset", ctypes.c_ulonglong),
        ("ExtentLength", ctypes.c_ulonglong),
    ]


class VOLUME_DISK_EXTENTS(ctypes.Structure):
    _fields_ = [
        ("NumberOfDiskExtents", wintypes.DWORD),
        ("_pad", wintypes.DWORD),
        ("Extents", DISK_EXTENT * 16),
    ]


class STORAGE_PROPERTY_QUERY(ctypes.Structure):
    _fields_ = [
        ("PropertyId", wintypes.DWORD),
        ("QueryType", wintypes.DWORD),
        ("AdditionalParameters", wintypes.BYTE * 1),
    ]


def _check_handle(handle):
    if not handle or handle == INVALID_HANDLE_VALUE:
        return False
    return True


def _last_error():
    return ctypes.get_last_error()


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


class RawDiskError(OSError):
    pass


class RawDisk:
    """Handle ke perangkat fisik (mis. \\\\.\\PhysicalDrive2), read-only."""

    def __init__(self, path: str, number: int | None = None):
        self.path = path
        self.number = number
        self._handle = k32.CreateFileW(
            path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, None, OPEN_EXISTING, 0, None
        )
        if not _check_handle(self._handle):
            err = _last_error()
            if err == ERROR_ACCESS_DENIED:
                raise RawDiskError(
                    err,
                    "Akses ke %s ditolak. Jalankan aplikasi sebagai Administrator." % path,
                )
            raise RawDiskError(err, "Tidak bisa membuka %s (kode %d)" % (path, err))
        self.sector_size = self._read_sector_size()
        self.size = self._read_size()

    # ------------------------------------------------------------------ info
    def _read_sector_size(self) -> int:
        geom = DISK_GEOMETRY()
        ret = wintypes.DWORD(0)
        ok = k32.DeviceIoControl(
            self._handle,
            IOCTL_DISK_GET_DRIVE_GEOMETRY,
            None,
            0,
            ctypes.byref(geom),
            ctypes.sizeof(geom),
            ctypes.byref(ret),
            None,
        )
        if ok and geom.BytesPerSector >= 512:
            return int(geom.BytesPerSector)
        return 512

    def _read_size(self) -> int:
        value = ctypes.c_int64(0)
        ret = wintypes.DWORD(0)
        ok = k32.DeviceIoControl(
            self._handle,
            IOCTL_DISK_GET_LENGTH_INFO,
            None,
            0,
            ctypes.byref(value),
            ctypes.sizeof(value),
            ctypes.byref(ret),
            None,
        )
        if not ok:
            raise RawDiskError(_last_error(), "Gagal membaca ukuran disk %s" % self.path)
        return int(value.value)

    def model_name(self) -> str:
        try:
            query = STORAGE_PROPERTY_QUERY()
            query.PropertyId = 0  # StorageDeviceProperty
            query.QueryType = 0  # PropertyStandardQuery
            buf = ctypes.create_string_buffer(1024)
            ret = wintypes.DWORD(0)
            ok = k32.DeviceIoControl(
                self._handle,
                IOCTL_STORAGE_QUERY_PROPERTY,
                ctypes.byref(query),
                ctypes.sizeof(query),
                buf,
                ctypes.sizeof(buf),
                ctypes.byref(ret),
                None,
            )
            if not ok or ret.value < 24:
                return ""
            data = buf.raw[: ret.value]
            vendor_off = int.from_bytes(data[12:16], "little")
            product_off = int.from_bytes(data[16:20], "little")

            def cstr(off):
                if off <= 0 or off >= len(data):
                    return ""
                end = data.find(b"\x00", off)
                if end < 0:
                    end = len(data)
                return data[off:end].decode("ascii", "ignore").strip()

            return " ".join(part for part in (cstr(vendor_off), cstr(product_off)) if part)
        except Exception:
            return ""

    # ------------------------------------------------------------------ I/O
    def read_at(self, offset: int, size: int) -> bytes:
        """Baca `size` byte pada offset absolut (harus kelipatan sector)."""
        if offset % self.sector_size or size % self.sector_size:
            raise ValueError(
                "Pembacaan raw tidak sejajar sector (offset=%d size=%d sector=%d)"
                % (offset, size, self.sector_size)
            )
        k32.SetFilePointerEx(self._handle, offset, None, 0)
        buf = ctypes.create_string_buffer(size)
        got = wintypes.DWORD(0)
        ok = k32.ReadFile(self._handle, buf, size, ctypes.byref(got), None)
        if not ok:
            raise RawDiskError(_last_error(), "Gagal membaca disk pada offset %d" % offset)
        return buf.raw[: got.value]

    def open_window(self, offset: int, length: int) -> "RawWindow":
        return RawWindow(self._handle, offset, length, self.sector_size, name=self.path)

    def close(self):
        if self._handle and self._handle != INVALID_HANDLE_VALUE:
            k32.CloseHandle(self._handle)
            self._handle = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class RawWindow:
    """Objek file-like read-only untuk sebuah partisi di dalam RawDisk.

    libfsapfs/libfshfs (via libbfio) memanggil seek/read; Windows mewajibkan
    setiap pembacaan raw disk sejajar dengan ukuran sector. Kelas ini menambah
    cache berjendela dan menyelaraskan sendiri semua pembacaan.
    """

    def __init__(self, handle, base_offset: int, length: int, sector_size: int, name: str = ""):
        self._handle = handle
        self._base = int(base_offset)
        self._length = int(length)
        self._sector = max(int(sector_size), 512)
        self._pos = 0
        self._cache_start = 0
        self._cache = b""
        self.name = name
        self.closed = False

    # ------------------------------------------------------------ alignment
    def _read_physical(self, offset: int, size: int) -> bytes:
        # offset & size sudah relatif terhadap window dan sejajar sector.
        k32.SetFilePointerEx(self._handle, self._base + offset, None, 0)
        buf = ctypes.create_string_buffer(size)
        got = wintypes.DWORD(0)
        ok = k32.ReadFile(self._handle, buf, size, ctypes.byref(got), None)
        if not ok:
            raise RawDiskError(
                _last_error(),
                "Gagal membaca partisi pada offset %d (ukuran %d)" % (offset, size),
            )
        if got.value < size:
            raise RawDiskError(0, "Pembacaan partisi terpotong (%d dari %d byte)" % (got.value, size))
        return buf.raw[: size]

    # ------------------------------------------------------------ file API
    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            size = self._length - self._pos
        size = min(int(size), self._length - self._pos)
        if size <= 0:
            return b""
        start = (self._pos // self._sector) * self._sector
        end = min(
            ((self._pos + size + self._sector - 1) // self._sector) * self._sector,
            self._length,
        )
        cache_end = self._cache_start + len(self._cache)
        if not (self._cache_start <= self._pos and self._pos + size <= cache_end):
            self._cache = self._read_physical(start, end - start)
            self._cache_start = start
        rel = self._pos - self._cache_start
        data = self._cache[rel : rel + size]
        self._pos += len(data)
        return data

    def seek(self, offset: int, whence: int = 0) -> int:
        if whence == 0:
            self._pos = int(offset)
        elif whence == 1:
            self._pos += int(offset)
        elif whence == 2:
            self._pos = self._length + int(offset)
        else:
            raise ValueError("whence tidak valid: %r" % (whence,))
        if self._pos < 0:
            raise OSError(22, "Seek ke posisi negatif")
        return self._pos

    def tell(self) -> int:
        return self._pos

    def get_offset(self) -> int:
        return self._pos

    def read_buffer_at_offset(self, size: int, offset: int) -> bytes:
        self.seek(offset)
        return self.read(size)

    def get_size(self) -> int:
        return self._length

    def close(self):
        # Handle dimiliki RawDisk; window hanya menandai dirinya tertutup.
        self.closed = True
        self._cache = b""


def list_volume_letters() -> list[str]:
    return list(string.ascii_uppercase)


def volume_extents(letter: str) -> list[tuple[int, int, int]]:
    """Kembalikan [(disk_number, starting_offset, extent_length)] untuk X:."""
    path = "\\\\.\\%s:" % letter
    handle = k32.CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, None, OPEN_EXISTING, 0, None)
    if not _check_handle(handle):
        return []
    try:
        buf = VOLUME_DISK_EXTENTS()
        ret = wintypes.DWORD(0)
        ok = k32.DeviceIoControl(
            handle,
            IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,
            None,
            0,
            ctypes.byref(buf),
            ctypes.sizeof(buf),
            ctypes.byref(ret),
            None,
        )
        if not ok:
            return []
        out = []
        for i in range(min(int(buf.NumberOfDiskExtents), 16)):
            ext = buf.Extents[i]
            out.append((int(ext.DiskNumber), int(ext.StartingOffset), int(ext.ExtentLength)))
        return out
    finally:
        k32.CloseHandle(handle)


def find_volume_letter(disk_number: int, start_offset: int, length: int) -> str | None:
    for letter in list_volume_letters():
        for disk, start, size in volume_extents(letter):
            if disk == disk_number and start == start_offset and size == length:
                return letter
    return None


def disk_number_for_path(path: str) -> int | None:
    drive, _ = __import__("os").path.splitdrive(__import__("os").path.abspath(path))
    if not drive:
        return None
    letter = drive.rstrip(":\\/").upper()
    if len(letter) != 1:
        return None
    extents = volume_extents(letter)
    if not extents:
        return None
    return extents[0][0]


def volume_info(letter: str) -> tuple[str, str]:
    """Kembalikan (label, nama_filesystem) untuk X:."""
    root = "%s:\\" % letter
    label = ctypes.create_unicode_buffer(261)
    fsname = ctypes.create_unicode_buffer(261)
    ok = k32.GetVolumeInformationW(
        root, label, 261, None, None, None, fsname, 261
    )
    if not ok:
        return "", ""
    return label.value, fsname.value


def list_physical_disks(max_disks: int = 32) -> list[int]:
    found = []
    for n in range(max_disks):
        path = "\\\\.\\PhysicalDrive%d" % n
        handle = k32.CreateFileW(
            path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, None, OPEN_EXISTING, 0, None
        )
        if _check_handle(handle):
            found.append(n)
            k32.CloseHandle(handle)
        else:
            # Jika errornya "access denied", disk ada tapi butuh admin.
            if _last_error() == ERROR_ACCESS_DENIED:
                found.append(n)
    return found


def open_physical_disk(number: int) -> RawDisk:
    return RawDisk("\\\\.\\PhysicalDrive%d" % number, number=number)