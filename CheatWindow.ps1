$root = $PSScriptRoot
if ($root -match "RE$") { $root = Split-Path $root }

Write-Host "--- Cheats Window Made by Simo ---" -ForegroundColor Red

& (Join-Path $root "enable-DevModeVars.ps1")
& (Join-Path $root "inst-CheatsWindow.ps1")
& (Join-Path $root "open-CheatsWindow.ps1")