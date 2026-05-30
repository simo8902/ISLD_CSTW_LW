$processName = "IslandCastawayPG.x86"
$proc = Get-Process $processName -ErrorAction SilentlyContinue

if (-not $proc) {
    Write-Host "Game is not running! Please launch the game first." -ForegroundColor Red
    exit
}

$base = $proc.MainModule.BaseAddress.ToInt64()

$source = @"
using System;
using System.Runtime.InteropServices;

public static class Win32
{
    [DllImport("kernel32.dll")]
    public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out int lpNumberOfBytesWritten);
    
    [DllImport("kernel32.dll")]
    public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out int lpNumberOfBytesRead);
}
"@
if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
    Add-Type -TypeDefinition $source
}

function Read-MemoryInt32($addr) {
    $buf = New-Object byte[] 4
    $read = 0
    if ([Win32]::ReadProcessMemory($proc.Handle, [IntPtr]$addr, $buf, 4, [ref]$read)) {
        return [System.BitConverter]::ToInt32($buf, 0)
    }
    return 0
}

function Write-MemoryByte($addr, $val) {
    $buf = [byte[]]($val)
    $written = 0
    return [Win32]::WriteProcessMemory($proc.Handle, [IntPtr]$addr, $buf, 1, [ref]$written)
}

# 1. Enable Global Flag (byte_1034914 -> RVA 0x424914)
$addrGlobal = $base + 0x424914
if (Write-MemoryByte $addrGlobal 1) {
    Write-Host "Set global master flag to 1"
} else {
    Write-Host "Failed to set global flag" -ForegroundColor Red
}

# 2. If Singleton exists, enable its internal flag (dword_1054B58 -> RVA 0x444B58)
$addrSingletonPtr = $base + 0x444B58
$valSingletonPtr = Read-MemoryInt32 $addrSingletonPtr

if ($valSingletonPtr -ne 0) {
    $enabledField = $valSingletonPtr + 1
    if (Write-MemoryByte $enabledField 1) {
        Write-Host "Set singleton internal flag to 1"
    } else {
        Write-Host "Failed to set singleton flag" -ForegroundColor Red
    }
} else {
    Write-Host "Singleton not initialized yet. It will read the global flag when it is created."
}

Write-Host "Dev Mode variables have been forced on." -ForegroundColor Blue
