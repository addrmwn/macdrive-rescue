// Test: salin FILE TUNGGAL (bukan folder).
import 'dart:io';

import 'package:macdrive_rescue/core/discovery.dart';
import 'package:macdrive_rescue/core/engine.dart';

Future<void> main() async {
  final drives = await scanMacDrives();
  final usable = drives.where((d) => d.isUsable).toList();
  final drive = usable.firstWhere(
    (d) => d.volumeName.toLowerCase().contains('data'),
    orElse: () => usable.first,
  );
  print('using: ${drive.volumeName}');

  // File tunggal: Config.plist di Desktop
  const filePath = 'Users/adidarmawan/Desktop/Config.plist';
  print('\n=== Scan file tunggal: $filePath ===');
  final scan = await scanVolume(
    diskNumber: drive.diskNumber,
    offset: drive.partition.start,
    length: drive.partition.length,
    kind: drive.fsKind,
    volumeIndex: drive.volumeIndex,
    startPath: filePath,
    options: const TransferOptions(),
  );
  print('files: ${scan.files.length}, dirs: ${scan.dirs.length}, bytes: ${scan.totalBytes}');
  for (final f in scan.files) {
    print('  ${f.relDisplay} -> dest: ${f.destParts.join('/')} (${f.size} B)');
  }
  if (scan.files.length != 1) {
    print('FAIL: harusnya 1 file');
    exit(1);
  }
  if (scan.dirs.isNotEmpty) {
    print('FAIL: tidak boleh ada folder');
    exit(1);
  }

  // Copy
  final dest = '${Directory.systemTemp.path}\\macdrive_e2e_singlefile';
  if (Directory(dest).existsSync()) Directory(dest).deleteSync(recursive: true);

  Map<String, dynamic>? done;
  await copyFiles(
    diskNumber: drive.diskNumber,
    offset: drive.partition.start,
    length: drive.partition.length,
    kind: drive.fsKind,
    volumeIndex: drive.volumeIndex,
    destRoot: dest,
    options: const TransferOptions(),
    files: scan.files,
    dirs: scan.dirs,
    onEvent: (e) {
      if (e['kind'] == 'done') done = e;
    },
  );
  print('\ncopied: ${done?['filesCopied']}, failed: ${done?['filesFailed']}');

  final entries = Directory(dest).listSync().map((e) => e.path.split('\\').last).toList();
  print('root entries: $entries');
  if (entries.contains('Config.plist')) {
    final f = File('$dest\\Config.plist');
    print('PASS: Config.plist tersalin (${f.lengthSync()} bytes)');
    print('mtime: ${f.statSync().modified}');
  } else {
    print('FAIL: Config.plist tidak ada');
    exit(1);
  }
  print('\nDONE');
}