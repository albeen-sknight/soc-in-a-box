<#
.SYNOPSIS
    Packs the agents folder (Sysmon, the forwarder and their configs) into a small "lab tools" ISO.

.DESCRIPTION
    Run on the PC. Unlike the answer ISOs, this one holds no password, so it can stay attached
    to the VMs. Put the forwarder .msi in windows\agents first; Git ignores it.
    Inside the VMs the files show up on the LABTOOLS drive, in the lab folder.

.EXAMPLE
    .\New-ToolsIso.ps1
#>
$ErrorActionPreference = 'Stop'

$buildRoot = Join-Path $PSScriptRoot 'build'
$stage     = Join-Path $buildRoot 'lab-tools'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $stage 'lab') -Force | Out-Null

# Everything from windows\agents goes in the lab folder
Copy-Item (Join-Path $PSScriptRoot '..\agents\*') (Join-Path $stage 'lab') -Recurse

if (-not (Get-ChildItem (Join-Path $stage 'lab') -Filter 'splunkforwarder-*-x64.msi')) {
    Write-Host 'Warning: no splunkforwarder-*-x64.msi in windows\agents, so the ISO has no forwarder installer.' -ForegroundColor Yellow
}

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
$image.FileSystemsToCreate = 3          # ISO 9660 plus Joliet, so long file names survive
$image.VolumeName = 'LABTOOLS'
$image.Root.AddTree($stage, $false)
$result = $image.CreateResultImage()

$isoPath = Join-Path $buildRoot 'lab-tools.iso'
[IsoWriter]::Write($isoPath, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)

Write-Host "Done: $isoPath" -ForegroundColor Green
