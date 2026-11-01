# Builds dist\BetterMart-Win64-Shipping.zip from the profile folder, with the
# profile files at the zip's root (config.txt, user_script.txt, scripts\).
# Entry names use forward slashes, so every unzip tool keeps the folders.
#
# Run from this folder:  powershell -ExecutionPolicy Bypass -File build_release.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$profileDir = Join-Path $root 'profile'
$dist = Join-Path $root 'dist'
$zipPath = Join-Path $dist 'BetterMart-Win64-Shipping.zip'

New-Item -ItemType Directory -Force $dist | Out-Null
if (Test-Path $zipPath) { Remove-Item $zipPath }

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    Get-ChildItem $profileDir -Recurse -File | ForEach-Object {
        $name = $_.FullName.Substring($profileDir.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $name) | Out-Null
        Write-Host "  $name"
    }
}
finally {
    $zip.Dispose()
}
Write-Host "Built $zipPath"
