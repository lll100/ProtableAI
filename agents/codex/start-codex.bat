@echo off
setlocal
set "PORTABLEAI_API_KEY=portable-local"
set "PORTABLEAI_AGENT_PORT=11436"
for /f "delims=" %%K in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\read-config-value.ps1" -Name agent_api_key') do set "PORTABLEAI_API_KEY=%%K"
for /f "delims=" %%P in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\read-config-value.ps1" -Name anthropic_port') do set "PORTABLEAI_AGENT_PORT=%%P"
set "OPENAI_BASE_URL=http://127.0.0.1:%PORTABLEAI_AGENT_PORT%"
set "OPENAI_API_KEY=%PORTABLEAI_API_KEY%"
set "OPENAI_MODEL=gpt-5-codex"
set "CODEX_API_KEY=%PORTABLEAI_API_KEY%"
set "CODEX_HOME=%~dp0home"
set "NODE_EXE=%~dp0..\runtime\node\node.exe"
set "CODEX_JS=%~dp0package\bin\codex.js"
if not exist "%NODE_EXE%" (
  echo F drive Node runtime was not found.
  pause
  exit /b 1
)
if not exist "%CODEX_JS%" (
  echo F drive Codex runtime was not found.
  pause
  exit /b 1
)
"%NODE_EXE%" "%CODEX_JS%" %*
endlocal
