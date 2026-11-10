/// Penyimpanan pengaturan terakhir (dest, opsi, drive) via SharedPreferences.
library;

import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class SavedSettings {
  final String? destPath;
  final String? lastVolumeName;
  final bool skipSystem;
  final bool skipHidden;
  final bool skipBuild;
  final bool skipApps;
  final bool preserveTimes;
  final String overwrite;
  final String symlinks;
  final String colonReplacement;
  final String language;

  const SavedSettings({
    this.destPath,
    this.lastVolumeName,
    this.skipSystem = true,
    this.skipHidden = false,
    this.skipBuild = true,
    this.skipApps = true,
    this.preserveTimes = true,
    this.overwrite = 'skip',
    this.symlinks = 'skip',
    this.colonReplacement = '-',
    this.language = 'id',
  });

  static const _keyDest = 'dest_path';
  static const _keyVolume = 'last_volume';
  static const _keySkipSystem = 'skip_system';
  static const _keySkipHidden = 'skip_hidden';
  static const _keySkipBuild = 'skip_build';
  static const _keySkipApps = 'skip_apps';
  static const _keyPreserve = 'preserve_times';
  static const _keyOverwrite = 'overwrite';
  static const _keySymlinks = 'symlinks';
  static const _keyColon = 'colon';
  static const _keyLanguage = 'language';

  static Future<SavedSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final defaultDest =
          '${Platform.environment['USERPROFILE'] ?? 'C:'}\\Documents\\Mac Transfer';
      return SavedSettings(
        destPath: prefs.getString(_keyDest) ?? defaultDest,
        lastVolumeName: prefs.getString(_keyVolume),
        skipSystem: prefs.getBool(_keySkipSystem) ?? true,
        skipHidden: prefs.getBool(_keySkipHidden) ?? false,
        skipBuild: prefs.getBool(_keySkipBuild) ?? true,
        skipApps: prefs.getBool(_keySkipApps) ?? true,
        preserveTimes: prefs.getBool(_keyPreserve) ?? true,
        overwrite: prefs.getString(_keyOverwrite) ?? 'skip',
        symlinks: prefs.getString(_keySymlinks) ?? 'skip',
        colonReplacement: prefs.getString(_keyColon) ?? '-',
        language: prefs.getString(_keyLanguage) ?? 'id',
      );
    } catch (_) {
      final defaultDest =
          '${Platform.environment['USERPROFILE'] ?? 'C:'}\\Documents\\Mac Transfer';
      return SavedSettings(destPath: defaultDest);
    }
  }

  static Future<void> save({
    required String destPath,
    String? lastVolumeName,
    required bool skipSystem,
    required bool skipHidden,
    required bool skipBuild,
    required bool skipApps,
    required bool preserveTimes,
    required String overwrite,
    required String symlinks,
    required String colonReplacement,
    String? language,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyDest, destPath);
      if (lastVolumeName != null) {
        await prefs.setString(_keyVolume, lastVolumeName);
      }
      await prefs.setBool(_keySkipSystem, skipSystem);
      await prefs.setBool(_keySkipHidden, skipHidden);
      await prefs.setBool(_keySkipBuild, skipBuild);
      await prefs.setBool(_keySkipApps, skipApps);
      await prefs.setBool(_keyPreserve, preserveTimes);
      await prefs.setString(_keyOverwrite, overwrite);
      await prefs.setString(_keySymlinks, symlinks);
      await prefs.setString(_keyColon, colonReplacement);
      if (language != null) {
        await prefs.setString(_keyLanguage, language);
      }
    } catch (_) {}
  }
}