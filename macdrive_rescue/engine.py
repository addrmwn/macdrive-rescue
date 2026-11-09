"""Engine transfer data dari volume Mac ke Windows.

Alur:
1. `scan()` menelusuri volume sumber, menerapkan filter nama sistem Mac,
   menyanitasi nama untuk NTFS, dan membangun daftar tugas (file + folder).
2. `copy()` menyalin setiap file (chunked), opsional menghitung hash dan
   memverifikasi hasil salinan, lalu menerapkan timestamp asli.
"""

from __future__ import annotations

import csv
import hashlib
import os
import threading
import time
from dataclasses import dataclass, field
from typing import Callable

from . import names
from .fsmac import Entry, MacVolume
from .util import free_space, long_path, set_file_times

# File/folder metadata khas macOS yang biasanya tidak perlu disalin.
SYSTEM_NAMES = {
    ".DS_Store",
    "._.DS_Store",
    ".Spotlight-V100",
    ".Trashes",
    ".fseventsd",
    ".TemporaryItems",
    ".DocumentRevisions-V100",
    ".VolumeIcon.icns",
    ".AppleDB",
    ".AppleDesktop",
    ".apdisk",
    "$RECYCLE.BIN",
    "System Volume Information",
    ".com.apple.timemachine.donotpresent",
}

# Folder rumah macOS yang biasanya berisi sampah/duplikat sistem.
SYSTEM_DIRS = {
    ".Trash",
    ".Trashes",
    "Caches",
}

# Folder artefak build/cache yang tidak perlu ikut tersalin (opsional).
BUILD_DIR_NAMES = {
    "build",
    "node_modules",
    ".dart_tool",
    "pods",
    "deriveddata",
    ".gradle",
    "__pycache__",
    ".next",
}

CHUNK_SIZE = 4 * 1024 * 1024  # 4 MB


@dataclass
class Options:
    skip_system: bool = True
    skip_hidden: bool = False          # lewati semua nama berawalan titik
    overwrite: str = "skip"            # skip | overwrite | rename
    verify: bool = True                # verifikasi hash setelah menyalin
    preserve_times: bool = True
    symlinks: str = "skip"             # skip | follow | as_target
    colon_replacement: str = "-"
    dry_run: bool = False
    skip_app_bundles: bool = False     # lewati paket .app/.framework (Library/Applications)
    skip_build_dirs: bool = False      # lewati folder build/cache (build, node_modules, ...)


@dataclass
class FileTask:
    src: Entry
    rel_parts: tuple[str, ...]         # komponen nama asli (Mac)
    dest_parts: tuple[str, ...]        # komponen nama hasil sanitasi
    size: int

    @property
    def rel_display(self) -> str:
        return "/".join(self.rel_parts)


@dataclass
class DirTask:
    src: Entry
    rel_parts: tuple[str, ...]
    dest_parts: tuple[str, ...]


@dataclass
class ScanResult:
    files: list[FileTask] = field(default_factory=list)
    dirs: list[DirTask] = field(default_factory=list)
    total_bytes: int = 0
    skipped_files: int = 0
    skipped_dirs: int = 0
    unreadable: list[str] = field(default_factory=list)
    cancelled: bool = False


@dataclass
class CopyStats:
    files_copied: int = 0
    files_skipped: int = 0
    files_failed: int = 0
    bytes_copied: int = 0
    verify_failed: int = 0
    started_at: float = 0.0
    ended_at: float = 0.0
    cancelled: bool = False
    errors: list[tuple[str, str]] = field(default_factory=list)  # (rel, pesan)
    manifest: list[tuple[str, str, int, str, str]] = field(default_factory=list)


def _should_skip(name: str, is_dir: bool, opts: Options, rel_parts: tuple[str, ...]) -> bool:
    if opts.skip_system:
        if name in SYSTEM_NAMES:
            return True
        if name.startswith("._"):
            return True
        if is_dir and name in SYSTEM_DIRS:
            return True
    if opts.skip_hidden and name.startswith("."):
        return True
    if opts.skip_app_bundles and is_dir and name.endswith((".app", ".framework", ".bundle")):
        return True
    if opts.skip_build_dirs and is_dir and name.lower() in BUILD_DIR_NAMES:
        return True
    return False


class Scanner:
    def __init__(self, volume: MacVolume, opts: Options,
                 on_progress: Callable[[str, int, int], None] | None = None,
                 cancel: threading.Event | None = None):
        self.volume = volume
        self.opts = opts
        self.on_progress = on_progress
        self.cancel = cancel or threading.Event()

    def scan(self, start: Entry | None = None) -> ScanResult:
        """Pindai `start` (default: root volume).

        Bila `start` adalah sebuah folder di dalam volume, folder itu sendiri
        menjadi root di tujuan — memilih LocalMesh menghasilkan
        <tujuan>/LocalMesh/... (bukan <tujuan>/Users/nama/Documents/LocalMesh).
        Bila `start` adalah root volume, isi volume disalin langsung ke tujuan.
        """
        result = ScanResult()
        root = start or self.volume.root
        if not root.is_dir:
            comp = names.sanitize_component(
                root.name, colon_replacement=self.opts.colon_replacement
            )
            result.files.append(FileTask(root, (root.name,), (comp,), root.size))
            result.total_bytes += root.size
            return result

        if start is None or self.volume.is_root(root):
            self._walk(root, (), (), result)
        else:
            safe = names.sanitize_component(
                root.name, colon_replacement=self.opts.colon_replacement
            )
            result.dirs.append(DirTask(root, (root.name,), (safe,)))
            self._walk(root, (root.name,), (safe,), result)
        return result

    def _walk(self, entry: Entry, rel: tuple[str, ...], dest: tuple[str, ...],
              result: ScanResult) -> None:
        if self.cancel.is_set():
            result.cancelled = True
            return
        try:
            children = self.volume.list_dir(entry)
        except Exception as exc:
            result.unreadable.append("%s (%s)" % ("/".join(rel) or "/", exc))
            return

        taken: set[str] = set()
        for child in children:
            if self.cancel.is_set():
                result.cancelled = True
                return
            if _should_skip(child.name, child.is_dir, self.opts, rel):
                if child.is_dir:
                    result.skipped_dirs += 1
                else:
                    result.skipped_files += 1
                continue

            if child.name.startswith("._"):
                # AppleDouble metadata, selalu lewati (tidak berguna di Windows).
                result.skipped_files += 1
                continue

            safe = names.sanitize_component(
                child.name, colon_replacement=self.opts.colon_replacement
            )
            unique = names.unique_name(safe, taken)

            child_rel = rel + (child.name,)
            child_dest = dest + (unique,)

            if child.is_symlink and self.opts.symlinks == "skip":
                continue

            if child.is_dir:
                result.dirs.append(DirTask(child, child_rel, child_dest))
                self._walk(child, child_rel, child_dest, result)
            else:
                result.files.append(FileTask(child, child_rel, child_dest, child.size))
                result.total_bytes += child.size

            if self.on_progress and (len(result.files) % 250 == 0):
                self.on_progress("scan", len(result.files), result.total_bytes)


class Copier:
    def __init__(self, volume: MacVolume, dest_root: str, opts: Options,
                 on_file: Callable[[dict], None] | None = None,
                 cancel: threading.Event | None = None):
        self.volume = volume
        self.dest_root = os.path.abspath(dest_root)
        self.opts = opts
        self.on_file = on_file
        self.cancel = cancel or threading.Event()
        self.stats = CopyStats()

    # ------------------------------------------------------------------ util
    def _dest_path(self, parts: tuple[str, ...]) -> str:
        return os.path.join(self.dest_root, *parts)

    def _emit(self, **payload):
        if self.on_file:
            self.on_file(payload)

    def _handle_existing(self, dest_path: str, task: FileTask) -> str:
        """Tentukan aksi: 'copy', 'skip', atau path alternatif (mode rename)."""
        if not os.path.exists(long_path(dest_path)):
            return "copy"
        if self.opts.overwrite == "overwrite":
            return "copy"
        if self.opts.overwrite == "rename":
            parent = os.path.dirname(dest_path)
            stem, dot, ext = task.dest_parts[-1].rpartition(".")
            base_stem, base_ext = (stem, "." + ext) if dot else (task.dest_parts[-1], "")
            n = 2
            while True:
                candidate = os.path.join(parent, "%s (%d)%s" % (base_stem, n, base_ext))
                if not os.path.exists(long_path(candidate)):
                    return candidate
                n += 1
        return "skip"

    # ------------------------------------------------------------------ copy
    def run(self, scan: ScanResult) -> CopyStats:
        start_t = time.time()
        self.stats = CopyStats(started_at=start_t)
        dest_norm = self.dest_root

        # Validasi ruang disk.
        free = free_space(dest_norm)
        if free >= 0 and scan.total_bytes > free and not self.opts.dry_run:
            raise RuntimeError(
                "Ruang disk tujuan tidak cukup: butuh %s, tersedia %s."
                % (_fmt_bytes(scan.total_bytes), _fmt_bytes(free))
            )

        os.makedirs(long_path(dest_norm), exist_ok=True)

        created_dirs: list[tuple[str, DirTask]] = []
        for d in scan.dirs:
            if self.cancel.is_set():
                self.stats.cancelled = True
                break
            path = self._dest_path(d.dest_parts)
            try:
                if not self.opts.dry_run:
                    os.makedirs(long_path(path), exist_ok=True)
                created_dirs.append((path, d))
            except OSError as exc:
                self.stats.files_failed += 1
                self.stats.errors.append(("/".join(d.rel_parts), "folder: %s" % exc))

        total = len(scan.files)
        for index, task in enumerate(scan.files, 1):
            if self.cancel.is_set():
                self.stats.cancelled = True
                break
            dest_path = self._dest_path(task.dest_parts)
            action = self._handle_existing(dest_path, task)
            if action == "skip":
                self.stats.files_skipped += 1
                self._emit(kind="file", rel=task.rel_display, status="skip",
                           size=task.size, index=index, total=total)
                continue

            target = dest_path if action == "copy" else action
            os.makedirs(long_path(os.path.dirname(target)), exist_ok=True)

            if self.opts.dry_run:
                self.stats.files_copied += 1
                self.stats.bytes_copied += task.size
                self._emit(kind="file", rel=task.rel_display, status="dry",
                           size=task.size, index=index, total=total)
                continue

            try:
                digest = self._copy_one(task, target)
                self.stats.files_copied += 1
                self.stats.bytes_copied += task.size

                if self.opts.verify and digest:
                    ok = self._verify(target, digest, task.size)
                    if not ok:
                        self.stats.verify_failed += 1
                        self.stats.errors.append((task.rel_display, "hash verifikasi tidak cocok"))
                        self._emit(kind="file", rel=task.rel_display, status="verify_fail",
                                   size=task.size, index=index, total=total)
                        continue

                if self.opts.preserve_times:
                    try:
                        if task.src.is_dir:
                            pass
                        else:
                            set_file_times(
                                target,
                                task.src.mtime_ns,
                                task.src.atime_ns,
                                task.src.ctime_ns,
                                is_dir=False,
                            )
                    except OSError as exc:
                        self.stats.errors.append((task.rel_display, "timestamp: %s" % exc))

                self.stats.manifest.append(
                    (
                        task.rel_display,
                        target,
                        task.size,
                        "%016x" % (digest or 0),
                        "ok",
                    )
                )
                self._emit(kind="file", rel=task.rel_display, status="ok",
                           size=task.size, index=index, total=total)
            except Exception as exc:
                self.stats.files_failed += 1
                self.stats.errors.append((task.rel_display, str(exc)))
                self._emit(kind="file", rel=task.rel_display, status="error",
                           size=task.size, index=index, total=total, error=str(exc))

        # Terapkan timestamp folder (setelah isi selesai) dari yang terdalam.
        if self.opts.preserve_times and not self.opts.dry_run:
            for path, d in reversed(created_dirs):
                try:
                    set_file_times(
                        path,
                        d.src.mtime_ns,
                        d.src.atime_ns,
                        d.src.ctime_ns,
                        is_dir=True,
                    )
                except OSError:
                    pass

        self.stats.ended_at = time.time()
        return self.stats

    def _copy_one(self, task: FileTask, dest_path: str) -> int | None:
        hasher = hashlib.blake2b() if self.opts.verify else None
        obj = self.volume.open_file(task.src)
        obj.seek(0)
        remaining = task.size
        tmp_path = long_path(dest_path)
        with open(tmp_path, "wb", buffering=CHUNK_SIZE) as out:
            while remaining > 0:
                if self.cancel.is_set():
                    raise InterruptedError("Salinan dibatalkan")
                chunk = obj.read(size=min(CHUNK_SIZE, remaining))
                if not chunk:
                    raise IOError(
                        "Data sumber berakhir lebih awal (%d byte tersisa)" % remaining
                    )
                out.write(chunk)
                remaining -= len(chunk)
                if hasher is not None:
                    hasher.update(chunk)
                self._emit(kind="progress", rel=task.rel_display,
                           bytes=len(chunk), file_size=task.size)
        if hasher is None:
            return None
        return int.from_bytes(hasher.digest()[:8], "big")

    def _verify(self, dest_path: str, expected: int, size: int) -> bool:
        hasher = hashlib.blake2b()
        with open(long_path(dest_path), "rb", buffering=CHUNK_SIZE) as f:
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                hasher.update(chunk)
        return int.from_bytes(hasher.digest()[:8], "big") == expected


def _fmt_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024.0 or unit == "TB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0
    return "%.1f TB" % n


def write_manifest(path: str, stats: CopyStats) -> None:
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f)
        writer.writerow(["sumber", "tujuan", "ukuran_byte", "hash_blake2b", "status"])
        for row in stats.manifest:
            writer.writerow(row)


def write_error_report(path: str, stats: CopyStats) -> None:
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f)
        writer.writerow(["path", "kesalahan"])
        for rel, msg in stats.errors:
            writer.writerow([rel, msg])