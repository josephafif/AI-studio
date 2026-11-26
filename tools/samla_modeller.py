"""Samlar Lennart-modeller i en mapp för datorversionen (mappen "modeller" bredvid Lennart.exe).

För varje modell skrivs <id>.lmod, <id>.tok.json och <id>.modell.json. Källor kan vara
  * modellpaket (.lennart) från exportera_mobil.py --paket
  * exportmappar med manifest.json (exportera_mobil.py --ut …)

    python tools/samla_modeller.py <utmapp> <källa> [<källa> …]
"""
import json
import shutil
import struct
import sys
from pathlib import Path


def from_package(p: Path, out: Path):
    with open(p, "rb") as f:
        head = f.read(12)
        if head[:8] != b"LENPKG01":
            raise SystemExit(f"{p} är inte ett .lennart-paket")
        (n,) = struct.unpack("<I", head[8:12])
        meta = json.loads(f.read(n).decode("utf-8"))
        entry = meta["entry"]
        start = (12 + n + 4095) // 4096 * 4096
        f.seek(start)
        lmod = out / f"{entry['id']}.lmod"
        with open(lmod, "wb") as w:
            shutil.copyfileobj(f, w, 16 << 20)
    if lmod.read_bytes()[:8] != b"LMOD0001":
        raise SystemExit(f"{p}: modelldata saknas")
    (out / f"{entry['id']}.tok.json").write_text(json.dumps(meta["tokenizer"], ensure_ascii=False), encoding="utf-8")
    return entry


def from_export(d: Path, out: Path):
    entries = json.loads((d / "manifest.json").read_text(encoding="utf-8"))["models"]
    for e in entries:
        for ext in (".lmod", ".tok.json"):
            src = d / f"{e['id']}{ext}"
            if not src.exists():
                raise SystemExit(f"{src} saknas")
            shutil.copyfile(src, out / src.name)
    return entries


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    all_entries = {}
    for src in map(Path, sys.argv[2:]):
        got = [from_package(src, out)] if src.suffix == ".lennart" else from_export(src, out)
        for e in got:
            all_entries[e["id"]] = e
            (out / f"{e['id']}.modell.json").write_text(json.dumps(e, ensure_ascii=False, indent=1), encoding="utf-8")
            print(f"  ✓ {e['name']:14s} ({e['id']}) {e['params'] / 1e6:6.1f} M parametrar, {e['steps']} steg")
    print(f"{len(all_entries)} modeller i {out}")


if __name__ == "__main__":
    main()
