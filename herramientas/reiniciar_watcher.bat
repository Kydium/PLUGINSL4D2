@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Cerrando el watcher que este abierto...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { ($_.Name -like 'python*') -and ($_.CommandLine -like '*watcher.py*') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
set "PYW="
for /f "delims=" %%i in ('where pythonw 2^>nul') do if not defined PYW set "PYW=%%i"
if not defined PYW (
  echo No encuentro pythonw. Revisa que Python este instalado.
  pause
  exit /b
)
start "" "%PYW%" "%~dp0watcher.py"
echo Watcher arrancado de nuevo. Su log: %~dp0logs\watcher.log
timeout /t 3 >nul
