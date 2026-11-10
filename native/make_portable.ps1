# Membuat MacDriveRescue-Portable.exe dengan dukungan self-update.
#
# Struktur file hasil:
#   [launcher.exe][payload ZIP][8B offset][8B size][magic "MACFSZP1"]
#
# Launcher mengekstrak ZIP sekali ke %LOCALAPPDATA%\MacDriveRescue lalu
# menjalankan exe dari sana. Lokasi instalasi yang stabil memungkinkan
# fitur auto-update menimpa file lama.
#
# Prasyarat:
#   - flutter build windows --release sudah dijalankan
#   - native/dist/macfs.dll ada
#   - native/dist/launcher.exe ada (jalankan native/build_launcher.bat)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$release = Join-Path $root "build\windows\x64\runner\Release"
$dll = Join-Path $PSScriptRoot "dist\macfs.dll"
$launcher = Join-Path $PSScriptRoot "dist\launcher.exe"

if (-not (Test-Path $release)) {
  throw "Folder build tidak ada. Jalankan: flutter build windows --release"
}
if (-not (Test-Path $dll)) {
  throw "macfs.dll tidak ada. Jalankan: native/build.bat"
}
if (-not (Test-Path $launcher)) {
  throw "launcher.exe tidak ada. Jalankan: native/build_launcher.bat"
}

Copy-Item $dll $release -Force

# Sertakan helper update (dipakai fitur auto-update).
$updaterExe = Join-Path $PSScriptRoot "dist\macfs_updater.exe"
if (Test-Path $updaterExe) {
  Copy-Item $updaterExe $release -Force
  Write-Host "      macfs_updater.exe disertakan"
} else {
  Write-Host "[PERINGATAN] macfs_updater.exe tidak ada - auto-update tidak akan berfungsi"
}

$sevenZip = "C:\Program Files\7-Zip\7z.exe"
if (-not (Test-Path $sevenZip)) {
  $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
}
if (-not $sevenZip) { throw "7z.exe tidak ditemukan. Install 7-Zip dulu." }

# ---- 1. Payload ZIP ----
Write-Host "[1/4] Mengompres payload (zip)..."
$payload = Join-Path $env:TEMP "macdrive_payload.zip"
if (Test-Path $payload) { Remove-Item $payload -Force }
# Zip dari isi folder Release (bukan folder itu sendiri).
Push-Location $release
try {
  & $sevenZip a -tzip -mx=5 $payload "*" | Out-Null
} finally {
  Pop-Location
}
$payloadSize = (Get-Item $payload).Length

# ---- 2. Launcher ber-icon ----
Write-Host "[2/4] Memasang icon pada launcher..."
$icon = Join-Path $root "windows\runner\resources\app_icon.ico"
$rcedit = Join-Path $env:TEMP "rcedit.exe"
if (-not (Test-Path $rcedit)) {
  try {
    Invoke-WebRequest "https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe" `
        -OutFile $rcedit -UseBasicParsing
  } catch {
    Write-Host "[PERINGATAN] Gagal mengunduh rcedit: $_"
  }
}
$launcherBranded = Join-Path $env:TEMP "launcher_branded.exe"
Copy-Item $launcher $launcherBranded -Force
if ((Test-Path $rcedit) -and (Test-Path $icon)) {
  & $rcedit $launcherBranded --set-icon $icon | Out-Null
  & $rcedit $launcherBranded --set-version-string "ProductName" "MacDrive Rescue" | Out-Null
  & $rcedit $launcherBranded --set-version-string "FileDescription" "MacDrive Rescue (portable launcher)" | Out-Null
  & $rcedit $launcherBranded --set-version-string "CompanyName" "Adi Darmawan" | Out-Null
  Write-Host "      Icon + metadata launcher OK"
}

# ---- 3. Gabungkan launcher + payload + trailer ----
Write-Host "[3/4] Menggabungkan paket..."
$out = Join-Path $root "MacDriveRescue-Portable.exe"
$combined = Join-Path $env:TEMP "macdrive_combined.exe"
if (Test-Path $combined) { Remove-Item $combined -Force }

$launcherSize = (Get-Item $launcherBranded).Length
$trailer = New-Object byte[] 24
[BitConverter]::GetBytes([UInt64]$launcherSize).CopyTo($trailer, 0)
[BitConverter]::GetBytes([UInt64]$payloadSize).CopyTo($trailer, 8)
[System.Text.Encoding]::ASCII.GetBytes("MACFSZP1").CopyTo($trailer, 16)

$stream = [System.IO.File]::Create($combined)
try {
  foreach ($part in @($launcherBranded, $payload)) {
    $bytes = [System.IO.File]::ReadAllBytes($part)
    $stream.Write($bytes, 0, $bytes.Length)
  }
  $stream.Write($trailer, 0, $trailer.Length)
} finally {
  $stream.Close()
}
Move-Item $combined $out -Force

# ---- 4. Selesai ----
$size = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host "[4/4] Selesai: MacDriveRescue-Portable.exe ($size MB)"
Write-Host "      Sekali ekstrak ke %LOCALAPPDATA%\MacDriveRescue, lalu auto-update aktif."