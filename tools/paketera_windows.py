"""Sätter ihop Lennart för Windows: programmet från byggflödet + modellerna, i zip-filer under 500 MB.

    python tools/paketera_windows.py <Release-mapp> <modellmapp> <utmapp>

<Release-mapp>: artefakten "Lennart-windows" från GitHub Actions (Lennart.exe, DLL:er, data/).
<modellmapp>:   från tools/samla_modeller.py (alla <id>.lmod, .tok.json, .modell.json).

Resultat:
    Lennart-för-Windows.zip   programmet + Lennart, Lennart 2 och den nyaste Lennart 3.x
    Lennart-3.3.zip …         en zip per övrig modell; packas upp på samma ställe och hamnar i Lennart/modeller
Alla filer ligger under mappen Lennart/ i zip-filerna, så de går ihop av sig själva.
"""
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "mobil" / "lennart_app" / "windows" / "paket" / "Läs-mig.txt"
MAX_BYTES = 480 * 1024 * 1024  # marginal till gränsen på 500 MB


def add_dir(z: zipfile.ZipFile, src: Path, arc: str):
    for f in sorted(src.rglob("*")):
        if f.is_file():
            z.write(f, f"{arc}/{f.relative_to(src).as_posix()}")


def add_model(z: zipfile.ZipFile, models: Path, mid: str):
    for ext in (".lmod", ".tok.json", ".modell.json"):
        z.write(models / f"{mid}{ext}", f"Lennart/modeller/{mid}{ext}")


def main():
    release, models, out = map(Path, sys.argv[1:4])
    out.mkdir(parents=True, exist_ok=True)
    if not (release / "Lennart.exe").exists() or not (release / "lmengine.dll").exists():
        raise SystemExit(f"{release} saknar Lennart.exe eller lmengine.dll")
    entries = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(models.glob("*.modell.json"))]
    entries.sort(key=lambda e: (e["params"], e["steps"]))
    big = [e for e in entries if e["params"] > 100e6]
    main_ids = [e["id"] for e in entries if e["params"] <= 100e6] + ([big[-1]["id"]] if big else [])
    files = []

    path = out / "Lennart-för-Windows.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        add_dir(z, release, "Lennart")
        z.write(README, "Lennart/Läs-mig.txt")
        for mid in main_ids:
            add_model(z, models, mid)
    files.append((path, [e["name"] for e in entries if e["id"] in main_ids]))

    for e in reversed([e for e in big if e["id"] not in main_ids]):
        path = out / f"{e['name'].replace(' ', '-')}.zip"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            add_model(z, models, e["id"])
        files.append((path, [e["name"]]))

    for path, names in files:
        size = path.stat().st_size
        flag = "  ← FÖR STOR" if size > MAX_BYTES else ""
        print(f"{path.name:28s} {size / 1e6:7.1f} MB  {', '.join(names)}{flag}")
        if size > MAX_BYTES:
            raise SystemExit("En fil blev för stor")


if __name__ == "__main__":
    main()
