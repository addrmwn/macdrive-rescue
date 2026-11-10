// Diagnostik mount: tahan N: hidup lalu periksa dari luar.
import 'dart:io';

import 'package:macdrive_rescue/core/macfs_ffi.dart';

Future<void> main() async {
  MacFsLibrary.ensureLoaded();
  print('winfsp available: ${WinFspChecker.available}');

  final mount = MacMount.mount(
    diskNumber: 2,
    offset: 209735680,
    length: 499898105856,
    kind: 0,
    volumeIndex: 0,
    mountPoint: 'N:',
  );
  print('mount: ${mount != null} err: ${MacMount.lastError}');
  if (mount == null) exit(1);
  print('mountpoint: ${mount.mountPoint} active: ${mount.isActive}');

  await Future<void>.delayed(const Duration(seconds: 20));
  mount.unmount();
  print('unmounted');
}