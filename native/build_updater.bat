@echo off
REM Build macfs_updater.exe (helper update tanpa console)
setlocal
set ROOT=%~dp0
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSPATH=%%i
if not defined VSPATH ( echo [ERROR] VS C++ tools tidak ditemukan & exit /b 1 )
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1

set OUT=%ROOT%dist
if not exist "%OUT%" mkdir "%OUT%"

cl /nologo /O2 /MT /W3 /DUNICODE /D_UNICODE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\macfs_updater.obj" "%ROOT%launcher\macfs_updater.c" /link /SUBSYSTEM:WINDOWS /OUT:"%OUT%\macfs_updater.exe" /MANIFESTUAC:"level='asInvoker' uiAccess='false'" shell32.lib ole32.lib user32.lib advapi32.lib
if errorlevel 1 ( echo [ERROR] build updater gagal & exit /b 1 )
echo [OK] %OUT%\macfs_updater.exe
endlocal
