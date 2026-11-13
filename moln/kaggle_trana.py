"""Körs som Kaggle-skript: hämtar data, tränar Lennart 2 på GPU och sparar modellen under Output.

Programmet (aicc/, tools/, moln/ …) ska finnas som ett Kaggle-dataset kopplat till körningen.
Inställningar ändras med miljövariablerna nedan eller direkt i filen.
"""
import glob
import os
import shutil
import subprocess
import sys
import zipfile

NAMN = os.environ.get("AICC_NAMN", "Lennart 2")
PARAMETRAR = os.environ.get("AICC_PARAMETRAR", "8000000")
STEG = os.environ.get("AICC_STEG", "15000")
BATCH = os.environ.get("AICC_BATCH", "64")

APP, DATA, UT = "/tmp/app", "/tmp/aicc-data", "/kaggle/working"


def run(*cmd):
    print("\n$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, cwd=APP)


hits = glob.glob("/kaggle/input/**/moln/trana.py", recursive=True)
if hits:
    shutil.copytree(os.path.dirname(os.path.dirname(hits[0])), APP, dirs_exist_ok=True)
else:
    zips = glob.glob("/kaggle/input/**/*.zip", recursive=True)
    if not zips:
        sys.exit("Hittar inte programmet under /kaggle/input – koppla datasetet med koden till körningen.")
    zipfile.ZipFile(zips[0]).extractall(APP)
    inner = glob.glob(APP + "/*/moln/trana.py")
    if inner and not os.path.exists(APP + "/moln/trana.py"):
        APP = os.path.dirname(os.path.dirname(inner[0]))
os.environ["AICC_DATA"] = DATA
os.makedirs(UT, exist_ok=True)

import torch  # noqa: E402

if torch.cuda.is_available():
    print("GPU:", ", ".join(torch.cuda.get_device_name(i) for i in range(torch.cuda.device_count())), flush=True)
elif os.environ.get("AICC_TILLAT_CPU") != "1":
    sys.exit("Ingen GPU tilldelades körningen. Slå på Accelerator → GPU under Settings (kräver "
             "telefonverifierat Kaggle-konto) och kör igen. Sätt AICC_TILLAT_CPU=1 för att träna på CPU ändå.")
try:
    import urllib.request
    urllib.request.urlopen("https://huggingface.co", timeout=20)
except Exception as fel:  # noqa: BLE001
    sys.exit(f"Körningen saknar internet ({fel}). Slå på Internet under Settings (kräver telefonverifierat konto).")
run(sys.executable, "-m", "pip", "-q", "install", "pyarrow", "psutil")
run(sys.executable, "tools/hamta_data.py")
slug = "".join(c if c.isalnum() else "-" for c in NAMN.lower()).strip("-")
out = f"{UT}/{slug}.aicc-modell.zip"
run(sys.executable, "moln/trana.py", "--ny", NAMN, "--parametrar", PARAMETRAR, "--lager", "6", "--heads", "6",
    "--context", "256", "--ordforrad", "8192", "--steg", STEG, "--batch", BATCH, "--ut", out)

# Några provfrågor i loggen, så att resultatet går att bedöma utan att ladda ner modellen
sys.path.insert(0, APP)
from aicc.core import models  # noqa: E402
from aicc.engine import inference  # noqa: E402

model = next(m for m in models.list_models() if m["namn"] == NAMN)
print("\n=== Provfrågor ===")
for q in ["Hej!", "Vad är nätfiske?", "Vad är en brandvägg?", "Hur skyddar jag mig mot ransomware?",
          "Vad är kryptografi?", "Vad är TCP?", "Vad är Linux?", "Kan du förklara vad ett operativsystem är?",
          "Vad säger cybersäkerhetslagen?", "Hur skapar jag ett starkt lösenord?"]:
    svar = "".join(e.get("text", "") for e in inference.chat_stream(
        model["id"], [{"role": "user", "content": q}], 0.3, 120, 40))
    print(f"F: {q}\nS: {svar.strip()}\n", flush=True)
print("Klar. Modellen finns under Output:", out)
