import 'dart:io';

import 'package:flutter/material.dart';

import 'package:macdrive_rescue/core/discovery.dart';
import 'package:macdrive_rescue/core/l10n.dart';
import 'package:macdrive_rescue/core/macfs_ffi.dart';
import 'package:macdrive_rescue/ui/theme.dart';
import 'package:macdrive_rescue/ui/widgets.dart';

/// Dialog info disk/volume + tombol mount.
class DiskInfoDialog extends StatefulWidget {
  final MacDrive drive;
  const DiskInfoDialog({super.key, required this.drive});

  @override
  State<DiskInfoDialog> createState() => _DiskInfoDialogState();
}

class _DiskInfoDialogState extends State<DiskInfoDialog> {
  MacMount? _mount;
  bool _busy = false;
  String? _error;

  L get _t => L(L.current);

  @override
  void dispose() {
    _mount?.unmount();
    super.dispose();
  }

  /// Mount dengan huruf drive OTOMATIS (disarankan).
  /// WinFsp memilih huruf sendiri dari Z: ke bawah, sehingga tidak ada
  /// kemungkinan bentrok dengan huruf yang sudah dipakai.
  Future<void> _mountAutomatic() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final drive = widget.drive;
      final mount = MacMount.mount(
        diskNumber: drive.diskNumber,
        offset: drive.partition.start,
        length: drive.partition.length,
        kind: drive.fsKind,
        volumeIndex: drive.volumeIndex,
        mountPoint: '', // kosong = otomatis
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _mount = mount;
        _error = mount == null
            ? (MacMount.lastError ?? _t.mountFailed)
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  /// Mount manual: pengguna memilih huruf drive sendiri.
  Future<void> _chooseAndMount() async {
    final letters = <String>[];
    for (var c = 'M'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final letter = String.fromCharCode(c);
      try {
        if (await Directory('$letter:\\').exists()) continue;
      } catch (_) {}
      letters.add(letter);
    }
    if (letters.isEmpty || !mounted) return;

    final letter = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.chooseLetter),
        content: SizedBox(
          width: 320,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: letters
                .take(12)
                .map((l) => OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, l),
                      child: Text('$l:'),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_t.cancel),
          ),
        ],
      ),
    );
    if (letter == null || !mounted) return;
    await _mountAt(letter);
  }

  Future<void> _mountAt(String letter) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final drive = widget.drive;
      final mount = MacMount.mount(
        diskNumber: drive.diskNumber,
        offset: drive.partition.start,
        length: drive.partition.length,
        kind: drive.fsKind,
        volumeIndex: drive.volumeIndex,
        mountPoint: '$letter:',
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _mount = mount;
        _error = mount == null ? (MacMount.lastError ?? _t.mountFailed) : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final drive = widget.drive;
    final winfsp = WinFspChecker.available;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.storage_rounded, color: AppColors.accent, size: 22),
          const SizedBox(width: 10),
          Text(_t.diskInfo,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(_t.volumeLabel, drive.volumeName, highlight: true),
            _row(_t.filesystemLabel, drive.kindLabel),
            _row(_t.capacityLabel,
                '${drive.partition.sizeGb.toStringAsFixed(1)} GB'),
            if (drive.mountLetter != null)
              _row('Windows', '${drive.mountLetter}:'),
            _row(_t.encryptedLabel, _t.notEncrypted),
            if (_mount != null && _mount!.isActive) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF173B26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        color: AppColors.green, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_t.mountedAt}: ${_mount!.mountPoint}  '
                        '(${_t.mountReadOnlyNote})',
                        style: const TextStyle(
                            color: AppColors.green, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: AppColors.red, fontSize: 12)),
              const SizedBox(height: 6),
              Text(_t.mountTroubleshoot,
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 11, height: 1.4)),
            ],
            if (!winfsp) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B2F1F),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _t.mountNeedsWinFsp,
                  style: const TextStyle(
                      color: AppColors.yellow, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!winfsp)
          TextButton.icon(
            onPressed: () {
              Process.start('cmd', ['/c', 'start', '', 'https://winfsp.dev/rel/'],
                  mode: ProcessStartMode.detached, runInShell: true);
            },
            icon: const Icon(Icons.open_in_new_rounded, size: 15),
            label: const Text('winfsp.dev'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_t.cancel),
        ),
        if (_mount != null && _mount!.isActive)
          OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _mount?.unmount();
                _mount = null;
              });
            },
            icon: const Icon(Icons.link_off_rounded, size: 16),
            label: Text(_t.unmountDrive),
          )
        else ...[
          TextButton(
            onPressed: (_busy || !winfsp) ? null : _chooseAndMount,
            child: Text(_t.chooseLetter),
          ),
          FilledButton.icon(
            onPressed: (_busy || !winfsp) ? null : _mountAutomatic,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.drive_file_move_rounded, size: 16),
            label: Text(_t.mountAsDrive),
          ),
        ],
      ],
    );
  }

  Widget _row(String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label,
                style:
                    const TextStyle(color: AppColors.muted, fontSize: 12.5)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: highlight ? AppColors.accent : AppColors.text,
                fontSize: 12.5,
                fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog password untuk volume APFS terenkripsi.
class UnlockDialog extends StatefulWidget {
  final MacDrive drive;
  const UnlockDialog({super.key, required this.drive});

  @override
  State<UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<UnlockDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  L get _t => L(L.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final drive = widget.drive;
      final volume = MacVolume.open(
        diskNumber: drive.diskNumber,
        offset: drive.partition.start,
        length: drive.partition.length,
        kind: drive.fsKind,
        volumeIndex: drive.volumeIndex,
      );
      final success = volume.unlock(_controller.text);
      volume.close();
      if (!mounted) return;
      if (success) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _busy = false;
          _error = _t.unlockFailed;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.lock_rounded, color: AppColors.accent, size: 22),
          const SizedBox(width: 10),
          Text(_t.unlockTitle,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t.unlockHint,
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 12.5, height: 1.4)),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              obscureText: _obscure,
              autofocus: true,
              onSubmitted: (_) => _busy ? null : _unlock(),
              style: const TextStyle(color: AppColors.text, fontSize: 13.5),
              decoration: InputDecoration(
                labelText: _t.passwordLabel,
                labelStyle: const TextStyle(color: AppColors.muted),
                filled: true,
                fillColor: AppColors.cardInner,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                    color: AppColors.muted,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
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
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: AppColors.red, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(_t.cancel),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _unlock,
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_open_rounded, size: 16),
          label: Text(_t.unlockButton),
        ),
      ],
    );
  }
}