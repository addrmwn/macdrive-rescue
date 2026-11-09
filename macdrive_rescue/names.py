"""Sanitasi nama file/folder dari macOS agar valid di Windows (NTFS).

Aturan utama:
- Karakter yang dilarang NTFS: < > : " / \\ | ? * serta karakter kontrol 0-31.
- macOS mengizinkan ':' di nama file (Finder menampilkannya sebagai '/').
  Strategi default: ganti ':' menjadi '-' agar tidak tertukar dengan pemisah path.
- Nama tidak boleh berakhir dengan spasi atau titik.
- Nama perangkat cadangan (CON, PRN, AUX, NUL, COM1-9, LPT1-9) tidak boleh dipakai.
- Batas nama per komponen: 255 karakter UTF-16.
- Tabrakan nama setelah sanitasi ditangani dengan memberi akhiran " (2)", " (3)", dst.
"""

from __future__ import annotations

import re
import unicodedata

ILLEGAL_CHARS = '<>:"/\\|?*'
CONTROL_CHARS = "".join(chr(c) for c in range(32))
RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}
# Windows melarang nama yang berakhir dengan titik/spasi.
MAX_COMPONENT_LEN = 255

_CHAR_MAP = {
    ":": "-",  # paling umum dari macOS
    "<": "_",
    ">": "_",
    '"': "_",
    "/": "_",  # tidak seharusnya muncul, pertahanan berlapis
    "\\": "_",
    "|": "_",
    "?": "_",
    "*": "_",
}


def sanitize_component(
    name: str,
    *,
    colon_replacement: str = "-",
    replace_illegal: bool = True,
    max_len: int = MAX_COMPONENT_LEN,
) -> str:
    """Bersihkan satu komponen nama (bukan path penuh)."""
    if not name:
        return "_"

    # Normalisasi Unicode (HFS+ menyimpan nama sebagai NFD).
    try:
        name = unicodedata.normalize("NFC", name)
    except Exception:
        pass

    if replace_illegal:
        out = []
        for ch in name:
            if ch == ":":
                out.append(colon_replacement)
            elif ch in ILLEGAL_CHARS or ch in CONTROL_CHARS:
                out.append(_CHAR_MAP.get(ch, "_"))
            else:
                out.append(ch)
        name = "".join(out)
    else:
        name = "".join("_" if ch in CONTROL_CHARS else ch for ch in name)

    # Hapus titik/spasi di ujung (Windows tidak bisa membuatnya).
    name = name.rstrip(" .")
    if not name:
        name = "_"

    # Nama perangkat cadangan: beri akhiran garis bawah.
    base = name.split(".")[0].upper()
    if base in RESERVED_NAMES:
        name = "_" + name

    # Batasi panjang komponen dengan tetap mempertahankan ekstensi.
    if len(name) > max_len:
        stem, dot, ext = name.rpartition(".")
        if dot and len(ext) <= 16:
            keep = max_len - len(ext) - 1
            name = stem[:keep] + "." + ext
        else:
            name = name[:max_len]

    return name


def unique_name(candidate: str, taken_lower: set[str]) -> str:
    """Pastikan unik (case-insensitive ala Windows). Mengembalikan nama final."""
    if candidate.lower() not in taken_lower:
        taken_lower.add(candidate.lower())
        return candidate

    stem, dot, ext = candidate.rpartition(".")
    if not dot:
        stem, ext = candidate, ""
    n = 2
    while True:
        suffix = " (%d)" % n
        if ext:
            test = stem[: MAX_COMPONENT_LEN - len(suffix) - len(ext) - 1] + suffix + "." + ext
        else:
            test = stem[: MAX_COMPONENT_LEN - len(suffix)] + suffix
        if test.lower() not in taken_lower:
            taken_lower.add(test.lower())
            return test
        n += 1