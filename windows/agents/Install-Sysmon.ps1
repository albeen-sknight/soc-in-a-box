#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Sysmon on a lab machine with the sysmon-modular config from this folder.

.DESCRIPTION
    Windows' own logs say "a program started". Sysmon adds who started it, with what
    command line, what it connected to, and whether it touched LSASS, where passwords live.
    Run on DC01, WS01 and WS02. Safe to run again: if Sysmon is already there it just
    reloads the config.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\lab\Install-Sysmon.ps1
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'sysmonconfig.xml'),
    # SHA256 of the pinned config, so a changed or broken file never gets loaded by accident
    [string]$ConfigHash = 'F115AAC5770DAE468E5CFB48C58A8B6E37588208A31F1B746812C534577A244B'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes the download much faster in Windows PowerShell

# 1. Check the config is exactly the one I reviewed
$actual = (Get-FileHash $ConfigPath -Algorithm SHA256).Hash
if ($actual -ne $ConfigHash) {
    throw "sysmonconfig.xml doesn't match the pinned version. Expected $ConfigHash, got $actual."
}

# 2. Download Sysmon from Microsoft's Sysinternals site into a temporary folder
$work = Join-Path $env:TEMP 'sysmon-install'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$zip = Join-Path $work 'Sysmon.zip'
Write-Host 'Downloading Sysmon from Sysinternals...'
Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/Sysmon.zip' -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $work -Force
$exe = Join-Path $work 'Sysmon64.exe'

# 3. Only run it if Microsoft really signed it
$signature = Get-AuthenticodeSignature $exe
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "Sysmon64.exe isn't validly signed by Microsoft (status: $($signature.Status)). Not installing."
}

# 4. Install it, or just load the new config if it's already running
if (Get-Service -Name 'Sysmon64' -ErrorAction SilentlyContinue) {
    Write-Host 'Sysmon is already installed, updating the config...'
    & $exe -c $ConfigPath | Out-Null
} else {
    Write-Host 'Installing Sysmon...'
    & $exe -accepteula -i $ConfigPath | Out-Null
}
if ($LASTEXITCODE -ne 0) { throw "Sysmon exited with code $LASTEXITCODE." }

# 5. Prove it's working: the service runs and the Sysmon log has events in it
Start-Sleep -Seconds 5
$service = Get-Service -Name 'Sysmon64'
$events  = Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -MaxEvents 5 -ErrorAction SilentlyContinue

Remove-Item $work -Recurse -Force

Write-Host ''
if ($service.Status -eq 'Running' -and $events) {
    Write-Host "Done. Sysmon is running on $env:COMPUTERNAME and logging." -ForegroundColor Green
} else {
    Write-Host "Sysmon installed, but check it: service is $($service.Status), recent events: $(@($events).Count)." -ForegroundColor Yellow
}
