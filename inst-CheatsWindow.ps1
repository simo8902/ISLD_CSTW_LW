$processName = "IslandCastawayPG.x86"
$proc = Get-Process $processName -ErrorAction SilentlyContinue

if (-not $proc) {
    Write-Host "Game is not running! Please launch the game first." -ForegroundColor Red
    exit
}

$base = [UInt32]$proc.MainModule.BaseAddress.ToInt64()

$source = @"
using System;
using System.Runtime.InteropServices;

public static class NativeInstantiatorV2
{
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(UInt32 access, bool inheritHandle, UInt32 processId);

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
    public static extern bool CloseHandle(IntPtr handle);
}
"@

if (-not ([System.Management.Automation.PSTypeName]'NativeInstantiatorV2').Type) {
    Add-Type -TypeDefinition $source
}

function Add-U32 {
    param(
        [System.Collections.Generic.List[byte]]$Code,
        [UInt32]$Value
    )
    $Code.AddRange([BitConverter]::GetBytes($Value))
}

$PROCESS_ACCESS = 0x1F0FFF
$MEM_COMMIT_RESERVE = 0x3000
$MEM_RELEASE = 0x8000
$PAGE_EXECUTE_READWRITE = 0x40

# RVAs (calculated based on B00000 base)
# sub_B213D0 (Window Resolver Wrapper) = 0x213D0
# aCheatingWindow = "Cheating Window" = 0x3B47DC
# sub_B0B100 (StdString ctor) = 0x0B100
# sub_B0B890 (StdString dtor) = 0x0B890

$windowResolverRva = [UInt32]0x213D0
$strCheatingWindowRva = [UInt32]0x3B47DC
$stringCtorRva = [UInt32]0x0B100
$stringDtorRva = [UInt32]0x0B890

$handle = [NativeInstantiatorV2]::OpenProcess($PROCESS_ACCESS, $false, [UInt32]$proc.Id)
if ($handle -eq [IntPtr]::Zero) {
    throw "OpenProcess failed"
}

try {
    $resolver = [UInt32]($base + $windowResolverRva)
    $strCheatingWindow = [UInt32]($base + $strCheatingWindowRva)
    $stringCtor = [UInt32]($base + $stringCtorRva)
    $stringDtor = [UInt32]($base + $stringDtorRva)

    $code = New-Object System.Collections.Generic.List[byte]
    $code.AddRange([byte[]](0x55))                          # push ebp
    $code.AddRange([byte[]](0x89, 0xE5))                     # mov ebp, esp
    $code.AddRange([byte[]](0x83, 0xEC, 0x30))               # sub esp, 0x30
    
    # 1. StdString ctor(&tmpStr, "Cheating Window")
    $code.AddRange([byte[]](0x68))                          # push str
    Add-U32 $code $strCheatingWindow
    $code.AddRange([byte[]](0x8D, 0x4D, 0xD8))               # lea ecx, [ebp-0x28]
    $code.AddRange([byte[]](0xB8))                          # mov eax, ctor
    Add-U32 $code $stringCtor
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax
    
    # 2. sub_B213D0(&outPtr, &tmpStr)
    # ecx = &outPtr. push &tmpStr
    $code.AddRange([byte[]](0x8D, 0x45, 0xD8))               # lea eax, [ebp-0x28]
    $code.AddRange([byte[]](0x50))                          # push eax
    $code.AddRange([byte[]](0x8D, 0x4D, 0xF0))               # lea ecx, [ebp-0x10]
    $code.AddRange([byte[]](0xB8))                          # mov eax, resolver
    Add-U32 $code $resolver
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax
    
    # 3. StdString dtor(&tmpStr)
    $code.AddRange([byte[]](0x8D, 0x4D, 0xD8))               # lea ecx, [ebp-0x28]
    $code.AddRange([byte[]](0xB8))                          # mov eax, dtor
    Add-U32 $code $stringDtor
    $code.AddRange([byte[]](0xFF, 0xD0))                     # call eax
    
    # Epilogue
    $code.AddRange([byte[]](0x31, 0xC0))                     # xor eax, eax
    $code.AddRange([byte[]](0x89, 0xEC))                     # mov esp, ebp
    $code.AddRange([byte[]](0x5D))                          # pop ebp
    $code.AddRange([byte[]](0xC3))                           # ret

    $remote = [NativeInstantiatorV2]::VirtualAllocEx($handle, [IntPtr]::Zero, [UInt32]$code.Count, $MEM_COMMIT_RESERVE, $PAGE_EXECUTE_READWRITE)
    if ($remote -eq [IntPtr]::Zero) {
        throw "VirtualAllocEx failed"
    }

    $written = [UIntPtr]::Zero
    if (-not [NativeInstantiatorV2]::WriteProcessMemory($handle, $remote, $code.ToArray(), [UInt32]$code.Count, [ref]$written)) {
        throw "WriteProcessMemory failed"
    }
    
    $threadId = [UInt32]0
    $thread = [NativeInstantiatorV2]::CreateRemoteThread($handle, [IntPtr]::Zero, 0, $remote, [IntPtr]::Zero, 0, [ref]$threadId)
    if ($thread -eq [IntPtr]::Zero) {
        throw "CreateRemoteThread failed"
    }
    
    $wait = [NativeInstantiatorV2]::WaitForSingleObject($thread, 5000)
    if ($wait -ne 0) {
        Write-Host "Remote thread wait timed out or failed. Check if game is active." -ForegroundColor Yellow
    } else {
        Write-Host "done" -ForegroundColor Blue
    }
    [NativeInstantiatorV2]::CloseHandle($thread) | Out-Null
    [NativeInstantiatorV2]::VirtualFreeEx($handle, $remote, 0, $MEM_RELEASE) | Out-Null

} finally {
    [NativeInstantiatorV2]::CloseHandle($handle) | Out-Null
}
