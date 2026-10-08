# Stop-Lab.ps1
# Puts the lab to sleep for the night: suspends the VMs (they resume exactly where they were),
# then stops the SOC and WEB01 containers. No logs or settings are lost.

$ErrorActionPreference = 'Continue'
$repo   = Split-Path $PSScriptRoot -Parent                       # C:\GitHub\soc-in-a-box
$vmRoot = 'C:\VMs'
$labVms = 'WS02', 'WS01', 'DC01'                                 # workstations first, the domain controller last

function Say($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok($text)  { Write-Host "   OK  $text" -ForegroundColor Green }

# 1. Suspend the VMs
Say 'Lab VMs'
$vmrun = @("${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmrun.exe",
           "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$running = & $vmrun -T ws list                                   # VMs that are on right now
foreach ($name in $labVms) {
    $vmx = Get-ChildItem $vmRoot -Recurse -Filter "$name.vmx" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vmx -and ($running -contains $vmx.FullName)) {
        & $vmrun -T ws suspend $vmx.FullName | Out-Null          # save its memory to disk and stop it
        Ok "$name suspended"
    } else { Ok "$name was already off" }
}

# 2. Stop the SOC containers (Splunk, waf-shipper, pager-relay)
Say 'SOC containers'
Push-Location $repo
docker compose stop
Pop-Location

# 3. Stop WEB01
Say 'WEB01 (WAF Flight Recorder)'
$waf = docker ps -q --filter 'label=com.docker.compose.project=waf-flight-recorder'
if ($waf) { docker stop $waf | Out-Null; Ok 'WAF containers stopped' } else { Ok 'already stopped' }

Say 'Lab is asleep. Run Start-Lab tomorrow.'
