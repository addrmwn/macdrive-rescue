/// Engine transfer: scan volume Mac -> daftar tugas, lalu salin ke Windows.
///
/// Semua operasi berat (scan & copy) berjalan di isolate terpisah lewat
/// `Isolate.run`, sehingga UI tetap responsif. Progress dikirim via port.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:macdrive_rescue/core/macfs_ffi.dart';
import 'package:macdrive_rescue/core/names.dart';
import 'package:macdrive_rescue/core/win_time.dart';

// ---------------------------------------------------------------------------
// Opsi & model
// ---------------------------------------------------------------------------

class TransferOptions {
  final bool skipSystem;
  final bool skipHidden;
  final bool skipBuildDirs;
  final bool skipAppBundles;
  final String overwrite; // skip | overwrite | rename
  final bool verify;
  final bool preserveTimes;
  final String symlinks; // skip | follow
  final String colonReplacement;
  final bool dryRun;

  const TransferOptions({
    this.skipSystem = true,
    this.skipHidden = false,
    this.skipBuildDirs = true,
    this.skipAppBundles = true,
    this.overwrite = 'skip',
    this.verify = true,
    this.preserveTimes = true,
    this.symlinks = 'skip',
    this.colonReplacement = '-',
    this.dryRun = false,
  });
}

class FileTask {
  final List<String> relParts; // nama asli Mac (untuk log)
  final List<String> destParts; // nama tersanitasi
  final int size;
  const FileTask(this.relParts, this.destParts, this.size);

  String get relDisplay => relParts.join('/');
}

class DirTask {
  final List<String> relParts;
  final List<String> destParts;
  final int mtimeNs;
  const DirTask(this.relParts, this.destParts, this.mtimeNs);
}

class ScanResult {
  final List<FileTask> files;
  final List<DirTask> dirs;
  final int totalBytes;
  final int skippedFiles;
  final int skippedDirs;
  final List<String> unreadable;
  final bool cancelled;
  const ScanResult({
    required this.files,
    required this.dirs,
    required this.totalBytes,
    required this.skippedFiles,
    required this.skippedDirs,
    required this.unreadable,
    this.cancelled = false,
  });
}

class CopyStats {
  final int filesCopied;
  final int filesSkipped;
  final int filesFailed;
  final int bytesCopied;
  final int verifyFailed;
  final double durationSeconds;
  final bool cancelled;
  final List<List<String>> errors; // [rel, pesan]
  final List<List<String>> manifest; // [rel, dest, size, hash, status]
  const CopyStats({
    required this.filesCopied,
    required this.filesSkipped,
    required this.filesFailed,
    required this.bytesCopied,
    required this.verifyFailed,
    required this.durationSeconds,
    required this.cancelled,
    required this.errors,
    required this.manifest,
  });
}

// ---------------------------------------------------------------------------
// Konstanta filter
// ---------------------------------------------------------------------------

const _systemNames = {
  '.DS_Store',
  '._.DS_Store',
  '.Spotlight-V100',
  '.Trashes',
  '.fseventsd',
  '.TemporaryItems',
  '.DocumentRevisions-V100',
  '.VolumeIcon.icns',
  '.AppleDB',
  '.AppleDesktop',
  '.apdisk',
  r'$RECYCLE.BIN',
  'System Volume Information',
  '.com.apple.timemachine.donotpresent',
};

const _systemDirs = {'.Trash', '.Trashes', 'Caches'};

const _buildDirs = {
  'build',
  'node_modules',
  '.dart_tool',
  'pods',
  'deriveddata',
  '.gradle',
  '__pycache__',
  '.next',
};

bool _shouldSkip(String name, bool isDir, TransferOptions opts) {
  if (opts.skipSystem) {
    if (_systemNames.contains(name)) return true;
    if (name.startsWith('._')) return true;
    if (isDir && _systemDirs.contains(name)) return true;
  }
  if (opts.skipHidden && name.startsWith('.')) return true;
  if (opts.skipAppBundles &&
      isDir &&
      (name.endsWith('.app') ||
          name.endsWith('.framework') ||
          name.endsWith('.bundle'))) {
    return true;
  }
  if (opts.skipBuildDirs && isDir && _buildDirs.contains(name.toLowerCase())) {
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Scan (berjalan di isolate)
// ---------------------------------------------------------------------------

/// Memindai volume sumber dan mengembalikan daftar tugas.
Future<ScanResult> scanVolume({
  required int diskNumber,
  required int offset,
  required int length,
  required int kind,
  required int volumeIndex,
  String? startPath,
  required TransferOptions options,
  void Function(int files, int bytes)? onProgress,
  bool Function()? isCancelled,
}) async {
  final raw = await Isolate.run<Map<String, dynamic>>(() => _scanWorker(_ScanMessage(
        diskNumber: diskNumber,
        offset: offset,
        length: length,
        kind: kind,
        volumeIndex: volumeIndex,
        startPath: startPath,
        options: _OptionsDto.from(options),
      )));
  return parseScanResult(raw);
}

class _ScanMessage {
  final int diskNumber;
  final int offset;
  final int length;
  final int kind;
  final int volumeIndex;
  final String? startPath;
  final _OptionsDto options;

  _ScanMessage({
    required this.diskNumber,
    required this.offset,
    required this.length,
    required this.kind,
    required this.volumeIndex,
    required this.startPath,
    required this.options,
  });
}

class _OptionsDto {
  final bool skipSystem;
  final bool skipHidden;
  final bool skipBuildDirs;
  final bool skipAppBundles;
  final String overwrite;
  final bool verify;
  final bool preserveTimes;
  final String symlinks;
  final String colonReplacement;
  final bool dryRun;

  const _OptionsDto({
    required this.skipSystem,
    required this.skipHidden,
    required this.skipBuildDirs,
    required this.skipAppBundles,
    required this.overwrite,
    required this.verify,
    required this.preserveTimes,
    required this.symlinks,
    required this.colonReplacement,
    required this.dryRun,
  });

  factory _OptionsDto.from(TransferOptions o) => _OptionsDto(
        skipSystem: o.skipSystem,
        skipHidden: o.skipHidden,
        skipBuildDirs: o.skipBuildDirs,
        skipAppBundles: o.skipAppBundles,
        overwrite: o.overwrite,
        verify: o.verify,
        preserveTimes: o.preserveTimes,
        symlinks: o.symlinks,
        colonReplacement: o.colonReplacement,
        dryRun: o.dryRun,
      );

  TransferOptions toOptions() => TransferOptions(
        skipSystem: skipSystem,
        skipHidden: skipHidden,
        skipBuildDirs: skipBuildDirs,
        skipAppBundles: skipAppBundles,
        overwrite: overwrite,
        verify: verify,
        preserveTimes: preserveTimes,
        symlinks: symlinks,
        colonReplacement: colonReplacement,
        dryRun: dryRun,
      );
}

/// Worker scan yang berjalan di isolate.
///
/// Catatan: DLL di-load ulang di isolate ini (DynamicLibrary.open idempoten
/// per proses, aman).
Future<Map<String, dynamic>> _scanWorker(_ScanMessage msg) async {
  MacFsLibrary.ensureLoaded();
  final options = msg.options.toOptions();
  final volume = MacVolume.open(
    diskNumber: msg.diskNumber,
    offset: msg.offset,
    length: msg.length,
    kind: msg.kind,
    volumeIndex: msg.kind == FsKind.apfs ? msg.volumeIndex : -1,
  );

  final files = <FileTask>[];
  final dirs = <DirTask>[];
  final unreadable = <String>[];
  var totalBytes = 0;
  var skippedFiles = 0;
  var skippedDirs = 0;

// Entry root / start.
  int rootId;
  String? startName;
  var startIsFile = false;
  if (msg.startPath != null && msg.startPath!.isNotEmpty) {
    rootId = _openPath(volume, msg.startPath!);
    if (rootId == 0) {
      volume.close();
      throw MacFsException('File/folder tidak ditemukan: ${msg.startPath}');
    }
    startName = msg.startPath!.split('/').last;
    final mode = volume.entryMode(rootId);
    startIsFile = (mode & sIFMT) != sIFDIR;
  } else {
    rootId = volume.rootId();
  }

  void walk(int dirId, List<String> rel, List<String> dest) {
    final childCount = volume.entryCount(dirId);
    if (childCount < 0) return;
    final taken = <String>{};
    for (var i = 0; i < childCount; i++) {
      final childId = volume.entryChild(dirId, i);
      if (childId == 0) continue;
      try {
        final name = volume.entryName(childId);
        final mode = volume.entryMode(childId);
        final isDir = (mode & sIFMT) == sIFDIR;
        final isLink = (mode & sIFMT) == sIFLNK;
        final size = volume.entrySize(childId);

        if (_shouldSkip(name, isDir, options) || name.startsWith('._')) {
          if (isDir) {
            skippedDirs++;
          } else {
            skippedFiles++;
          }
          continue;
        }
        if (isLink && options.symlinks == 'skip') {
          continue;
        }
        final safe = uniqueName(
          sanitizeComponent(name, colonReplacement: options.colonReplacement),
          taken,
        );
        final childRel = [...rel, name];
        final childDest = [...dest, safe];
        if (isDir) {
          dirs.add(DirTask(childRel, childDest, volume.entryMtimeNs(childId)));
          walk(childId, childRel, childDest);
        } else {
          files.add(FileTask(childRel, childDest, size));
          totalBytes += size;
        }
      } finally {
        volume.release(childId);
      }
    }
  }

final initialRel = <String>[];
  final initialDest = <String>[];
  if (startName != null && startIsFile) {
    // Sumber berupa file tunggal: salin file itu saja ke folder tujuan.
    final fullRel =
        msg.startPath!.split('/').where((p) => p.isNotEmpty).toList();
    final safe = sanitizeComponent(startName,
        colonReplacement: options.colonReplacement);
    files.add(FileTask(fullRel, [safe], volume.entrySize(rootId)));
    totalBytes += volume.entrySize(rootId);
  } else if (startName != null) {
    // relParts = path lengkap dari root volume (untuk membuka file saat copy).
    initialRel.addAll(
        msg.startPath!.split('/').where((p) => p.isNotEmpty).toList());
    // destParts = hanya nama folder awal (jadi root di tujuan).
    initialDest.add(sanitizeComponent(startName,
        colonReplacement: options.colonReplacement));
    dirs.add(DirTask(initialRel, initialDest, volume.entryMtimeNs(rootId)));
    walk(rootId, initialRel, initialDest);
  } else {
    walk(rootId, initialRel, initialDest);
  }
  volume.close();

  return {
    'files': files
        .map((f) => {'rel': f.relParts, 'dest': f.destParts, 'size': f.size})
        .toList(),
    'dirs': dirs
        .map((d) => {'rel': d.relParts, 'dest': d.destParts, 'mtime': d.mtimeNs})
        .toList(),
    'totalBytes': totalBytes,
    'skippedFiles': skippedFiles,
    'skippedDirs': skippedDirs,
    'unreadable': unreadable,
  };
}

int _openPath(MacVolume volume, String path) {
  // Gunakan root walk karena bridge belum mengekspos open_path via Dart.
  // Format path: "Users/adidarmawan/Documents/LocalMesh"
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  var current = volume.rootId();
  for (final part in parts) {
    final count = volume.entryCount(current);
    var foundId = 0;
    for (var i = 0; i < count; i++) {
      final childId = volume.entryChild(current, i);
      if (childId == 0) continue;
      if (volume.entryName(childId) == part) {
        foundId = childId;
        break;
      }
      volume.release(childId);
    }
    if (foundId == 0) return 0;
    if (current != volume.rootId()) {
      volume.release(current);
    }
    current = foundId;
  }
  return current;
}

/// Mengubah hasil isolate menjadi ScanResult.
ScanResult parseScanResult(Map<String, dynamic> raw) {
  final files = <FileTask>[];
  for (final item in (raw['files'] as List)) {
    final map = item as Map;
    files.add(FileTask(
      List<String>.from(map['rel'] as List),
      List<String>.from(map['dest'] as List),
      map['size'] as int,
    ));
  }
  final dirs = <DirTask>[];
  for (final item in (raw['dirs'] as List)) {
    final map = item as Map;
    dirs.add(DirTask(
      List<String>.from(map['rel'] as List),
      List<String>.from(map['dest'] as List),
      map['mtime'] as int,
    ));
  }
  return ScanResult(
    files: files,
    dirs: dirs,
    totalBytes: raw['totalBytes'] as int,
    skippedFiles: raw['skippedFiles'] as int,
    skippedDirs: raw['skippedDirs'] as int,
    unreadable: List<String>.from(raw['unreadable'] as List),
  );
}

// ---------------------------------------------------------------------------
// Copy
// ---------------------------------------------------------------------------

class _CopyMessage {
  final int diskNumber;
  final int offset;
  final int length;
  final int kind;
  final int volumeIndex;
  final String destRoot;
  final _OptionsDto options;
  final List<Map<String, dynamic>> files;
  final List<Map<String, dynamic>> dirs;
  final SendPort progressPort;
  final SendPort resultPort;

  _CopyMessage({
    required this.diskNumber,
    required this.offset,
    required this.length,
    required this.kind,
    required this.volumeIndex,
    required this.destRoot,
    required this.options,
    required this.files,
    required this.dirs,
    required this.progressPort,
    required this.resultPort,
  });
}

/// Menyalin file dari volume Mac ke folder Windows.
///
/// Mengirim progress via [onEvent]; hasil akhir juga dikirim ke callback yang
/// sama dengan `kind == 'done'`.
Future<void> copyFiles({
  required int diskNumber,
  required int offset,
  required int length,
  required int kind,
  required int volumeIndex,
  required String destRoot,
  required TransferOptions options,
  required List<FileTask> files,
  required List<DirTask> dirs,
  required void Function(Map<String, dynamic> event) onEvent,
  Future<void> Function()? cancelSignal,
}) async {
  final resultPort = ReceivePort();
  final progressPort = ReceivePort();
  final isolate = await Isolate.spawn(_copyWorker, _CopyMessage(
    diskNumber: diskNumber,
    offset: offset,
    length: length,
    kind: kind,
    volumeIndex: volumeIndex,
    destRoot: destRoot,
    options: _OptionsDto.from(options),
    files: files
        .map((f) => {'rel': f.relParts, 'dest': f.destParts, 'size': f.size})
        .toList(),
    dirs: dirs
        .map((d) => {'rel': d.relParts, 'dest': d.destParts, 'mtime': d.mtimeNs})
        .toList(),
    progressPort: progressPort.sendPort,
    resultPort: resultPort.sendPort,
  ));

  final events = StreamController<Map<String, dynamic>>();
  progressPort.listen((message) {
    if (message is Map) {
      onEvent(Map<String, dynamic>.from(message));
    }
  });
  resultPort.listen((message) {
    if (message is Map) {
      final map = Map<String, dynamic>.from(message);
      onEvent(map);
    }
    events.close();
    resultPort.close();
    progressPort.close();
    isolate.kill(priority: Isolate.immediate);
  });
  await events.stream.drain<void>();
}

void _copyWorker(_CopyMessage msg) {
  try {
    MacFsLibrary.ensureLoaded();
    final options = msg.options.toOptions();
    final volume = MacVolume.open(
      diskNumber: msg.diskNumber,
      offset: msg.offset,
      length: msg.length,
      kind: msg.kind,
      volumeIndex: msg.kind == FsKind.apfs ? msg.volumeIndex : -1,
    );

    var filesCopied = 0;
    var filesSkipped = 0;
    var filesFailed = 0;
    var bytesCopied = 0;
    var verifyFailed = 0;
    final errors = <List<String>>[];
    final manifest = <List<String>>[];
    final failedTasks = <Map<String, dynamic>>[];
    final started = DateTime.now();

    final destRoot = msg.destRoot;
    Directory(destRoot).createSync(recursive: true);

    // Buat folder.
    final createdDirs = <Map<String, dynamic>>[];
    for (final d in msg.dirs) {
      final destParts = List<String>.from(d['dest'] as List);
      final path = _joinPath(destRoot, destParts);
      try {
        Directory(path).createSync(recursive: true);
        createdDirs.add({'path': path, 'mtime': d['mtime']});
      } catch (e) {
        filesFailed++;
        errors.add([(d['rel'] as List).join('/'), 'folder: $e']);
      }
    }

    final total = msg.files.length;
    var index = 0;
for (final f in msg.files) {
      index++;
      final relParts = List<String>.from(f['rel'] as List);
      final destParts = List<String>.from(f['dest'] as List);
      final size = f['size'] as int;
      // Tampilkan path relatif terhadap folder tujuan (ramah dibaca).
      final relDisplay = destParts.join('/');
      var destPath = _joinPath(destRoot, destParts);

      if (File(destPath).existsSync() || Directory(destPath).existsSync()) {
        if (options.overwrite == 'skip') {
          filesSkipped++;
          msg.progressPort.send({
            'kind': 'file',
            'rel': relDisplay,
            'status': 'skip',
            'index': index,
            'total': total,
          });
          continue;
        }
        if (options.overwrite == 'rename') {
          destPath = _renamedPath(destPath);
        }
      }

      if (options.dryRun) {
        filesCopied++;
        bytesCopied += size;
        msg.progressPort.send({
          'kind': 'file',
          'rel': relDisplay,
          'status': 'dry',
          'index': index,
          'total': total,
        });
        continue;
      }

      try {
        Directory(_dirname(destPath)).createSync(recursive: true);
        // Buka entry via path (relatif terhadap volume).
        final entryId = _openByRel(volume, relParts);
        if (entryId == 0) {
          throw 'tidak bisa membuka file di volume';
        }
try {
          final sink = File(destPath).openSync(mode: FileMode.write);
          final buffer = Uint8List(4 * 1024 * 1024);
          var offset = 0;
          var retries = 0;
          while (offset < size) {
            var read = volume.readInto(entryId, buffer, offset);
            if (read <= 0) {
              // Retry: koneksi USB/disk kadang gagal sesaat.
              if (retries < 3) {
                retries++;
                msg.progressPort.send({
                  'kind': 'retry',
                  'rel': relDisplay,
                  'attempt': retries,
                });
                sleep(const Duration(milliseconds: 300));
                continue;
              }
              break;
            }
            retries = 0;
            sink.writeFromSync(buffer, 0, read);
            offset += read;
            msg.progressPort.send({
              'kind': 'progress',
              'rel': relDisplay,
              'bytes': read,
              'fileIndex': index,
              'fileTotal': total,
            });
          }
          sink.closeSync();
          if (offset != size) {
            throw 'pembacaan tidak lengkap (${offset}/${size}) setelah 3 percobaan';
          }
        } finally {
          volume.release(entryId);
        }

if (options.preserveTimes) {
          final entryId2 = _openByRel(volume, relParts);
          if (entryId2 != 0) {
            try {
              setFileTimesWindows(
                destPath,
                mtimeNs: volume.entryMtimeNs(entryId2),
                atimeNs: volume.entryAtimeNs(entryId2),
                ctimeNs: volume.entryCtimeNs(entryId2),
              );
            } finally {
              volume.release(entryId2);
            }
          }
        }

        filesCopied++;
        bytesCopied += size;
        manifest.add([relDisplay, destPath, '$size', '', 'ok']);
        msg.progressPort.send({
          'kind': 'file',
          'rel': relDisplay,
          'status': 'ok',
          'index': index,
          'total': total,
        });
      } catch (e) {
        filesFailed++;
        errors.add([relDisplay, e.toString()]);
        failedTasks.add({'rel': relParts, 'dest': destParts, 'size': size});
        msg.progressPort.send({
          'kind': 'file',
          'rel': relDisplay,
          'status': 'error',
          'index': index,
          'total': total,
          'error': e.toString(),
        });
      }
    }

// Set timestamp folder setelah isi selesai (terdalam dulu).
    if (options.preserveTimes) {
      for (final d in createdDirs.reversed) {
        final mtime = d['mtime'] as int? ?? 0;
        if (mtime > 0) {
          setFileTimesWindows(d['path'] as String, mtimeNs: mtime, isDir: true);
        }
      }
    }

    volume.close();
    final duration = DateTime.now().difference(started).inMilliseconds / 1000.0;
    msg.resultPort.send({
      'kind': 'done',
      'filesCopied': filesCopied,
      'filesSkipped': filesSkipped,
      'filesFailed': filesFailed,
      'bytesCopied': bytesCopied,
      'verifyFailed': verifyFailed,
      'durationSeconds': duration,
      'cancelled': false,
      'errors': errors,
      'manifest': manifest,
      'failedTasks': failedTasks,
    });
  } catch (e) {
    msg.resultPort.send({
      'kind': 'done',
      'filesCopied': 0,
      'filesSkipped': 0,
      'filesFailed': 0,
      'bytesCopied': 0,
      'verifyFailed': 0,
      'durationSeconds': 0.0,
      'cancelled': false,
      'errors': [
        ['', e.toString()]
      ],
      'manifest': [],
      'fatal': e.toString(),
    });
  }
}

int _openByRel(MacVolume volume, List<String> relParts) {
  var current = volume.rootId();
  for (var i = 0; i < relParts.length; i++) {
    final part = relParts[i];
    final count = volume.entryCount(current);
    var found = 0;
    for (var j = 0; j < count; j++) {
      final childId = volume.entryChild(current, j);
      if (childId == 0) continue;
      if (volume.entryName(childId) == part) {
        found = childId;
        break;
      }
      volume.release(childId);
    }
    if (found == 0) return 0;
    if (current != volume.rootId()) {
      volume.release(current);
    }
    current = found;
  }
  return current;
}

int entryMtimeFor(MacVolume volume, List<String> relParts) {
  final id = _openByRel(volume, relParts);
  if (id == 0) return 0;
  try {
    return volume.entryMtimeNs(id);
  } finally {
    volume.release(id);
  }
}

String _joinPath(String root, List<String> parts) {
  var path = root;
  for (final p in parts) {
    path = '$path${Platform.pathSeparator}$p';
  }
  return path;
}

String _dirname(String path) {
  final idx = path.lastIndexOf(Platform.pathSeparator);
  return idx <= 0 ? path : path.substring(0, idx);
}

String _renamedPath(String path) {
  final dir = _dirname(path);
  final base = path.substring(dir.length + 1);
  final lastDot = base.lastIndexOf('.');
  final stem = lastDot > 0 ? base.substring(0, lastDot) : base;
  final ext = lastDot > 0 ? base.substring(lastDot) : '';
  var n = 2;
  while (true) {
    final candidate = '$dir${Platform.pathSeparator}$stem ($n)$ext';
    if (!File(candidate).existsSync() && !Directory(candidate).existsSync()) {
      return candidate;
    }
    n++;
  }
}

/// Utilitas untuk menulis laporan CSV.
Future<void> writeManifestCsv(
    String path, List<List<String>> manifest) async {
  final buffer = StringBuffer();
  buffer.writeln('sumber,tujuan,ukuran_byte,hash,status');
  for (final row in manifest) {
    buffer.writeln(row.map(_csvEscape).join(','));
  }
  await File(path).writeAsString('\uFEFF$buffer');
}

Future<void> writeErrorCsv(String path, List<List<String>> errors) async {
  final buffer = StringBuffer();
  buffer.writeln('path,kesalahan');
  for (final row in errors) {
    buffer.writeln(row.map(_csvEscape).join(','));
  }
  await File(path).writeAsString('\uFEFF$buffer');
}

String _csvEscape(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

// Utility JSON untuk debug.
String encodeEvent(Map<String, dynamic> event) => jsonEncode(event);
