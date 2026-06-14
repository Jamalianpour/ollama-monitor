# Ollama Monitor – Windows uninstaller (run as Administrator)
[CmdletBinding()]
param(
    [string]$ServiceName = "OllamaMonitor",
    [string]$InstallDir  = "C:\OllamaMonitor",
    [switch]$DeleteData
)

$ErrorActionPreference = "Stop"

$nssm = (Get-Command nssm -ErrorAction SilentlyContinue)?.Source
if ($nssm) {
    Write-Host "==> Stopping and removing service"
    & $nssm stop   $ServiceName confirm 2>$null
    & $nssm remove $ServiceName confirm 2>$null
} else {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName
}

Write-Host "==> Removing install directory: $InstallDir"
Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue

if (-not $DeleteData) {
    $ans = Read-Host "Delete database at $InstallDir\data? (y/N)"
    if ($ans -match "^[Yy]$") { $DeleteData = $true }
}
if ($DeleteData) {
    Remove-Item -Path "$InstallDir\data" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "    Database deleted."
}

Write-Host "✓ Ollama Monitor uninstalled."
