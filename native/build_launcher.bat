@echo off
REM Build launcher.exe (bootstrap kecil untuk MacDriveRescue-Portable.exe)
setlocal
set ROOT=%~dp0
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSPATH=%%i
if not defined VSPATH ( echo [ERROR] VS C++ tools tidak ditemukan & exit /b 1 )
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1

set OUT=%ROOT%dist
if not exist "%OUT%" mkdir "%OUT%"

cl /nologo /O2 /MT /W3 /DUNICODE /D_UNICODE /Fo"%OUT%\launcher.obj" "%ROOT%launcher\launcher.c" /link /SUBSYSTEM:WINDOWS /OUT:"%OUT%\launcher.exe" /MANIFESTUAC:"level='asInvoker' uiAccess='false'" shell32.lib ole32.lib user32.lib advapi32.lib
if errorlevel 1 ( echo [ERROR] build launcher gagal & exit /b 1 )
echo [OK] %OUT%\launcher.exe
endlocal
