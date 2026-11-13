@echo off
chcp 65001 >nul
cd /d "%~dp0"
title AI Control Center
if not exist ".venv\Scripts\python.exe" (
  echo Kontrollpanelen ar inte installerad annu. Kor installera.bat forst.
  pause
  exit /b 1
)
".venv\Scripts\python.exe" main.py %*
if errorlevel 1 pause
