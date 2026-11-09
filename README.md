# MacDrive Rescue

Aplikasi Windows untuk **menyalin data dari drive Mac (APFS & HFS+) ke Windows** — tanpa memerlukan lisensi MacDrive.

Dibangun dengan **Flutter** dan **Dart FFI** ke library native C (libfsapfs, libfshfs). Aplikasi membaca disk fisik secara langsung (*raw*, read-only), sehingga tetap bekerja meskipun driver MacDrive trial sudah kedaluwarsa, rusak, atau tidak terpasang sama sekali.

> Kasus umum: MacDrive terpasang tetapi trial habis — Windows hanya bisa "melihat" nama folder di drive Mac, tetapi **gagal membuka/menyalin file** (error `A device attached to the system is not functioning` / WinError 31 / Permission denied). Aplikasi ini melewati driver tersebut sepenuhnya.

## Cara kerja

```
┌─────────────────┐     FFI      ┌──────────────┐    raw I/O    ┌────────────┐
│  Flutter UI     │ ──────────▶  │  macfs.dll   │ ───────────▶  │ Physical   │
│  (Dart)         │              │  (C native)  │               │ DriveN     │
└─────────────────┘              └──────────────┘               └────────────┘
                                        │
                          ┌─────────────┴─────────────┐
                          │ libfsapfs  │  libfshfs    │
                          │  (APFS)    │  (HFS+)      │
                          └────────────┴──────────────┘
```

- **`macfs.dll`** — bridge C yang menautkan libfsapfs/libfshfs secara statis, ditambah akses raw disk Windows dan parser GPT/MBR.
- **Flutter UI** berkomunikasi dengan DLL melalui `dart:ffi`.
- Semua operasi berat (scan & copy) berjalan di **isolate terpisah** agar UI tetap responsif.

## Fitur

- Deteksi otomatis semua volume APFS/HFS+ di seluruh disk fisik (termasuk semua volume logis dalam container APFS).
- **Folder yang dipilih menjadi root tujuan** — memilih `LocalMesh` menghasilkan `<tujuan>\LocalMesh\...`, tanpa rantai path `Users\adidarmawan\Documents\...`.
- **Sanitasi nama file** khas Mac untuk NTFS:
  - `:` → `-` (bisa diubah ke `_` atau `：`)
  - Karakter terlarang `< > " | ? *` → `_`
  - Nama berakhir titik/spasi dan nama perangkat cadangan (CON, NUL, COM1, …) ditangani
  - Tabrakan nama otomatis diberi akhiran ` (2)`, ` (3)`, …
  - Normalisasi Unicode NFD → NFC
- **Path panjang** (> 260 karakter) didukung.
- **Pertahankan tanggal** file (modifikasi, akses, pembuatan) via Win32 `SetFileTime`.
- Filter file sistem Mac (`.DS_Store`, `._*`, `.Trashes`, …) dan folder build/cache (`build`, `node_modules`, `.dart_tool`, …).
- Opsi symlink: lewati atau ikuti target.
- Mode jika file sudah ada: lewati / timpa / ganti nama.
- Mode **simulasi** (dry-run).
- Progress bar dengan kecepatan dan estimasi waktu, log real-time berwarna.
- **Laporan CSV** (manifest + daftar error) otomatis di subfolder `_laporan`.
- **Auto-elevasi UAC** — aplikasi meminta hak Administrator saat dijalankan (wajib untuk akses raw disk).

## Persyaratan

- Windows 10/11 (64-bit)
- Hak **Administrator** (wajib)
- Drive Mac terpasang (SATA/NVMe internal atau USB enclosure)

## Cara pakai

1. Unduh `MacDriveRescue-win64.zip` dari [halaman Releases](https://github.com/addrmwn/macdrive-rescue/releases).
2. Ekstrak ke folder mana pun, jalankan `macdrive_rescue.exe` (klik **Yes** pada prompt UAC).
3. Pilih volume Mac pada dropdown (volume `… - Data` biasanya berisi data pengguna).
4. Klik **Pilih Folder…** untuk memilih folder tertentu, atau **Seluruh Volume**.
5. Pilih folder tujuan Windows.
6. Atur opsi (default sudah aman).
7. Klik **Pindai Sumber**, lalu **Mulai Transfer**.

## Build dari source

### Prasyarat

- [Flutter](https://flutter.dev) 3.27+ (Windows desktop enabled)
- [Visual Studio Build Tools](https://visualstudio.microsoft.com/downloads/) dengan C++ workload
- Python 3.10+ (hanya untuk mengunduh source library)

### Langkah

```powershell
# 1. Unduh source library native (sekali saja)
powershell -ExecutionPolicy Bypass -File native/fetch_sources.ps1

# 2. Build DLL native (menghasilkan native/dist/macfs.dll)
native/build.bat

# 3. Build aplikasi Flutter
flutter pub get
flutter build windows --release

# 4. Salin DLL ke folder rilis
Copy-Item native/dist/macfs.dll build/windows/x64/runner/Release/

# 5. Buat paket zip
Compress-Archive -Path build/windows/x64/runner/Release/* `
    -DestinationPath MacDriveRescue-win64.zip -Force
```

## Struktur proyek

```
lib/
  main.dart                    # entry point
  core/
    macfs_ffi.dart             # binding Dart FFI ke macfs.dll
    partition.dart             # info partisi via DLL
    discovery.dart             # deteksi volume Mac
    engine.dart                # scan + copy (isolate)
    names.dart                 # sanitasi nama Mac -> NTFS
    win_time.dart              # SetFileTime via Win32
  ui/
    home_screen.dart           # layar utama
    theme.dart                 # tema gelap
    widgets.dart               # komponen UI
native/
  bridge/macfs_bridge.c/.h     # bridge C (API ringkas untuk Flutter)
  shim/libbfio.h               # shim header
  fetch_sources.ps1            # unduh source libfsapfs/libfshfs/zlib
  build.bat                    # build DLL dengan MSVC
  vendor/                      # (diunduh) source library + zlib
test/
  smoke_dll.dart               # uji DLL via Dart FFI
  e2e_engine.dart              # uji end-to-end scan+copy (butuh admin)
```

## Lisensi

Kode aplikasi: [MIT](LICENSE).

Library native yang ditautkan:
- [libfsapfs](https://github.com/libyal/libfsapfs) — LGPL-3.0-or-later
- [libfshfs](https://github.com/libyal/libfshfs) — LGPL-3.0-or-later
- [zlib](https://zlib.net) — zlib license