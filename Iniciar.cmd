@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0NekoPonte.ps1" (
  echo Extraia todos os arquivos do ZIP antes de abrir o programa.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0NekoPonte.ps1"
if errorlevel 1 pause
