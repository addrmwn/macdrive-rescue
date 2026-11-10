/// Lokalisasi sederhana (English & Bahasa Indonesia).
///
/// Penggunaan:
///   final t = L.of(context);   // atau L.current bila tanpa context
///   Text(t.appTitle);
library;

import 'package:flutter/widgets.dart';

enum AppLanguage { english, indonesian }

class L {
  final AppLanguage language;
  const L(this.language);

  static AppLanguage _current = AppLanguage.indonesian;
  static AppLanguage get current => _current;
  static set current(AppLanguage value) {
    _current = value;
    _notifier.value = value;
  }

  static final ValueNotifier<AppLanguage> _notifier =
      ValueNotifier<AppLanguage>(AppLanguage.indonesian);
  static ValueNotifier<AppLanguage> get notifier => _notifier;

  static L of(BuildContext context) => L(_current);

  bool get isId => language == AppLanguage.indonesian;

  String _t(String id, String en) => isId ? id : en;

  // ---------------------------------------------------------------- umum
  String get appTitle => 'MacDrive Rescue';
  String get appTagline =>
      _t('Salin data drive Mac (APFS / HFS+) ke Windows',
          'Copy data from Mac drives (APFS / HFS+) to Windows');
  String get adminMode => _t('Mode Administrator', 'Administrator mode');
  String get noAdmin => _t('Tanpa Administrator', 'Without Administrator');
  String get language_ => _t('Bahasa', 'Language');

  // ---------------------------------------------------------------- kartu 1
  String get step1Title => _t('Pilih data dari drive Mac', 'Choose data from your Mac drive');
  String get step1Subtitle =>
      _t('dibaca langsung dari disk — aman, read-only',
          'read directly from disk — safe, read-only');
  String get drive => _t('Drive', 'Drive');
  String get rescan => _t('Pindai Ulang', 'Rescan');
  String get scanningDisks => _t('Memindai disk...', 'Scanning disks...');
  String get noMacDrive => _t('Tidak ada drive Mac terdeteksi', 'No Mac drive detected');
  String get chooseDrive => _t('Pilih drive', 'Choose drive');
  String get sourceFolder => _t('Folder sumber', 'Source');
  String get chooseItem => _t('Pilih Item...', 'Choose Items...');
  String get wholeVolume => _t('Seluruh Volume', 'Whole Volume');
  String get noSource => _t('Belum ada folder dipilih', 'No source chosen yet');
  String get pickSourceHint =>
      _t('Pilih drive, lalu pilih folder sumber', 'Choose a drive, then pick a source');
  String get wholeVolumeHint => _t('Seluruh isi volume akan disalin ke folder tujuan',
      'The entire volume will be copied to the destination');
  String get nItemsSelected => _t('item dipilih', 'items selected');

  // ---------------------------------------------------------------- kartu 2
  String get step2Title => _t('Simpan ke folder Windows', 'Save to a Windows folder');
  String get step2Subtitle => _t('folder sumber akan muncul di dalam folder ini',
      'the source will appear inside this folder');
  String get browse => _t('Telusuri...', 'Browse...');
  String get freeSpace => _t('Ruang tersedia', 'Free space');

  // ---------------------------------------------------------------- kartu 3
  String get step3Title => _t('Opsi penyalinan', 'Copy options');
  String get step3Subtitle =>
      _t('default sudah aman untuk kebanyakan orang', 'defaults are safe for most people');
  String get skipSystem => _t('Lewati file sistem Mac (.DS_Store, ._*)',
      'Skip Mac system files (.DS_Store, ._*)');
  String get skipBuild => _t('Lewati folder build/cache', 'Skip build/cache folders');
  String get skipApps => _t('Lewati .app/.framework', 'Skip .app/.framework');
  String get verifyHash => _t('Verifikasi hash', 'Verify hash');
  String get preserveTimes => _t('Pertahankan tanggal', 'Keep timestamps');
  String get ifExists => _t('Jika file sudah ada', 'If file exists');
  String get colonChar => _t("Karakter ':' jadi", "Replace ':' with");
  String get symlink => _t('Symlink', 'Symlink');
  String get skipHidden => _t('Lewati file tersembunyi', 'Skip hidden files');
  String get dryRun => _t('Simulasi saja', 'Dry run');

  // ---------------------------------------------------------------- aksi
  String get scanSource => _t('Pindai Sumber', 'Scan Source');
  String get startTransfer => _t('Mulai Transfer', 'Start Transfer');
  String get copyingEllipsis => _t('Menyalin...', 'Copying...');
  String get retryFailed => _t('Coba Lagi yang Gagal', 'Retry Failed');
  String get openDest => _t('Buka Folder Tujuan', 'Open Destination');
  String get cancel => _t('Batal', 'Cancel');

  // ---------------------------------------------------------------- progress
  String get pickAndScan => _t('Pilih folder sumber, lalu klik Pindai.',
      'Pick a source, then click Scan.');
  String get counting => _t('Menghitung file...', 'Counting files...');
  String get ready => _t('Siap menyalin.', 'Ready to copy.');
  String get copying => _t('Menyalin data...', 'Copying data...');
  String get copyDone => _t('Transfer selesai.', 'Transfer finished.');
  String get copyFailed => _t('Transfer gagal.', 'Transfer failed.');
  String get cancelled => _t('Transfer dibatalkan.', 'Transfer cancelled.');
  String get files => _t('file', 'files');
  String get folders => _t('folder', 'folders');
  String get file => _t('File', 'File');
  String get remaining => _t('Sisa', 'Left');
  String get starting => _t('Menyiapkan...', 'Preparing...');
  String get driveReady => _t('Drive siap:', 'Drive ready:');

  // ---------------------------------------------------------------- log
  String get activity => _t('Aktivitas', 'Activity');
  String get copiedLabel => _t('Tersalin:', 'Copied:');
  String get failedLabel => _t('GAGAL:', 'FAILED:');
  String get retrying => _t('Mencoba ulang', 'Retrying');
  String get simulate => _t('(simulasi)', '(dry run)');

  // ---------------------------------------------------------------- dialog browser
  String get pickFileOrFolder => _t('Pilih file atau folder di', 'Choose files or folders in');
  String get browserHint =>
      _t('Centang file/folder yang ingin disalin, lalu klik tombol di kanan bawah.',
          'Check files/folders to copy, then click the button on the bottom right.');
  String get selectedItems => _t('item dipilih', 'items selected');
  String get checkToCopy => _t('Centang file/folder yang ingin disalin',
      'Check the files/folders you want to copy');
  String get saveThisFolder => _t('Salin Folder Ini', 'Copy This Folder');
  String get saveItemCount => _t('Salin', 'Copy');

  // ---------------------------------------------------------------- dialog copy
  String get startCopyTitle => _t('Mulai menyalin?', 'Start copying?');
  String get willBeCopiedTo => _t('akan disalin ke:', 'will be copied to:');
  String get dryRunNote => _t('\n\nMode simulasi aktif - tidak ada file yang ditulis.',
      '\n\nDry run enabled - no files will be written.');
  String get start => _t('Mulai', 'Start');
  String get done => _t('Selesai', 'Done');
  String get copied => _t('File tersalin', 'Copied');
  String get skipped => _t('dilewati', 'skipped');
  String get failed => _t('gagal', 'failed');
  String get retryingFailed => _t('Mencoba ulang file yang gagal...',
      'Retrying failed files...');
  String get startRetry => _t('Mencoba ulang', 'Retrying');

  // ---------------------------------------------------------------- error
  String get failOpenVolume => _t('Gagal membuka volume:', 'Failed to open volume:');
  String get sourceNotFound => _t('File/folder tidak ditemukan:',
      'File/folder not found:');
  String get notEnoughSpace => _t('Ruang disk tujuan tidak cukup',
      'Not enough space on destination');
}