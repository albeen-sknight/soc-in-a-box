<#
.SYNOPSIS
    Builds a small "answer ISO" for one lab VM: the filled answer file plus the build scripts.

.DESCRIPTION
    Run this on the PC. It asks for the VM's admin password, fills in the answer file
    template, copies the right build scripts next to it, and packs it all into an ISO.
    Attach that ISO to the VM as a second DVD drive and Windows installs itself.
    Afterwards the scripts sit on that drive, in a folder called lab.

.EXAMPLE
    .\New-AnswerIso.ps1 -ComputerName DC01
#>
param(
    # Which lab machine this ISO is for
    [Parameter(Mandatory)]
    [ValidateSet('DC01', 'WS01', 'WS02')]
    [string]$ComputerName,

    # Keyboard layout inside the VM. 0c0a:0000040a is the Spanish keyboard.
    [string]$InputLocale = '0c0a:0000040a',

    # Leave empty to use the right edition for the machine (see below)
    [string]$ImageName = ''
)

$ErrorActionPreference = 'Stop'

# The exact edition names on the Microsoft evaluation ISOs
if (-not $ImageName) {
    if ($ComputerName -eq 'DC01') {
        $ImageName = 'Windows Server 2025 Standard Evaluation (Desktop Experience)'
    } else {
        $ImageName = 'Windows 11 Enterprise Evaluation'
    }
}

# Which build scripts go on the ISO for this machine
if ($ComputerName -eq 'DC01') {
    $scriptFolder = Join-Path $PSScriptRoot '..\dc01'
} else {
    $scriptFolder = Join-Path $PSScriptRoot '..\workstations'
}

# Ask for the password twice so a typo doesn't lock me out of the VM
function Read-NewPassword([string]$Prompt) {
    while ($true) {
        $first  = Read-Host $Prompt -AsSecureString
        $second = Read-Host 'Type it again' -AsSecureString
        $a = [System.Net.NetworkCredential]::new('', $first).Password
        $b = [System.Net.NetworkCredential]::new('', $second).Password
        if ($a -and ($a -ceq $b)) { return $a }
        Write-Host "They don't match, try again." -ForegroundColor Yellow
    }
}

$password = Read-NewPassword "Admin password for $ComputerName (from your password manager)"

# Fill in the template. Escape the password in case it has characters like & or <
$template = Get-Content (Join-Path $PSScriptRoot 'autounattend.template.xml') -Raw
$filled = $template.Replace('__COMPUTER_NAME__', $ComputerName)
$filled = $filled.Replace('__IMAGE_NAME__', $ImageName)
$filled = $filled.Replace('__INPUT_LOCALE__', $InputLocale)
$filled = $filled.Replace('__ADMIN_PASSWORD__', [System.Security.SecurityElement]::Escape($password))

# Start from a clean build folder for this machine (the build folder is in .gitignore)
$buildRoot = Join-Path $PSScriptRoot 'build'
$stage     = Join-Path $buildRoot $ComputerName
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $stage 'lab') -Force | Out-Null

# Save the answer file and copy the build scripts next to it
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $stage 'autounattend.xml'), $filled, $utf8NoBom)
Copy-Item (Join-Path $scriptFolder '*') (Join-Path $stage 'lab') -Recurse
# Every machine also gets the agents (Sysmon now, the forwarder later)
Copy-Item (Join-Path $PSScriptRoot '..\agents\*') (Join-Path $stage 'lab') -Recurse

# Pack the folder into an ISO with the ISO maker that's built into Windows (IMAPI2)
if (-not ('IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class IsoWriter {
    public static void Write(string path, object comStream, int blockSize, int totalBlocks) {
        IStream stream = (IStream)comStream;
        byte[] buffer = new byte[blockSize];
        IntPtr bytesRead = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (FileStream file = File.Create(path)) {
                for (int i = 0; i < totalBlocks; i++) {
                    stream.Read(buffer, blockSize, bytesRead);
                    file.Write(buffer, 0, Marshal.ReadInt32(bytesRead));
                }
            }
        } finally {
            Marshal.FreeHGlobal(bytesRead);
        }
    }
}
'@
}

$image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$image.FileSystemsToCreate = 3        # ISO 9660 plus Joliet, so long file names survive
$image.VolumeName = 'ANSWER'
$image.Root.AddTree($stage, $false)   # put the folder's contents at the root of the ISO
$result = $image.CreateResultImage()

$isoPath = Join-Path $buildRoot "$ComputerName-answer.iso"
[IsoWriter]::Write($isoPath, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)

Write-Host ''
Write-Host "Done: $isoPath" -ForegroundColor Green
Write-Host 'This ISO holds the admin password in plain text.' -ForegroundColor Yellow
Write-Host 'Delete the build folder once the VM is installed and snapshotted.' -ForegroundColor Yellow
