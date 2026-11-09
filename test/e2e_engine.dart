// Test e2e engine Dart: scan + copy dari drive F: asli.
// Jalankan: dart run test/e2e_engine.dart (butuh Administrator)
import 'dart:io';

import 'package:macdrive_rescue/core/discovery.dart';
import 'package:macdrive_rescue/core/engine.dart';

Future<void> main() async {
  print('=== E2E: scan + copy dari drive Mac ===');

  final drives = await scanMacDrives();
  print('drives found: ${drives.length}');
  for (final d in drives) {
    print('  - ${d.label}');
  }
  final usable = drives.where((d) => d.isUsable).toList();
  if (usable.isEmpty) {
    print('TIDAK ADA DRIVE USABLE');
    exit(1);
  }
  final drive = usable.firstWhere(
    (d) => d.volumeName.toLowerCase().contains('data'),
    orElse: () => usable.first,
  );
  print('\nusing: ${drive.volumeName}');

  // Scan folder kecil: cari folder di /Users/adidarmawan/Documents
  print('\n=== Scan source (seluruh volume, batasi output) ===');
  final stopwatch = Stopwatch()..start();
  final scan = await scanVolume(
    diskNumber: drive.diskNumber,
    offset: drive.partition.start,
    length: drive.partition.length,
    kind: drive.fsKind,
    volumeIndex: drive.volumeIndex,
    startPath: 'Users/adidarmawan/Documents/LocalMesh',
    options: const TransferOptions(),
  );
  print('scan selesai dalam ${stopwatch.elapsedMilliseconds}ms');
  print('files: ${scan.files.length}, dirs: ${scan.dirs.length}, '
      'bytes: ${scan.totalBytes}, skipped: ${scan.skippedFiles}/${scan.skippedDirs}');
  for (final f in scan.files.take(5)) {
    print('  ${f.relDisplay} (${f.size} B)');
  }

  // Copy
  print('\n=== Copy ke temp ===');
  final dest = '${Directory.systemTemp.path}\\macdrive_e2e_dart';
  if (Directory(dest).existsSync()) {
    Directory(dest).deleteSync(recursive: true);
  }
  final copyStart = Stopwatch()..start();
  Map<String, dynamic>? finalEvent;
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
    onEvent: (event) {
      if (event['kind'] == 'done') finalEvent = event;
    },
  );
  print('copy selesai dalam ${copyStart.elapsedMilliseconds}ms');
  if (finalEvent != null) {
    print('copied: ${finalEvent!['filesCopied']}, failed: ${finalEvent!['filesFailed']}, '
        'skipped: ${finalEvent!['filesSkipped']}, bytes: ${finalEvent!['bytesCopied']}');
    final errors = finalEvent!['errors'] as List;
    for (final e in errors.take(5)) {
      print('  ERROR: $e');
    }
  }

  // Verifikasi hasil
  print('\n=== Verifikasi hasil di disk ===');
  var fileCount = 0;
  var totalSize = 0;
  await for (final entity in Directory(dest).list(recursive: true)) {
    if (entity is File) {
      fileCount++;
      totalSize += await entity.length();
    }
  }
  print('on disk: $fileCount files, $totalSize bytes');

  // Cek struktur: LocalMesh harus jadi root.
  final entries = Directory(dest).listSync().map((e) => e.path.split('\\').last).toList();
  print('root entries: $entries');
  if (entries.contains('LocalMesh')) {
    print('PASS: LocalMesh adalah root tujuan');
  } else {
    print('FAIL: LocalMesh tidak ditemukan di root');
  }

  // Cek timestamp file pertama.
  if (scan.files.isNotEmpty) {
    final first = scan.files.first;
    final destPath = '$dest\\${first.destParts.join('\\')}';
    if (File(destPath).existsSync()) {
      final stat = File(destPath).statSync();
      final srcNs = 0; // Ambil dari manifest tidak tersedia di test ini
      print('first file: $destPath');
      print('  dest mtime: ${stat.modified}');
    }
  }

  print('\nDONE');
}