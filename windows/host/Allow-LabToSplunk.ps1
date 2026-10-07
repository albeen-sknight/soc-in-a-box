#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Opens Splunk's forwarder port on the PC, but only to the lab network.

.DESCRIPTION
    Run on the PC itself, as administrator. It's like telling the building's security desk:
    let couriers from the lab floor through to the camera room, and nobody else.
    The forwarders on DC01, WS01 and WS02 (10.10.10.0/24) can reach Splunk on port 9997.
    Nothing on my home network or the internet can.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\windows\host\Allow-LabToSplunk.ps1
#>
param(
    [string]$LabNetwork = '10.10.10.0/24',
    [int]   $Port       = 9997
)

$ErrorActionPreference = 'Stop'
$name = "SOC in a Box: lab forwarders to Splunk ($Port)"

# Replace the rule if it's already there, so running this twice doesn't stack copies
Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule

New-NetFirewallRule `
    -DisplayName   $name `
    -Description   'Lets the lab VMs send their logs to Splunk. Nothing else may connect to this port.' `
    -Direction     Inbound `
    -Protocol      TCP `
    -LocalPort     $Port `
    -RemoteAddress $LabNetwork `
    -Action        Allow `
    -Profile       Any | Out-Null

Write-Host "Done. Only $LabNetwork can reach port $Port on this PC." -ForegroundColor Green
