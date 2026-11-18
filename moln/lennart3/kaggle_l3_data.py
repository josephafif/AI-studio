"""Kaggle-körning (CPU, internet på): förbereder träningsdata för Lennart 3.

Koden (lennart3_data.py m.fl.) kommer från datasetet lennart-3-kod. Resultatet hamnar under
Output och kopplas sedan som indata till körningen trana-lennart-3.
"""
import glob
import os
import subprocess
import sys
import time
import urllib.request

try:
    urllib.request.urlopen("https://huggingface.co", timeout=20)
except Exception as fel:  # noqa: BLE001
    sys.exit(f"Körningen saknar internet ({fel}). Slå på Internet under Settings.")
script = glob.glob("/kaggle/input/**/lennart3_data.py", recursive=True)
if not script:
    sys.exit("Hittar inte lennart3_data.py – koppla datasetet lennart-3-kod till körningen.")
os.environ.setdefault("L3_OUT", "/kaggle/working")
os.environ.setdefault("L3_CACHE", "/tmp/l3cache")
t0 = time.time()
rc = subprocess.run([sys.executable, "-u", script[0]]).returncode
print(f"\nKlart efter {(time.time() - t0) / 3600:.2f} h, returkod {rc}", flush=True)
sys.exit(rc)
