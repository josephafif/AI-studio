"""Kaggle-körning (GPU T4 ×2): tränar Lennart 3 med en process per GPU.

Indata: datasetet lennart-3-kod (skripten) och Output från körningen lennart-3-data (web.bin, chat.bin,
tokenizer.json …). Finns en resume_checkpoint.pt bland indata fortsätter träningen därifrån.
Resultat under Output: lennart3/lennart3.pt (färdig modell), resume_checkpoint.pt, tokenizer.json, loggar.
"""
import glob
import os
import subprocess
import sys
import time

os.environ.setdefault("L3_START", str(time.time()))
import torch  # noqa: E402

n = torch.cuda.device_count()
names = [torch.cuda.get_device_name(i) for i in range(n)]
print("GPU:er:", ", ".join(names) or "inga", flush=True)
if n < 2 and os.environ.get("L3_TILLAT_EN_GPU") != "1":
    sys.exit("Körningen fick färre än två GPU:er. Välj Accelerator → GPU T4 x2 under Settings och kör igen.")
script = glob.glob("/kaggle/input/**/lennart3_train.py", recursive=True)
if not script:
    sys.exit("Hittar inte lennart3_train.py – koppla datasetet lennart-3-kod till körningen.")
if not glob.glob("/kaggle/input/**/web.bin", recursive=True):
    sys.exit("Hittar inte träningsdatan (web.bin) – koppla Output från lennart-3-data till körningen.")
os.environ.setdefault("L3_OUT", "/kaggle/working/lennart3")
os.environ.setdefault("OMP_NUM_THREADS", "2")
cmd = [sys.executable, "-m", "torch.distributed.run", "--standalone", f"--nproc_per_node={n}", script[0]]
print("$", " ".join(cmd), flush=True)
t0 = time.time()
rc = subprocess.run(cmd).returncode
if rc != 0 and time.time() - t0 < 1200 and os.environ.get("L3_MICRO") is None:
    # Troligen slut på GPU-minne direkt i början: samma mängd tokens per steg, mindre delbatcher.
    print("\nTräningen avbröts tidigt – försöker igen med 4 sekvenser per delsteg.", flush=True)
    os.environ["L3_MICRO"], os.environ["L3_ACCUM"] = "4", "16"
    rc = subprocess.run(cmd).returncode
print(f"\nTräningsprocessen avslutades med kod {rc}", flush=True)
sys.exit(rc)
