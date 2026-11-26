"""Bygger webbversionen av Lennart till en enda fil: webb/lennart.html.

    python webb/app/bygg.py

Steg:
  1. Motorn (mobil/engine/lmengine.c) → lmengine.wasm med Zig (pip install ziglang).
  2. Arbetstrådens Dart-del (mobil/lennart_app/webbmotor/arbetare.dart) → JavaScript med dart2js.
  3. arbetare-start.js + motorn (base64) + Dart-delen läggs in i mall.html.

Filen fungerar både publicerad och öppnad direkt från disken: allt ligger i den, och inget hämtas
utifrån förutom typsnitt.
"""
import base64
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROT = HERE.parent.parent
MOTOR = ROT / "mobil" / "engine" / "lmengine.c"
APP = ROT / "mobil" / "lennart_app"
DART = os.environ.get("DART", "/root/tools/flutter/bin/dart")
EXPORTER = "lm_load_mem lm_free lm_info lm_reset lm_pos lm_logits lm_rewind lm_logprob lm_eval lm_eval_all malloc free".split()


def kor(cmd, **kw):
    print("$", " ".join(str(c) for c in cmd)[:160])
    subprocess.run(cmd, check=True, **kw)


def main():
    wasm = HERE / "lmengine.wasm"
    kor([sys.executable, "-m", "ziglang", "cc", "-target", "wasm32-wasi", "-O3", "-s", "-msimd128", "-fopenmp-simd",
         "-fno-math-errno", "-mexec-model=reactor", *[f"-Wl,--export={e}" for e in EXPORTER],
         "-Wl,--initial-memory=33554432", "-Wl,--max-memory=4294901760", "-o", wasm, MOTOR])
    dartjs = HERE / "arbetare.dart.js"
    kor([DART, "compile", "js", "-O2", "--no-source-maps", "-o", dartjs, "webbmotor/arbetare.dart"], cwd=APP)
    (HERE / "arbetare.dart.js.deps").unlink(missing_ok=True)

    start = (HERE / "arbetare-start.js").read_text(encoding="utf-8")
    start = start.replace("__WASM__", base64.b64encode(wasm.read_bytes()).decode())
    arbetare = start + "\n" + dartjs.read_text(encoding="utf-8")
    if "</script" in arbetare.lower():
        arbetare = arbetare.replace("</script", "<\\/script").replace("</SCRIPT", "<\\/SCRIPT")
    mall = (HERE / "mall.html").read_text(encoding="utf-8")
    assert "/*ARBETARE*/" in mall
    html = mall.replace("/*ARBETARE*/", arbetare)
    ut = ROT / "webb" / "lennart.html"
    ut.write_text(html, encoding="utf-8")
    # Arbetstråden för sig, för tester utan gränssnitt.
    (HERE / "arbetare.js").write_text(arbetare, encoding="utf-8")
    print(f"skrev {ut} ({len(html) / 1e6:.2f} MB)")


if __name__ == "__main__":
    main()
