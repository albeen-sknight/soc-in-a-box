#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fills the limonada.local domain: departments, groups and the 40 fictional staff.

.DESCRIPTION
    Run on DC01 after it has rebooted as a domain controller, logged in as LIMONADA\Administrator.
    It asks for two passwords: the shared one for the staff, and one for the IT admin account.
    Safe to run twice: anything that already exists gets skipped.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\lab\02-Build-Limonada.ps1
#>
param(
    [string]  $StaffCsv      = (Join-Path $PSScriptRoot 'staff.csv'),
    # VMware's NAT gateway relays DNS to the PC. Public DNS like 1.1.1.1 gets blocked on my network.
    [string[]]$DnsForwarders = @('10.10.10.2')
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain = Get-ADDomain
$root   = $domain.DistinguishedName   # DC=limonada,DC=local
$suffix = $domain.DNSRoot             # limonada.local

# Ask for a password twice so a typo doesn't lock anyone out
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

# Create an OU only if it isn't there yet, and hand back its full name
function New-OUIfMissing([string]$Name, [string]$Path) {
    $dn = "OU=$Name,$Path"
    try {
        Get-ADOrganizationalUnit -Identity $dn | Out-Null
    } catch {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
        Write-Host "  + OU $Name"
    }
    return $dn
}

# 1. DNS: DC01 answers the lab's name lookups and passes anything on the internet to the gateway
Write-Host 'Setting DNS forwarders...'
Set-DnsServerForwarder -IPAddress $DnsForwarders

# 2. The folder tree in Active Directory, like the floors and rooms of the office
Write-Host 'Creating the OUs...'
$staff = Import-Csv -Path $StaffCsv -Encoding UTF8
$departments = $staff.Department | Sort-Object -Unique

$companyOU = New-OUIfMissing 'Limonada' $root
$staffOU   = New-OUIfMissing 'Staff' $companyOU
foreach ($dept in $departments) { New-OUIfMissing $dept $staffOU | Out-Null }
$wsOU      = New-OUIfMissing 'Workstations' $companyOU
New-OUIfMissing 'Servers' $companyOU | Out-Null
$groupsOU  = New-OUIfMissing 'Groups' $companyOU
$adminsOU  = New-OUIfMissing 'Admins' $companyOU

# Computers that join the domain land in Workstations, so the company's policies reach them
redircmp $wsOU | Out-Null

# 3. One security group per department
Write-Host 'Creating the department groups...'
foreach ($dept in $departments) {
    $groupName = "GG_$dept"
    if (-not (Get-ADGroup -Filter "Name -eq '$groupName'")) {
        New-ADGroup -Name $groupName -GroupScope Global -GroupCategory Security -Path $groupsOU `
            -Description "Everyone in $dept"
        Write-Host "  + group $groupName"
    }
}

# 4. The staff, read from staff.csv. Login names look like lucia.navarro
$staffPassword = Read-NewPassword 'Shared password for the staff accounts'
Write-Host 'Creating the staff accounts...'
foreach ($person in $staff) {
    $sam = ('{0}.{1}' -f $person.FirstName, $person.LastName).ToLower()
    if (Get-ADUser -Filter "SamAccountName -eq '$sam'") { continue }

    New-ADUser `
        -Name              "$($person.FirstName) $($person.LastName)" `
        -GivenName         $person.FirstName `
        -Surname           $person.LastName `
        -DisplayName       "$($person.FirstName) $($person.LastName)" `
        -SamAccountName    $sam `
        -UserPrincipalName "$sam@$suffix" `
        -Title             $person.Title `
        -Department        $person.Department `
        -Company           'Limonada S.L.' `
        -Path              "OU=$($person.Department),$staffOU" `
        -AccountPassword   $staffPassword `
        -Enabled           $true `
        -PasswordNeverExpires $true

    Add-ADGroupMember -Identity "GG_$($person.Department)" -Members $sam
    Write-Host "  + $sam"
}

# 5. The IT manager gets a separate admin account, the way real companies keep
#    everyday logins and admin logins apart
$adminSam = 'adm.carlos.ruiz'
if (-not (Get-ADUser -Filter "SamAccountName -eq '$adminSam'")) {
    $adminPassword = Read-NewPassword "Password for $adminSam (the domain admin from your password manager)"
    New-ADUser `
        -Name              'Carlos Ruiz (admin)' `
        -GivenName         'Carlos' `
        -Surname           'Ruiz' `
        -DisplayName       'Carlos Ruiz (admin)' `
        -SamAccountName    $adminSam `
        -UserPrincipalName "$adminSam@$suffix" `
        -Title             'IT Manager' `
        -Department        'IT' `
        -Company           'Limonada S.L.' `
        -Path              $adminsOU `
        -AccountPassword   $adminPassword `
        -Enabled           $true `
        -PasswordNeverExpires $true
    Add-ADGroupMember -Identity 'Domain Admins' -Members $adminSam
    Write-Host "  + $adminSam (Domain Admins)"
}

# 6. A quick check that everything is there
$count = (Get-ADUser -Filter * -SearchBase $staffOU).Count
Write-Host ''
Write-Host "Done. $count staff accounts in $($departments.Count) departments." -ForegroundColor Green
