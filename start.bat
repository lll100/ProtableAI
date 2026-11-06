@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
set "rc=%errorlevel%"
if not "%rc%"=="0" (
  echo.
  echo PortableAI startup failed. Exit code: %rc%
  echo See logs: %~dp0logs\startup.log and service_error.log
  pause
)
endlocal & exit /b %rc%
