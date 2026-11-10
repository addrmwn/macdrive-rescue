// Uji akses N: dari dalam proses yang sama setelah mount.
import 'dart:io';

import 'package:macdrive_rescue/core/macfs_ffi.dart';

Future<void> main() async {
  MacFsLibrary.ensureLoaded();
  print('winfsp: ${WinFspChecker.available}');

  final mount = MacMount.mount(
    diskNumber: 2,
    offset: 209735680,
    length: 499898105856,
    kind: 0,
    volumeIndex: 0,
    mountPoint: 'N:',
  );
  if (mount == null) {
    print('MOUNT FAILED: ${MacMount.lastError}');
    exit(1);
  }
  print('mounted: ${mount.mountPoint}');

  await Future<void>.delayed(const Duration(seconds: 2));

  // Cek dari dalam proses ini.
  print('N:\\ existsSync: ${Directory('N:\\').existsSync()}');
  try {
    final entries = Directory('N:\\').listSync().take(5);
    print('entries: ${entries.map((e) => e.path).toList()}');
  } catch (e) {
    print('listSync error: ${e.runtimeType}: $e');
  }

  // Coba via cmd juga.
  final result = Process.runSync('cmd', ['/c', 'dir N:\\']);
  print('cmd exit: ${result.exitCode}');
  print('cmd out: ${(result.stdout as String).trim().split('\n').take(6).join(' | ')}');
  print('cmd err: ${(result.stderr as String).trim()}');

  mount.unmount();
  print('unmounted');
}