// Uji fitur mount: ketersediaan WinFsp + API surface.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:macdrive_rescue/core/macfs_ffi.dart';

void main() {
  MacFsLibrary.ensureLoaded();
  print('WinFsp available: ${WinFspChecker.available}');

  // Periksa bahwa simbol mount ada tanpa crash.
  final lib = DynamicLibrary.open('native/dist/macfs.dll');
  for (final name in [
    'macfs_winfsp_available',
    'macfs_mount_volume',
    'macfs_unmount',
    'macfs_mount_error',
    'macfs_mount_point',
    'macfs_mount_is_active',
  ]) {
    try {
      lib.lookup(name);
      print('symbol OK: $name');
    } catch (e) {
      print('symbol MISSING: $name ($e)');
    }
  }

  // Coba mount — harus gagal dengan pesan WinFsp bila belum terpasang.
  final mount = MacMount.mount(
    diskNumber: 2,
    offset: 209735680,
    length: 499898105856,
    kind: 0,
    volumeIndex: 0,
    mountPoint: 'M:',
  );
  print('mount result: ${mount == null ? "null" : "handle"}');
  print('lastError: ${MacMount.lastError}');
  mount?.unmount();
}