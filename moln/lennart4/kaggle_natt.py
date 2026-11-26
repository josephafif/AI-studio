"""Bygger och skickar Lennart 4:s träningskörning till Kaggle (2× T4): fas 1 (svensk förträning) och sedan
fas 2 (samtal) i samma session, från pilotens vikter.

    python moln/lennart4/kaggle_natt.py              # bygg och skicka
    python moln/lennart4/kaggle_natt.py --bara-bygg  # bygg kernel-mappen men skicka inte

Kräver Kaggle-CLI:t med inloggning (~/.kaggle). Träningskoden (lfm_trana.py) och Lennarts egna samtal
(moln/lennart3/lennart3_samtal.jsonl) bäddas in i kernel-filen, så att körningen inte behöver några dataset.
Kaggles GPU-kvot är cirka 30 timmar i veckan; en hel körning tar ungefär 10 timmar. Fas 1 sparar en
sparpunkt var 100:e minut, så att inget går förlorat om tiden eller kvoten tar slut.

Pilotens mätningar (26 nov): 5 150 tokens/s på 2× T4 i fp16 (cirka 18 M tokens i timmen), toppminne 10,9 GB.
"""
import argparse
import base64
import json
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROT = HERE.parent.parent
DOCKER = "gcr.io/kaggle-private-byod/python@sha256:fc720c15545eb096a510e1f085b17fc118387a007599424d953a4f327b71cacf"

DRIVARE = '''# Lennart 4.0 – träningskörning: fas 1 (svensk förträning, ~{min1} min) och fas 2 (samtal, ~{min2} min) på
# LFM2.5-350M. Startar från vikterna i kernel-källan {start} (finns de inte: originalet från Hugging Face).
# Byggd av moln/lennart4/kaggle_natt.py i AI Studio-repot; träningskoden är moln/lennart4/lfm_trana.py.
import base64, glob, subprocess, sys
from pathlib import Path
KOD = base64.b64decode("{kod}").decode()
SAMTAL = base64.b64decode("{samtal}").decode()
Path("/kaggle/working/lfm_trana.py").write_text(KOD)
Path("/kaggle/working/samtal.jsonl").write_text(SAMTAL)
hittad = sorted(glob.glob("/kaggle/input/**/modell/config.json", recursive=True))
start = str(Path(hittad[-1]).parent) if hittad else "LiquidAI/LFM2.5-350M"
print("startmodell:", start, flush=True)

def kor(*args):
    cmd = [sys.executable, "/kaggle/working/lfm_trana.py", *args]
    print("$", " ".join(cmd), flush=True)
    return subprocess.run(cmd).returncode

if {min1} > 0:
    rc = kor("--fas", "cpt", "--modell", start, "--ut", "/kaggle/working/l4-fas1", "--minuter", "{min1}",
             "--tokens", "{tokens1}", "--lr", "{lr1}", "--micro", "2", "--eval-var", "50", "--spara-var", "100")
    print("fas 1 klar med kod", rc, flush=True)
    start = "/kaggle/working/l4-fas1/modell"
if {min2} > 0 and Path(start + "/config.json").exists() or ({min2} > 0 and not start.startswith("/")):
    rc2 = kor("--fas", "sft", "--modell", start, "--ut", "/kaggle/working/l4-fas2", "--minuter", "{min2}",
              "--tokens", "{tokens2}", "--lr", "{lr2}", "--micro", "2", "--samtal", "/kaggle/working/samtal.jsonl",
              "--upprepa-egna", "30", "--eval-var", "40", "--spara-var", "60")
    print("fas 2 klar med kod", rc2, flush=True)
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slug", default="lennart-4-fas1", help="kernelns namn på Kaggle")
    ap.add_argument("--start", default="josephafif/lennart-4-pilot", help="kernel vars utdata (…/modell) är startvikterna")
    ap.add_argument("--minuter-fas1", type=int, default=420)
    ap.add_argument("--minuter-fas2", type=int, default=140)
    ap.add_argument("--lr-fas1", default="2e-4")
    ap.add_argument("--lr-fas2", default="5e-5")
    ap.add_argument("--bara-bygg", action="store_true")
    a = ap.parse_args()

    agare = a.start.split("/")[0]
    kod = base64.b64encode((HERE / "lfm_trana.py").read_bytes()).decode()
    samtal = base64.b64encode((ROT / "moln" / "lennart3" / "lennart3_samtal.jsonl").read_bytes()).decode()
    mapp = Path(tempfile.mkdtemp(prefix="kaggle-l4-"))
    text = DRIVARE.format(min1=a.minuter_fas1, min2=a.minuter_fas2, start=a.start, kod=kod, samtal=samtal,
                          tokens1=f"{a.minuter_fas1 * 60 * 5150:.2e}", tokens2=f"{a.minuter_fas2 * 60 * 5150:.2e}",
                          lr1=a.lr_fas1, lr2=a.lr_fas2)
    compile(text, "drivare", "exec")
    (mapp / f"{a.slug}.py").write_text(text)
    (mapp / "kernel-metadata.json").write_text(json.dumps({
        "id": f"{agare}/{a.slug}", "title": a.slug, "code_file": f"{a.slug}.py", "language": "python",
        "kernel_type": "script", "is_private": True, "enable_gpu": True, "enable_tpu": False, "enable_internet": True,
        "keywords": ["gpu"], "dataset_sources": [], "kernel_sources": [a.start] if a.start else [],
        "competition_sources": [], "model_sources": [], "machine_shape": "NvidiaTeslaT4", "docker_image": DOCKER,
    }, indent=2))
    print("kernel-mapp:", mapp)
    if a.bara_bygg:
        return
    r = subprocess.run(["kaggle", "kernels", "push", "-p", str(mapp)], capture_output=True, text=True)
    print((r.stdout + r.stderr).strip())
    if "quota" in (r.stdout + r.stderr).lower():
        raise SystemExit("GPU-kvoten är slut – försök igen när den har nollställts (se Kaggle → Settings → Quota).")


if __name__ == "__main__":
    main()
