# Mengunduh dan mengekstrak source library native (libfsapfs, libfshfs, zlib)
# ke folder native/vendor. Jalankan sekali sebelum native/build.bat.
#
# Sumber: sdist PyPI (berisi source C lengkap libyal + semua dependensi)
#         dan zlib dari GitHub (madler/zlib).

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $PSScriptRoot "vendor"
$downloads = Join-Path $env:TEMP "macfs_deps"

New-Item -ItemType Directory -Force $vendor | Out-Null
New-Item -ItemType Directory -Force $downloads | Out-Null

if ((Test-Path (Join-Path $vendor "libfsapfs")) -and
    (Test-Path (Join-Path $vendor "libfshfs")) -and
    (Test-Path (Join-Path $vendor "zlib"))) {
  Write-Host "[OK] native/vendor sudah lengkap."
  exit 0
}

$python = "py"
if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
  $python = "python"
}

Write-Host "[1/3] Mengunduh sdist libfsapfs-python..."
& $python -m pip download libfsapfs-python --no-binary :all: --no-deps -d $downloads
Write-Host "[2/3] Mengunduh sdist libfshfs-python..."
& $python -m pip download libfshfs-python --no-binary :all: --no-deps -d $downloads

$apfsTar = Get-ChildItem $downloads -Filter "libfsapfs_python-*.tar.gz" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$hfsTar = Get-ChildItem $downloads -Filter "libfshfs_python-*.tar.gz" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $apfsTar -or -not $hfsTar) {
  throw "Gagal mengunduh sdist."
}

$src = Join-Path $downloads "src"
if (Test-Path $src) { Remove-Item $src -Recurse -Force }
New-Item -ItemType Directory -Force $src | Out-Null
Write-Host "[3/3] Mengekstrak..."
tar -xzf $apfsTar.FullName -C $src
tar -xzf $hfsTar.FullName -C $src

$apfsDir = Get-ChildItem $src -Directory -Filter "libfsapfs_python-*" | Select-Object -First 1
$hfsDir = Get-ChildItem $src -Directory -Filter "libfshfs_python-*" | Select-Object -First 1

# Salin library yang dipakai.
$libs = @(
  "libcerror", "libcthreads", "libcdata", "libclocale", "libcnotify",
  "libcsplit", "libuna", "libcfile", "libcpath", "libbfio", "libfcache",
  "libfdata", "libfdatetime", "libfguid", "libfmos", "libhmac", "libcaes"
)
foreach ($lib in $libs) {
  Copy-Item (Join-Path $apfsDir.FullName $lib) (Join-Path $vendor $lib) -Recurse -Force
}
Copy-Item (Join-Path $apfsDir.FullName "libfsapfs") (Join-Path $vendor "libfsapfs") -Recurse -Force
Copy-Item (Join-Path $hfsDir.FullName "libfshfs") (Join-Path $vendor "libfshfs") -Recurse -Force
Copy-Item (Join-Path $apfsDir.FullName "common") (Join-Path $vendor "common") -Recurse -Force
Copy-Item (Join-Path $hfsDir.FullName "common") (Join-Path $vendor "common_hfs") -Recurse -Force
Copy-Item (Join-Path $apfsDir.FullName "include") (Join-Path $vendor "include_apfs") -Recurse -Force
Copy-Item (Join-Path $hfsDir.FullName "include") (Join-Path $vendor "include_hfs") -Recurse -Force

# zlib dari GitHub.
$zlibZip = Join-Path $downloads "zlib131.zip"
if (-not (Test-Path $zlibZip)) {
  Write-Host "[zlib] Mengunduh zlib 1.3.1..."
  Invoke-WebRequest "https://github.com/madler/zlib/releases/download/v1.3.1/zlib131.zip" `
      -OutFile $zlibZip -UseBasicParsing
}
Expand-Archive $zlibZip -DestinationPath $downloads -Force
Copy-Item (Join-Path $downloads "zlib-1.3.1") (Join-Path $vendor "zlib") -Recurse -Force

# Prune file yang tidak dipakai build (docs, tests, dll.) agar repo kecil.
$prune = @("doc", "examples", "test", "contrib", "old", "manuals", "tests",
           "ossfuzz", "po", "dpkg", "m4", "msvscpp")
foreach ($dir in $prune) {
  Get-ChildItem $vendor -Directory | ForEach-Object {
    $target = Join-Path $_.FullName $dir
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
  }
}

Write-Host "[OK] native/vendor siap. Lanjutkan dengan native/build.bat"