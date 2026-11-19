"""Kaggle-körning (GPU T4 ×2): fortsätter träna Lennart 3 från resume_checkpoint.pt.

Indata: datasetet lennart-3-kod, Output från lennart-3-data och Output från den föregående
träningskörningen (som innehåller resume_checkpoint.pt). Avbryter direkt om checkpointen saknas,
så att GPU-tid aldrig läggs på att börja om från början av misstag.
"""
import glob
import os
import subprocess
import sys
import time

# Körtid i timmar. Kaggle stoppar GPU-körningar efter 12 h, och om veckokvoten tar slut mitt i
# körningen sparas ingen slutmodell – välj därför högst den kvot som finns kvar.
TIMMAR = 11.0

os.environ.setdefault("L3_START", str(time.time()))
os.environ.setdefault("L3_HOURS", str(TIMMAR))
import torch  # noqa: E402

n = torch.cuda.device_count()
print("GPU:er:", ", ".join(torch.cuda.get_device_name(i) for i in range(n)) or "inga", flush=True)
if n < 2:
    sys.exit("Körningen fick färre än två GPU:er. Välj Accelerator → GPU T4 x2 under Settings och kör igen.")
script = glob.glob("/kaggle/input/**/lennart3_train.py", recursive=True)
data = glob.glob("/kaggle/input/**/web.bin", recursive=True)
resume = sorted(glob.glob("/kaggle/input/**/resume_checkpoint.pt", recursive=True), key=os.path.getmtime)
if not script or not data:
    sys.exit("Koden eller träningsdatan saknas bland indata (lennart-3-kod, lennart-3-data).")
if not resume:
    sys.exit("Hittar ingen resume_checkpoint.pt bland indata – lägg till Output från förra träningskörningen.")
print("Fortsätter från:", resume[-1], flush=True)
os.environ["L3_RESUME"] = resume[-1]
os.environ.setdefault("L3_OUT", "/kaggle/working/lennart3")
os.environ.setdefault("OMP_NUM_THREADS", "2")
cmd = [sys.executable, "-m", "torch.distributed.run", "--standalone", f"--nproc_per_node={n}", script[0]]
print("$", " ".join(cmd), flush=True)
rc = subprocess.run(cmd).returncode
print(f"\nTräningsprocessen avslutades med kod {rc}", flush=True)
sys.exit(rc)
