@echo off
setlocal DisableDelayedExpansion
rem Wrapper that bypasses the PowerShell execution policy for this script only.
set "forward="
set "escaped="
set quote=^"

:next
set argument=%1
if not defined argument goto run
setlocal EnableDelayedExpansion
if not "!argument:~-1!"=="!quote!" (endlocal & goto append)
endlocal

rem Windows PowerShell 5.1 can leave an odd run of backslashes before the
rem closing quote. Make it even so powershell.exe keeps the quote as a delimiter.
set "tail=%~1"
set "escape="
:trailing
if not "%tail:~-1%"=="\" goto quote
set "tail=%tail:~0,-1%"
if defined escape (set "escape=") else set "escape=\"
goto trailing

:quote
if not defined escape goto append
set argument="%~1%escape%"
set "escaped=1"

:append
set forward=%forward% %argument%
shift /1
goto next

:run
if not defined escaped set forward=%*
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0unica-cursor.ps1" %forward%
exit /b %ERRORLEVEL%
