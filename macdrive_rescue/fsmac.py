"""Adapter filesystem Mac (APFS & HFS+) di atas raw disk.

Menyediakan antarmuka seragam untuk menjelajah dan membaca file dari volume
APFS (lewat libfsapfs/pyfsapfs) maupun HFS+ (lewat libfshfs/pyfshfs).
"""

from __future__ import annotations

import stat
from dataclasses import dataclass, field

from . import rawdisk
from .util import detect_unix_ns

try:
    import pyfsapfs
except ImportError:  # pragma: no cover
    pyfsapfs = None

try:
    import pyfshfs
except ImportError:  # pragma: no cover
    pyfshfs = None


@dataclass
class Entry:
    name: str
    is_dir: bool
    is_symlink: bool
    size: int
    mtime_ns: int | None
    atime_ns: int | None
    ctime_ns: int | None  # created
    link_target: str | None = None
    raw: object = field(default=None, repr=False)


class MacVolumeError(Exception):
    pass


class MacVolume:
    """Sebuah volume logis Mac (satu filesystem di dalam container/partisi)."""

    def __init__(self, fs_name, volume, display_name: str):
        self.fs_name = fs_name
        self._volume = volume
        self.display_name = display_name
        self._root = volume.get_root_directory()
        if self._root is None:
            raise MacVolumeError(
                "Direktori root volume '%s' tidak bisa dibaca (mungkin volume sistem "
                "yang di-seal atau terenkripsi)." % display_name
            )

    # ------------------------------------------------------------- metadata
    @property
    def root(self) -> Entry:
        return self._entry_from(self._root)

    def _entry_from(self, obj) -> Entry:
        mode = obj.get_file_mode()
        is_dir = stat.S_ISDIR(mode)
        is_link = stat.S_ISLNK(mode)
        name = obj.get_name() or ""
        link_target = None
        if is_link:
            try:
                link_target = obj.get_symbolic_link_target()
            except Exception:
                link_target = None
        size = obj.get_size() or 0
        hint = "apfs_ns" if self.fs_name == "APFS" else "hfs_seconds"
        mtime = detect_unix_ns(obj.get_modification_time_as_integer(), hint)
        try:
            atime = detect_unix_ns(obj.get_access_time_as_integer(), hint)
        except Exception:
            atime = None
        try:
            ctime = detect_unix_ns(obj.get_creation_time_as_integer(), hint)
        except Exception:
            ctime = None
        return Entry(
            name=name,
            is_dir=is_dir,
            is_symlink=is_link,
            size=int(size),
            mtime_ns=mtime,
            atime_ns=atime,
            ctime_ns=ctime,
            link_target=link_target,
            raw=obj,
        )

    # ------------------------------------------------------------- browsing
    def is_root(self, entry: Entry) -> bool:
        """True bila entry adalah direktori root volume ini."""
        try:
            return entry.raw.get_identifier() == self._root.get_identifier()
        except Exception:
            return False

    def list_dir(self, entry: Entry) -> list[Entry]:
        obj = entry.raw
        out = []
        count = obj.get_number_of_sub_file_entries()
        for i in range(count):
            try:
                child = obj.get_sub_file_entry(i)
            except Exception:
                continue
            out.append(self._entry_from(child))
        return out

    def open_file(self, entry: Entry):
        return entry.raw

    def close(self):
        for closer in ("close",):
            fn = getattr(self._volume, closer, None)
            if callable(fn):
                try:
                    fn()
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# APFS
# ---------------------------------------------------------------------------

class ApfsContainer:
    def __init__(self, raw_window, password: str | None = None):
        if pyfsapfs is None:
            raise MacVolumeError("Library pyfsapfs tidak tersedia.")
        self._window = raw_window
        self._password = password
        try:
            self._container = pyfsapfs.open_file_object(raw_window, mode="r")
        except OSError as exc:
            raise MacVolumeError("Bukan container APFS yang valid atau rusak: %s" % exc)

    def get_number_of_volumes(self) -> int:
        return int(self._container.get_number_of_volumes())

    def volume_at(self, index: int):
        """Kembalikan MacVolume, LockedVolume, atau raise MacVolumeError."""
        try:
            vol = self._container.get_volume(index)
        except Exception as exc:
            raise MacVolumeError("Gagal membuka volume #%d: %s" % (index, exc))
        name = vol.get_name() or ("Volume %d" % index)
        if vol.is_locked():
            if not self._password:
                return LockedVolume(name, index, self)
            try:
                vol.set_password(self._password)
                if not vol.unlock():
                    return LockedVolume(name, index, self)
            except Exception:
                return LockedVolume(name, index, self)
        return MacVolume("APFS", vol, name)

    def volumes(self) -> list[MacVolume]:
        out = []
        for i in range(self.get_number_of_volumes()):
            try:
                out.append(self.volume_at(i))
            except MacVolumeError:
                continue
        return out

    def close(self):
        try:
            self._container.close()
        except Exception:
            pass


class LockedVolume:
    """Volume terenkripsi yang belum bisa dibuka (placeholder)."""

    fs_name = "APFS (terkunci)"
    is_locked = True

    def __init__(self, name: str, index: int, container: ApfsContainer):
        self.display_name = name
        self.index = index
        self._container = container

    def volumes(self):  # pragma: no cover - untuk antarmuka seragam
        return []


# ---------------------------------------------------------------------------
# HFS+
# ---------------------------------------------------------------------------

class HfsVolume(MacVolume):
    pass


def open_apfs_window(window) -> ApfsContainer:
    """Buka container APFS dari objek window yang sudah ada."""
    return ApfsContainer(window)


def open_hfs_window(window, password: str | None = None) -> MacVolume:
    """Buka volume HFS+ dari objek window yang sudah ada."""
    if pyfshfs is None:
        raise MacVolumeError("Library pyfshfs tidak tersedia.")
    try:
        volume = pyfshfs.open_file_object(window, mode="r")
    except OSError as exc:
        raise MacVolumeError("Bukan volume HFS+ yang valid atau rusak: %s" % exc)
    if password:
        try:
            volume.set_password(password)
            volume.unlock()
        except Exception:
            pass
    try:
        name = volume.get_name() or "HFS+ Volume"
    except Exception:
        name = "HFS+ Volume"
    return MacVolume("HFS+", volume, name)


def open_apfs(disk, partition_) -> ApfsContainer:
    window = disk.open_window(partition_.start, partition_.length)
    return ApfsContainer(window)


def open_hfs(disk, partition_, password: str | None = None) -> MacVolume:
    window = disk.open_window(partition_.start, partition_.length)
    return open_hfs_window(window, password)