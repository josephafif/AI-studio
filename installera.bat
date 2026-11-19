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

rem Paket som används av en igångvarande kontrollpanel kan inte skrivas över (Åtkomst nekad).
for %%D in (".paket\psutil" ".venv\Lib\site-packages\psutil") do (
  if exist "%%~D" (
    ren "%%~D" psutil_lastest >nul 2>nul
    if errorlevel 1 goto :igang
    ren "%%~dpDpsutil_lastest" psutil >nul 2>nul
  )
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
set "KOLL=.venv\Scripts\python.exe -c "import "
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
set "KOLL=%PY% -c "import sys; sys.path.insert(0, '.paket'); import "

:paket
echo.
echo Vilken version av PyTorch vill du installera?
set "VAL=1"
%KOLL%torch" >nul 2>nul
if not errorlevel 1 (
  echo   [0] Behall den som redan ar installerad - standard
  set "VAL=0"
)
echo   [1] CPU  - fungerar pa alla datorer
echo   [2] GPU  - NVIDIA-grafikkort med CUDA 12.6 och aktuell drivrutin
set /p "VAL=Val: "
set "INDEX=https://download.pytorch.org/whl/cpu"
if "%VAL%"=="2" set "INDEX=https://download.pytorch.org/whl/cu126"
if "%VAL%"=="0" goto :ovriga
%PIP% install %MAL% torch --index-url %INDEX%
if errorlevel 1 goto :fel

:ovriga
rem Bara paket som saknas installeras – befintliga lämnas orörda.
for %%P in (psutil tokenizers) do (
  %KOLL%%%P" >nul 2>nul
  if errorlevel 1 (
    %PIP% install %MAL% %%P
    if errorlevel 1 goto :fel
  ) else (
    echo %%P finns redan.
  )
)
%KOLL%webview" >nul 2>nul
if errorlevel 1 (
  %PIP% install %MAL% pywebview
  if errorlevel 1 (
    echo.
    echo OBS: pywebview kunde inte installeras. Kontrollpanelen oppnas da i webblasaren i stallet.
  )
)

echo.
echo Installationen ar klar. Starta kontrollpanelen med starta.bat
pause
exit /b 0

:igang
echo.
echo Kontrollpanelen verkar vara igang. Stang dess fonster (och konsolfonstret fran starta.bat)
echo och kor installera.bat igen.
pause
exit /b 1

:fel
echo.
echo Installationen misslyckades. Se felmeddelandet ovan.
pause
exit /b 1
