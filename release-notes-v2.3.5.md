## English

### What changed in v2.3.5

**Mount improvements**
- **Automatic drive letter is now the default** — no manual letter picking needed (avoids conflicts with used letters). Manual choice is still available as a secondary option.
- Mount now verifies the drive is really accessible instead of trusting internal status.
- Fixed a crash when mount cleanup ran after a failed mount.
- Added a direct **winfsp.dev** button in the Disk Info dialog.

**Honest note about Mount**

On our test machine, WinFsp reports success but Windows never creates the drive letter — even the official WinFsp `memfs` sample fails the same way there. That indicates a WinFsp/driver problem on that specific machine, not something the app can fix.

**Mount is optional.** Copying your data with **Start Transfer** works 100% and does not need WinFsp at all.

If you want to keep trying mount: https://winfsp.dev/rel/ → reinstall → restart PC.

**Requirements:** Windows 10/11 64-bit + Administrator rights.

---

## Bahasa Indonesia

### Yang berubah di v2.3.5

**Perbaikan mount**
- **Huruf drive otomatis kini jadi default** — tidak perlu memilih huruf manual (menghindari bentrok dengan huruf yang terpakai). Pilihan manual masih tersedia sebagai opsi sekunder.
- Mount kini memverifikasi drive benar-benar dapat diakses, bukan sekadar mempercayai status internal.
- Memperbaiki crash saat cleanup berjalan setelah mount gagal.
- Menambahkan tombol **winfsp.dev** langsung di dialog Info Disk.

**Catatan jujur soal Mount**

Di mesin pengujian kami, WinFsp melaporkan sukses tetapi Windows tidak pernah membuat huruf drive — bahkan sample resmi WinFsp `memfs` juga gagal dengan cara yang sama. Itu menandakan masalah driver WinFsp di mesin tersebut, bukan hal yang bisa diperbaiki dari aplikasi.

**Mount bersifat opsional.** Menyalin data dengan **Mulai Transfer** berfungsi 100% dan sama sekali tidak membutuhkan WinFsp.

Jika ingin tetap mencoba mount: https://winfsp.dev/rel/ → pasang ulang → restart PC.

**Persyaratan:** Windows 10/11 64-bit + hak Administrator.
