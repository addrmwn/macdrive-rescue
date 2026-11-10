import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:macdrive_rescue/core/discovery.dart';
import 'package:macdrive_rescue/core/engine.dart';
import 'package:macdrive_rescue/core/l10n.dart';
import 'package:macdrive_rescue/core/macfs_ffi.dart';
import 'package:macdrive_rescue/core/settings.dart';
import 'package:macdrive_rescue/core/updater.dart';
import 'package:macdrive_rescue/ui/theme.dart';
import 'package:macdrive_rescue/ui/widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _logController = ScrollController();
  final _logEntries = <_LogEntry>[];
  final _destController = TextEditingController(
    text: '${Platform.environment['USERPROFILE'] ?? 'C:'}\\Documents\\Mac Transfer',
  );

  List<MacDrive> _drives = [];
  MacDrive? _selectedDrive;
  List<String> _sourcePaths = const []; // relatif terhadap volume
  String _sourceLabel = 'Belum ada folder dipilih';
  String _sourceHint = 'Pilih drive, lalu pilih folder sumber';
  bool _isAdmin = false;
  bool _busy = false;
  bool _scanning = false;
  bool _copying = false;

  ScanResult? _scanResult;
  double _progress = 0;
  String _progressText = '0%';
  String _speed = '';
  String _eta = '';
  String _currentFile = '';
  String _summary = 'Pilih folder sumber, lalu klik Pindai.';
  String _status = 'Menyiapkan...';
  String _freeSpace = '';
  void Function()? _cancelCopy;
  // File yang gagal pada transfer terakhir (untuk tombol "Coba Lagi").
  List<FileTask> _failedFiles = [];
  String _lastDestRoot = '';

  // Auto-update
  bool _checkingUpdate = false;
  UpdateInfo? _availableUpdate;
  double _updateProgress = 0;
  bool _downloadingUpdate = false;

  // Opsi
  bool _optSkipSystem = true;
  bool _optSkipHidden = false;
  bool _optSkipBuild = true;
  bool _optSkipApps = true;
  bool _optVerify = true;
  bool _optPreserveTimes = true;
  bool _optDryRun = false;
  String _optOverwrite = 'skip';
  String _optSymlinks = 'skip';
  String _optColon = '-';

  SavedSettings? _settings;

  Future<void> _loadSettings() async {
    final s = await SavedSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = s;
      if (s.destPath != null && s.destPath!.isNotEmpty) {
        _destController.text = s.destPath!;
      }
      _optSkipSystem = s.skipSystem;
      _optSkipHidden = s.skipHidden;
      _optSkipBuild = s.skipBuild;
      _optSkipApps = s.skipApps;
      _optPreserveTimes = s.preserveTimes;
      _optOverwrite = s.overwrite;
      _optSymlinks = s.symlinks;
      _optColon = s.colonReplacement;
      L.current = s.language == 'en'
          ? AppLanguage.english
          : AppLanguage.indonesian;
    });
    _updateFreeSpace();
  }

  void _saveSettings() {
    SavedSettings.save(
      destPath: _destController.text.trim(),
      lastVolumeName: _selectedDrive?.volumeName,
      skipSystem: _optSkipSystem,
      skipHidden: _optSkipHidden,
      skipBuild: _optSkipBuild,
      skipApps: _optSkipApps,
      preserveTimes: _optPreserveTimes,
      overwrite: _optOverwrite,
      symlinks: _optSymlinks,
      colonReplacement: _optColon,
      language: L.current == AppLanguage.english ? 'en' : 'id',
    );
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkAdmin().then((ok) {
      setState(() => _isAdmin = ok);
      if (ok) {
        _scanDrives();
      } else {
        _setStatus('Berjalan tanpa hak Administrator — drive Mac tidak bisa dibaca.');
        _log('PERINGATAN: tanpa Administrator, pembacaan disk mentah akan gagal.',
            level: _LogLevel.warn);
      }
    });
    _updateFreeSpace();
    _destController.addListener(_updateFreeSpace);
    // Cek update di latar belakang (tidak mengganggu startup).
    _autoCheckUpdate();
  }

  Future<void> _autoCheckUpdate() async {
    try {
      await Future<void>.delayed(const Duration(seconds: 4));
      final info = await Updater.check();
      if (!mounted || info == null) return;
      setState(() => _availableUpdate = info);
      if (info.isNewer) {
        _log('${_t.updateAvailable} ${info.tag}', level: _LogLevel.ok);
      }
    } catch (_) {
      // Diamkan — auto-check tidak boleh mengganggu pengguna.
    }
  }

  @override
  void dispose() {
    _destController.dispose();
    _logController.dispose();
    super.dispose();
  }

  // ----------------------------------------------------------- utilities
  Future<bool> _checkAdmin() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")',
      ]);
      return (result.stdout as String).trim().toLowerCase() == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> _relaunchAsAdmin() async {
    final exe = Platform.resolvedExecutable;
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Start-Process -FilePath "${exe.replaceAll('"', '`"')}" -Verb RunAs',
      ]);
      exit(0);
    } catch (_) {}
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  void _log(String message, {_LogLevel level = _LogLevel.info}) {
    if (!mounted) return;
    setState(() {
      _logEntries.add(_LogEntry(
        time: DateTime.now(),
        message: message,
        level: level,
      ));
      if (_logEntries.length > 500) {
        _logEntries.removeAt(0);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logController.hasClients) {
        _logController.jumpTo(_logController.position.maxScrollExtent);
      }
    });
  }

  void _updateFreeSpace() {
    final dest = _destController.text.trim();
    if (dest.isEmpty) return;
    try {
      var root = dest;
      while (root.isNotEmpty && !Directory(root).existsSync()) {
        final idx = root.lastIndexOf(Platform.pathSeparator);
        if (idx <= 0) {
          root = '';
          break;
        }
        root = root.substring(0, idx);
      }
      if (root.isEmpty) {
        setState(() => _freeSpace = '');
        return;
      }
      final drive = root.substring(0, 2);
      final result = _freeSpaceOf(drive);
      if (result != null) {
        setState(() => _freeSpace = L.current == AppLanguage.english
            ? '${_t.freeSpace} on ${drive.toUpperCase()}: ${result}'
            : '${_t.freeSpace} di ${drive.toUpperCase()}: ${result}');
      }
    } catch (_) {}
  }

  String? _freeSpaceOf(String driveLetter) {
    try {
      final result = Process.runSync('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-Volume -DriveLetter ${driveLetter.replaceAll(':', '')}).SizeRemaining',
      ]);
      final bytes = int.tryParse((result.stdout as String).trim());
      if (bytes == null) return null;
      return _humanSize(bytes);
    } catch (_) {
      return null;
    }
  }

  static String _humanSize(num bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return unit == 0
        ? '${value.toInt()} ${units[unit]}'
        : '${value.toStringAsFixed(1)} ${units[unit]}';
  }

  static String _humanSpeed(double bytesPerSec) => '${_humanSize(bytesPerSec)}/s';

  static String _humanEta(double? seconds) {
    if (seconds == null || seconds.isNaN || seconds < 0 || seconds > 86400 * 7) {
      return '--:--';
    }
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ------------------------------------------------------------ scanning
  Future<void> _scanDrives() async {
    if (!_isAdmin) {
      await _relaunchAsAdmin();
      return;
    }
    setState(() {
      _busy = true;
      _selectedDrive = null;
      _sourcePaths = const [];
      _scanResult = null;
      _drives = [];
      _sourceLabel = _t.noSource;
      _sourceHint = _t.pickSourceHint;
    });
    _setStatus(_t.scanningDisks);
    try {
      final drives = await scanMacDrives();
      if (!mounted) return;
      setState(() {
        _drives = drives;
        _busy = false;
      });
      final usable = drives.where((d) => d.isUsable).toList();
      if (usable.isNotEmpty) {
        _log('Ditemukan ${usable.length} drive Mac yang bisa dibaca.', level: _LogLevel.ok);
        final last = _settings?.lastVolumeName;
        MacDrive pick = usable.first;
        if (last != null) {
          for (final d in usable) {
            if (d.volumeName == last) {
              pick = d;
              break;
            }
          }
        }
        _selectDrive(pick);
      } else {
        _log('Tidak ada drive Mac yang bisa dibaca.', level: _LogLevel.warn);
        _setStatus('Tidak ada drive Mac terdeteksi. Pastikan drive terpasang, lalu klik Pindai Ulang.');
      }
      for (final d in drives.where((d) => !d.isUsable)) {
        _log('Tidak bisa dipakai: ${d.label}', level: _LogLevel.warn);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _log('Gagal memindai disk: $e', level: _LogLevel.error);
      _setStatus('Gagal memindai disk.');
    }
  }

  void _selectDrive(MacDrive drive) {
    setState(() {
      _selectedDrive = drive;
      _sourcePaths = const [];
      _scanResult = null;
      _sourceLabel = drive.volumeName;
      _sourceHint = _t.wholeVolumeHint;
      _summary = _t.pickAndScan;
    });
    _setStatus('${_t.driveReady} ${drive.volumeName}');
    _log('Drive dibuka: ${drive.volumeName} (${drive.kindLabel})');
  }

  Future<void> _browseFolders() async {
    final drive = _selectedDrive;
    if (drive == null) return;
    final result = await showDialog<FolderSelection>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FolderBrowserDialog(drive: drive),
    );
    if (result == null || !mounted) return;
    setState(() {
      _sourcePaths = result.paths;
      if (result.paths.isEmpty) {
        _sourceLabel = drive.volumeName;
        _sourceHint = _t.wholeVolumeHint;
      } else if (result.paths.length == 1) {
        _sourceLabel = result.names.first;
        _sourceHint = L.current == AppLanguage.english
            ? '${result.names.first} will be copied to the destination'
            : '${result.names.first} akan disalin ke folder tujuan';
      } else {
        _sourceLabel = '${result.paths.length} ${_t.nItemsSelected}';
        _sourceHint = result.names.join(', ');
      }
      _scanResult = null;
      _failedFiles.clear();
    });
    _log('Sumber dipilih: ${result.names.join(', ')}');
    await _scanSource();
  }

  Future<void> _pickDestination() async {
    // Dialog pilih folder sederhana berbasis drive Windows.
    final dir = await _pickWindowsDirectory();
    if (dir != null) {
      _destController.text = dir;
    }
  }

  Future<String?> _pickWindowsDirectory() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        '''
Add-Type -AssemblyName System.Windows.Forms;
\$dialog = New-Object System.Windows.Forms.FolderBrowserDialog;
\$dialog.Description = 'Pilih folder tujuan';
\$dialog.ShowNewFolderButton = \$true;
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output \$dialog.SelectedPath
}
''',
      ]);
      final text = (result.stdout as String).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  TransferOptions _options() => TransferOptions(
        skipSystem: _optSkipSystem,
        skipHidden: _optSkipHidden,
        skipBuildDirs: _optSkipBuild,
        skipAppBundles: _optSkipApps,
        overwrite: _optOverwrite,
        verify: _optVerify,
        preserveTimes: _optPreserveTimes,
        symlinks: _optSymlinks,
        colonReplacement: _optColon,
        dryRun: _optDryRun,
      );

  Future<void> _scanSource() async {
    final drive = _selectedDrive;
    if (drive == null || _scanning || _copying) return;
    setState(() {
      _scanning = true;
      _progress = 0;
      _progressText = '0%';
      _summary = _t.counting;
    });
    _setStatus(_t.counting);
    try {
final result = await scanVolume(
        diskNumber: drive.diskNumber,
        offset: drive.partition.start,
        length: drive.partition.length,
        kind: drive.fsKind,
        volumeIndex: drive.volumeIndex,
        startPaths: _sourcePaths,
        options: _options(),
      );
      if (!mounted) return;
      setState(() {
        _scanResult = result;
        _scanning = false;
        _summary =
            '${result.files.length} file • ${result.dirs.length} folder • ${_humanSize(result.totalBytes)}';
      });
      _setStatus(_t.ready);
      _log(
        'Siap: ${result.files.length} file, ${result.dirs.length} folder, total ${_humanSize(result.totalBytes)}.',
        level: _LogLevel.ok,
      );
      if (result.skippedFiles > 0 || result.skippedDirs > 0) {
        _log('Dilewati otomatis: ${result.skippedFiles} file dan ${result.skippedDirs} folder sistem/build.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      _log('Gagal memindai: $e', level: _LogLevel.error);
      _setStatus('Gagal menghitung file.');
    }
  }

  // ---------------------------------------------------------------- copy
  /// Menyalin [scan]. Bila [onlyFiles] diberikan (retry), hanya file itu
  /// yang disalin dan dialog konfirmasi dilewati.
  Future<void> _startCopy({List<FileTask>? onlyFiles}) async {
    final drive = _selectedDrive;
    final scan = _scanResult;
    if (drive == null || scan == null) return;
    final isRetry = onlyFiles != null && onlyFiles.isNotEmpty;
    final filesToCopy = isRetry ? onlyFiles : scan.files;
    final dirsToCopy = isRetry ? const <DirTask>[] : scan.dirs;
    final totalBytes = isRetry
        ? filesToCopy.fold<int>(0, (sum, f) => sum + f.size)
        : scan.totalBytes;
    final dest = _destController.text.trim();
    if (dest.isEmpty) {
      _log('Folder tujuan belum dipilih.', level: _LogLevel.warn);
      return;
    }
    try {
      Directory(dest).createSync(recursive: true);
    } catch (e) {
      _log('Tidak bisa membuat folder tujuan: $e', level: _LogLevel.error);
      return;
    }

    if (!isRetry) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Mulai menyalin?'),
          content: Text(
            '${filesToCopy.length} file (${_humanSize(totalBytes)}) akan disalin ke:\n\n$dest'
            '${_optDryRun ? '\n\nMode simulasi aktif — tidak ada file yang ditulis.' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mulai'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() {
      _copying = true;
      _progress = 0;
      _progressText = '0%';
      _speed = '';
      _eta = '';
      _currentFile = '';
      _summary = isRetry ? _t.retryingFailed : _t.copying;
    });
    _setStatus(_t.copying);
    _log('Mulai menyalin ke: $dest');
    _saveSettings();

    var bytesDone = 0;
    final started = DateTime.now();

void onEvent(Map<String, dynamic> event) {
      if (!mounted) return;
      final kind = event['kind'];
      if (kind == 'progress') {
        bytesDone += event['bytes'] as int;
        final total = totalBytes <= 0 ? 1 : totalBytes;
        final elapsed = DateTime.now().difference(started).inMilliseconds / 1000.0;
        final speed = elapsed <= 0 ? 0.0 : bytesDone / elapsed;
        final pct = (bytesDone * 100.0 / total).clamp(0.0, 100.0);
        final index = event['fileIndex'] as int?;
        final fileTotal = event['fileTotal'] as int?;
        setState(() {
          _progress = pct / 100.0;
          _progressText = '${pct.toStringAsFixed(1)}%';
          _speed = _humanSpeed(speed);
          _eta = 'Sisa ${_humanEta(speed > 0 ? (total - bytesDone) / speed : null)}';
          final rel = event['rel'] as String? ?? '';
          _currentFile = (index != null && fileTotal != null)
              ? 'File $index/$fileTotal  $rel'
              : rel;
        });
      } else if (kind == 'retry') {
        _log(
          'Mencoba ulang (${event['attempt']}/3): ${event['rel'] ?? ''}',
          level: _LogLevel.warn,
        );
      } else if (kind == 'file') {
        final status = event['status'];
        final rel = event['rel'] as String? ?? '';
        if (status == 'error') {
          _log('GAGAL: $rel - ${event['error'] ?? ''}', level: _LogLevel.error);
        } else if (status == 'ok') {
          final index = event['index'] as int? ?? 0;
          if (index % 200 == 0) _log('Tersalin: $rel');
        } else if (status == 'dry') {
          _log('(simulasi) $rel');
        }
      } else if (kind == 'done') {
        final copied = event['filesCopied'] as int;
        final skipped = event['filesSkipped'] as int;
        final failed = event['filesFailed'] as int;
        final bytes = event['bytesCopied'] as int;
        final duration = (event['durationSeconds'] as num).toDouble();
        final errors = (event['errors'] as List).cast<List>();
        final failedTasks = (event['failedTasks'] as List? ?? [])
            .map((e) {
              final map = e as Map;
              return FileTask(
                List<String>.from(map['rel'] as List),
                List<String>.from(map['dest'] as List),
                map['size'] as int,
              );
            })
            .toList();
        setState(() {
          _copying = false;
          _progress = 1.0;
          _progressText = '100%';
          _eta = '';
          _currentFile = '';
          _speed = _humanSpeed(duration > 0 ? bytes / duration : 0);
          _summary =
              'Selesai: $copied file tersalin (${_humanSize(bytes)}), $skipped dilewati, $failed gagal.';
          _failedFiles = failedTasks;
          _lastDestRoot = dest;
        });
        _setStatus(_t.copyDone);
        _log(
          'Selesai: $copied file tersalin (${_humanSize(bytes)}), $skipped dilewati, $failed gagal.',
          level: _LogLevel.ok,
        );

        // Tulis laporan CSV.
        try {
          final reportDir = Directory('$dest\\_laporan');
          reportDir.createSync(recursive: true);
          final stamp = DateTime.now()
              .toIso8601String()
              .replaceAll(':', '')
              .replaceAll('-', '')
              .split('.')
              .first;
          final manifest = (event['manifest'] as List)
              .map((e) => List<String>.from(e as List))
              .toList();
          final errorRows = errors
              .map((e) => List<String>.from(e as List))
              .toList();
          writeManifestCsv('${reportDir.path}\\manifest-$stamp.csv', manifest);
          if (errorRows.isNotEmpty) {
            writeErrorCsv('${reportDir.path}\\error-$stamp.csv', errorRows);
          }
        } catch (e) {
          _log('Gagal menulis laporan CSV: $e', level: _LogLevel.warn);
        }

        if (failed > 0) {
          _log('$failed file gagal — lihat potongan log di atas.', level: _LogLevel.error);
        }
      }
    }

    try {
      await copyFiles(
        diskNumber: drive.diskNumber,
        offset: drive.partition.start,
        length: drive.partition.length,
        kind: drive.fsKind,
        volumeIndex: drive.volumeIndex,
        destRoot: dest,
        options: _options(),
        files: filesToCopy,
        dirs: dirsToCopy,
        onEvent: onEvent,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _copying = false);
      _log('Transfer gagal: $e', level: _LogLevel.error);
      _setStatus(_t.copyFailed);
    }
  }

  Future<void> _retryFailed() async {
    if (_failedFiles.isEmpty || _copying || _scanning) return;
    final count = _failedFiles.length;
    _log('Mencoba ulang $count file yang gagal...', level: _LogLevel.warn);
    await _startCopy(onlyFiles: List<FileTask>.from(_failedFiles));
  }

  void _openDestination() {
    final dest = _destController.text.trim();
    if (dest.isEmpty) return;
    try {
      Directory(dest).createSync(recursive: true);
      Process.start('explorer.exe', [dest], mode: ProcessStartMode.detached);
    } catch (_) {}
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final usable = _drives.where((d) => d.isUsable).toList();
    return Scaffold(
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSourceCard(usable),
                  const SizedBox(height: 12),
                  _buildDestinationCard(),
                  const SizedBox(height: 12),
                  _buildOptionsCard(),
                  const SizedBox(height: 14),
                  _buildActionRow(),
                  const SizedBox(height: 12),
                  _buildProgressCard(),
                  const SizedBox(height: 12),
                  _buildLogCard(),
                ],
              ),
            ),
          ),
          _buildStatusBar(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: AppColors.headerBg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 14),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(Icons.storage_rounded,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'MacDrive Rescue',
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _t.appTagline,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11.5),
                    ),
                  ],
                ),
                const Spacer(),
                _buildLanguageSelector(),
                const SizedBox(width: 10),
                StatusBadge(
                  text: _isAdmin ? _t.adminMode : _t.noAdmin,
                  color: _isAdmin ? AppColors.green : AppColors.red,
                  background:
                      _isAdmin ? const Color(0xFF173B26) : const Color(0xFF3B1F1F),
                ),
              ],
            ),
          ),
          const Divider(height: 2, thickness: 2, color: AppColors.accent),
        ],
      ),
    );
  }

  L get _t => L(L.current);

  Widget _buildLanguageSelector() {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.cardInner,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<AppLanguage>(
          value: L.current,
          isDense: true,
          dropdownColor: AppColors.cardInner,
          style: const TextStyle(color: AppColors.text, fontSize: 12),
          icon: const Icon(Icons.language_rounded,
              color: AppColors.muted, size: 15),
          items: const [
            DropdownMenuItem(
                value: AppLanguage.indonesian, child: Text('Indonesia')),
            DropdownMenuItem(
                value: AppLanguage.english, child: Text('English')),
          ],
          onChanged: (v) {
            if (v != null) {
              setState(() => L.current = v);
              _saveSettings();
            }
          },
        ),
      ),
    );
  }

  Widget _buildSourceCard(List<MacDrive> usable) {
    return StepCard(
      step: '1',
      title: _t.step1Title,
      subtitle: _t.step1Subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FieldLabel(_t.drive),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.cardInner,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<MacDrive>(
                      isExpanded: true,
                      value: usable.contains(_selectedDrive)
                          ? _selectedDrive
                          : null,
                      hint: Text(
                        _busy
                            ? _t.scanningDisks
                            : usable.isEmpty
                                ? _t.noMacDrive
                                : _t.chooseDrive,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 13),
                      ),
                      dropdownColor: AppColors.cardInner,
                      style: const TextStyle(
                          color: AppColors.text, fontSize: 13),
                      items: usable
                          .map((d) => DropdownMenuItem(
                                value: d,
                                child: Text(d.label,
                                    overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: _copying || _scanning
                          ? null
                          : (d) {
                              if (d != null) _selectDrive(d);
                            },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SecondaryButton(
                label: _t.rescan,
                icon: Icons.refresh_rounded,
                onPressed: _busy ? null : _scanDrives,
              ),
            ],
          ),
          const SizedBox(height: 10),
          InnerBox(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FieldLabel(_t.sourceFolder),
                      const SizedBox(height: 4),
                      Text(
                        _sourceLabel,
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _sourceHint,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
const SizedBox(width: 12),
                SizedBox(
                  width: 160,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PrimaryButton(
                        label: _t.chooseItem,
                        icon: Icons.folder_open_rounded,
                        onPressed: (_selectedDrive == null ||
                                _copying ||
                                _scanning)
                            ? null
                            : _browseFolders,
                      ),
                      const SizedBox(height: 8),
                      SecondaryButton(
                        label: _t.wholeVolume,
                        icon: Icons.album_rounded,
                        onPressed: (_selectedDrive == null ||
                                _copying ||
                                _scanning)
                            ? null
                            : () {
                              setState(() {
                                _sourcePaths = const [];
                                _sourceLabel = _selectedDrive!.volumeName;
                                _sourceHint = _t.wholeVolumeHint;
                                _scanResult = null;
                              });
                              _scanSource();
},
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDestinationCard() {
    return StepCard(
      step: '2',
      title: _t.step2Title,
      subtitle: _t.step2Subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _destController,
                  enabled: !_copying,
                  style: const TextStyle(color: AppColors.text, fontSize: 13),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.cardInner,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SecondaryButton(
                label: _t.browse,
                icon: Icons.folder_rounded,
                onPressed: _copying ? null : _pickDestination,
              ),
            ],
          ),
          if (_freeSpace.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _freeSpace,
              style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionsCard() {
    return StepCard(
      step: '3',
      title: _t.step3Title,
      subtitle: _t.step3Subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              _check(_t.skipSystem, _optSkipSystem,
                  (v) => setState(() => _optSkipSystem = v)),
              _check(_t.skipBuild, _optSkipBuild,
                  (v) => setState(() => _optSkipBuild = v)),
              _check(_t.skipApps, _optSkipApps,
                  (v) => setState(() => _optSkipApps = v)),
              _check(_t.verifyHash, _optVerify,
                  (v) => setState(() => _optVerify = v)),
              _check(_t.preserveTimes, _optPreserveTimes,
                  (v) => setState(() => _optPreserveTimes = v)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                FieldLabel(_t.ifExists),
                const SizedBox(width: 8),
                _dropdown(_optOverwrite, const ['skip', 'overwrite', 'rename'],
                    (v) => setState(() => _optOverwrite = v)),
              ]),
              Row(mainAxisSize: MainAxisSize.min, children: [
                FieldLabel(_t.colonChar),
                const SizedBox(width: 8),
                _dropdown(
                    _optColon,
                    const ['-', '_', '：'],
                    (v) => setState(() => _optColon = v),
                    width: 64),
              ]),
              Row(mainAxisSize: MainAxisSize.min, children: [
                FieldLabel(_t.symlink),
                const SizedBox(width: 8),
                _dropdown(_optSymlinks, const ['skip', 'follow'],
                    (v) => setState(() => _optSymlinks = v)),
              ]),
              _check(_t.skipHidden, _optSkipHidden,
                  (v) => setState(() => _optSkipHidden = v)),
              _check(_t.dryRun, _optDryRun,
                  (v) => setState(() => _optDryRun = v)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: Checkbox(
            value: value,
            onChanged: _copying ? null : (v) => onChanged(v ?? false),
            activeColor: AppColors.accent,
            side: const BorderSide(color: AppColors.muted, width: 1.4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(width: 7),
        Text(label,
            style: const TextStyle(color: AppColors.text, fontSize: 12.5)),
      ],
    );
  }

  Widget _dropdown(String value, List<String> values, ValueChanged<String> onChanged,
      {double width = 110}) {
    return Container(
      width: width,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.cardInner,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AppColors.cardInner,
          style: const TextStyle(color: AppColors.text, fontSize: 12),
          icon: const Icon(Icons.arrow_drop_down,
              color: AppColors.muted, size: 18),
          items: values
              .map((v) => DropdownMenuItem(value: v, child: Text(v)))
              .toList(),
          onChanged: _copying ? null : (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        SecondaryButton(
          label: _t.scanSource,
          icon: Icons.search_rounded,
          onPressed: (_selectedDrive == null || _scanning || _copying)
              ? null
              : _scanSource,
        ),
        const SizedBox(width: 8),
        PrimaryButton(
          label: _copying ? _t.copyingEllipsis : _t.startTransfer,
          icon: Icons.play_arrow_rounded,
          onPressed: (_scanResult == null || _scanning || _copying)
              ? null
              : _startCopy,
        ),
        if (_failedFiles.isNotEmpty && !_copying && !_scanning) ...[
          const SizedBox(width: 8),
          SecondaryButton(
            label: '${_t.retryFailed} (${_failedFiles.length})',
            icon: Icons.replay_rounded,
            onPressed: _retryFailed,
          ),
        ],
        const SizedBox(width: 8),
        SecondaryButton(
          label: _t.openDest,
          icon: Icons.folder_special_rounded,
          onPressed: _openDestination,
        ),
        const Spacer(),
        if (_scanning || _copying)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildProgressCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _summary,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                _progressText,
                style: const TextStyle(
                  color: AppColors.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 12,
              backgroundColor: AppColors.cardInner,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppColors.accent),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: Text(
                  _currentFile,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ),
              if (_speed.isNotEmpty)
                Text(_speed,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11.5)),
              if (_eta.isNotEmpty) ...[
                const SizedBox(width: 14),
                Text(_eta,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11.5)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLogCard() {
    return Container(
      height: 170,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Text(
              _t.activity,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              decoration: BoxDecoration(
                color: AppColors.headerBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Scrollbar(
                controller: _logController,
                child: ListView.builder(
                  controller: _logController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  itemCount: _logEntries.length,
                  itemBuilder: (_, i) {
                    final entry = _logEntries[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Text(
                        '[${entry.time.hour.toString().padLeft(2, '0')}:${entry.time.minute.toString().padLeft(2, '0')}:${entry.time.second.toString().padLeft(2, '0')}] ${entry.message}',
                        style: TextStyle(
                          color: entry.color,
                          fontSize: 11.5,
                          fontFamily: 'Consolas',
                          height: 1.35,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ================================================================ update
  Future<void> _manualCheckUpdate() async {
    setState(() => _checkingUpdate = true);
    _setStatus(_t.checkingUpdate);
    try {
      final info = await Updater.check();
      if (!mounted) return;
      setState(() {
        _checkingUpdate = false;
        _availableUpdate = info;
      });
      if (info == null || !info.isNewer) {
        _setStatus(_t.upToDate);
        _log(_t.upToDate, level: _LogLevel.ok);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${_t.upToDate} (v$appVersion)'),
              backgroundColor: AppColors.cardInner,
            ),
          );
        }
        return;
      }
      _log('${_t.updateAvailable} ${info.tag}', level: _LogLevel.ok);
      if (mounted) await _showUpdateDialog(info);
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      _log('${_t.checkUpdateFailed}: $e', level: _LogLevel.error);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_t.checkUpdateFailed}: $e'),
            backgroundColor: AppColors.cardInner,
          ),
        );
      }
    }
  }

  Future<void> _showUpdateDialog(UpdateInfo info) async {
    setState(() => _updateProgress = 0);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded,
                color: AppColors.accent, size: 22),
            const SizedBox(width: 10),
            Text(_t.updateAvailable,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.cardInner,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${_t.currentVersion}: v$appVersion',
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 12.5)),
                    ),
                    Expanded(
                      child: Text('${_t.newVersion}: ${info.tag}'
                          '${info.downloadSize > 0 ? ' (${_HomeScreenState._humanSize(info.downloadSize)})' : ''}',
                          style: const TextStyle(
                              color: AppColors.green,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
              if (info.releaseNotes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(_t.releaseNotes,
                    style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: Text(
                      info.releaseNotes
                          .replaceAll(RegExp(r'^#+ ', multiLine: true), '')
                          .replaceAll('**', '')
                          .replaceAll('`', ''),
                      style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                          height: 1.45),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: Text(_t.later),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'update'),
            icon: const Icon(Icons.download_rounded, size: 16),
            label: Text(_t.updateNow),
          ),
        ],
      ),
    );
    if (action == 'update' && mounted) {
      await _downloadAndApplyUpdate(info);
    }
  }

  Future<void> _downloadAndApplyUpdate(UpdateInfo info) async {
    setState(() {
      _downloadingUpdate = true;
      _updateProgress = 0;
    });
    _setStatus(_t.downloadingUpdate);
    try {
      final zip = await Updater.download(
        info,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _updateProgress = (received / total).clamp(0.0, 1.0));
        },
      );
      if (!mounted) return;
      _log('${_t.updateReady} (${_HomeScreenState._humanSize(zip.lengthSync())})',
          level: _LogLevel.ok);
      _setStatus(_t.applyingUpdate);

      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_t.updateReady),
          content: Text(_t.applyingUpdate),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.updateNow),
            ),
          ],
        ),
      );
      if (confirm == true && mounted) {
        await Updater.applyAndRestart(zip);
        exit(0);
      } else {
        setState(() => _downloadingUpdate = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloadingUpdate = false);
      _log('${_t.updateFailed}: $e', level: _LogLevel.error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_t.updateFailed}: $e'),
          backgroundColor: AppColors.cardInner,
        ),
      );
    }
  }

  Widget _buildStatusBar() {
    return Container(
      color: AppColors.headerBg,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      child: Row(
        children: [
          Text(
            _status,
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
          const Spacer(),
          if (_checkingUpdate || _downloadingUpdate) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 8),
          ],
          InkWell(
            onTap: (_checkingUpdate || _downloadingUpdate) ? null : _manualCheckUpdate,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                _availableUpdate != null && _availableUpdate!.isNewer
                    ? 'v$appVersion  \u2192  ${_availableUpdate!.tag}'
                    : 'v$appVersion',
                style: TextStyle(
                  color: _availableUpdate != null && _availableUpdate!.isNewer
                      ? AppColors.green
                      : const Color(0xFF4A4F63),
                  fontSize: 10.5,
                  fontWeight: _availableUpdate != null && _availableUpdate!.isNewer
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

enum _LogLevel { info, ok, warn, error }

class _LogEntry {
  final DateTime time;
  final String message;
  final _LogLevel level;
  const _LogEntry({
    required this.time,
    required this.message,
    required this.level,
  });

  Color get color {
    switch (level) {
      case _LogLevel.ok:
        return AppColors.green;
      case _LogLevel.warn:
        return AppColors.yellow;
      case _LogLevel.error:
        return AppColors.red;
      case _LogLevel.info:
        return const Color(0xFFB8BDD0);
    }
  }
}

// ---------------------------------------------------------------------------
// Folder browser
// ---------------------------------------------------------------------------

class FolderSelection {
  final List<String> paths; // relatif terhadap volume ("" = root)
  final List<String> names;
  const FolderSelection(this.paths, this.names);
}

class _FolderBrowserDialog extends StatefulWidget {
  final MacDrive drive;
  const _FolderBrowserDialog({required this.drive});

  @override
  State<_FolderBrowserDialog> createState() => _FolderBrowserDialogState();
}

class _FolderBrowserNode {
  final String path;
  final String name;
  final bool isDir;
  final int size;
  List<_FolderBrowserNode>? children;
  bool expanded = false;
  bool loading = false;

  _FolderBrowserNode({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    this.children,
  });

  bool get hasChildren => isDir;
}

class _FolderBrowserDialogState extends State<_FolderBrowserDialog> {
  MacVolume? _volume;
  _FolderBrowserNode? _root;
  String? _error;
  _FolderBrowserNode? _selected;
  final _checked = <String, _FolderBrowserNode>{};

  @override
  void initState() {
    super.initState();
    _openVolume();
  }

  Future<void> _openVolume() async {
    try {
      final volume = widget.drive.open();
      final rootId = volume.rootId();
      final node = _FolderBrowserNode(
        path: '',
        name: widget.drive.volumeName,
        isDir: true,
        size: 0,
      );
      _volume = volume;
      _loadChildren(volume, rootId, node);
      setState(() {
        _root = node;
        _selected = node;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _loadChildren(
      MacVolume volume, int entryId, _FolderBrowserNode node) {
    final count = volume.entryCount(entryId);
    final children = <_FolderBrowserNode>[];
    final dirs = <_FolderBrowserNode>[];
    final files = <_FolderBrowserNode>[];
    for (var i = 0; i < count; i++) {
      final childId = volume.entryChild(entryId, i);
      if (childId == 0) continue;
      final name = volume.entryName(childId);
      final mode = volume.entryMode(childId);
      final size = volume.entrySize(childId);
      volume.release(childId);
      final isDir = (mode & sIFMT) == sIFDIR;
      final childPath =
          node.path.isEmpty ? name : '${node.path}/$name';
      final childNode = _FolderBrowserNode(
        path: childPath,
        name: name,
        isDir: isDir,
        size: size,
      );
      (isDir ? dirs : files).add(childNode);
    }
    dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    children.addAll(dirs);
    children.addAll(files);
    node.children = children;
  }

  void _toggle(_FolderBrowserNode node) {
    setState(() {
      if (node.expanded) {
        node.expanded = false;
        return;
      }
      if (node.children == null && _volume != null) {
        // Buka entrynya dulu untuk ambil anak-anak.
        try {
          final volume = _volume!;
          final entryId = _openPath(volume, node.path);
          if (entryId != 0) {
            _loadChildren(volume, entryId, node);
            volume.release(entryId);
          } else {
            node.children = [];
          }
        } catch (_) {
          node.children = [];
        }
      }
      node.expanded = true;
    });
  }

  int _openPath(MacVolume volume, String path) {
    if (path.isEmpty) return volume.rootId();
    final parts = path.split('/');
    var current = volume.rootId();
    for (final part in parts) {
      final count = volume.entryCount(current);
      var found = 0;
      for (var i = 0; i < count; i++) {
        final childId = volume.entryChild(current, i);
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

  @override
  void dispose() {
    _volume?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: SizedBox(
        width: 700,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${L(L.current).pickFileOrFolder} ${widget.drive.volumeName}',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                L(L.current).browserHint,
                style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.headerBg,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              '${L(L.current).failOpenVolume}\n$_error',
                              style: const TextStyle(
                                  color: AppColors.red, fontSize: 12.5),
                            ),
                          ),
                        )
                      : _root == null
                          ? const Center(
                              child: CircularProgressIndicator(),
                            )
                          : _buildTree(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _checked.isEmpty
                          ? L(L.current).checkToCopy
                          : '${_checked.length} item dipilih: '
                              '${_checked.values.map((n) => n.name).take(3).join(', ')}'
                              '${_checked.length > 3 ? ', ...' : ''}',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SecondaryButton(
                    label: L(L.current).cancel,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  PrimaryButton(
                    label: _checked.isEmpty
                        ? L(L.current).saveThisFolder
                        : '${L(L.current).saveItemCount} ${_checked.length}',
                    icon: Icons.check_rounded,
                    onPressed: () {
                      final paths = _checked.keys.toList();
                      final names =
                          _checked.values.map((n) => n.name).toList();
                      if (paths.isEmpty) {
                        // Default: seluruh volume.
                        Navigator.pop(
                            context, const FolderSelection([], []));
                        return;
                      }
                      Navigator.pop(
                          context, FolderSelection(paths, names));
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTree() {
    final rows = <Widget>[];
    void visit(_FolderBrowserNode node, int depth) {
      rows.add(_buildRow(node, depth));
      if (node.expanded && node.children != null) {
        for (final child in node.children!) {
          visit(child, depth + 1);
        }
      }
    }

    visit(_root!, 0);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: rows,
    );
  }

  Widget _buildRow(_FolderBrowserNode node, int depth) {
    final isChecked = _checked.containsKey(node.path);
    return InkWell(
      onTap: () => setState(() {
        if (isChecked) {
          _checked.remove(node.path);
        } else {
          _checked[node.path] = node;
        }
        _selected = node;
      }),
      onDoubleTap: node.isDir ? () => _toggle(node) : null,
      child: Container(
        color: isChecked
            ? AppColors.accentDim.withValues(alpha: 0.35)
            : Colors.transparent,
        padding: EdgeInsets.only(
          left: 8.0 + depth * 22,
          right: 12,
          top: 6,
          bottom: 6,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: node.hasChildren
                  ? InkWell(
                      onTap: () => _toggle(node),
                      child: Icon(
                        node.expanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                        color: AppColors.muted,
                        size: 18,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: isChecked,
                onChanged: (_) => setState(() {
                  if (isChecked) {
                    _checked.remove(node.path);
                  } else {
                    _checked[node.path] = node;
                  }
                  _selected = node;
                }),
                activeColor: AppColors.accent,
                side: const BorderSide(color: AppColors.muted, width: 1.3),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              node.isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
              color: node.isDir ? const Color(0xFFF0B429) : AppColors.muted,
              size: 17,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.name,
                style: TextStyle(
                  color: node.isDir ? AppColors.text : AppColors.muted,
                  fontSize: 12.5,
                  fontWeight:
                      node.isDir ? FontWeight.w500 : FontWeight.w400,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!node.isDir)
              Text(
                _HomeScreenState._humanSize(node.size),
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }
}

