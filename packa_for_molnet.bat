@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (".venv\Scripts\python.exe" tools\packa_for_molnet.py) else (where py >nul 2>nul && (py -3 tools\packa_for_molnet.py) || (python tools\packa_for_molnet.py))
pause
