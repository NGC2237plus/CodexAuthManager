@echo off
if exist "%~dp0CodexAuthManager.exe" (
  start "" "%~dp0CodexAuthManager.exe"
) else (
  start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0CodexAuthManager.ps1"
)
exit /b
