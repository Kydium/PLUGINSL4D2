@echo off
chcp 65001 >nul
echo Cerrando el watcher...
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process | Where-Object { ($_.Name -like 'python*') -and ($_.CommandLine -like '*watcher.py*') }; if ($p) { $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Write-Host ('Listo: se cerraron ' + @($p).Count + ' watcher(s).') } else { Write-Host 'No habia ningun watcher abierto.' }"
pause
