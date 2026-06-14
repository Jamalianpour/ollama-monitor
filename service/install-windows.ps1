# ─────────────────────────────────────────────────────────────────────────────
# Ollama Monitor – Windows Service Installer
# Requires: Python 3.10+, NSSM (https://nssm.cc)
#
# Usage (run as Administrator):
#   .\install-windows.ps1
#   .\install-windows.ps1 -InstallDir "C:\OllamaMonitor" -Port 12434
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [string]$InstallDir = "C:\OllamaMonitor",
    [string]$ServiceName = "OllamaMonitor",
    [int]$Port = 12434,
    [string]$OllamaHost = "http://localhost:11434",
    [int]$LogKeepDays = 7
)

$ErrorActionPreference = "Stop"

# ── Check admin ───────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

# ── Check Python ──────────────────────────────────────────────────────────────
$python = (Get-Command python -ErrorAction SilentlyContinue)?.Source
if (-not $python) {
    Write-Error "Python not found. Install from https://python.org"
    exit 1
}
Write-Host "==> Using Python: $python"

# ── Check / install NSSM ─────────────────────────────────────────────────────
$nssm = (Get-Command nssm -ErrorAction SilentlyContinue)?.Source
if (-not $nssm) {
    Write-Host "==> NSSM not found. Attempting to install via winget..."
    try {
        winget install --id NSSM.NSSM --silent --accept-package-agreements --accept-source-agreements
        $nssm = (Get-Command nssm -ErrorAction SilentlyContinue)?.Source
    } catch { }
    if (-not $nssm) {
        Write-Error "NSSM is required. Download from https://nssm.cc and add to PATH."
        exit 1
    }
}
Write-Host "==> Using NSSM: $nssm"

# ── Copy source files ─────────────────────────────────────────────────────────
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$backendDest = "$InstallDir\backend"
Write-Host "==> Copying backend to $backendDest"
New-Item -ItemType Directory -Force -Path $backendDest | Out-Null
Copy-Item -Path "$repoRoot\backend\*" -Destination $backendDest -Recurse -Force

# ── Python venv ───────────────────────────────────────────────────────────────
$venv = "$InstallDir\.venv"
Write-Host "==> Creating Python venv at $venv"
& $python -m venv $venv
& "$venv\Scripts\pip.exe" install --quiet --upgrade pip
& "$venv\Scripts\pip.exe" install --quiet -r "$backendDest\requirements.txt"

# ── DB directory ──────────────────────────────────────────────────────────────
$dbDir = "$InstallDir\data"
New-Item -ItemType Directory -Force -Path $dbDir | Out-Null
$dbPath = "$dbDir\monitor.db"

# ── Stop existing service ─────────────────────────────────────────────────────
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "==> Stopping existing service"
    & $nssm stop $ServiceName confirm
    & $nssm remove $ServiceName confirm
}

# ── Register with NSSM ───────────────────────────────────────────────────────
Write-Host "==> Registering Windows service: $ServiceName"
$pythonExe = "$venv\Scripts\python.exe"
$mainPy    = "$backendDest\main.py"

& $nssm install $ServiceName $pythonExe $mainPy
& $nssm set $ServiceName AppDirectory $backendDest
& $nssm set $ServiceName DisplayName "Ollama Monitor"
& $nssm set $ServiceName Description "Real-time monitoring backend for Ollama"
& $nssm set $ServiceName Start SERVICE_AUTO_START

# Environment variables
& $nssm set $ServiceName AppEnvironmentExtra `
    "OLLAMA_HOST=$OllamaHost" `
    "MONITOR_DB=$dbPath" `
    "LOG_KEEP_DAYS=$LogKeepDays"

# Logging
$logDir = "$InstallDir\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
& $nssm set $ServiceName AppStdout "$logDir\stdout.log"
& $nssm set $ServiceName AppStderr "$logDir\stderr.log"
& $nssm set $ServiceName AppRotateFiles 1
& $nssm set $ServiceName AppRotateOnline 1
& $nssm set $ServiceName AppRotateBytes 10485760  # 10 MB

# Restart on failure
& $nssm set $ServiceName AppExit Default Restart
& $nssm set $ServiceName AppRestartDelay 5000

# ── Start service ─────────────────────────────────────────────────────────────
Write-Host "==> Starting service"
& $nssm start $ServiceName

Start-Sleep -Seconds 2
$svc = Get-Service -Name $ServiceName
Write-Host ""
Write-Host "✓ Ollama Monitor installed."
Write-Host ""
Write-Host "  Service status : $($svc.Status)"
Write-Host "  Dashboard      : http://localhost:$Port  (after Flutter build)"
Write-Host "  API health     : http://localhost:$Port/api/health"
Write-Host "  DB             : $dbPath"
Write-Host "  Logs           : $logDir"
Write-Host ""
Write-Host "  To stop:      Stop-Service $ServiceName"
Write-Host "  To uninstall: .\uninstall-windows.ps1"
