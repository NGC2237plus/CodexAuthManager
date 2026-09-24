@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "CODEX_DIR=C:\Users\NGC2237\.codex"
set "AUTH_FILE=%CODEX_DIR%\auth.json"
set "AUTH_STORE=%CODEX_DIR%\my_auth"
set "CURRENT_FILE=%AUTH_STORE%\.current_account.txt"

if not exist "%CODEX_DIR%" (
  echo Directory not found: %CODEX_DIR%
  pause
  exit /b 1
)

if not exist "%AUTH_STORE%" (
  mkdir "%AUTH_STORE%" >nul 2>nul
)

:MAIN
cls
echo ========================================
echo Codex Auth Manager
echo ========================================
echo.
call :SHOW_STATUS
echo.
echo Choose an action:
echo   1. Switch account
echo   2. Save current account
echo   3. List current/all accounts
echo   0. Exit
echo.
set "choice="
set /p "choice=Enter choice: "

if "%choice%"=="1" goto SWITCH_ACCOUNT
if "%choice%"=="2" goto SAVE_ACCOUNT
if "%choice%"=="3" goto LIST_ACCOUNTS
if "%choice%"=="0" goto END

echo.
echo Invalid choice.
pause
goto MAIN

:SHOW_STATUS
if exist "%AUTH_FILE%" (
  echo Login status: signed in ^(auth.json found^)
) else (
  echo Login status: not signed in ^(auth.json not found^)
)

if exist "%CURRENT_FILE%" (
  set "currentAccount="
  set /p "currentAccount="<"%CURRENT_FILE%"
  if defined currentAccount (
    echo Current account record: !currentAccount!
  ) else (
    echo Current account record: none
  )
) else (
  echo Current account record: none
)
exit /b 0

:SWITCH_ACCOUNT
cls
echo ========================================
echo Switch Account
echo ========================================
echo.
call :SHOW_STATUS
echo.

call :PICK_ACCOUNT "Pick target account (number or folder name)" targetAccount
if not defined targetAccount goto MAIN

set "TARGET_AUTH=%AUTH_STORE%\%targetAccount%\auth.json"
if not exist "%TARGET_AUTH%" (
  echo.
  echo Target account has no auth.json:
  echo %TARGET_AUTH%
  pause
  goto MAIN
)

if exist "%AUTH_FILE%" (
  call :GET_CURRENT_ACCOUNT currentAccount
  if not defined currentAccount (
    echo.
    echo Switch cancelled. A current account name is required to back up auth.json.
    pause
    goto MAIN
  )

  if not exist "%AUTH_STORE%\!currentAccount!" (
    mkdir "%AUTH_STORE%\!currentAccount!" >nul 2>nul
  )

  copy /Y "%AUTH_FILE%" "%AUTH_STORE%\!currentAccount!\auth.json" >nul
  if errorlevel 1 (
    echo.
    echo Failed to back up current auth.json.
    pause
    goto MAIN
  )
  echo Saved current auth.json to: %AUTH_STORE%\!currentAccount!\auth.json
) else (
  echo No current auth.json found. Backup skipped.
)

copy /Y "%TARGET_AUTH%" "%AUTH_FILE%" >nul
if errorlevel 1 (
  echo.
  echo Switch failed. Could not copy target auth.json.
  pause
  goto MAIN
)

> "%CURRENT_FILE%" echo %targetAccount%
echo.
echo Switched to account: %targetAccount%
pause
goto MAIN

:SAVE_ACCOUNT
cls
echo ========================================
echo Save Current Account
echo ========================================
echo.
call :SHOW_STATUS
echo.

if not exist "%AUTH_FILE%" (
  echo No current auth.json found. Nothing to save.
  pause
  goto MAIN
)

call :PICK_ACCOUNT "Save to account (number or new folder name)" saveAccount
if not defined saveAccount goto MAIN

if not exist "%AUTH_STORE%\%saveAccount%" (
  mkdir "%AUTH_STORE%\%saveAccount%" >nul 2>nul
)

copy /Y "%AUTH_FILE%" "%AUTH_STORE%\%saveAccount%\auth.json" >nul
if errorlevel 1 (
  echo.
  echo Save failed.
  pause
  goto MAIN
)

> "%CURRENT_FILE%" echo %saveAccount%
echo.
echo Saved current auth.json to: %AUTH_STORE%\%saveAccount%\auth.json
echo Current account record updated: %saveAccount%
pause
goto MAIN

:LIST_ACCOUNTS
cls
echo ========================================
echo Account List
echo ========================================
echo.
call :SHOW_STATUS
echo.
if exist "%~dp0codex-auth-list.ps1" (
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0codex-auth-list.ps1" -CodexDir "%CODEX_DIR%" -AuthStore "%AUTH_STORE%"
  if errorlevel 1 call :SHOW_ACCOUNT_FOLDERS
) else (
  echo Online helper not found. Showing the local account list.
  call :SHOW_ACCOUNT_FOLDERS
)
echo.
pause
goto MAIN

:PICK_ACCOUNT
set "promptText=%~1"
set "returnVar=%~2"
set "%returnVar%="
set "accountCount=0"
call :SHOW_ACCOUNT_FOLDERS

echo.
echo Press Enter to cancel.
set "selected="
set /p "selected=%promptText%: "
if not defined selected exit /b 0

set "picked="
set "notNumber="
for /f "delims=0123456789" %%A in ("%selected%") do set "notNumber=%%A"
if not defined notNumber (
  if defined account[%selected%] (
    set "picked=!account[%selected%]!"
  )
)

if not defined picked set "picked=%selected%"
set "%returnVar%=%picked%"
exit /b 0

:GET_CURRENT_ACCOUNT
set "returnVar=%~1"
set "%returnVar%="

if exist "%CURRENT_FILE%" (
  set "savedCurrent="
  set /p "savedCurrent="<"%CURRENT_FILE%"
  if defined savedCurrent (
    echo Current account record: !savedCurrent!
    set "confirm="
    set /p "confirm=Back up current auth.json with this name? [Y/n]: "
    if /i not "!confirm!"=="n" (
      set "%returnVar%=!savedCurrent!"
      exit /b 0
    )
  )
)

echo.
call :PICK_ACCOUNT "Pick current account name for backup (number or folder name)" typedCurrent
if defined typedCurrent set "%returnVar%=!typedCurrent!"
exit /b 0

:SHOW_ACCOUNT_FOLDERS
set "accountCount=0"
echo Account folders:
for /d %%D in ("%AUTH_STORE%\*") do (
  set /a accountCount+=1
  set "account[!accountCount!]=%%~nxD"
  echo   !accountCount!. %%~nxD
)

if "%accountCount%"=="0" (
  echo   (none)
)
exit /b 0

:END
endlocal
exit /b 0
