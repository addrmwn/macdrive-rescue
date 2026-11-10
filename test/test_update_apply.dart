// Simulasi mekanisme apply update (tanpa menimpa instalasi asli).
// Meniru script yang digenerate Updater.applyAndRestart.
import 'dart:io';

Future<void> main() async {
  final base = Directory.systemTemp.createTempSync('macfs_apply_test_');
  final installDir = Directory('${base.path}\\install')..createSync();
  final payloadSrc = Directory('${base.path}\\src')..createSync();

  // 1. "Instalasi lama" berisi file versi lama.
  File('${installDir.path}\\app.txt').writeAsStringSync('OLD');
  File('${installDir.path}\\data.txt').writeAsStringSync('keep me');

  // 2. Payload "versi baru": app.txt baru + file tambahan.
  File('${payloadSrc.path}\\app.txt').writeAsStringSync('NEW');
  File('${payloadSrc.path}\\extra.txt').writeAsStringSync('extra');

  // 3. Zip payload dengan 7z (seperti make_portable).
  final zipPath = '${base.path}\\payload.zip';
  final zip = await Process.run(
      r'C:\Program Files\7-Zip\7z.exe', ['a', '-tzip', zipPath, '*'],
      workingDirectory: payloadSrc.path);
  if (zip.exitCode != 0) {
    print('ZIP FAIL: ${zip.stdout}');
    exit(1);
  }

  // 4. Ekstrak zip dengan tar (seperti updater).
  final extractDir = Directory('${base.path}\\extract')..createSync();
  final tar = await Process.run('tar', ['-xf', zipPath, '-C', extractDir.path]);
  if (tar.exitCode != 0) {
    print('TAR FAIL: ${tar.stderr}');
    exit(1);
  }
  print('extracted: ${extractDir.listSync().map((e) => e.path.split('\\').last).toList()}');

  // 5. Jalankan skrip update yang meniru applyAndRestart (PID palsu yang sudah mati).
  const deadPid = 999999;
  final script = '''
@echo off
setlocal
:wait
tasklist /FI "PID eq $deadPid" 2>nul | find "$deadPid" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
robocopy "${extractDir.path}" "${installDir.path}" /E /IS /NFL /NDL /NJH /NJS /R:3 /W:1 >nul
cd /d "%TEMP%"
del "%~f0" >nul 2>&1
''';
  final batPath = '${base.path}\\apply.bat';
  File(batPath).writeAsStringSync(script);
  final run = await Process.run('cmd.exe', ['/c', batPath]);
  print('script exit: ${run.exitCode}');

  // 6. Verifikasi.
  final appContent = File('${installDir.path}\\app.txt').readAsStringSync();
  final extraExists = File('${installDir.path}\\extra.txt').existsSync();
  final dataKept = File('${installDir.path}\\data.txt').readAsStringSync();

  print('app.txt: $appContent (expect NEW)');
  print('extra.txt: ${extraExists ? "ada" : "TIDAK ADA"} (expect ada)');
  print('data.txt: $dataKept (expect "keep me" - file lama dipertahankan)');

  final pass = appContent == 'NEW' && extraExists && dataKept == 'keep me';
  print(pass ? '\nPASS: mekanisme update OK' : '\nFAIL');

  base.deleteSync(recursive: true);
}