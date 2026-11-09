# MacDrive Rescue

Aplikasi Windows untuk **mengambil/menyalin data dari drive Mac (APFS & HFS+)** ke komputer Windows — tanpa memerlukan lisensi MacDrive.

Dibuat khusus untuk kasus umum: MacDrive terpasang tetapi trial-nya sudah habis, sehingga Windows hanya bisa "melihat" nama folder di drive Mac, tetapi **gagal membuka/menyalin file** (error `A device attached to the system is not functioning` / WinError 31 / Permission denied).

## Cara kerja

Aplikasi **tidak memakai driver MacDrive**. Ia membaca disk fisik secara langsung (raw, read-only) dengan hak Administrator, lalu mem-parsing filesystem:

- **APFS** (macOS High Sierra ke atas) via `libfsapfs`
- **HFS+** (macOS lama) via `libfshfs`

Karena membaca data mentah, data tetap bisa diambil meskipun MacDrive trial habis, rusak, atau bahkan tidak terpasang.

## Fitur

- Deteksi otomatis semua volume APFS/HFS+ di seluruh disk fisik (termasuk semua volume logis dalam container APFS).
- Dukungan volume APFS terenkripsi (bila password dimasukkan — via API library).
- **Folder yang dipilih menjadi root tujuan**: memilih `LocalMesh` menghasilkan `<tujuan>\LocalMesh\...` — tanpa rantai path `Users\adidarmawan\Documents\...`.
- **Sanitasi nama file** khas Mac agar valid di Windows:
  - `:` → `-` (bisa diubah menjadi `_` atau `：`)
  - Karakter terlarang `< > " | ? *` → `_`
  - Nama berakhir titik/spasi dan nama perangkat cadangan (CON, NUL, COM1, ...) ditangani
  - Tabrakan nama otomatis diberi akhiran ` (2)`, ` (3)`, ...
  - Normalisasi Unicode NFD → NFC
- **Path panjang** (> 260 karakter) didukung penuh lewat `\\?\`.
- **Verifikasi hash BLAKE2b** setelah penyalinan (opsional).
- **Pertahankan tanggal file** (modifikasi, akses, pembuatan).
- Filter file sistem Mac (`.DS_Store`, `._*`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, dll.).
- Filter folder build/cache (opsional, aktif default): `build`, `node_modules`, `.dart_tool`, `Pods`, `DerivedData`, dll.
- Opsi symlink: lewati atau ikuti target.
- Mode jika file sudah ada: lewati / timpa / ganti nama.
- Mode **simulasi** (dry-run) untuk melihat apa yang akan disalin tanpa menulis.
- Progress bar dengan kecepatan dan estimasi waktu, log real-time.
- **Laporan CSV** (manifest + daftar error) otomatis di subfolder `_laporan` dalam folder tujuan.
- Auto-elevasi UAC.

## Persyaratan

- Windows 10/11 (64-bit)
- Hak **Administrator** (wajib, untuk akses raw disk)
- Drive Mac terpasang (internal SATA/NVMe atau USB enclosure)

## Cara pakai (versi .exe — disarankan)

1. Jalankan `dist\MacDriveRescue.exe` (klik Yes pada prompt UAC).
2. Pilih volume Mac pada dropdown (volume `... - Data` biasanya berisi data pengguna).
3. Klik **Pilih Folder...** untuk memilih folder tertentu, atau **Pakai Seluruh Volume**.
4. Pilih folder tujuan di Windows.
5. Atur opsi (default sudah aman: lewati file sistem, verifikasi hash, pertahankan tanggal).
6. Klik **Pindai Sumber**, lalu **Mulai Transfer**.

## Cara pakai (dari source)

```powershell
# Siapkan environment (sekali saja)
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install libfsapfs-python libfshfs-python pyinstaller

# Jalankan (akan meminta UAC)
.\.venv\Scripts\python.exe main.py
```

## Build .exe

```powershell
.\.venv\Scripts\pyinstaller.exe MacDriveRescue.spec --noconfirm --clean
# hasil: dist\MacDriveRescue.exe
```

## Menjalankan test

```powershell
.\.venv\Scripts\python.exe tests\test_units.py
```

Test end-to-end dengan drive Mac asli (butuh admin) dapat dijalankan lewat skrip terpisah; lihat `tests/README` bila ada.

## Catatan penting

- **Read-only**: aplikasi tidak pernah menulis ke drive Mac. Aman untuk data bukti.
- **Volume sistem macOS** (`Macintosh HD` non-Data yang di-seal) memang tidak bisa dibaca isinya — itu normal dan bukan data pengguna. Gunakan volume **Data**.
- Untuk APFS terenkripsi (FileVault), password diperlukan. Fitur unlock tersedia tetapi belum diekspos di GUI.
- Jika drive Mac belum pernah di-mount MacDrive, Windows mungkin memberi huruf drive; aplikasi tetap bekerja karena membaca langsung dari disk fisik.
- Kecepatan baca bervariasi (±10–100 MB/s) tergantung jenis koneksi drive.

## Struktur proyek

```
main.py                  # launcher
macdrive_rescue/
  gui.py                 # antarmuka Tkinter
  discovery.py           # deteksi disk/partisi/volume Mac
  rawdisk.py             # akses raw disk Windows (ctypes)
  partition.py           # parser GPT/MBR
  fsmac.py               # adapter APFS/HFS+ (pyfsapfs/pyfshfs)
  engine.py              # scan + copy engine
  names.py               # sanitasi nama Mac -> Windows
  util.py                # timestamp, long path, format
tests/test_units.py      # unit test
MacDriveRescue.spec      # konfigurasi PyInstaller
dist/MacDriveRescue.exe  # hasil build
```