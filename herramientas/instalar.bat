@echo off
chcp 65001 >nul
title Instalador del watcher - ClubCampestre
cd /d "%~dp0"

set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY ( where py >nul 2>nul && set "PY=py" )
if not defined PY (
  echo No encuentro Python.
  echo Instalalo desde https://www.python.org/downloads/  ^(marca "Add python.exe to PATH"^)
  echo o escribe en una consola:  winget install -e --id Python.Python.3.12
  echo y vuelve a abrir este archivo.
  pause
  exit /b
)
where git >nul 2>nul
if errorlevel 1 (
  echo No encuentro Git.
  echo Instalalo desde https://git-scm.com/download/win
  echo o escribe en una consola:  winget install -e --id Git.Git
  echo y vuelve a abrir este archivo.
  pause
  exit /b
)

%PY% "%~dp0instalar.py"
echo.
pause
