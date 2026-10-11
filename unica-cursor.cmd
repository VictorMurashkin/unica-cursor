@echo off
rem Wrapper that bypasses the PowerShell execution policy for this script only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0unica-cursor.ps1" %*
exit /b %ERRORLEVEL%
