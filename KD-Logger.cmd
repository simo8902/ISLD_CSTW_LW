@echo off
setlocal EnableExtensions
title Island Castaway - OpenKODE Log Capture
net session >nul 2>&1
if %errorlevel% NEQ 0 (
  echo gimme rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "KDLOG_OUT=%~dp0KDLog.txt"
echo Island Castaway OpenKODE log capture
echo Output file: %KDLOG_OUT%
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText('%~f0'); $m='#__'+'PSBODY__'; Invoke-Expression $t.Substring($t.IndexOf($m)+$m.Length)"
echo.
pause
exit /b
#__PSBODY__
$ErrorActionPreference = 'Stop'
$gameName = 'IslandCastawayPG.x86'
$out = $env:KDLOG_OUT
if (-not $out) { $out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'KDLog.txt' }

# Drop Windows/WIL OS noise (e.g. onecoreuap ... dll!ADDR: (caller: ...) ... Access is denied),
# keep ALL game OpenKODE logs ([report]/[xpromo]/[fmod]/[texture]/Texture::/Sound:: etc).
$noise = '(\.(dll|exe)!\w+:\s*\(caller:|onecoreuap\\|\[xpromo\]|\[pushwoosh\]|\[setenv\])'

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class DBG {
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool DebugActiveProcess(uint pid);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool DebugActiveProcessStop(uint pid);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool DebugSetProcessKillOnExit(bool b);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool WaitForDebugEvent(IntPtr e, uint ms);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool ContinueDebugEvent(uint pid, uint tid, uint status);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out int r);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr OpenProcess(uint acc, bool inh, uint pid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@

Write-Host "=== Island Castaway - OpenKODE log capture ===" -ForegroundColor Red
Write-Host "Output: $out"
Write-Host "Waiting for game ($gameName) ..." -ForegroundColor Blue
$proc = $null
while (-not $proc) {
  $proc = Get-Process $gameName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { Start-Sleep -Milliseconds 800 }
}
$pidv = [uint32]$proc.Id
Write-Host ("Found PID {0}. Attaching debugger..." -f $pidv) -ForegroundColor Green
$hProc = [DBG]::OpenProcess(0x0410,$false,$pidv)
if (-not [DBG]::DebugActiveProcess($pidv)) {
  Write-Host ("Attach FAILED (GLE={0}). Detach WinDbg/other debugger and try again." -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) -ForegroundColor Red
  return
}
[DBG]::DebugSetProcessKillOnExit($false) | Out-Null
Write-Host "Attached. Capturing... (Ctrl+C or close window to stop; game stays running)" -ForegroundColor Green

$buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(512)
$CONT = [uint32]0x00010002
$NOTH = [uint32]0x80010001L
$count = 0
"==== OpenKODE capture started $(Get-Date) ====" | Out-File -LiteralPath $out -Encoding utf8
try {
  while ($true) {
    if ($proc.HasExited) { Write-Host "Game exited." -ForegroundColor Yellow; break }
    if ([DBG]::WaitForDebugEvent($buf,200)) {
      $code = [Runtime.InteropServices.Marshal]::ReadInt32($buf,0)
      $epid = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($buf,4)
      $etid = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($buf,8)
      $status = $CONT
      if ($code -eq 8) {
        $sp = [Runtime.InteropServices.Marshal]::ReadIntPtr($buf,16)
        $fu = [Runtime.InteropServices.Marshal]::ReadInt16($buf,24)
        $ln = [Runtime.InteropServices.Marshal]::ReadInt16($buf,26)
        if ($ln -gt 0) {
          $nb = if ($fu -ne 0) { $ln*2 } else { $ln }
          $tb = New-Object byte[] $nb; $rd = 0
          if ([DBG]::ReadProcessMemory($hProc,$sp,$tb,$nb,[ref]$rd) -and $rd -gt 0) {
            $s = if ($fu -ne 0) { [Text.Encoding]::Unicode.GetString($tb,0,$rd) } else { [Text.Encoding]::Default.GetString($tb,0,$rd) }
            $s = $s.TrimEnd("`0","`r","`n")
            if ($s.Length -and $s -notmatch $noise) {
              Add-Content -LiteralPath $out -Value $s
              $count++
              if ($count % 25 -eq 0) { Write-Host ("  {0} lines..." -f $count) -ForegroundColor DarkGray }
            }
          }
        }
      } elseif ($code -eq 1) {
        $ex = [Runtime.InteropServices.Marshal]::ReadInt32($buf,16)
        if ($ex -eq 0x80000003 -or $ex -eq 0x80000004) { $status = $CONT } else { $status = $NOTH }
      } elseif ($code -eq 5) { $status = $CONT }
      [DBG]::ContinueDebugEvent($epid,$etid,$status) | Out-Null
      if ($code -eq 5) { break }
    }
  }
} finally {
  [DBG]::DebugActiveProcessStop($pidv) | Out-Null
  if ($hProc -ne [IntPtr]::Zero) { [DBG]::CloseHandle($hProc) | Out-Null }
  Write-Host ("Stopped. {0} game log lines written to {1}. Game left running." -f $count,$out) -ForegroundColor Green
}