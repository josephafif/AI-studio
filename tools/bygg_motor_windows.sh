#!/bin/sh
# Bygger motorn för Windows (mobil/engine/windows/lmengine.dll) med mingw-w64 på Linux.
# OpenMP länkas statiskt, så DLL:en behöver bara Windows egna systembibliotek (KERNEL32, msvcrt).
#   sudo apt-get install gcc-mingw-w64-x86-64-win32
set -e
cd "$(dirname "$0")/.."
x86_64-w64-mingw32-gcc-win32 -O3 -march=x86-64-v2 -mtune=generic -fopenmp -shared -static -Wall \
  -o mobil/engine/windows/lmengine.dll mobil/engine/lmengine.c -lm
x86_64-w64-mingw32-strip mobil/engine/windows/lmengine.dll
x86_64-w64-mingw32-objdump -p mobil/engine/windows/lmengine.dll | grep "DLL Name"
tr -d "\r" < mobil/engine/lmengine.c | sha256sum | cut -c1-16 > mobil/engine/windows/kalla.sha
echo "klart: mobil/engine/windows/lmengine.dll"
