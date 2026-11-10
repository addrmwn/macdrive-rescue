import 'dart:io';

import 'package:flutter/material.dart';

import 'package:macdrive_rescue/core/discovery.dart';
import 'package:macdrive_rescue/core/l10n.dart';
import 'package:macdrive_rescue/core/macfs_ffi.dart';
import 'package:macdrive_rescue/ui/theme.dart';

/// Dialog info disk/volume (tanpa fitur mount).
class DiskInfoDialog extends StatelessWidget {
  final MacDrive drive;
  const DiskInfoDialog({super.key, required this.drive});

  @override
  Widget build(BuildContext context) {
    final t = L(L.current);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.storage_rounded, color: AppColors.accent, size: 22),
          const SizedBox(width: 10),
          Text(
            t.diskInfo,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(t.volumeLabel, drive.volumeName, highlight: true),
            _row(t.filesystemLabel, drive.kindLabel),
            _row(
              t.capacityLabel,
              '${drive.partition.sizeGb.toStringAsFixed(1)} GB',
            ),
            if (drive.mountLetter != null)
              _row('Windows', '${drive.mountLetter}:'),
            _row(t.encryptedLabel, t.notEncrypted),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.cancel),
        ),
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
            child: Text(
              label,
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
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
          Text(
            _t.unlockTitle,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _t.unlockHint,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
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
                    _obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
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
              Text(
                _error!,
                style: const TextStyle(color: AppColors.red, fontSize: 12),
              ),
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
