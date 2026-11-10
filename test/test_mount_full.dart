// Uji mount penuh: mount M:, baca file nyata, unmount.
import 'dart:io';

import 'package:macdrive_rescue/core/macfs_ffi.dart';

Future<void> main() async {
  MacFsLibrary.ensureLoaded();

  final mount = MacMount.mount(
    diskNumber: 2,
    offset: 209735680,
    length: 499898105856,
    kind: 0,
    volumeIndex: 0,
    mountPoint: 'M:',
  );
  if (mount == null) {
    print('MOUNT FAILED: ${MacMount.lastError}');
    exit(1);
  }
  print('mounted at: ${mount.mountPoint}');

  await Future<void>.delayed(const Duration(seconds: 2));

  // 1. Drive terlihat oleh Windows?
  final driveVisible = Directory('M:\\').existsSync();
  print('M:\\ exists: $driveVisible');

  // 2. Listing direktori root.
  try {
    final entries = Directory('M:\\').listSync().take(10);
    print('root entries: ${entries.map((e) => e.path.split('\\').last).toList()}');
  } catch (e) {
    print('listdir ERROR: $e');
  }

  // 3. Baca file yang sebelumnya diblokir MacDrive.
  final testPath = 'M:\\Users\\adidarmawan\\Desktop\\Config.plist';
  try {
    final file = File(testPath);
    if (file.existsSync()) {
      final length = file.lengthSync();
      final data = file.readAsBytesSync();
      final head = String.fromCharCodes(data.take(38));
      print('Config.plist via M: -> $length bytes, head: $head');
      print(length == 55944 ? 'PASS: ukuran benar' : 'FAIL: ukuran ${length}');
    } else {
      print('FAIL: file tidak ditemukan via M:');
    }
  } catch (e) {
    print('read ERROR: $e');
  }

  // 4. Cek navigasi folder bertingkat.
  try {
    final dir = Directory('M:\\Users\\adidarmawan\\Documents');
    final count = dir.listSync().length;
    print('Documents via M:: $count entries');
  } catch (e) {
    print('navigate ERROR: $e');
  }

  // 5. Coba tulis (harus ditolak - read-only).
  try {
    File('M:\\test-write.txt').writeAsStringSync('hello');
    print('WRITE SUCCEEDED - unexpected!');
  } catch (e) {
    print('write rejected (expected): ${e.runtimeType}');
  }

  mount.unmount();
  print('unmounted');
  await Future<void>.delayed(const Duration(seconds: 1));
  print('M:\\ exists after unmount: ${Directory('M:\\').existsSync()}');
  print('\nDONE');
}