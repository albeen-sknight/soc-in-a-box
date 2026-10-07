#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates one Group Policy that turns on the logging the SOC needs, on every machine in the domain.

.DESCRIPTION
    Windows only writes down a small part of what happens by default, like a shop camera that
    only records the front door. This policy points the cameras at everything the detections need:
      - Advanced audit policy: logons, account and group changes, new processes, scheduled tasks
      - The full command line on every new process (event 4688)
      - PowerShell script block and module logging (event 4104)
      - A bigger Security log, so events don't roll off before Splunk picks them up

    Run on DC01 as LIMONADA\Administrator, after 02-Build-Limonada.ps1.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\lab\03-New-SecurityLoggingGpo.ps1
#>
param(
    [string]$GpoName = 'Limonada Security Logging'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
Import-Module GroupPolicy

$domain   = Get-ADDomain
$dnsRoot  = $domain.DNSRoot
$domainDN = $domain.DistinguishedName

if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) {
    throw "A GPO called '$GpoName' already exists. Delete it in Group Policy Management first if you want to rebuild it."
}

Write-Host "Creating the GPO '$GpoName'..."
$gpo  = New-GPO -Name $GpoName -Comment 'Audit policy, command line and PowerShell logging for the SOC'
$guid = $gpo.Id.ToString('B').ToUpper()

# 1. Registry based settings
$settings = @(
    # Make the detailed audit settings below win over the old style ones
    @{ Key = 'HKLM\System\CurrentControlSet\Control\Lsa'; Name = 'SCENoApplyLegacyAuditPolicy'; Value = 1 }
    # Put the full command line in every "new process" event (4688)
    @{ Key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System\Audit'; Name = 'ProcessCreationIncludeCmdLine_Enabled'; Value = 1 }
    # Record the text of every PowerShell script that runs (4104), even when it's encoded
    @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; Name = 'EnableScriptBlockLogging'; Value = 1 }
    # Record which PowerShell commands were called and with what (4103)
    @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\PowerShell\ModuleLogging'; Name = 'EnableModuleLogging'; Value = 1 }
    # Make the Security log 256 MB, so a burst of events doesn't push older ones out
    @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\EventLog\Security'; Name = 'MaxSize'; Value = 262144 }
)
foreach ($s in $settings) {
    Set-GPRegistryValue -Guid $gpo.Id -Key $s.Key -ValueName $s.Name -Type DWord -Value $s.Value | Out-Null
}
# Log every PowerShell module, not just a list of them
Set-GPRegistryValue -Guid $gpo.Id -Key 'HKLM\Software\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames' `
    -ValueName '*' -Type String -Value '*' | Out-Null

# 2. Advanced audit policy. Group Policy stores it as a small CSV inside the GPO's folder in SYSVOL.
#    Setting value: 1 = Success, 2 = Failure, 3 = Success and Failure
$audit = @(
    # What each line catches, and which detection uses it.
    # The comma in front of each line keeps it as one row of three values.
    ,@('Audit Credential Validation',            '{0CCE923F-69AE-11D9-BED3-505054503030}', 3)  # NTLM logons (D01, D02)
    ,@('Audit Kerberos Authentication Service',  '{0CCE9242-69AE-11D9-BED3-505054503030}', 3)  # Kerberos logons, 4771 failures (D02)
    ,@('Audit Kerberos Service Ticket Operations','{0CCE9240-69AE-11D9-BED3-505054503030}', 3)
    ,@('Audit Logon',                            '{0CCE9215-69AE-11D9-BED3-505054503030}', 3)  # 4624 and 4625 (D01, D02)
    ,@('Audit Logoff',                           '{0CCE9216-69AE-11D9-BED3-505054503030}', 1)
    ,@('Audit Account Lockout',                  '{0CCE9217-69AE-11D9-BED3-505054503030}', 2)
    ,@('Audit Special Logon',                    '{0CCE921B-69AE-11D9-BED3-505054503030}', 1)  # admin logons
    ,@('Audit User Account Management',          '{0CCE9235-69AE-11D9-BED3-505054503030}', 3)  # 4720 new account (D04)
    ,@('Audit Security Group Management',        '{0CCE9237-69AE-11D9-BED3-505054503030}', 3)  # 4728, 4732, 4756 (D03)
    ,@('Audit Computer Account Management',      '{0CCE9236-69AE-11D9-BED3-505054503030}', 3)
    ,@('Audit Process Creation',                 '{0CCE922B-69AE-11D9-BED3-505054503030}', 1)  # 4688 (D05, D07, D09)
    ,@('Audit Other Object Access Events',       '{0CCE9227-69AE-11D9-BED3-505054503030}', 3)  # 4698 new scheduled task (D07)
    ,@('Audit Sensitive Privilege Use',          '{0CCE9228-69AE-11D9-BED3-505054503030}', 3)
    ,@('Audit Audit Policy Change',              '{0CCE922F-69AE-11D9-BED3-505054503030}', 3)  # someone turning logging off
    ,@('Audit Security State Change',            '{0CCE9210-69AE-11D9-BED3-505054503030}', 3)
    ,@('Audit Security System Extension',        '{0CCE9211-69AE-11D9-BED3-505054503030}', 3)  # new services and drivers
    ,@('Audit System Integrity',                 '{0CCE9212-69AE-11D9-BED3-505054503030}', 3)
    ,@('Audit Directory Service Changes',        '{0CCE923C-69AE-11D9-BED3-505054503030}', 3)  # changes inside Active Directory
)

$lines = @('Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value')
foreach ($a in $audit) {
    $label = switch ($a[2]) { 1 { 'Success' } 2 { 'Failure' } 3 { 'Success and Failure' } }
    $lines += ",System,$($a[0]),$($a[1]),$label,,$($a[2])"
}

$gpoFolder = "\\$dnsRoot\SYSVOL\$dnsRoot\Policies\$guid"
$auditDir  = Join-Path $gpoFolder 'Machine\Microsoft\Windows NT\Audit'
New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
Set-Content -Path (Join-Path $auditDir 'audit.csv') -Value $lines -Encoding ASCII

# 3. Tell Group Policy this GPO now carries audit settings too, then bump its version
#    so every machine knows there's something new to apply
$gpoDN   = "CN=$guid,CN=Policies,CN=System,$domainDN"
$gpoAD   = Get-ADObject -Identity $gpoDN -Properties gPCMachineExtensionNames, versionNumber

$registryCse = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
$auditCse    = '[{F3CCC681-B74C-4060-9F26-CD84525DCA2A}{0F3F3735-573D-9804-99E4-AB2A69BA5FD4}]'
$newVersion  = [int]$gpoAD.versionNumber + 1

Set-ADObject -Identity $gpoDN -Replace @{
    gPCMachineExtensionNames = $registryCse + $auditCse
    versionNumber            = $newVersion
}
$gptIni = Join-Path $gpoFolder 'GPT.INI'
(Get-Content $gptIni) -replace '^Version=\d+', "Version=$newVersion" | Set-Content $gptIni -Encoding ASCII

# 4. Link the GPO to the whole domain and to the Domain Controllers OU, so DC01 gets it too
New-GPLink -Guid $gpo.Id -Target $domainDN -LinkEnabled Yes | Out-Null
New-GPLink -Guid $gpo.Id -Target "OU=Domain Controllers,$domainDN" -LinkEnabled Yes | Out-Null

# 5. Apply it on DC01 now instead of waiting up to 90 minutes
gpupdate /force | Out-Null

Write-Host ''
Write-Host "Done. Check it worked with:  auditpol /get /category:*" -ForegroundColor Green
