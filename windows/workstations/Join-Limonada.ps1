#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Gives a workstation its fixed lab address and joins it to the limonada.local domain.

.DESCRIPTION
    Run on WS01 or WS02, logged in as labadmin, once DC01 is up and the staff exist.
    It asks for the domain admin login, then the machine reboots on its own.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\lab\Join-Limonada.ps1
#>
param(
    # Leave empty and the script picks the address from the lab plan below
    [string]$IPAddress    = '',
    [int]   $PrefixLength = 24,
    [string]$Gateway      = '10.10.10.2',
    [string]$DcAddress    = '10.10.10.10',
    [string]$DomainName   = 'limonada.local'
)

$ErrorActionPreference = 'Stop'

# The lab plan: each workstation always gets the same address
$labPlan = @{ 'WS01' = '10.10.10.21'; 'WS02' = '10.10.10.22' }
if (-not $IPAddress) {
    $IPAddress = $labPlan[$env:COMPUTERNAME]
    if (-not $IPAddress) { throw "No address planned for $env:COMPUTERNAME. Pass -IPAddress yourself." }
}

# Find the network adapter that's connected
$adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $adapter) { throw 'No connected network adapter found.' }

# Clear the automatic address and set the fixed one
Write-Host "Setting $IPAddress on $($adapter.Name)..."
Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null

# Use DC01 as the DNS server, the way every machine in a Windows domain finds its domain controller
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DcAddress

# Make sure DC01 answers before trying to join. I knock on its directory port (LDAP, 389)
# instead of pinging, because a fresh address can take a few seconds to come up
# and DC01's firewall may ignore pings anyway.
Write-Host "Checking that $DomainName is reachable..."
$reachable = $false
foreach ($try in 1..6) {
    if (Test-NetConnection -ComputerName $DcAddress -Port 389 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        $reachable = $true
        break
    }
    Start-Sleep -Seconds 5
}
if (-not $reachable) {
    throw "Can't reach DC01 at $DcAddress on port 389. Is it switched on?"
}
Resolve-DnsName $DomainName -Type A | Out-Null

# Join the domain. The login box wants LIMONADA\Administrator or LIMONADA\adm.carlos.ruiz
$cred = Get-Credential -UserName 'LIMONADA\Administrator' -Message "Domain admin login to join $DomainName"
Write-Host "Joining $DomainName. The machine reboots when it's done..."
Add-Computer -DomainName $DomainName -Credential $cred -Restart
