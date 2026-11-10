/// Binding FFI ke macfs.dll - jembatan native ke libfsapfs (APFS) dan
/// libfshfs (HFS+). Semua panggilan berjalan sinkron; engine memanggilnya
/// dari isolate terpisah agar UI tetap responsif.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Tipe native
// ---------------------------------------------------------------------------

typedef _OpenNative = Pointer<Void> Function(
    Int32 disk, Uint64 offset, Uint64 length, Int32 kind);
typedef _OpenDart = Pointer<Void> Function(
    int disk, int offset, int length, int kind);

typedef _CtxVoidNative = Void Function(Pointer<Void> ctx);
typedef _CtxVoidDart = void Function(Pointer<Void> ctx);

typedef _CtxStrNative = Pointer<Utf8> Function(Pointer<Void> ctx);
typedef _CtxStrDart = Pointer<Utf8> Function(Pointer<Void> ctx);

typedef _CtxIntNative = Int32 Function(Pointer<Void> ctx);
typedef _CtxIntDart = int Function(Pointer<Void> ctx);

typedef _SelectNative = Int32 Function(Pointer<Void> ctx, Int32 index);
typedef _SelectDart = int Function(Pointer<Void> ctx, int index);

typedef _UnlockNative = Int32 Function(Pointer<Void> ctx, Pointer<Utf8> password);
typedef _UnlockDart = int Function(Pointer<Void> ctx, Pointer<Utf8> password);

typedef _RootNative = Int64 Function(Pointer<Void> ctx);
typedef _RootDart = int Function(Pointer<Void> ctx);

typedef _CountNative = Int32 Function(Pointer<Void> ctx, Int64 id);
typedef _CountDart = int Function(Pointer<Void> ctx, int id);

typedef _ChildNative = Int64 Function(Pointer<Void> ctx, Int64 id, Int32 index);
typedef _ChildDart = int Function(Pointer<Void> ctx, int id, int index);

typedef _IdStrNative = Pointer<Utf8> Function(Pointer<Void> ctx, Int64 id);
typedef _IdStrDart = Pointer<Utf8> Function(Pointer<Void> ctx, int id);

typedef _IdU64Native = Uint64 Function(Pointer<Void> ctx, Int64 id);
typedef _IdU64Dart = int Function(Pointer<Void> ctx, int id);

typedef _IdU32Native = Uint32 Function(Pointer<Void> ctx, Int64 id);
typedef _IdU32Dart = int Function(Pointer<Void> ctx, int id);

typedef _IdI64Native = Int64 Function(Pointer<Void> ctx, Int64 id);
typedef _IdI64Dart = int Function(Pointer<Void> ctx, int id);

typedef _IdVoidNative = Void Function(Pointer<Void> ctx, Int64 id);
typedef _IdVoidDart = void Function(Pointer<Void> ctx, int id);

typedef _ReadNative = Int64 Function(Pointer<Void> ctx, Int64 id,
    Pointer<Void> buffer, Uint64 size, Uint64 offset);
typedef _ReadDart = int Function(Pointer<Void> ctx, int id,
    Pointer<Void> buffer, int size, int offset);

// Mount (WinFsp) - dynamic loading, tidak wajib ada.
typedef _WinFspAvailableNative = Int32 Function();
typedef _WinFspAvailableDart = int Function();
typedef _MountVolumeNative = Pointer<Void> Function(
    Int32 diskNumber, Uint64 offset, Uint64 length, Int32 kind,
    Int32 volumeIndex, Pointer<Utf8> mountPoint);
typedef _MountVolumeDart = Pointer<Void> Function(
    int diskNumber, int offset, int length, int kind, int volumeIndex,
    Pointer<Utf8> mountPoint);
typedef _MountHandleNative = Void Function(Pointer<Void> handle);
typedef _MountHandleDart = void Function(Pointer<Void> handle);
typedef _MountStrNative = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _MountStrDart = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _MountIntNative = Int32 Function(Pointer<Void> handle);
typedef _MountIntDart = int Function(Pointer<Void> handle);

// Fungsi partisi (global, tidak butuh ctx).
typedef _DiskCountNative = Int32 Function();
typedef _DiskCountDart = int Function();
typedef _CanAccessNative = Int32 Function();
typedef _CanAccessDart = int Function();
typedef _PartCountNative = Int32 Function(Int32 diskNumber);
typedef _PartCountDart = int Function(int diskNumber);
typedef _PartGetNative = Int32 Function(
    Int32 diskNumber,
    Int32 index,
    Pointer<Uint64> offset,
    Pointer<Uint64> length,
    Pointer<Int32> kind,
    Pointer<Utf8> guid,
    Int32 guidLen,
    Pointer<Utf8> name,
    Int32 nameLen);
typedef _PartGetDart = int Function(
    int diskNumber,
    int index,
    Pointer<Uint64> offset,
    Pointer<Uint64> length,
    Pointer<Int32> kind,
    Pointer<Utf8> guid,
    int guidLen,
    Pointer<Utf8> name,
    int nameLen);

// ---------------------------------------------------------------------------
// Konstanta
// ---------------------------------------------------------------------------

class FsKind {
  static const int apfs = 0;
  static const int hfs = 1;
}

// Mode POSIX
const int sIFMT = 0xF000;
const int sIFDIR = 0x4000;
const int sIFLNK = 0xA000;
const int sIFREG = 0x8000;

// ---------------------------------------------------------------------------
// MacFs - pembungkus DLL
// ---------------------------------------------------------------------------

class MacFsException implements Exception {
  final String message;
  MacFsException(this.message);
  @override
  String toString() => message;
}

class MacEntry {
  final String name;
  final int size;
  final int mode;
  final int mtimeNs;
  final int ctimeNs;
  final int atimeNs;
  final String? linkTarget;

  MacEntry({
    required this.name,
    required this.size,
    required this.mode,
    required this.mtimeNs,
    required this.ctimeNs,
    required this.atimeNs,
    this.linkTarget,
  });

  bool get isDir => (mode & sIFMT) == sIFDIR;
  bool get isSymlink => (mode & sIFMT) == sIFLNK;
  bool get isFile => (mode & sIFMT) == sIFREG;
}

class MacFsLibrary {
  static DynamicLibrary? _lib;
  static late final _OpenDart _open;
  static late final _CtxVoidDart _close;
  static late final _CtxStrDart _error;
  static late final _CtxIntDart _volumeCount;
  static late final _SelectDart _selectVolume;
  static late final _CtxStrDart _volumeName;
  static late final _CtxIntDart _volumeIsLocked;
  static late final _UnlockDart _unlock;
  static late final _RootDart _root;
  static late final _CountDart _entryCount;
  static late final _ChildDart _entryChild;
  static late final _IdVoidDart _entryRelease;
  static late final _IdStrDart _entryName;
  static late final _IdU64Dart _entrySize;
  static late final _IdU32Dart _entryMode;
  static late final _IdI64Dart _entryMtime;
  static late final _IdI64Dart _entryCtime;
  static late final _IdI64Dart _entryAtime;
  static late final _IdStrDart _entryLinkTarget;
  static late final _ReadDart _readAt;

  static late final _WinFspAvailableDart _winfspAvailable;
  static late final _MountVolumeDart _mountVolume;
  static late final _MountHandleDart _unmount;
  static late final _MountStrDart _mountError;
  static late final _MountStrDart _mountPoint;
  static late final _MountIntDart _mountIsActive;

  static late final _DiskCountDart _diskCount;
  static late final _CanAccessDart _canAccess;
  static late final _PartCountDart _partCount;
  static late final _PartGetDart _partGet;

  /// Memuat DLL. Mencari di beberapa lokasi standar.
  static void ensureLoaded() {
    if (_lib != null) return;
    final candidates = <String>[
      // Saat dev: native/dist relatif terhadap root proyek.
      File('native/dist/macfs.dll').absolute.path,
      // Saat release: di samping exe.
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}macfs.dll',
      // Fallback: folder data aplikasi.
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}native${Platform.pathSeparator}macfs.dll',
    ];
    String? lastError;
    DynamicLibrary? loaded;
    for (final path in candidates) {
      if (!File(path).existsSync()) continue;
      try {
        loaded = DynamicLibrary.open(path);
        break;
      } catch (e) {
        lastError = e.toString();
      }
    }
    if (loaded == null) {
      throw MacFsException(
          'Tidak bisa memuat macfs.dll${lastError != null ? " ($lastError)" : ""}. '
          'Pastikan file DLL berada di folder aplikasi.');
    }
    _lib = loaded;
    final lib = loaded;
    _open = lib.lookupFunction<_OpenNative, _OpenDart>('macfs_open');
    _close = lib.lookupFunction<_CtxVoidNative, _CtxVoidDart>('macfs_close');
    _error = lib.lookupFunction<_CtxStrNative, _CtxStrDart>('macfs_error');
    _volumeCount = lib.lookupFunction<_CtxIntNative, _CtxIntDart>('macfs_volume_count');
    _selectVolume = lib.lookupFunction<_SelectNative, _SelectDart>('macfs_select_volume');
    _volumeName = lib.lookupFunction<_CtxStrNative, _CtxStrDart>('macfs_volume_name');
    _volumeIsLocked = lib.lookupFunction<_CtxIntNative, _CtxIntDart>('macfs_volume_is_locked');
    _unlock = lib.lookupFunction<_UnlockNative, _UnlockDart>('macfs_unlock_password');
    _root = lib.lookupFunction<_RootNative, _RootDart>('macfs_root');
    _entryCount = lib.lookupFunction<_CountNative, _CountDart>('macfs_entry_count');
    _entryChild = lib.lookupFunction<_ChildNative, _ChildDart>('macfs_entry_child');
    _entryRelease = lib.lookupFunction<_IdVoidNative, _IdVoidDart>('macfs_entry_release');
    _entryName = lib.lookupFunction<_IdStrNative, _IdStrDart>('macfs_entry_name');
    _entrySize = lib.lookupFunction<_IdU64Native, _IdU64Dart>('macfs_entry_size');
    _entryMode = lib.lookupFunction<_IdU32Native, _IdU32Dart>('macfs_entry_mode');
    _entryMtime = lib.lookupFunction<_IdI64Native, _IdI64Dart>('macfs_entry_mtime_ns');
    _entryCtime = lib.lookupFunction<_IdI64Native, _IdI64Dart>('macfs_entry_ctime_ns');
    _entryAtime = lib.lookupFunction<_IdI64Native, _IdI64Dart>('macfs_entry_atime_ns');
    _entryLinkTarget = lib.lookupFunction<_IdStrNative, _IdStrDart>('macfs_entry_link_target');
    _readAt = lib.lookupFunction<_ReadNative, _ReadDart>('macfs_read_at');
    _winfspAvailable = lib.lookupFunction<_WinFspAvailableNative,
        _WinFspAvailableDart>('macfs_winfsp_available');
    _mountVolume = lib.lookupFunction<_MountVolumeNative, _MountVolumeDart>(
        'macfs_mount_volume');
    _unmount = lib.lookupFunction<_MountHandleNative, _MountHandleDart>(
        'macfs_unmount');
    _mountError = lib.lookupFunction<_MountStrNative, _MountStrDart>(
        'macfs_mount_error');
    _mountPoint = lib.lookupFunction<_MountStrNative, _MountStrDart>(
        'macfs_mount_point');
    _mountIsActive = lib.lookupFunction<_MountIntNative, _MountIntDart>(
        'macfs_mount_is_active');

    _diskCount = lib.lookupFunction<_DiskCountNative, _DiskCountDart>('macfs_disk_count');
    _canAccess = lib.lookupFunction<_CanAccessNative, _CanAccessDart>('macfs_can_access_disks');
    _partCount = lib.lookupFunction<_PartCountNative, _PartCountDart>('macfs_disk_partition_count');
_partGet = lib.lookupFunction<_PartGetNative, _PartGetDart>('macfs_disk_partition_get');
  }

  /// Jumlah disk fisik yang ada.
  static int diskCount() {
    ensureLoaded();
    return _diskCount();
  }

  /// Apakah proses berjalan sebagai Administrator (bisa akses disk)?
  static bool canAccessDisks() {
    ensureLoaded();
    return _canAccess() == 1;
  }

  /// Jumlah partisi pada disk (GPT/MBR).
  static int partitionCount(int diskNumber) {
    ensureLoaded();
    return _partCount(diskNumber);
  }

  /// Info partisi. Mengembalikan record (offset, length, kind, guid, name).
  static ({int offset, int length, int kind, String guid, String name})?
      partitionAt(int diskNumber, int index) {
    ensureLoaded();
    final offsetPtr = malloc.allocate<Uint64>(1);
    final lengthPtr = malloc.allocate<Uint64>(1);
    final kindPtr = malloc.allocate<Int32>(1);
    final guidPtr = malloc.allocate<Utf8>(64);
    final namePtr = malloc.allocate<Utf8>(128);
    try {
      final ok = _partGet(
          diskNumber, index, offsetPtr, lengthPtr, kindPtr, guidPtr, 64,
          namePtr, 128);
      if (ok != 1) return null;
      return (
        offset: offsetPtr.value,
        length: lengthPtr.value,
        kind: kindPtr.value,
        guid: guidPtr.toDartString(),
        name: namePtr.toDartString(),
      );
    } finally {
      malloc.free(offsetPtr);
      malloc.free(lengthPtr);
      malloc.free(kindPtr);
      malloc.free(guidPtr);
      malloc.free(namePtr);
    }
  }
}

/// Satu volume Mac yang sudah dibuka. Gunakan `close()` setelah selesai.
class MacVolume {
  Pointer<Void> _ctx;
  final int kind;
  final String name;
  final bool isLocked;

  MacVolume._(this._ctx, this.kind, this.name, this.isLocked);

  /// Membuka disk fisik pada window offset/length.
  static MacVolume open({
    required int diskNumber,
    required int offset,
    required int length,
    required int kind,
    int volumeIndex = 0,
  }) {
    MacFsLibrary.ensureLoaded();
    final ctx = MacFsLibrary._open(diskNumber, offset, length, kind);
    if (ctx == nullptr) {
      throw MacFsException(
          'Gagal membuka disk $diskNumber. Pastikan aplikasi berjalan sebagai '
          'Administrator.');
    }
    final errorPtr = MacFsLibrary._error(ctx);
    if (errorPtr != nullptr) {
      final message = errorPtr.toDartString();
      MacFsLibrary._close(ctx);
      throw MacFsException(message);
    }
    if (kind == FsKind.apfs && volumeIndex >= 0) {
      if (MacFsLibrary._selectVolume(ctx, volumeIndex) != 1) {
        final msg = MacFsLibrary._error(ctx);
        MacFsLibrary._close(ctx);
        throw MacFsException(msg == nullptr ? 'Gagal memilih volume' : msg.toDartString());
      }
    }
    final namePtr = MacFsLibrary._volumeName(ctx);
    final name = namePtr == nullptr ? '(tanpa nama)' : namePtr.toDartString();
    final locked = kind == FsKind.apfs
        ? MacFsLibrary._volumeIsLocked(ctx) == 1
        : false;
    return MacVolume._(ctx, kind, name, locked);
  }

  /// Membaca daftar nama volume (APFS container). HFS+: satu volume.
  static List<String> listVolumeNames({
    required int diskNumber,
    required int offset,
    required int length,
    required int kind,
  }) {
    MacFsLibrary.ensureLoaded();
    final ctx = MacFsLibrary._open(diskNumber, offset, length, kind);
    if (ctx == nullptr) {
      throw MacFsException(
          'Gagal membuka disk $diskNumber (butuh Administrator?).');
    }
    final errorPtr = MacFsLibrary._error(ctx);
    if (errorPtr != nullptr) {
      final message = errorPtr.toDartString();
      MacFsLibrary._close(ctx);
      throw MacFsException(message);
    }
    final count = MacFsLibrary._volumeCount(ctx);
    final names = <String>[];
    for (var i = 0; i < count; i++) {
      if (MacFsLibrary._selectVolume(ctx, i) == 1) {
        final p = MacFsLibrary._volumeName(ctx);
        names.add(p == nullptr ? '(tanpa nama)' : p.toDartString());
      } else {
        names.add('(tidak bisa dibuka)');
      }
    }
    MacFsLibrary._close(ctx);
    return names;
  }

  bool unlock(String password) {
    MacFsLibrary.ensureLoaded();
    final ptr = password.toNativeUtf8();
    try {
      return MacFsLibrary._unlock(_ctx, ptr) == 1;
    } finally {
      malloc.free(ptr);
    }
  }

  String? lastError() {
    final p = MacFsLibrary._error(_ctx);
    return p == nullptr ? null : p.toDartString();
  }

  int rootId() => MacFsLibrary._root(_ctx);

  int entryCount(int id) => MacFsLibrary._entryCount(_ctx, id);

  int entryChild(int id, int index) => MacFsLibrary._entryChild(_ctx, id, index);

  void release(int id) => MacFsLibrary._entryRelease(_ctx, id);

  String entryName(int id) {
    final p = MacFsLibrary._entryName(_ctx, id);
    return p == nullptr ? '' : p.toDartString();
  }

  int entrySize(int id) => MacFsLibrary._entrySize(_ctx, id);
  int entryMode(int id) => MacFsLibrary._entryMode(_ctx, id);
  int entryMtimeNs(int id) => MacFsLibrary._entryMtime(_ctx, id);
  int entryCtimeNs(int id) => MacFsLibrary._entryCtime(_ctx, id);
  int entryAtimeNs(int id) => MacFsLibrary._entryAtime(_ctx, id);

  String? entryLinkTarget(int id) {
    final p = MacFsLibrary._entryLinkTarget(_ctx, id);
    return p == nullptr ? null : p.toDartString();
  }

  MacEntry readEntry(int id) {
    return MacEntry(
      name: entryName(id),
      size: entrySize(id),
      mode: entryMode(id),
      mtimeNs: entryMtimeNs(id),
      ctimeNs: entryCtimeNs(id),
      atimeNs: entryAtimeNs(id),
      linkTarget: entryLinkTarget(id),
    );
  }

  /// Membaca isi file pada offset tertentu ke dalam buffer Dart.
  /// Mengembalikan jumlah byte yang dibaca.
  int readInto(int id, Uint8List buffer, int offset) {
    final native = malloc.allocate<Uint8>(buffer.length);
    try {
      final read = MacFsLibrary._readAt(
          _ctx, id, native.cast(), buffer.length, offset);
      if (read < 0) return -1;
      buffer.setAll(0, native.asTypedList(read));
      return read;
    } finally {
      malloc.free(native);
    }
  }

  /// Membaca seluruh isi file (untuk file kecil). Untuk file besar gunakan
  /// readInto dengan chunk.
  Uint8List readAll(int id) {
    final size = entrySize(id);
    final result = Uint8List(size);
    var offset = 0;
    const chunk = 4 * 1024 * 1024;
    while (offset < size) {
      final want = (size - offset).clamp(0, chunk);
      final slice = Uint8List.sublistView(result, offset, offset + want);
      final read = readInto(id, slice, offset);
      if (read <= 0) break;
      offset += read;
    }
    return offset == size ? result : Uint8List.sublistView(result, 0, offset);
  }

  void close() {
    if (_ctx != nullptr) {
      MacFsLibrary._close(_ctx);
      _ctx = nullptr;
    }
  }
}

/// Handle mount WinFsp: volume Mac tampil sebagai huruf drive (read-only).
///
/// Hanya tersedia bila WinFsp terpasang di sistem. Gunakan
/// [WinFspChecker.available] untuk memeriksa.
class MacMount {
  Pointer<Void> _handle;
  final String mountPoint;
  bool _active;

  MacMount._(this._handle, this.mountPoint, this._active);

  /// Mount volume pada [mountPoint] (mis. "M:"). Mengembalikan null bila gagal;
  /// gunakan [MacMount.lastError] untuk pesan.
  static String? lastError;

  static MacMount? mount({
    required int diskNumber,
    required int offset,
    required int length,
    required int kind,
    required int volumeIndex,
    required String mountPoint,
  }) {
    MacFsLibrary.ensureLoaded();
    lastError = null;
    final pointPtr = mountPoint.toNativeUtf8();
    try {
      final handle = MacFsLibrary._mountVolume(
          diskNumber, offset, length, kind, volumeIndex, pointPtr);
      if (handle == nullptr) {
        lastError = 'Gagal membuat handle mount';
        return null;
      }
      final errorPtr = MacFsLibrary._mountError(handle);
      if (errorPtr != nullptr) {
        lastError = errorPtr.toDartString();
        MacFsLibrary._unmount(handle);
        return null;
      }
      final active = MacFsLibrary._mountIsActive(handle) == 1;
      if (!active) {
        lastError = 'Mount tidak aktif (drive letter mungkin dipakai)';
        MacFsLibrary._unmount(handle);
        return null;
      }
      final pointPtr2 = MacFsLibrary._mountPoint(handle);
      final actual = pointPtr2 == nullptr ? mountPoint : pointPtr2.toDartString();
      return MacMount._(handle, actual, true);
    } finally {
      malloc.free(pointPtr);
    }
  }

  bool get isActive => _active && _handle != nullptr;

  void unmount() {
    if (_handle != nullptr) {
      MacFsLibrary._unmount(_handle);
      _handle = nullptr;
      _active = false;
    }
  }
}

/// Pemeriksa ketersediaan WinFsp.
class WinFspChecker {
  static bool _cached = false;
  static bool _checked = false;

  static bool get available {
    if (_checked) return _cached;
    MacFsLibrary.ensureLoaded();
    _cached = MacFsLibrary._winfspAvailable() == 1;
    _checked = true;
    return _cached;
  }
}
