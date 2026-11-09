/// Util Windows: set timestamp file/folder via Win32 SetFileTime.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _CreateFileNative = IntPtr Function(
    Pointer<Utf16> path,
    Uint32 desiredAccess,
    Uint32 shareMode,
    Pointer<Void> securityAttributes,
    Uint32 creationDisposition,
    Uint32 flags,
    IntPtr templateFile);
typedef _CreateFileDart = int Function(
    Pointer<Utf16> path,
    int desiredAccess,
    int shareMode,
    Pointer<Void> securityAttributes,
    int creationDisposition,
    int flags,
    int templateFile);

typedef _SetFileTimeNative = Int32 Function(
    IntPtr handle,
    Pointer<Int64> creation,
    Pointer<Int64> access,
    Pointer<Int64> write);
typedef _SetFileTimeDart = int Function(
    int handle,
    Pointer<Int64> creation,
    Pointer<Int64> access,
    Pointer<Int64> write);

typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

const _fileWriteAttributes = 0x0100;
const _fileShareRead = 0x00000001;
const _fileShareWrite = 0x00000002;
const _fileShareDelete = 0x00000004;
const _openExisting = 3;
const _fileFlagBackupSemantics = 0x02000000;
const _invalidHandle = -1;

const _filetimeEpochDiff = 11644473600; // detik 1601->1970

class _Win32 {
  static final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
  static final _CreateFileDart createFile =
      _k32.lookupFunction<_CreateFileNative, _CreateFileDart>('CreateFileW');
  static final _SetFileTimeDart setFileTime =
      _k32.lookupFunction<_SetFileTimeNative, _SetFileTimeDart>('SetFileTime');
  static final _CloseHandleDart closeHandle =
      _k32.lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
}

/// Menetapkan waktu modifikasi/akses/pembuatan untuk file atau folder.
///
/// [mtimeNs] adalah nanodetik sejak 1970. Bila folder, gunakan [isDir] = true.
/// Mengembalikan true bila berhasil.
bool setFileTimesWindows(
  String path, {
  required int mtimeNs,
  int? atimeNs,
  int? ctimeNs,
  bool isDir = false,
}) {
  if (mtimeNs <= 0) return false;
  final pathPtr = path.toNativeUtf16();
  final handle = _Win32.createFile(
    pathPtr,
    _fileWriteAttributes,
    _fileShareRead | _fileShareWrite | _fileShareDelete,
    nullptr,
    _openExisting,
    isDir ? _fileFlagBackupSemantics : 0,
    0,
  );
  malloc.free(pathPtr);
  if (handle == _invalidHandle || handle == 0) {
    return false;
  }
  final creationPtr = malloc.allocate<Int64>(1);
  final accessPtr = malloc.allocate<Int64>(1);
  final writePtr = malloc.allocate<Int64>(1);
  try {
    writePtr.value = _toFiletime(mtimeNs);
    accessPtr.value = _toFiletime(atimeNs ?? mtimeNs);
    creationPtr.value = _toFiletime(ctimeNs ?? mtimeNs);
    final ok = _Win32.setFileTime(
            handle, creationPtr, accessPtr, writePtr) !=
        0;
    return ok;
  } finally {
    malloc.free(creationPtr);
    malloc.free(accessPtr);
    malloc.free(writePtr);
    _Win32.closeHandle(handle);
  }
}

int _toFiletime(int unixNs) {
  // 100ns sejak 1601.
  return (unixNs ~/ 100) + _filetimeEpochDiff * 10000000;
}
