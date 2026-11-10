/// Auto-update dari GitHub Releases.
///
/// Alur:
///  1. `check()` — ambil rilis terbaru dari GitHub API, bandingkan versi.
///  2. `download()` — unduh `MacDriveRescue-win64.zip` dengan progress.
///  3. `applyAndRestart()` — ekstrak ke folder temp, jalankan skrip yang
///     menunggu aplikasi keluar, salin file baru menimpa folder instalasi,
///     lalu buka ulang aplikasi.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const appVersion = '2.2.0';

const _repoOwner = 'addrmwn';
const _repoName = 'macdrive-rescue';
const _assetName = 'MacDriveRescue-win64.zip';

class UpdateInfo {
  final String latestVersion; // tanpa 'v', mis. "2.2.0"
  final String tag; // mis. "v2.2"
  final String releaseNotes;
  final String releaseUrl;
  final String downloadUrl;
  final int downloadSize;
  final bool isNewer;

  const UpdateInfo({
    required this.latestVersion,
    required this.tag,
    required this.releaseNotes,
    required this.releaseUrl,
    required this.downloadUrl,
    required this.downloadSize,
    required this.isNewer,
  });
}

class UpdateException implements Exception {
  final String message;
  UpdateException(this.message);
  @override
  String toString() => message;
}

/// Membandingkan versi semver sederhana. Mengembalikan >0 bila a lebih baru.
int compareVersions(String a, String b) {
  List<int> parse(String value) {
    final cleaned = value.replaceAll(RegExp(r'^v'), '').split('+').first;
    return cleaned
        .split('.')
        .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9].*$'), '')) ?? 0)
        .toList();
  }

  final left = parse(a);
  final right = parse(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l - r;
  }
  return 0;
}

class Updater {
  /// Cek rilis terbaru di GitHub.
  static Future<UpdateInfo?> check() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(
          'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest'));
      request.headers.set('User-Agent', 'MacDriveRescue-Updater');
      request.headers.set('Accept', 'application/vnd.github+json');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw UpdateException(
            'GitHub API mengembalikan ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?) ?? '';
      final latest = tag.replaceAll(RegExp(r'^v'), '');
      final assets = (json['assets'] as List?) ?? [];
      String downloadUrl = '';
      int size = 0;
      for (final asset in assets) {
        final map = asset as Map<String, dynamic>;
        if (map['name'] == _assetName) {
          downloadUrl = (map['browser_download_url'] as String?) ?? '';
          size = (map['size'] as int?) ?? 0;
          break;
        }
      }
      if (downloadUrl.isEmpty) {
        throw UpdateException('Aset $_assetName tidak ditemukan pada rilis $tag');
      }
      return UpdateInfo(
        latestVersion: latest,
        tag: tag,
        releaseNotes: (json['body'] as String?) ?? '',
        releaseUrl: (json['html_url'] as String?) ?? '',
        downloadUrl: downloadUrl,
        downloadSize: size,
        isNewer: compareVersions(latest, appVersion) > 0,
      );
    } on SocketException catch (e) {
      throw UpdateException('Tidak ada koneksi internet: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// Mengunduh zip rilis terbaru. [onProgress] dipanggil (received, total).
  static Future<File> download(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      // Ikuti redirect GitHub (302 ke CDN).
      Future<HttpClientResponse> fetch(Uri uri, {int redirects = 0}) async {
        final request = await client.getUrl(uri);
        request.headers.set('User-Agent', 'MacDriveRescue-Updater');
        final response = await request.close();
        if ((response.statusCode == 301 ||
                response.statusCode == 302 ||
                response.statusCode == 307) &&
            redirects < 5) {
          final location = response.headers.value('location');
          await response.drain<void>();
          if (location != null) {
            return fetch(Uri.parse(location), redirects: redirects + 1);
          }
        }
        return response;
      }

      final response = await fetch(Uri.parse(info.downloadUrl));
      if (response.statusCode != 200) {
        throw UpdateException('Unduhan gagal (HTTP ${response.statusCode})');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : info.downloadSize;
      final temp = Directory.systemTemp.createTempSync('macfs_update_');
      final file = File('${temp.path}\\update.zip');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null) onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      if (total > 0 && received != total) {
        throw UpdateException(
            'Unduhan tidak lengkap ($received dari $total byte)');
      }
      return file;
    } finally {
      client.close(force: true);
    }
  }

  /// Ekstrak zip lalu jalankan skrip update; aplikasi akan menutup diri.
  /// Skrip menunggu proses ini selesai, menyalin file baru, dan membuka ulang.
  static Future<void> applyAndRestart(File zip) async {
    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final currentPid = pid;

    final temp = Directory.systemTemp.createTempSync('macfs_apply_');
    final extractDir = Directory('${temp.path}\\payload')..createSync();

    // Ekstrak dengan tar.exe bawaan Windows.
    final tar = await Process.run('tar', ['-xf', zip.path, '-C', extractDir.path]);
    if (tar.exitCode != 0) {
      throw UpdateException(
          'Gagal mengekstrak: ${tar.stderr.toString().trim()}');
    }

    final script = '''
@echo off
setlocal
:wait
tasklist /FI "PID eq $currentPid" 2>nul | find "$currentPid" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
robocopy "EXTRACT_PLACEHOLDER" "$installDir" /E /IS /NFL /NDL /NJH /NJS /R:3 /W:1 >nul
start "" "$exePath"
cd /d "%TEMP%"
rmdir /S /Q "TEMP_PLACEHOLDER" >nul 2>&1
del "%~f0" >nul 2>&1
'''
        .replaceAll("EXTRACT_PLACEHOLDER", extractDir.path)
        .replaceAll("TEMP_PLACEHOLDER", temp.path);

    final batPath = '${Directory.systemTemp.path}\\macfs_update_\${currentPid}.bat';
    await File(batPath).writeAsString(script, flush: true);

    await Process.start(
      'cmd.exe',
      ['/c', batPath],
      mode: ProcessStartMode.detached,
      workingDirectory: Directory.systemTemp.path,
    );
  }

}