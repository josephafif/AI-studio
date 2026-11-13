@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title AI Control Center - installation

where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
%PY% --version >nul 2>nul
if errorlevel 1 (
  echo Python hittades inte. Installera Python 3.10 eller senare fran https://www.python.org/downloads/
  echo och kryssa i "Add python.exe to PATH". Kor sedan installera.bat igen.
  pause
  exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
  echo Skapar virtuell miljo i .venv ...
  %PY% -m venv .venv || goto :fel
)
set "VPY=.venv\Scripts\python.exe"
"%VPY%" -m pip install --upgrade pip >nul

echo.
echo Vilken version av PyTorch vill du installera?
echo   [1] CPU  - fungerar pa alla datorer (standard)
echo   [2] GPU  - NVIDIA-grafikkort (CUDA 12.6, krav: aktuell NVIDIA-drivrutin)
set "VAL=1"
set /p "VAL=Val (1/2): "
if "%VAL%"=="2" (
  "%VPY%" -m pip install torch --index-url https://download.pytorch.org/whl/cu126 || goto :fel
) else (
  "%VPY%" -m pip install torch --index-url https://download.pytorch.org/whl/cpu || goto :fel
)
"%VPY%" -m pip install psutil || goto :fel
"%VPY%" -m pip install pywebview
if errorlevel 1 (
  echo.
  echo OBS: pywebview kunde inte installeras. Kontrollpanelen oppnas da i webblasaren i stallet.
)

echo.
echo Installationen ar klar. Starta kontrollpanelen med starta.bat
pause
exit /b 0

:fel
echo.
echo Installationen misslyckades. Se felmeddelandet ovan.
pause
exit /b 1
