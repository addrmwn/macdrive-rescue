// Tes final mount: huruf otomatis + verifikasi dari proses lain.
import 'dart:io';

import 'package:macdrive_rescue/core/discovery.dart';
import 'package:macdrive_rescue/core/macfs_ffi.dart';

Future<void> main() async {
  MacFsLibrary.ensureLoaded();
  print('winfsp available: ${WinFspChecker.available}');

  final list = await scanMacDrives();
  MacDrive? pick;
  for (final d in list) {
    if (d.isUsable && d.volumeName.toLowerCase().contains('data')) {
      pick = d;
      break;
    }
  }
  pick ??= list.where((d) => d.isUsable).firstOrNull;
  if (pick == null) {
    print('Tidak ada volume Mac');
    exit(1);
  }
  print('volume: ${pick.volumeName} (disk ${pick.diskNumber})');

  // 1. Huruf otomatis.
  print('\n--- mode otomatis ---');
  final auto = MacMount.mount(
    diskNumber: pick.diskNumber,
    offset: pick.partition.start,
    length: pick.partition.length,
    kind: pick.fsKind,
    volumeIndex: pick.volumeIndex,
    mountPoint: '',
  );
  print('auto: ${auto != null} err=${MacMount.lastError}');
  if (auto != null) {
    print('  mountPoint="${auto.mountPoint}" active=${auto.isActive}');
    await Future<void>.delayed(const Duration(seconds: 3));
    final drives = Process.runSync('powershell', [
      '-NoProfile', '-Command',
      '(Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name) -join ","'
    ]);
    print('  drives terlihat: ${(drives.stdout as String).trim()}');
    auto.unmount();
  }

  // 2. Huruf eksplisit M:.
  print('\n--- mode M: ---');
  final explicit = MacMount.mount(
    diskNumber: pick.diskNumber,
    offset: pick.partition.start,
    length: pick.partition.length,
    kind: pick.fsKind,
    volumeIndex: pick.volumeIndex,
    mountPoint: 'M:',
  );
  print('M: ${explicit != null} err=${MacMount.lastError}');
  if (explicit != null) {
    await Future<void>.delayed(const Duration(seconds: 3));
    final dir = Process.runSync('cmd', ['/c', 'dir M:\\']);
    print('  dir M: exit=${dir.exitCode}');
    print('  out: ${(dir.stdout as String).split('\n').take(4).join(' | ')}');
    print('  err: ${(dir.stderr as String).trim()}');
    explicit.unmount();
  }

  print('\nDONE');
}