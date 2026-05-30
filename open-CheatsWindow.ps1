$ErrorActionPreference = 'Stop'

$processName = 'IslandCastawayPG.x86'

$source = @"
using System;
using System.Runtime.InteropServices;

public static class NativeDirectCheats
{
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(UInt32 access, bool inheritHandle, UInt32 processId);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr process, IntPtr baseAddress, byte[] buffer, UInt32 size, out UIntPtr bytesRead);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteProcessMemory(IntPtr process, IntPtr baseAddress, byte[] buffer, UInt32 size, out UIntPtr bytesWritten);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UInt32 size, UInt32 allocationType, UInt32 protect);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UInt32 size, UInt32 freeType);      

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr CreateRemoteThread(IntPtr process, IntPtr threadAttributes, UInt32 stackSize, IntPtr startAddress, IntPtr parameter, UInt32 creationFlags, out UInt32 threadId);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern UInt32 WaitForSingleObject(IntPtr handle, UInt32 milliseconds);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetExitCodeThread(IntPtr thread, out UInt32 exitCode);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr handle);
}
"@

if (-not ('NativeDirectCheats' -as [type])) {
    Add-Type -TypeDefinition $source
}

function Add-U32 {
    param(
        [System.Collections.Generic.List[byte]]$Code,
        [UInt32]$Value
    )
    $Code.AddRange([BitConverter]::GetBytes($Value))
}

$proc = Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) {
    throw "Game is not running!"
}

$PROCESS_ACCESS = 0x1F0FFF
$MEM_COMMIT_RESERVE = 0x3000
$MEM_RELEASE = 0x8000
$PAGE_EXECUTE_READWRITE = 0x40

# RVAs (Base C10000)
$nameConstRva = [UInt32]0x3B47DC
$tokenConstRva = [UInt32]0x3B4820
$stringCtorRva = [UInt32]0x0B100
$tokenHelperRva = [UInt32]0x0C760
$managerGetterRva = [UInt32]0x1122D0 # FIXED FROM 0x122D0
$openDispatcherRva = [UInt32]0x2E2CC0
$stringDtorRva = [UInt32]0x0B890
$initCheatsRva = [UInt32]0x10AF60

$handle = [NativeDirectCheats]::OpenProcess($PROCESS_ACCESS, $false, [UInt32]$proc.Id)
if ($handle -eq [IntPtr]::Zero) {
    throw "OpenProcess failed"
}

try {
    $exeBase = [UInt32]$proc.MainModule.BaseAddress.ToInt64()

    $nameConst = [UInt32]($exeBase + $nameConstRva)
    $tokenConst = [UInt32]($exeBase + $tokenConstRva)
    $stringCtor = [UInt32]($exeBase + $stringCtorRva)
    $tokenHelper = [UInt32]($exeBase + $tokenHelperRva)
    $managerGetter = [UInt32]($exeBase + $managerGetterRva)
    $openDispatcher = [UInt32]($exeBase + $openDispatcherRva)
    $stringDtor = [UInt32]($exeBase + $stringDtorRva)
    $initCheats = [UInt32]($exeBase + $initCheatsRva)

    $code = New-Object System.Collections.Generic.List[byte]
    $code.AddRange([byte[]](0x55))                          # push ebp
    $code.AddRange([byte[]](0x89, 0xE5))                     # mov ebp, esp
    $code.AddRange([byte[]](0x83, 0xEC, 0x50))               # sub esp, 0x50

    # call initCheats
    $code.AddRange([byte[]](0xB8))
    Add-U32 $code $initCheats
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax

    # stringCtor(&name, "Cheating Window")
    $code.AddRange([byte[]](0x68))                          # push nameConst
    Add-U32 $code $nameConst
    $code.AddRange([byte[]](0x8D, 0x4D, 0xC0))               # lea ecx, [ebp-0x40]
    $code.AddRange([byte[]](0xB8))                          # mov eax, stringCtor
    Add-U32 $code $stringCtor
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax

    # tokenHelper(&token, "Windows\Cheating")
    $code.AddRange([byte[]](0x68))                          # push tokenConst
    Add-U32 $code $tokenConst
    $code.AddRange([byte[]](0x8D, 0x4D, 0xD8))               # lea ecx, [ebp-0x28]
    $code.AddRange([byte[]](0xB8))                          # mov eax, tokenHelper
    Add-U32 $code $tokenHelper
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax

    # openWindow
    $code.AddRange([byte[]](0x8D, 0x45, 0xC0))               # lea eax, [ebp-0x40]
    $code.AddRange([byte[]](0x50))                          # push eax
    $code.AddRange([byte[]](0x8D, 0x45, 0xD8))               # lea eax, [ebp-0x28]
    $code.AddRange([byte[]](0x50))                          # push eax
    $code.AddRange([byte[]](0xB8))                          # mov eax, managerGetter
    Add-U32 $code $managerGetter
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax
    $code.AddRange([byte[]](0x89, 0xC1))                     # mov ecx, eax
    $code.AddRange([byte[]](0xB8))                          # mov eax, openDispatcher
    Add-U32 $code $openDispatcher
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax

    # stringDtor(&name)
    $code.AddRange([byte[]](0x8D, 0x4D, 0xC0))               # lea ecx, [ebp-0x40]
    $code.AddRange([byte[]](0xB8))                          # mov eax, stringDtor
    Add-U32 $code $stringDtor
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax

    # Epilogue
    $code.AddRange([byte[]](0x31, 0xC0))                     # xor eax, eax
    $code.AddRange([byte[]](0x89, 0xEC))                     # mov esp, ebp
    $code.AddRange([byte[]](0x5D))                          # pop ebp
    $code.AddRange([byte[]](0xC2, 0x04, 0x00))               # ret 4

    $remote = [NativeDirectCheats]::VirtualAllocEx($handle, [IntPtr]::Zero, [UInt32]$code.Count, $MEM_COMMIT_RESERVE, $PAGE_EXECUTE_READWRITE)
    if ($remote -eq [IntPtr]::Zero) {
        throw "VirtualAllocEx failed"
    }
    $remote32 = [UInt32]$remote.ToInt64()

    $written = [UIntPtr]::Zero
    if (-not [NativeDirectCheats]::WriteProcessMemory($handle, $remote, $code.ToArray(), [UInt32]$code.Count, [ref]$written)) {
        throw "WriteProcessMemory failed"
    }
    
    $threadId = [UInt32]0
    $thread = [NativeDirectCheats]::CreateRemoteThread($handle, [IntPtr]::Zero, 0, $remote, [IntPtr]::Zero, 0, [ref]$threadId)
    if ($thread -eq [IntPtr]::Zero) {
        throw "CreateRemoteThread failed"
    }
    
    $wait = [NativeDirectCheats]::WaitForSingleObject($thread, 5000)
    if ($wait -ne 0) {
        Write-Host "Remote thread wait timed out or failed. Make sure the game window is active." -ForegroundColor Yellow
    } else {
        Write-Host "Success! cheat window opened." -ForegroundColor Blue
    }
    [NativeDirectCheats]::CloseHandle($thread) | Out-Null
    [NativeDirectCheats]::VirtualFreeEx($handle, $remote, 0, $MEM_RELEASE) | Out-Null

} finally {
    [NativeDirectCheats]::CloseHandle($handle) | Out-Null
}
