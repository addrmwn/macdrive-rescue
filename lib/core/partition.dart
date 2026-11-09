/// Parser tabel partisi GPT/MBR — dijalankan di sisi native (macfs.dll)
/// karena Dart tidak bisa membuka path perangkat `\\.\PhysicalDriveN`.
library;

import 'dart:io';

import 'package:macdrive_rescue/core/macfs_ffi.dart';

/// GUID partisi Apple.
class GptGuids {
  static const apfs = '7c3457ef-0000-11aa-aa11-00306543ecac';
  static const hfs = '48465300-0000-11aa-aa11-00306543ecac';
}

class Partition {
  final int index;
  final int diskNumber;
  final int start;
  final int length;
  final String typeGuid;
  final String name;

  const Partition({
    required this.index,
    required this.diskNumber,
    required this.start,
    required this.length,
    required this.typeGuid,
    required this.name,
  });

  String get kind {
    switch (typeGuid) {
      case GptGuids.apfs:
        return 'APFS';
      case GptGuids.hfs:
        return 'HFS+';
      default:
        return 'unknown';
    }
  }

  bool get isMac => typeGuid == GptGuids.apfs || typeGuid == GptGuids.hfs;

  double get sizeGb => length / (1024 * 1024 * 1024);
}

/// Membaca semua partisi dari disk fisik via DLL native.
Future<List<Partition>> readPartitions(int diskNumber) async {
  MacFsLibrary.ensureLoaded();
  final count = MacFsLibrary.partitionCount(diskNumber);
  if (count <= 0) return [];
  final parts = <Partition>[];
  for (var i = 0; i < count; i++) {
    final info = MacFsLibrary.partitionAt(diskNumber, i);
    if (info == null) continue;
    parts.add(Partition(
      index: i + 1,
      diskNumber: diskNumber,
      start: info.offset,
      length: info.length,
      typeGuid: info.guid,
      name: info.name,
    ));
  }
  return parts;
}

/// Memetakan huruf drive Windows (mis. "F") ke nomor disk fisik.
Future<int?> diskNumberForDriveLetter(String letter) async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    '(Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue).DiskNumber',
  ]);
  final text = (result.stdout as String).trim();
  return int.tryParse(text);
}

/// Daftar huruf drive yang punya volume terpasang.
Future<List<String>> mountedDriveLetters() async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    '(Get-Volume | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter) -join ","',
  ]);
  final text = (result.stdout as String).trim();
  if (text.isEmpty) return [];
  return text.split(',');
}