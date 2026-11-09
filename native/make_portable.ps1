# Membuat satu file exe portable (self-extracting) dari hasil build Flutter.
#
# Hasil: MacDriveRescue-Portable.exe — double-click langsung jalan
# (ekstrak ke temp + auto-run). Hanya butuh UAC untuk akses raw disk.
#
# Prasyarat:
#   - flutter build windows --release sudah dijalankan
#   - native/dist/macfs.dll sudah ada
#   - 7-Zip terpasang (7z.exe)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$release = Join-Path $root "build\windows\x64\runner\Release"
$dll = Join-Path $PSScriptRoot "dist\macfs.dll"

if (-not (Test-Path $release)) {
  throw "Folder build tidak ada. Jalankan dulu: flutter build windows --release"
}
if (-not (Test-Path $dll)) {
  throw "macfs.dll tidak ada. Jalankan dulu: native/build.bat"
}

Copy-Item $dll $release -Force

# Cari 7-Zip.
$sevenZip = "C:\Program Files\7-Zip\7z.exe"
if (-not (Test-Path $sevenZip)) {
  $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
}
if (-not $sevenZip) {
  throw "7z.exe tidak ditemukan. Install 7-Zip dulu."
}

# SFX resmi dari LZMA SDK (hanya 34 KB, tanpa dialog ekstrak).
$sfx = Join-Path $env:TEMP "7zS2.sfx"
if (-not (Test-Path $sfx)) {
  Write-Host "[1/4] Mengunduh LZMA SDK untuk SFX..."
  $sdk = Join-Path $env:TEMP "lzma_sdk.7z"
  if (-not (Test-Path $sdk)) {
    Invoke-WebRequest "https://www.7-zip.org/a/lzma2501.7z" -OutFile $sdk -UseBasicParsing
  }
  & $sevenZip e $sdk -o"$env:TEMP\lzma_sfx" "bin\7zS2.sfx" -y | Out-Null
  Copy-Item "$env:TEMP\lzma_sfx\7zS2.sfx" $sfx -Force
}

# Config SFX.
$config = Join-Path $env:TEMP "sfx_config.txt"
@'
;!@Install@!UTF-8!
Title="MacDrive Rescue"
RunProgram="macdrive_rescue.exe"
GUIMode="0"
;!@InstallEnd@!
'@ | Set-Content $config -Encoding UTF8

# Arsip payload.
Write-Host "[2/4] Mengompres payload..."
$payload = Join-Path $env:TEMP "macdrive_payload.7z"
if (Test-Path $payload) { Remove-Item $payload -Force }
& $sevenZip a -t7z -mx=5 $payload "$release\*" | Out-Null

# Gabungkan SFX + config + payload.
Write-Host "[3/4] Menggabungkan SFX..."
$out = Join-Path $root "MacDriveRescue-Portable.exe"
$combined = Join-Path $env:TEMP "macdrive_combined.exe"
if (Test-Path $combined) { Remove-Item $combined -Force }
cmd /c "copy /b `"$sfx`" + `"$config`" + `"$payload`" `"$combined`"" | Out-Null
Move-Item $combined $out -Force

$size = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host "[4/4] Selesai: MacDriveRescue-Portable.exe ($size MB)"
Write-Host "       Double-click untuk menjalankan (UAC akan muncul)."