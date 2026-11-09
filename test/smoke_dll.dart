// Smoke test DLL macfs via Dart FFI.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:ffi/ffi.dart';

// Struktur FFI
typedef _OpenNative = Pointer<Void> Function(Int32 disk, Uint64 offset, Uint64 length, Int32 kind);
typedef _OpenDart = Pointer<Void> Function(int disk, int offset, int length, int kind);
typedef _CloseNative = Void Function(Pointer<Void> ctx);
typedef _CloseDart = void Function(Pointer<Void> ctx);
typedef _ErrorNative = Pointer<Utf8> Function(Pointer<Void> ctx);
typedef _ErrorDart = Pointer<Utf8> Function(Pointer<Void> ctx);
typedef _IntFnNative = Int32 Function(Pointer<Void> ctx);
typedef _IntFnDart = int Function(Pointer<Void> ctx);
typedef _SelectNative = Int32 Function(Pointer<Void> ctx, Int32 index);
typedef _SelectDart = int Function(Pointer<Void> ctx, int index);
typedef _NameNative = Pointer<Utf8> Function(Pointer<Void> ctx);
typedef _NameDart = Pointer<Utf8> Function(Pointer<Void> ctx);
typedef _RootNative = Int64 Function(Pointer<Void> ctx);
typedef _RootDart = int Function(Pointer<Void> ctx);
typedef _EntryCountNative = Int32 Function(Pointer<Void> ctx, Int64 id);
typedef _EntryCountDart = int Function(Pointer<Void> ctx, int id);
typedef _ChildNative = Int64 Function(Pointer<Void> ctx, Int64 id, Int32 index);
typedef _ChildDart = int Function(Pointer<Void> ctx, int id, int index);
typedef _EntryNameNative = Pointer<Utf8> Function(Pointer<Void> ctx, Int64 id);
typedef _EntryNameDart = Pointer<Utf8> Function(Pointer<Void> ctx, int id);
typedef _EntrySizeNative = Uint64 Function(Pointer<Void> ctx, Int64 id);
typedef _EntrySizeDart = int Function(Pointer<Void> ctx, int id);
typedef _EntryModeNative = Uint32 Function(Pointer<Void> ctx, Int64 id);
typedef _EntryModeDart = int Function(Pointer<Void> ctx, int id);
typedef _EntryMtimeNative = Int64 Function(Pointer<Void> ctx, Int64 id);
typedef _EntryMtimeDart = int Function(Pointer<Void> ctx, int id);
typedef _ReadAtNative = Int64 Function(Pointer<Void> ctx, Int64 id, Pointer<Void> buffer, Uint64 size, Uint64 offset);
typedef _ReadAtDart = int Function(Pointer<Void> ctx, int id, Pointer<Void> buffer, int size, int offset);
typedef _ReleaseNative = Void Function(Pointer<Void> ctx, Int64 id);
typedef _ReleaseDart = void Function(Pointer<Void> ctx, int id);

void main() async {
  final dllPath = Platform.script.resolve('../native/dist/macfs.dll').toFilePath();
  print('Loading: $dllPath');
  final lib = DynamicLibrary.open(dllPath);

  final open = lib.lookupFunction<_OpenNative, _OpenDart>('macfs_open');
  final close = lib.lookupFunction<_CloseNative, _CloseDart>('macfs_close');
  final error = lib.lookupFunction<_ErrorNative, _ErrorDart>('macfs_error');
  final volumeCount = lib.lookupFunction<_IntFnNative, _IntFnDart>('macfs_volume_count');
  final selectVolume = lib.lookupFunction<_SelectNative, _SelectDart>('macfs_select_volume');
  final volumeName = lib.lookupFunction<_NameNative, _NameDart>('macfs_volume_name');
  final root = lib.lookupFunction<_RootNative, _RootDart>('macfs_root');
  final entryCount = lib.lookupFunction<_EntryCountNative, _EntryCountDart>('macfs_entry_count');
  final entryChild = lib.lookupFunction<_ChildNative, _ChildDart>('macfs_entry_child');
  final entryName = lib.lookupFunction<_EntryNameNative, _EntryNameDart>('macfs_entry_name');
  final entrySize = lib.lookupFunction<_EntrySizeNative, _EntrySizeDart>('macfs_entry_size');
  final entryMode = lib.lookupFunction<_EntryModeNative, _EntryModeDart>('macfs_entry_mode');
  final entryMtime = lib.lookupFunction<_EntryMtimeNative, _EntryMtimeDart>('macfs_entry_mtime_ns');
  final readAt = lib.lookupFunction<_ReadAtNative, _ReadAtDart>('macfs_read_at');
  final release = lib.lookupFunction<_ReleaseNative, _ReleaseDart>('macfs_entry_release');

  // F: = disk 2, offset 209735680, length 499898105856 (dari GPT)
  print('\n=== Opening APFS on disk 2 ===');
  final ctx = open(2, 209735680, 499898105856, 0); // 0 = APFS
  if (ctx == nullptr) {
    print('FAILED to open');
    return;
  }
  final errPtr = error(ctx);
  if (errPtr != nullptr) print('error: ${errPtr.toDartString()}');

  final count = volumeCount(ctx);
  print('volumes: $count');
  for (var i = 0; i < count; i++) {
    selectVolume(ctx, i);
    print('  [$i] "${volumeName(ctx).toDartString()}"');
  }

  // Pilih volume Data
  var dataIdx = -1;
  for (var i = 0; i < count; i++) {
    selectVolume(ctx, i);
    if (volumeName(ctx).toDartString().contains('Data')) dataIdx = i;
  }
  print('\nUsing volume index $dataIdx');
  selectVolume(ctx, dataIdx);
  print('volume: "${volumeName(ctx).toDartString()}"');

  final rootId = root(ctx);
  print('root id: $rootId');
  final n = entryCount(ctx, rootId);
  print('root entries: $n');
  for (var i = 0; i < n && i < 15; i++) {
    final childId = entryChild(ctx, rootId, i);
    if (childId == 0) continue;
    final name = entryName(ctx, childId).toDartString();
    final mode = entryMode(ctx, childId);
    final isDir = (mode & 0xF000) == 0x4000;
    print('  ${isDir ? "[D]" : "[F]"} $name (mode=0x${mode.toRadixString(16)}, size=${entrySize(ctx, childId)})');
    release(ctx, childId);
  }

  // Navigasi: Users > adidarmawan > Desktop > Config.plist
  print('\n=== Navigating to Config.plist ===');
  int findChild(int parent, String name) {
    final c = entryCount(ctx, parent);
    for (var i = 0; i < c; i++) {
      final id = entryChild(ctx, parent, i);
      if (id == 0) continue;
      if (entryName(ctx, id).toDartString() == name) return id;
      release(ctx, id);
    }
    return 0;
  }

  final users = findChild(rootId, 'Users');
  print('Users: $users');
  final home = findChild(users, 'adidarmawan');
  print('home: $home');
  final desktop = findChild(home, 'Desktop');
  print('Desktop: $desktop');
  final config = findChild(desktop, 'Config.plist');
  print('Config.plist: $config');

  if (config != 0) {
    final size = entrySize(ctx, config);
    final mtime = entryMtime(ctx, config);
    print('size: $size bytes, mtime_ns: $mtime (${DateTime.fromMillisecondsSinceEpoch(mtime ~/ 1000000).toUtc()})');
    final buf = calloc.allocate<Uint8>(64);
    final read = readAt(ctx, config, buf.cast(), 64, 0);
    print('read: $read bytes');
    final bytes = buf.asTypedList(read);
    print('first bytes: ${utf8.decode(bytes, allowMalformed: true).split('\n').first}');
  }

  close(ctx);
  print('\nDONE OK');
}
