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

if exist ".venv\Scripts\python.exe" goto :venv
%PY% -c "import venv, ensurepip" >nul 2>nul
if errorlevel 1 goto :lokalt
echo Skapar virtuell miljo i .venv ...
%PY% -m venv .venv
if errorlevel 1 goto :lokalt

:venv
set "PIP=.venv\Scripts\python.exe -m pip"
set "MAL="
%PIP% install --upgrade pip >nul
goto :paket

:lokalt
echo.
echo Din Python saknar modulen venv. Paketen installeras i mappen .paket i stallet.
if exist ".venv" rmdir /s /q ".venv"
if exist ".paket\pip" goto :harpip
echo Hamtar pip ...
curl -sSL -o "%TEMP%\aicc-get-pip.py" https://bootstrap.pypa.io/get-pip.py
if errorlevel 1 goto :fel
%PY% "%TEMP%\aicc-get-pip.py" --target .paket --no-warn-script-location
if errorlevel 1 goto :fel
:harpip
set "PIP=%PY% tools\pipkor.py"
set "MAL=--target .paket --upgrade --no-warn-script-location"

:paket
echo.
echo Vilken version av PyTorch vill du installera?
echo   [1] CPU  - fungerar pa alla datorer, standard
echo   [2] GPU  - NVIDIA-grafikkort med CUDA 12.6 och aktuell drivrutin
set "VAL=1"
set /p "VAL=Val (1/2): "
set "INDEX=https://download.pytorch.org/whl/cpu"
if "%VAL%"=="2" set "INDEX=https://download.pytorch.org/whl/cu126"
%PIP% install %MAL% torch --index-url %INDEX%
if errorlevel 1 goto :fel
%PIP% install %MAL% psutil tokenizers
if errorlevel 1 goto :fel
%PIP% install %MAL% pywebview
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
