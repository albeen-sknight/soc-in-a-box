#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the Splunk Universal Forwarder on a lab machine and points it at the SOC.

.DESCRIPTION
    The forwarder is the courier. It reads the Windows and Sysmon logs on this machine and
    carries them to Splunk at 10.10.10.1:9997. Run on DC01, WS01 and WS02.
    Safe to run again: if the forwarder is already there it just refreshes the config.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File D:\lab\Install-Forwarder.ps1
#>
param(
    # The installer I downloaded from splunk.com, copied next to this script (not kept in Git)
    [string]$Msi = '',
    [string]$Indexer = '10.10.10.1',
    [int]   $Port = 9997
)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramFiles 'SplunkUniversalForwarder'
$appSource  = Join-Path $PSScriptRoot 'forwarder\limonada_forwarder'

# 1. Can this machine reach Splunk at all? If not, there's no point installing anything yet.
Write-Host "Checking that Splunk answers on ${Indexer}:${Port}..."
if (-not (Test-NetConnection -ComputerName $Indexer -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    throw "Can't reach Splunk at ${Indexer}:${Port}. Is Docker running, and is the firewall rule on the PC in place?"
}

# 2. Install the forwarder if it isn't there yet
if (-not (Get-Service -Name 'SplunkForwarder' -ErrorAction SilentlyContinue)) {
    if (-not $Msi) {
        $Msi = (Get-ChildItem -Path $PSScriptRoot -Filter 'splunkforwarder-*-x64.msi' | Select-Object -First 1).FullName
    }
    if (-not $Msi) { throw "No splunkforwarder-*-x64.msi found next to this script." }

    # Only run it if Splunk really signed it
    $signature = Get-AuthenticodeSignature $Msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Splunk') {
        throw "The forwarder installer isn't validly signed by Splunk (status: $($signature.Status)). Not installing."
    }

    Write-Host "Installing $(Split-Path $Msi -Leaf)..."
    $log = Join-Path $env:TEMP 'splunkforwarder-install.log'
    $arguments = @(
        '/i', "`"$Msi`"",
        'AGREETOLICENSE=Yes',   # accept the licence without a pop up
        'GENRANDOMPASSWORD=1',  # the forwarder's own local admin gets a random password: nobody logs into it
        'USE_LOCAL_SYSTEM=1',   # run as Local System, so it can read the Security and Sysmon logs
        'LAUNCHSPLUNK=0',       # don't start yet: the config goes in first
        '/quiet', '/norestart',
        '/L*v', "`"$log`""
    )
    $process = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "The installer failed with code $($process.ExitCode). Details in $log" }
}

# 3. Copy in my app: what to read (inputs.conf) and where to send it (outputs.conf)
Write-Host 'Copying the limonada_forwarder app...'
$appTarget = Join-Path $installDir 'etc\apps\limonada_forwarder'
if (Test-Path $appTarget) { Remove-Item $appTarget -Recurse -Force }
Copy-Item $appSource $appTarget -Recurse

# 4. Start it (or restart it so it reads the new config)
Write-Host 'Starting the forwarder...'
Restart-Service -Name 'SplunkForwarder' -Force
Set-Service -Name 'SplunkForwarder' -StartupType Automatic

# 5. Prove it's connected: the forwarder should hold an open connection to Splunk
Start-Sleep -Seconds 15
$connected = Get-NetTCPConnection -RemoteAddress $Indexer -RemotePort $Port -State Established -ErrorAction SilentlyContinue

Write-Host ''
if ($connected) {
    Write-Host "Done. $env:COMPUTERNAME is sending its logs to Splunk at ${Indexer}:${Port}." -ForegroundColor Green
} else {
    Write-Host "Installed, but no connection to ${Indexer}:${Port} yet. Wait a minute and check again with:" -ForegroundColor Yellow
    Write-Host "  Get-NetTCPConnection -RemotePort $Port" -ForegroundColor Yellow
}
