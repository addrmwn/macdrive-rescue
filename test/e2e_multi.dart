// Test: salin MULTI file + MULTI folder sekaligus.
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

  // 2 folder + 1 file sekaligus
  const paths = [
    'Users/adidarmawan/Documents/LocalMesh',
    'Users/adidarmawan/Documents/mikhmon',
    'Users/adidarmawan/Desktop/Config.plist',
  ];

  print('=== Scan multi-source (${paths.length} item) ===');
  final scan = await scanVolume(
    diskNumber: drive.diskNumber,
    offset: drive.partition.start,
    length: drive.partition.length,
    kind: drive.fsKind,
    volumeIndex: drive.volumeIndex,
    startPaths: paths,
    options: const TransferOptions(),
  );
  print('files: ${scan.files.length}, dirs: ${scan.dirs.length}, bytes: ${scan.totalBytes}');

  // Periksa bahwa tiap item muncul di root tujuan.
  final topLevel = <String>{};
  for (final f in scan.files) {
    if (f.destParts.isNotEmpty) topLevel.add(f.destParts.first);
  }
  print('top-level entries: $topLevel');

  final expected = {'LocalMesh', 'mikhmon', 'Config.plist'};
  final missing = expected.difference(topLevel);
  if (missing.isNotEmpty) {
    print('FAIL: missing $missing');
    exit(1);
  }
  print('PASS: ketiga item ada di root tujuan');

  // Copy
  final dest = '${Directory.systemTemp.path}\\macdrive_e2e_multi';
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

  final entries = Directory(dest).listSync().map((e) => e.path.split('\\').last).toSet();
  print('root entries: $entries');
  if (entries.containsAll({'LocalMesh', 'mikhmon', 'Config.plist'})) {
    print('PASS: multi-source copy OK');
  } else {
    print('FAIL');
    exit(1);
  }
  print('\nDONE');
}