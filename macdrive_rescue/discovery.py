"""Deteksi drive Mac: pindai disk fisik, temukan partisi APFS/HFS+, buka volume.

Penting: handle RawDisk dan window partisi harus tetap hidup selama volume
dipakai (objek MacVolume membaca data on-demand dari disk). Karena itu
MacDrive menyimpan referensi disk+window dan menyediakan close().
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import fsmac, partition, rawdisk

try:
    import pyfsapfs
except ImportError:  # pragma: no cover
    pyfsapfs = None
try:
    import pyfshfs
except ImportError:  # pragma: no cover
    pyfshfs = None


@dataclass
class MacDrive:
    disk_number: int
    disk_model: str
    partition: partition.Partition
    fs_kind: str  # "APFS" | "HFS+"
    volume_name: str = ""
    mounted_letter: str | None = None
    container: object = field(default=None, repr=False)
    volume: object = field(default=None, repr=False)
    disk: object = field(default=None, repr=False)
    window: object = field(default=None, repr=False)
    error: str = ""

    @property
    def is_usable(self) -> bool:
        return self.volume is not None and not self.error

    @property
    def label(self) -> str:
        """Label ramah manusia: 'Macintosh HD 15 - Data (466 GB, drive F:)'."""
        size = self.partition.length / (1024 ** 3)
        name = self.volume_name or self.fs_kind
        extras = ["%.0f GB" % size]
        if self.mounted_letter:
            extras.append("drive %s:" % self.mounted_letter)
        label = "%s (%s)" % (name, ", ".join(extras))
        if self.error:
            label += " — %s" % self.error
        return label

    def close(self):
        if self.volume is not None:
            try:
                self.volume.close()
            except Exception:
                pass
            self.volume = None
        if self.container is not None:
            try:
                self.container.close()
            except Exception:
                pass
            self.container = None
        if self.window is not None:
            try:
                self.window.close()
            except Exception:
                pass
            self.window = None
        if self.disk is not None:
            try:
                self.disk.close()
            except Exception:
                pass
            self.disk = None


def _signature_check(window, fs_kind: str) -> bool:
    """Cek apakah partisi benar-benar berisi filesystem yang diklaim GPT."""
    try:
        if fs_kind == "APFS" and pyfsapfs is not None:
            window.seek(0)
            return bool(pyfsapfs.check_container_signature_file_object(window))
        if fs_kind == "HFS+" and pyfshfs is not None:
            window.seek(0)
            return bool(pyfshfs.check_volume_signature_file_object(window))
    except Exception:
        return False
    return False


def _make_handle_drive(disk_number: int, model: str, part: partition.Partition,
                       fs_kind: str) -> MacDrive:
    """Buka disk + window baru untuk satu volume (mandiri, tanpa share)."""
    drive = MacDrive(
        disk_number=disk_number,
        disk_model=model,
        partition=part,
        fs_kind=fs_kind,
        mounted_letter=rawdisk.find_volume_letter(disk_number, part.start, part.length),
    )
    try:
        disk = rawdisk.open_physical_disk(disk_number)
        drive.disk = disk
        drive.window = disk.open_window(part.start, part.length)
    except OSError as exc:
        drive.error = "gagal membuka disk: %s" % exc
        return drive
    if not _signature_check(drive.window, fs_kind):
        drive.error = "isi partisi bukan %s (signature tidak cocok)" % fs_kind
        drive.close()
        return drive
    return drive


def _open_apfs_volumes(disk_number: int, model: str, part: partition.Partition) -> list[MacDrive]:
    """Buka container APFS dan buat satu MacDrive per volume logis."""
    # Sesi probe: hanya untuk membaca daftar volume.
    probe = _make_handle_drive(disk_number, model, part, "APFS")
    if probe.error:
        return [probe]
    try:
        probe_container = fsmac.open_apfs_window(probe.window)
    except Exception as exc:
        probe.error = "gagal membuka container APFS: %s" % exc
        probe.close()
        return [probe]

    count = probe_container.get_number_of_volumes()
    names: list[tuple[int, str, bool]] = []
    for i in range(count):
        try:
            vol = probe_container.volume_at(i)
        except Exception as exc:
            names.append((i, "Volume %d (gagal: %s)" % (i, exc), True))
            continue
        locked = isinstance(vol, fsmac.LockedVolume)
        names.append((i, vol.display_name, locked))
        try:
            vol.close()
        except Exception:
            pass
    probe.close()

    if not names:
        return [
            MacDrive(
                disk_number=disk_number,
                disk_model=model,
                partition=part,
                fs_kind="APFS",
                error="tidak ada volume di dalam container",
            )
        ]

    drives: list[MacDrive] = []
    for index, name, locked in names:
        d = MacDrive(
            disk_number=disk_number,
            disk_model=model,
            partition=part,
            fs_kind="APFS",
            volume_name=name,
            mounted_letter=rawdisk.find_volume_letter(disk_number, part.start, part.length),
        )
        if locked:
            d.error = "terkunci atau tidak bisa dibaca"
            drives.append(d)
            continue
        # Stack independen per volume.
        try:
            d.disk = rawdisk.open_physical_disk(disk_number)
            d.window = d.disk.open_window(part.start, part.length)
            d.container = fsmac.open_apfs_window(d.window)
            vol = d.container.volume_at(index)
            if isinstance(vol, fsmac.LockedVolume):
                d.error = "terkunci"
                d.close()
            else:
                d.volume = vol
        except Exception as exc:
            d.error = "gagal membuka volume: %s" % exc
            d.close()
        drives.append(d)

    return drives


def _open_hfs_volume(disk_number: int, model: str, part: partition.Partition) -> MacDrive:
    drive = _make_handle_drive(disk_number, model, part, "HFS+")
    if drive.error:
        return drive
    try:
        drive.volume = fsmac.open_hfs_window(drive.window)
        drive.volume_name = drive.volume.display_name
    except Exception as exc:
        drive.error = "gagal membuka volume HFS+: %s" % exc
        drive.close()
    return drive


def scan_mac_drives() -> list[MacDrive]:
    """Telusuri semua disk fisik, kembalikan daftar volume Mac yang bisa dibuka.

    Setiap MacDrive memiliki handle disk terbuka; panggil close() bila selesai.
    """
    if not rawdisk.is_admin():
        raise PermissionError(
            "Aplikasi harus dijalankan sebagai Administrator untuk membaca disk secara langsung."
        )
    results: list[MacDrive] = []

    for disk_number in rawdisk.list_physical_disks():
        try:
            probe = rawdisk.open_physical_disk(disk_number)
        except OSError:
            continue
        try:
            model = probe.model_name()
            parts = partition.read_partitions(probe, disk_number)
        except Exception:
            continue
        finally:
            probe.close()

        for part in partition.mac_partitions(parts):
            if part.kind == "APFS":
                results.extend(_open_apfs_volumes(disk_number, model, part))
            elif part.kind == "HFS+":
                results.append(_open_hfs_volume(disk_number, model, part))

    # Volume "Data" (berisi data pengguna) tampil lebih dulu.
    def sort_key(d: MacDrive):
        name = (d.volume_name or "").lower()
        priority = 0 if "data" in name else (1 if d.is_usable else 2)
        return (priority, name)

    results.sort(key=sort_key)
    return results