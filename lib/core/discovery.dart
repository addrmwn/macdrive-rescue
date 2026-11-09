/// Deteksi drive Mac: pindai semua disk fisik, temukan partisi APFS/HFS+,
/// dan verifikasi isinya via DLL.
library;

import 'package:macdrive_rescue/core/macfs_ffi.dart';
import 'package:macdrive_rescue/core/partition.dart';

class MacDrive {
  final int diskNumber;
  final Partition partition;
  final int fsKind;
  final int volumeIndex;
  final String volumeName;
  final String? mountLetter;
  final String? error;

  const MacDrive({
    required this.diskNumber,
    required this.partition,
    required this.fsKind,
    required this.volumeIndex,
    required this.volumeName,
    this.mountLetter,
    this.error,
  });

  bool get isUsable => error == null;

  String get kindLabel => fsKind == FsKind.apfs ? 'APFS' : 'HFS+';

  String get label {
    final extras = <String>['${partition.sizeGb.toStringAsFixed(0)} GB'];
    if (mountLetter != null) extras.add('drive $mountLetter:');
    final suffix = error != null ? ' — $error' : '';
    return '$volumeName (${extras.join(', ')})$suffix';
  }

  /// Membuka volume untuk dipakai (butuh Administrator).
  MacVolume open() => MacVolume.open(
        diskNumber: diskNumber,
        offset: partition.start,
        length: partition.length,
        kind: fsKind,
        volumeIndex: fsKind == FsKind.apfs ? volumeIndex : -1,
      );
}

/// Memindai semua disk fisik dan mengembalikan daftar volume Mac.
Future<List<MacDrive>> scanMacDrives({int maxDisks = 16}) async {
  MacFsLibrary.ensureLoaded();
  final results = <MacDrive>[];

  // Gur huruf drive untuk info "Windows X:".
  final letters = await mountedDriveLetters();
  final mapDiskToLetter = <int, String>{};
  for (final letter in letters) {
    final disk = await diskNumberForDriveLetter(letter);
    if (disk != null) {
      mapDiskToLetter[disk] = letter;
    }
  }

  for (var diskNumber = 0; diskNumber < maxDisks; diskNumber++) {
    List<Partition> parts;
    try {
      parts = await readPartitions(diskNumber);
    } catch (_) {
      continue;
    }
    final macParts = parts.where((p) => p.isMac).toList();
    if (macParts.isEmpty) continue;

    for (final part in macParts) {
      final kind = part.typeGuid == GptGuids.apfs ? FsKind.apfs : FsKind.hfs;
      try {
        if (kind == FsKind.apfs) {
          final names = MacVolume.listVolumeNames(
            diskNumber: diskNumber,
            offset: part.start,
            length: part.length,
            kind: kind,
          );
          if (names.isEmpty) {
            results.add(MacDrive(
              diskNumber: diskNumber,
              partition: part,
              fsKind: kind,
              volumeIndex: 0,
              volumeName: '(tidak ada volume)',
              mountLetter: mapDiskToLetter[diskNumber],
              error: 'container APFS kosong',
            ));
            continue;
          }
          for (var i = 0; i < names.length; i++) {
            results.add(MacDrive(
              diskNumber: diskNumber,
              partition: part,
              fsKind: kind,
              volumeIndex: i,
              volumeName: names[i],
              mountLetter: mapDiskToLetter[diskNumber],
            ));
          }
        } else {
          // HFS+: buka untuk baca nama volume.
          final vol = MacVolume.open(
            diskNumber: diskNumber,
            offset: part.start,
            length: part.length,
            kind: kind,
            volumeIndex: -1,
          );
          final name = vol.name;
          vol.close();
          results.add(MacDrive(
            diskNumber: diskNumber,
            partition: part,
            fsKind: kind,
            volumeIndex: 0,
            volumeName: name,
            mountLetter: mapDiskToLetter[diskNumber],
          ));
        }
      } catch (e) {
        results.add(MacDrive(
          diskNumber: diskNumber,
          partition: part,
          fsKind: kind,
          volumeIndex: 0,
          volumeName: part.kind,
          mountLetter: mapDiskToLetter[diskNumber],
          error: e is MacFsException ? e.message : e.toString(),
        ));
      }
    }
  }

  // Urutkan: volume "Data" di depan.
  results.sort((a, b) {
    int rank(MacDrive d) {
      if (!d.isUsable) return 2;
      return d.volumeName.toLowerCase().contains('data') ? 0 : 1;
    }
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    return a.volumeName.toLowerCase().compareTo(b.volumeName.toLowerCase());
  });
  return results;
}
