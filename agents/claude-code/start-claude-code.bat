@echo off
setlocal
rem Keep the portable launcher isolated from %USERPROFILE%\.claude. A host
rem machine may contain a different provider URL and token; Claude Code loads
rem that config unless CLAUDE_CONFIG_DIR is explicitly redirected.
set "CLAUDE_CONFIG_DIR=%~dp0home"
if not exist "%CLAUDE_CONFIG_DIR%" mkdir "%CLAUDE_CONFIG_DIR%"
set "PORTABLEAI_API_KEY=portable-local"
set "PORTABLEAI_AGENT_PORT=11436"
for /f "delims=" %%K in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\read-config-value.ps1" -Name agent_api_key') do set "PORTABLEAI_API_KEY=%%K"
for /f "delims=" %%P in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\read-config-value.ps1" -Name anthropic_port') do set "PORTABLEAI_AGENT_PORT=%%P"
set "ANTHROPIC_BASE_URL=http://127.0.0.1:%PORTABLEAI_AGENT_PORT%"
set "ANTHROPIC_API_KEY=%PORTABLEAI_API_KEY%"
set "ANTHROPIC_AUTH_TOKEN=%PORTABLEAI_API_KEY%"
set "CLAUDE_CODE_API_BASE_URL=http://127.0.0.1:%PORTABLEAI_AGENT_PORT%"
set "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
set "ANTHROPIC_MODEL=claude-sonnet-4-5-20250929"
set "CLAUDE_CODE_DEBUG_LOGS_DIR=%~dp0..\..\logs\claude-debug"
set "CLAUDE_EXE=%~dp0package\bin\claude.exe"
if not exist "%CLAUDE_EXE%" (
  echo F drive Claude Code runtime was not found.
  echo Recopy agents\claude-code\package, then run this launcher again.
  pause
  exit /b 1
)
"%CLAUDE_EXE%" %*
endlocal
