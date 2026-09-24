# Compatibility entry point: switching now shares identity/save/login invariants.
param([string]$ScratchDirectory=$env:TEMP)
& (Join-Path $PSScriptRoot 'Test-Accounts.ps1') -ScratchDirectory $ScratchDirectory