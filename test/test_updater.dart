// Test: fungsi updater (cek versi & perbandingan semver).
import 'package:macdrive_rescue/core/updater.dart';

Future<void> main() async {
  // 1. Uji perbandingan semver.
  print('=== semver compare ===');
  final cases = [
    ('2.2.0', '2.1.0', 1),
    ('2.1', '2.1.0', 0),
    ('v2.3', '2.2.0', 1),
    ('2.1.0', '2.2.0', -1),
    ('2.10.0', '2.9.9', 1),
  ];
  for (final (a, b, expected) in cases) {
    final actual = compareVersions(a, b);
    final ok = (actual > 0 && expected > 0) ||
        (actual < 0 && expected < 0) ||
        (actual == 0 && expected == 0);
    print('compare($a, $b) = $actual (expect sign $expected) ${ok ? "OK" : "FAIL"}');
  }

  // 2. Uji cek update ke GitHub (repo live).
  print('\n=== check GitHub releases ===');
  try {
    final info = await Updater.check();
    if (info == null) {
      print('Tidak ada rilis?');
      return;
    }
    print('latest: ${info.latestVersion} (${info.tag})');
    print('current: $appVersion');
    print('isNewer: ${info.isNewer}');
    print('asset size: ${info.downloadSize} bytes');
    print('download url: ${info.downloadUrl}');
    print('notes length: ${info.releaseNotes.length} chars');
  } catch (e) {
    print('ERROR: $e');
    return;
  }
  print('\nDONE');
}