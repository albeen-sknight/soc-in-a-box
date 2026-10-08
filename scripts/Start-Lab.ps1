# Start-Lab.ps1
# Brings the whole lab up in the right order: Docker, the SOC containers, WEB01, then DC01, WS01 and WS02.
# At the end it checks which machines are sending logs, opens the SOC dashboard and a terminal in the repo.
# Run it from anywhere: it finds the repo from its own location.

$ErrorActionPreference = 'Continue'                          # keep going if one step complains
$repo   = Split-Path $PSScriptRoot -Parent                       # C:\GitHub\soc-in-a-box
$vmRoot = 'C:\VMs'                                               # where the VMs live
$labVms = 'DC01', 'WS01', 'WS02'                                 # start order: the domain controller first
$dashboard = 'http://localhost:8000/en-US/app/limonada_soc/soc_overview'

function Say($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok($text)  { Write-Host "   OK  $text" -ForegroundColor Green }
function Warn($text){ Write-Host "   !!  $text" -ForegroundColor Yellow }

# Wait until a test returns true, checking every few seconds. Gives up after $seconds.
function Wait-Until([scriptblock]$test, [int]$seconds, [int]$every = 5) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $test) { return $true }
        Start-Sleep -Seconds $every
        Write-Host '.' -NoNewline
    }
    return $false
}

# 1. Docker Desktop
Say 'Docker Desktop'
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    # Docker is not answering. Find Docker Desktop's exe and launch it; if it is not where we expect, ask you to open it.
    $dockerExe = @("$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
                   "$env:LOCALAPPDATA\Docker\Docker Desktop.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($dockerExe) { Start-Process $dockerExe; Ok 'launching Docker Desktop' }
    else { Warn 'Could not find Docker Desktop.exe. Open Docker Desktop yourself from the Start menu.' }
    Write-Host '   waiting for the Docker engine' -NoNewline
    if (Wait-Until { docker info *> $null; $LASTEXITCODE -eq 0 } 180 5) { Write-Host ''; Ok 'Docker is running' }
    else { Write-Host ''; Warn 'Docker did not come up in 3 minutes. Open Docker Desktop, wait for the whale to go green, then run this again.'; return }
} else { Ok 'Docker was already running' }

# 2. WEB01, the WAF Flight Recorder containers (they already exist, so just start them)
Say 'WEB01 (WAF Flight Recorder)'
$waf = docker ps -aq --filter 'label=com.docker.compose.project=waf-flight-recorder'
if ($waf) { docker start $waf | Out-Null; Ok "started $(@($waf).Count) WAF containers" }
else { Warn 'No waf-flight-recorder containers found. Build them once from C:\GitHub\waf-flight-recorder.' }

# 3. The SOC: Splunk, the WAF shipper and the pager relay
Say 'SOC containers (Splunk, waf-shipper, pager-relay)'
Push-Location $repo
docker compose up -d                                             # starts them; recreates any whose config changed
Pop-Location

# 4. The Windows VMs. vmrun "start" also resumes a suspended VM.
Say 'Lab VMs'
$vmrun = @("${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmrun.exe",
           "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vmrun) { Warn 'vmrun.exe not found. Start the VMs by hand in VMware.' }
else {
    $running = & $vmrun -T ws list                               # VMs that are already on
    foreach ($name in $labVms) {
        $vmx = Get-ChildItem $vmRoot -Recurse -Filter "$name.vmx" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $vmx) { Warn "$name.vmx not found under $vmRoot"; continue }
        if ($running -contains $vmx.FullName) { Ok "$name was already on"; continue }
        & $vmrun -T ws start $vmx.FullName gui | Out-Null         # power on or resume, in the VMware window
        Ok "$name starting"
        if ($name -eq 'DC01') {
            # The workstations need the domain controller, so wait for it to answer on LDAP (port 389)
            Write-Host '   waiting for DC01 to answer' -NoNewline
            $up = Wait-Until { (Test-NetConnection 10.10.10.10 -Port 389 -WarningAction SilentlyContinue).TcpTestSucceeded } 300 10
            Write-Host ''
            if ($up) { Ok 'DC01 is answering' } else { Warn 'DC01 is slow to answer; starting the workstations anyway' }
        }
    }
}

# 5. Wait for Splunk to be healthy
Say 'Splunk'
Write-Host '   waiting for Splunk' -NoNewline
$healthy = Wait-Until { (docker inspect -f '{{.State.Health.Status}}' splunk) -eq 'healthy' } 300 10
Write-Host ''
if ($healthy) { Ok 'Splunk is healthy' } else { Warn 'Splunk is not healthy yet. Check it in Docker Desktop.' }

# 6. Which machines are sending logs? Asks Splunk for every host seen in the last 10 minutes.
Say 'Log check'
$pw = (Get-Content (Join-Path $repo '.env') | Where-Object { $_ -like 'SPLUNK_PASSWORD=*' }) -replace '^SPLUNK_PASSWORD=', ''
$query = '| tstats count where index IN (wineventlog, sysmon, waf) earliest=-10m by host'
function Get-LiveHosts {
    $csv = curl.exe -sk -u "admin:$pw" https://127.0.0.1:8089/services/search/jobs/export `
        --data-urlencode "search=$query" -d output_mode=csv 2>$null
    if (-not $csv) { return @() }
    return @($csv | ConvertFrom-Csv | ForEach-Object { $_.host })
}
Write-Host '   waiting for the forwarders to reconnect' -NoNewline
$null = Wait-Until { $h = Get-LiveHosts; ($labVms | Where-Object { $h -notcontains $_ }).Count -eq 0 } 300 15
Write-Host ''
$live = Get-LiveHosts
foreach ($name in $labVms + 'WEB01') {
    if ($live -contains $name) { Ok "$name is sending logs" }
    elseif ($name -eq 'WEB01') { Warn 'WEB01: no WAF events in 10 minutes. Normal if nobody has browsed Juice Shop.' }
    else { Warn "$name has sent nothing in 10 minutes. Is it still booting?" }
}

# 7. Open the SOC dashboard
Say 'Done'
Start-Process $dashboard
Ok 'SOC dashboard opened in your browser'


# 8. Open a PowerShell window in the repo folder, ready for docker commands and the attacks
Say 'Terminal'
Start-Process powershell -ArgumentList '-NoExit', '-Command', "Set-Location '$repo'; Write-Host 'Lab terminal ready, you are in the repo folder.' -ForegroundColor Green"
Ok 'opened a PowerShell window in the repo folder'
