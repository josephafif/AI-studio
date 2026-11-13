"""Packar programmet till ai-studio-moln.zip som laddas upp till molndatorn (Colab/Kaggle).

    python tools/packa_for_molnet.py

Datamappen, .venv och .paket följer inte med. Vill du träna vidare på en egen modell:
exportera den i kontrollpanelen och ladda upp zip-filen separat.
"""
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INCLUDE = ["aicc", "tools", "moln", "resources", "exempel", "main.py", "requirements.txt"]

out = ROOT / "ai-studio-moln.zip"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for name in INCLUDE:
        path = ROOT / name
        files = [path] if path.is_file() else sorted(p for p in path.rglob("*") if p.is_file())
        for f in files:
            if "__pycache__" not in f.parts and f.suffix != ".pyc":
                zf.write(f, f.relative_to(ROOT).as_posix())
print(f"Skapade {out} ({out.stat().st_size / 2**20:.1f} MB). Ladda upp filen i molnanteckningsboken.")
