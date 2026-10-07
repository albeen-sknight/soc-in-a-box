#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Gives DC01 its fixed lab address and turns it into the domain controller for limonada.local.

.DESCRIPTION
    Run on DC01, logged in as Administrator, right after Windows finishes installing.
    It asks for the DSRM password, then the machine reboots on its own.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\lab\01-Promote-DC01.ps1
#>
param(
    [string]$IPAddress    = '10.10.10.10',
    [int]   $PrefixLength = 24,
    [string]$Gateway      = '10.10.10.2',
    [string]$DomainName   = 'limonada.local',
    [string]$NetbiosName  = 'LIMONADA'
)

$ErrorActionPreference = 'Stop'

# Stop straight away if this is the wrong machine
if ($env:COMPUTERNAME -ne 'DC01') {
    throw "This script is for DC01, but this machine is called $env:COMPUTERNAME."
}

# Ask for a password twice so a typo doesn't lock me out
function Read-NewPassword([string]$Prompt) {
    while ($true) {
        $first  = Read-Host $Prompt -AsSecureString
        $second = Read-Host 'Type it again' -AsSecureString
        $a = [System.Net.NetworkCredential]::new('', $first).Password
        $b = [System.Net.NetworkCredential]::new('', $second).Password
        if ($a -and ($a -ceq $b)) { return $first }
        Write-Host "They don't match, try again." -ForegroundColor Yellow
    }
}

# Find the network adapter that's connected
$adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $adapter) { throw 'No connected network adapter found.' }

# A domain controller needs an address that never changes, so clear the automatic one and set a fixed one
Write-Host "Setting $IPAddress on $($adapter.Name)..."
Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null

# Until DC01 runs its own DNS, use VMware's gateway, which passes lookups on to the PC's DNS
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $Gateway

# Install the Active Directory role and its admin tools
Write-Host 'Installing Active Directory Domain Services...'
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null

# DSRM is the emergency password for repairing Active Directory. I type it here and it never gets saved.
$dsrm = Read-NewPassword 'Pick a DSRM password (save it in your password manager)'

# Create the new forest and the limonada.local domain, with DNS on DC01.
# When it finishes, the machine reboots by itself. Log back in as LIMONADA\Administrator.
Write-Host "Creating the $DomainName domain. DC01 reboots when it's done..."
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -SafeModeAdministratorPassword $dsrm `
    -InstallDns `
    -Force
