"""Utvärderar läsförmågan: frågebanken med 0, 1 eller 3 Wikipedia-träffar i frågan (samma format som
läsdatan). Kör samma sak för vanliga Lennart 3.4 och för läsarversionen.

Kör: python forskning/kunskapsbank/las_utvardera.py <index.pkl> <lib> <tokenizer.json> <ut.json> namn=modell.lmod ...
"""
import json
import re
import sys
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tankeskalning"))
sys.path.insert(0, str(HERE.parent / "ekodekodning"))
from sok import Index  # noqa: E402
from tankeskalning import correct  # noqa: E402
from fragor import FRAGOR  # noqa: E402
from ekodekodning import Engine, write_draft  # noqa: E402
from lasdata import PROMPT  # noqa: E402

CHAT = ["Hej! Vem är du?", "Hur mår du?", "Vad är nätfiske?", "Ge mig tips för att sova bättre.",
        "Någon har hackat mitt konto, vad gör jag?"]


def first_sentences(t, n=2):
    return " ".join(re.split(r"(?<=[.!?])\s", t.strip())[:n])


def main():
    ixp, lib, tokp, outp = sys.argv[1:5]
    models = dict(a.split("=", 1) for a in sys.argv[5:])
    ix = Index(ixp)
    tok = Tokenizer.from_file(tokp)
    sp = {s: tok.token_to_id(s) for s in ("<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>")}
    banned = [sp["<|endoftext|>"], sp["<|user|>"], sp["<|assistant|>"]]
    hits = {q: ix.search(q, 3) for q, _ in FRAGOR}
    res = {}
    for name, path in models.items():
        eng = Engine(lib, path)
        rng = np.random.default_rng(0)

        def answer(text):
            prompt = [sp["<|user|>"]] + tok.encode(text).ids[-440:] + [sp["<|assistant|>"]]
            eng.reset()
            p0 = eng.eval(prompt)
            d, _ = write_draft(eng, rng, prompt, p0, 50, 0.0, 40, banned, sp["<|end|>"], [prompt], None, True)
            return tok.decode(d.toks)

        r = {"utan_text": [], "1_traff": [], "3_traffar": []}
        ex = []
        for q, keys in FRAGOR:
            a0 = answer(q)
            a1 = answer(PROMPT.format(ctx=f"Text: {hits[q][0][1][:450]}", q=q))
            a3 = answer(PROMPT.format(ctx="\n\n".join(f"Text: {h[1][:450]}" for h in hits[q]), q=q))
            for k, a in (("utan_text", a0), ("1_traff", a1), ("3_traffar", a3)):
                r[k].append(correct(first_sentences(a), keys))
            ex.append(dict(fraga=q, utan_text=a0, med_3=a3, ratt_3=r["3_traffar"][-1]))
        chat = {q: answer(q) for q in CHAT}
        res[name] = dict(traffsakerhet={k: round(float(np.mean(v)), 3) for k, v in r.items()}, exempel=ex, samtal=chat)
        print(name, res[name]["traffsakerhet"], flush=True)
        for q, a in chat.items():
            print(f"   {q} → {a[:120]!r}", flush=True)
    json.dump(res, open(outp, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
