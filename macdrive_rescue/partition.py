"""Parser tabel partisi GPT/MBR sederhana (read-only) di atas RawDisk."""

from __future__ import annotations

import struct
import uuid
from dataclasses import dataclass

# APFS: 7C3457EF-0000-11AA-AA11-00306543ECAC
APFS_TYPE_GUID = uuid.UUID("7c3457ef-0000-11aa-aa11-00306543ecac")
# HFS+: 48465300-0000-11AA-AA11-00306543ECAC (Apple HFS)
HFS_TYPE_GUID = uuid.UUID("48465300-0000-11aa-aa11-00306543ecac")
# Apple Boot (Recovery HD): 426F6F74-0000-11AA-AA11-00306543ECAC
APPLE_BOOT_GUID = uuid.UUID("426f6f74-0000-11aa-aa11-00306543ecac")
# Apple APFS container
APPLE_APFS_GUID = APFS_TYPE_GUID


def guid_from_bytes(raw: bytes) -> uuid.UUID:
    # GUID GPT disimpan dalam format little-endian untuk 3 field pertama.
    return uuid.UUID(bytes_le=raw)


@dataclass
class Partition:
    index: int
    disk_number: int
    start: int  # byte offset on disk
    length: int  # bytes
    type_guid: uuid.UUID | None
    name: str
    scheme: str  # "GPT" | "MBR"

    @property
    def kind(self) -> str:
        if self.type_guid == APFS_TYPE_GUID:
            return "APFS"
        if self.type_guid == HFS_TYPE_GUID:
            return "HFS+"
        if self.type_guid == APPLE_BOOT_GUID:
            return "Apple Boot"
        return "unknown"

    def describe(self) -> str:
        size_gb = self.length / (1024 ** 3)
        return "Disk %d, Partisi %d (%s, %.2f GB)%s" % (
            self.disk_number,
            self.index,
            self.kind,
            size_gb,
            " - %s" % self.name if self.name else "",
        )


def _read_exact(disk, offset: int, size: int) -> bytes:
    sector = disk.sector_size
    aligned_start = (offset // sector) * sector
    aligned_end = ((offset + size + sector - 1) // sector) * sector
    data = disk.read_at(aligned_start, aligned_end - aligned_start)
    rel = offset - aligned_start
    return data[rel : rel + size]


def read_gpt(disk, disk_number: int) -> list[Partition]:
    header = _read_exact(disk, disk.sector_size, 92)
    if header[:8] != b"EFI PART":
        return []
    (entries_lba,) = struct.unpack_from("<Q", header, 72)
    (num_entries,) = struct.unpack_from("<I", header, 80)
    (entry_size,) = struct.unpack_from("<I", header, 84)
    if num_entries <= 0 or num_entries > 1024 or entry_size < 128 or entry_size > 4096:
        return []
    raw = _read_exact(disk, entries_lba * disk.sector_size, num_entries * entry_size)
    parts = []
    for i in range(num_entries):
        entry = raw[i * entry_size : (i + 1) * entry_size]
        if entry[:16] == b"\x00" * 16:
            continue
        type_guid = guid_from_bytes(entry[:16])
        (first_lba, last_lba) = struct.unpack_from("<QQ", entry, 32)
        if last_lba < first_lba:
            continue
        name = entry[56:128].decode("utf-16-le", "ignore").split("\x00", 1)[0]
        parts.append(
            Partition(
                index=i + 1,
                disk_number=disk_number,
                start=first_lba * disk.sector_size,
                length=(last_lba - first_lba + 1) * disk.sector_size,
                type_guid=type_guid,
                name=name,
                scheme="GPT",
            )
        )
    return parts


MBR_TYPES = {
    0xAF: "HFS+",
    0xA8: "APFS",  # Apple APFS (beberapa skema)
}


def read_mbr(disk, disk_number: int) -> list[Partition]:
    mbr = _read_exact(disk, 0, 512)
    if mbr[510:512] != b"\x55\xaa":
        return []
    parts = []
    for i in range(4):
        base = 446 + i * 16
        ptype = mbr[base + 4]
        if ptype == 0:
            continue
        (lba_start,) = struct.unpack_from("<I", mbr, base + 8)
        (sectors,) = struct.unpack_from("<I", mbr, base + 12)
        if lba_start == 0 or sectors == 0:
            continue
        kind_label = MBR_TYPES.get(ptype, "unknown")
        type_guid = APFS_TYPE_GUID if kind_label == "APFS" else (
            HFS_TYPE_GUID if kind_label == "HFS+" else None
        )
        parts.append(
            Partition(
                index=i + 1,
                disk_number=disk_number,
                start=lba_start * disk.sector_size,
                length=sectors * disk.sector_size,
                type_guid=type_guid,
                name="",
                scheme="MBR",
            )
        )
    return parts


def read_partitions(disk, disk_number: int) -> list[Partition]:
    parts = read_gpt(disk, disk_number)
    if parts:
        return parts
    return read_mbr(disk, disk_number)


APPLE_TYPES = {APFS_TYPE_GUID, HFS_TYPE_GUID}


def mac_partitions(parts: list[Partition]) -> list[Partition]:
    return [p for p in parts if p.type_guid in APPLE_TYPES]