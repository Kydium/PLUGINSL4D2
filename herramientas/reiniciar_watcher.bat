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
rem si este .bat esta en la carpeta del instalador, usa el watcher instalado (carpeta watcher)
set "W=%~dp0"
if exist "%~dp0watcher\watcher_config.json" set "W=%~dp0watcher\"
start "" "%PYW%" "%W%watcher.py"
echo Watcher arrancado de nuevo. Su log: %W%logs\watcher.log
timeout /t 3 >nul
