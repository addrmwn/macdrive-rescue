## English

### Diagnostics & fixes in v2.3.4

- **Release notes encoding fixed** — previous release pages showed broken characters in place of dashes and arrows. New release tooling writes UTF-8 correctly and verifies it.
- **Mount diagnostics improved** — clearer error messages; the app now verifies that the mounted drive is really accessible before reporting success.

### Mount as Drive still not showing in Explorer?

If the drive doesn't appear after mounting, try this — it fixes the most common cause:

1. **Remove ALL WinFsp versions** (Control Panel → Programs → uninstall WinFsp 2017 / 2025, whichever exist).
2. **Restart** the PC.
3. Install **only** WinFsp 2.1 → **https://winfsp.dev/rel/**
   (direct: https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi)
4. **Restart** again.
5. Open MacDrive Rescue → Info Disk → Mount as Drive.

Having multiple WinFsp versions installed at once is the most common cause of the driver refusing to serve files.

> **Data copying works 100% without WinFsp.** Mount is an optional extra.

**Requirements:** Windows 10/11 64-bit + Administrator rights.

---

## Bahasa Indonesia

### Diagnostik & perbaikan di v2.3.4

- **Encoding catatan rilis diperbaiki** — halaman rilis sebelumnya menampilkan karakter rusak pengganti tanda hubung dan panah. Tooling rilis baru menulis UTF-8 dengan benar dan memverifikasinya.
- **Diagnostik mount ditingkatkan** — pesan error lebih jelas; aplikasi kini memverifikasi drive benar-benar dapat diakses sebelum melaporkan sukses.

### Mount sebagai Drive masih tidak muncul di Explorer?

Jika drive tidak muncul setelah mount, coba ini — mengatasi penyebab paling umum:

1. **Hapus SEMUA versi WinFsp** (Control Panel → Programs → uninstall WinFsp 2017 / 2025, mana pun yang ada).
2. **Restart** PC.
3. Install **hanya** WinFsp 2.1 → **https://winfsp.dev/rel/**
   (langsung: https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi)
4. **Restart** lagi.
5. Buka MacDrive Rescue → Info Disk → Mount sebagai Drive.

Beberapa versi WinFsp terpasang bersamaan adalah penyebab paling umum driver menolak melayani file.

> **Fitur salin data tetap 100% berfungsi tanpa WinFsp.** Mount hanya tambahan opsional.

**Persyaratan:** Windows 10/11 64-bit + hak Administrator.
