@echo off
chcp 65001 >nul
cd /d "%~dp0"
title AI Control Center
if exist ".venv\Scripts\python.exe" goto :venv
if exist ".paket\torch" goto :lokalt
echo Kontrollpanelen ar inte installerad annu. Kor installera.bat forst.
pause
exit /b 1

:venv
".venv\Scripts\python.exe" main.py %*
goto :klar

:lokalt
where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
%PY% main.py %*

:klar
if errorlevel 1 pause
