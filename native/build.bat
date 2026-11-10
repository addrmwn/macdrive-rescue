@echo off
REM ============================================================
REM  Build macfs.dll - Flutter FFI bridge untuk APFS & HFS+
REM  Menghasilkan: native\dist\macfs.dll (x64)
REM ============================================================
setlocal enabledelayedexpansion

set ROOT=%~dp0
set VENDOR=%ROOT%\vendor
set BRIDGE=%ROOT%\bridge
set SHIM=%ROOT%\shim
set OBJ=%ROOT%\build\obj
set DIST=%ROOT%\dist

if not exist "%DIST%" mkdir "%DIST%"
if not exist "%OBJ%" mkdir "%OBJ%"

REM --- Locate MSVC ---
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
if not exist "%VSWHERE%" (
  echo [ERROR] vswhere.exe tidak ditemukan. Install Visual Studio Build Tools.
  exit /b 1
)
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSPATH=%%i
if not defined VSPATH (
  echo [ERROR] Visual Studio C++ tools tidak ditemukan.
  exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] vcvars64.bat gagal.
  exit /b 1
)

REM --- Common flags ---
set CFLAGS=/nologo /c /O2 /MT /W0 /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_DEPRECATE /DUNICODE /D_UNICODE /DWINVER=0x0601 /D_WIN32_WINNT=0x0601
set LOCAL_DEFS=/DHAVE_LOCAL_LIBCERROR /DHAVE_LOCAL_LIBCTHREADS /DHAVE_LOCAL_LIBCDATA /DHAVE_LOCAL_LIBCLOCALE /DHAVE_LOCAL_LIBCNOTIFY /DHAVE_LOCAL_LIBCSPLIT /DHAVE_LOCAL_LIBUNA /DHAVE_LOCAL_LIBCFILE /DHAVE_LOCAL_LIBCPATH /DHAVE_LOCAL_LIBBFIO /DHAVE_LOCAL_LIBFCACHE /DHAVE_LOCAL_LIBFDATA /DHAVE_LOCAL_LIBFDATETIME /DHAVE_LOCAL_LIBFGUID /DHAVE_LOCAL_LIBFMOS /DHAVE_LOCAL_LIBHMAC /DHAVE_LOCAL_LIBCAES /DHAVE_LOCAL_LIBFSAPFS /DHAVE_LOCAL_LIBFSHFS
set ZLIB_DEFS=/DHAVE_ZLIB /DHAVE_ZLIB_UNCOMPRESS

set APFS_INC=/I"%SHIM%" /I"%VENDOR%\common" /I"%VENDOR%\include_apfs" /I"%VENDOR%\libcerror" /I"%VENDOR%\libcthreads" /I"%VENDOR%\libcdata" /I"%VENDOR%\libclocale" /I"%VENDOR%\libcnotify" /I"%VENDOR%\libcsplit" /I"%VENDOR%\libuna" /I"%VENDOR%\libcfile" /I"%VENDOR%\libcpath" /I"%VENDOR%\libbfio" /I"%VENDOR%\libfcache" /I"%VENDOR%\libfdata" /I"%VENDOR%\libfdatetime" /I"%VENDOR%\libfguid" /I"%VENDOR%\libfmos" /I"%VENDOR%\libhmac" /I"%VENDOR%\libcaes" /I"%VENDOR%\libfsapfs" /I"%VENDOR%\zlib"

set HFS_INC=/I"%SHIM%" /I"%VENDOR%\common_hfs" /I"%VENDOR%\include_hfs" /I"%VENDOR%\libcerror" /I"%VENDOR%\libcthreads" /I"%VENDOR%\libcdata" /I"%VENDOR%\libclocale" /I"%VENDOR%\libcnotify" /I"%VENDOR%\libcsplit" /I"%VENDOR%\libuna" /I"%VENDOR%\libcfile" /I"%VENDOR%\libcpath" /I"%VENDOR%\libbfio" /I"%VENDOR%\libfcache" /I"%VENDOR%\libfdata" /I"%VENDOR%\libfdatetime" /I"%VENDOR%\libfguid" /I"%VENDOR%\libfmos" /I"%VENDOR%\libhmac" /I"%VENDOR%\libcaes" /I"%VENDOR%\libfshfs" /I"%VENDOR%\zlib"

REM ============================================================
echo.
echo [1/6] zlib
REM ============================================================
if not exist "%OBJ%\zlib" mkdir "%OBJ%\zlib"
cl %CFLAGS% /Fo"%OBJ%\zlib\\" /I"%VENDOR%\zlib" "%VENDOR%\zlib\adler32.c" "%VENDOR%\zlib\compress.c" "%VENDOR%\zlib\crc32.c" "%VENDOR%\zlib\deflate.c" "%VENDOR%\zlib\gzclose.c" "%VENDOR%\zlib\gzlib.c" "%VENDOR%\zlib\gzread.c" "%VENDOR%\zlib\gzwrite.c" "%VENDOR%\zlib\infback.c" "%VENDOR%\zlib\inffast.c" "%VENDOR%\zlib\inflate.c" "%VENDOR%\zlib\inftrees.c" "%VENDOR%\zlib\trees.c" "%VENDOR%\zlib\uncompr.c" "%VENDOR%\zlib\zutil.c" > "%OBJ%\zlib.log" 2>&1
if errorlevel 1 ( echo [ERROR] zlib gagal & type "%OBJ%\zlib.log" & exit /b 1 )

REM ============================================================
echo [2/6] shared libyal libraries
REM ============================================================
for %%L in (libcerror libcthreads libcdata libclocale libcnotify libcsplit libuna libcfile libcpath libbfio libfcache libfdata libfdatetime libfguid libfmos libhmac libcaes) do (
  if not exist "%OBJ%\%%L" mkdir "%OBJ%\%%L"
  cl %CFLAGS% /MP4 %LOCAL_DEFS% /Fo"%OBJ%\%%L\\" %APFS_INC% "%VENDOR%\%%L\*.c" > "%OBJ%\%%L.log" 2>&1
  if errorlevel 1 ( echo [ERROR] %%L gagal & type "%OBJ%\%%L.log" & exit /b 1 )
)

REM ============================================================
echo [3/6] libfsapfs
REM ============================================================
if not exist "%OBJ%\libfsapfs" mkdir "%OBJ%\libfsapfs"
cl %CFLAGS% /MP4 %LOCAL_DEFS% %ZLIB_DEFS% /Fo"%OBJ%\libfsapfs\\" %APFS_INC% "%VENDOR%\libfsapfs\*.c" > "%OBJ%\libfsapfs.log" 2>&1
if errorlevel 1 ( echo [ERROR] libfsapfs gagal & type "%OBJ%\libfsapfs.log" & exit /b 1 )

REM ============================================================
echo [4/6] libfshfs
REM ============================================================
if not exist "%OBJ%\libfshfs" mkdir "%OBJ%\libfshfs"
cl %CFLAGS% /MP4 %LOCAL_DEFS% %ZLIB_DEFS% /Fo"%OBJ%\libfshfs\\" %HFS_INC% "%VENDOR%\libfshfs\*.c" > "%OBJ%\libfshfs.log" 2>&1
if errorlevel 1 ( echo [ERROR] libfshfs gagal & type "%OBJ%\libfshfs.log" & exit /b 1 )

REM ============================================================
echo [5/6] bridge
REM ============================================================
if not exist "%OBJ%\bridge" mkdir "%OBJ%\bridge"
cl %CFLAGS% %LOCAL_DEFS% /Fo"%OBJ%\bridge\\" /I"%BRIDGE%" /I"%ROOT%\vendor_winfsp" %APFS_INC% /I"%VENDOR%\include_hfs" "%BRIDGE%\macfs_bridge.c" > "%OBJ%\bridge.log" 2>&1
if errorlevel 1 ( echo [ERROR] bridge gagal & type "%OBJ%\bridge.log" & exit /b 1 )
cl %CFLAGS% %LOCAL_DEFS% /Fo"%OBJ%\bridge\\" /I"%BRIDGE%" /I"%ROOT%\vendor_winfsp" %APFS_INC% /I"%VENDOR%\include_hfs" "%BRIDGE%\macfs_mount.c" >> "%OBJ%\bridge.log" 2>&1
if errorlevel 1 ( echo [ERROR] bridge gagal & type "%OBJ%\bridge.log" & exit /b 1 )

REM ============================================================
echo [6/6] link macfs.dll
REM ============================================================
link /nologo /DLL /OUT:"%DIST%\macfs.dll" /MACHINE:X64 ^
  "%OBJ%\zlib\*.obj" "%OBJ%\libcerror\*.obj" "%OBJ%\libcthreads\*.obj" ^
  "%OBJ%\libcdata\*.obj" "%OBJ%\libclocale\*.obj" "%OBJ%\libcnotify\*.obj" ^
  "%OBJ%\libcsplit\*.obj" "%OBJ%\libuna\*.obj" "%OBJ%\libcfile\*.obj" ^
  "%OBJ%\libcpath\*.obj" "%OBJ%\libbfio\*.obj" "%OBJ%\libfcache\*.obj" ^
  "%OBJ%\libfdata\*.obj" "%OBJ%\libfdatetime\*.obj" "%OBJ%\libfguid\*.obj" ^
  "%OBJ%\libfmos\*.obj" "%OBJ%\libhmac\*.obj" "%OBJ%\libcaes\*.obj" ^
  "%OBJ%\libfsapfs\*.obj" "%OBJ%\libfshfs\*.obj" "%OBJ%\bridge\*.obj" ^
  advapi32.lib user32.lib > "%OBJ%\link.log" 2>&1
if errorlevel 1 ( echo [ERROR] link gagal & type "%OBJ%\link.log" & exit /b 1 )

echo.
echo [OK] %DIST%\macfs.dll
dir /b "%DIST%\macfs.dll"
endlocal