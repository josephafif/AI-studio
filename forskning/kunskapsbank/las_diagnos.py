"""Diagnos: lärde sig läsaren att hitta rätt artikel, eller bara svarets form?

Nya läsövningar (annat frö än träningen) i exakt träningsformatet. Vi mäter om svaret börjar med den
rätta artikelns titel (rätt artikel vald) och om det börjar med någon av de vilseledande artiklarnas titel.

Kör: python forskning/kunskapsbank/las_diagnos.py <index.pkl> <lib> <tokenizer.json> namn=modell.lmod ...
"""
import os
import re
import sys
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "ekodekodning"))
from sok import Index  # noqa: E402
from lasdata import make  # noqa: E402
from ekodekodning import Engine, write_draft  # noqa: E402


def main():
    ixp, lib, tokp = sys.argv[1:4]
    models = dict(a.split("=", 1) for a in sys.argv[4:])
    ix = Index(ixp)
    rng = np.random.default_rng(777)
    exs = []
    for d in rng.permutation(ix.N):
        e = make(ix, rng, int(d))
        if e and e["user"].count("Text: ") >= 2:
            exs.append(e)
        if len(exs) >= 60:
            break
    tok = Tokenizer.from_file(tokp)
    sp = {s: tok.token_to_id(s) for s in ("<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>")}
    banned = [sp["<|endoftext|>"], sp["<|user|>"], sp["<|assistant|>"]]
    for name, path in models.items():
        eng = Engine(lib, path, threads=int(os.environ.get("DIAG_THREADS", 1)))
        r = np.random.default_rng(0)
        right, wrong_title, by = 0, 0, {"framåt": [0, 0], "bakåt": [0, 0]}
        for e in exs:
            prompt = [sp["<|user|>"]] + tok.encode(e["user"]).ids[-440:] + [sp["<|assistant|>"]]
            eng.reset()
            p0 = eng.eval(prompt)
            dd, _ = write_draft(eng, r, prompt, p0, 40, 0.0, 40, banned, sp["<|end|>"], [prompt], None, True)
            ans = tok.decode(dd.toks).strip()
            ok = ans.startswith(e["titel"])
            titles = re.findall(r"Text: (.+?) (?:är|var) ", e["user"])
            wt = (not ok) and any(ans.startswith(t) for t in titles if t != e["titel"])
            right += ok
            wrong_title += wt
            by[e["typ"]][0] += ok
            by[e["typ"]][1] += 1
        n = len(exs)
        print(f"{name}: rätt artikel {right / n:.0%}, fel artikels titel {wrong_title / n:.0%} "
              f"(framåt {by['framåt'][0]}/{by['framåt'][1]}, bakåt {by['bakåt'][0]}/{by['bakåt'][1]})", flush=True)


if __name__ == "__main__":
    main()
