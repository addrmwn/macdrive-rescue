# Membuat GitHub Release dengan encoding UTF-8 yang benar.
#
# PENTING: jangan pakai PowerShell here-string (@") untuk body rilis.
# Windows PowerShell 5.1 menulis file/argumen sebagai ANSI sehingga em dash
# (—) dan panah (→) menjadi mojibake (â€", â†').
#
# Gunakan script ini: body ditulis ke file UTF-8 tanpa BOM, lalu dikirim
# sebagai byte UTF-8 ke GitHub API.
#
# Pemakaian:
#   powershell -ExecutionPolicy Bypass -File native/create_release.ps1 `
#       -Tag v2.4.0 -Name "MacDrive Rescue v2.4.0" -BodyFile notes.md

param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$BodyFile,
    [string]$TargetCommitish = "main",
    [string[]]$Assets = @()
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BodyFile)) { throw "Body file tidak ditemukan: $BodyFile" }

# Baca sebagai UTF-8 (tanpa BOM) dan verifikasi tidak ada karakter rusak.
$body = [System.IO.File]::ReadAllText((Resolve-Path $BodyFile), [System.Text.Encoding]::UTF8)
if ($body.Contains([char]0xFFFD)) {
    throw "Body mengandung karakter rusak (U+FFFD). Periksa encoding file."
}
if ($body.Contains([char]0x00E2 + [char]0x20AC)) {
    throw "Body mengandung mojibake (â€...). Simpan file sebagai UTF-8 yang benar."
}

# Token dari Git Credential Manager.
$credential = "protocol=https`nhost=github.com`n`n" | git credential fill 2>&1
$token = ($credential | Select-String "^password=").Line -replace "^password=", ""
if (-not $token) { throw "Token GitHub tidak ditemukan (git credential fill gagal)." }

$payload = @{
    tag_name = $Tag
    target_commitish = $TargetCommitish
    name = $Name
    body = $body
    draft = $false
    prerelease = $false
} | ConvertTo-Json -Depth 5

# Kirim sebagai byte UTF-8 eksplisit (bukan ANSI).
$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$request = [System.Net.HttpWebRequest]::Create(
    "https://api.github.com/repos/addrmwn/macdrive-rescue/releases")
$request.Method = "POST"
$request.ContentType = "application/json; charset=utf-8"
$request.Headers.Add("Authorization", "token $token")
$request.UserAgent = "macdrive-rescue"
$request.ContentLength = $bytes.Length
$stream = $request.GetRequestStream()
$stream.Write($bytes, 0, $bytes.Length)
$stream.Close()
$response = $request.GetResponse()
$reader = New-Object System.IO.StreamReader($response.GetResponseStream(),
    [System.Text.Encoding]::UTF8)
$release = $reader.ReadToEnd() | ConvertFrom-Json
$reader.Close()
Write-Host "Release dibuat: $($release.html_url)"
Write-Host "ID: $($release.id)"

# Upload aset.
foreach ($asset in $Assets) {
    if (-not (Test-Path $asset)) { Write-Host "[SKIP] $asset tidak ada"; continue }
    $fileName = Split-Path $asset -Leaf
    $fileBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $asset))
    $uploadUrl = "https://uploads.github.com/repos/addrmwn/macdrive-rescue/releases/$($release.id)/assets?name=$fileName"
    $uploadRequest = [System.Net.HttpWebRequest]::Create($uploadUrl)
    $uploadRequest.Method = "POST"
    $uploadRequest.ContentType = "application/octet-stream"
    $uploadRequest.Headers.Add("Authorization", "token $token")
    $uploadRequest.UserAgent = "macdrive-rescue"
    $uploadRequest.ContentLength = $fileBytes.Length
    $uploadStream = $uploadRequest.GetRequestStream()
    $uploadStream.Write($fileBytes, 0, $fileBytes.Length)
    $uploadStream.Close()
    $uploadResponse = $uploadRequest.GetResponse()
    $uploadReader = New-Object System.IO.StreamReader($uploadResponse.GetResponseStream())
    $uploadReader.ReadToEnd() | Out-Null
    $uploadReader.Close()
    $sizeMb = [math]::Round($fileBytes.Length / 1MB, 1)
    Write-Host "[OK] $fileName ($sizeMb MB)"
}

# Verifikasi encoding setelah dibuat.
$verifyRequest = [System.Net.HttpWebRequest]::Create(
    "https://api.github.com/repos/addrmwn/macdrive-rescue/releases/tags/$Tag")
$verifyRequest.Headers.Add("Authorization", "token $token")
$verifyRequest.UserAgent = "macdrive-rescue"
$verifyResponse = $verifyRequest.GetResponse()
$verifyReader = New-Object System.IO.StreamReader($verifyResponse.GetResponseStream(),
    [System.Text.Encoding]::UTF8)
$verified = $verifyReader.ReadToEnd() | ConvertFrom-Json
$verifyReader.Close()
$savedBody = $verified.body
$mojibake = $savedBody.Contains([char]0x00E2 + [char]0x20AC)
$replacement = $savedBody.Contains([char]0xFFFD)
Write-Host ""
Write-Host "Verifikasi encoding: mojibake=$mojibake replacement_char=$replacement"