"""Kan Lennart bli smartare med ett uppslagsverk i stället för att kunna fakta utantill?

Tre mätningar på frågebanken (forskning/tankeskalning/fragor.py):
  1. Sökningen ensam: står svaret i de 3 bästa Wikipedia-träffarna?
  2. Wikipedia som domare: välj det av Lennarts 6 utkast som bäst stöds av träffarna
     (viktat ordöverlapp mellan utkastet och artiklarna, utöver frågans egna ord).
  3. Läsa och svara: artikeln läggs i frågan ("Läs: … Fråga: …") och Lennart svarar.

Kör: python forskning/kunskapsbank/las.py <index.pkl> <pool.json> <lib> <modell.lmod> <tokenizer.json> <ut.json>
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tankeskalning"))
sys.path.insert(0, str(HERE.parent / "ekodekodning"))
from sok import Index, words  # noqa: E402
from tankeskalning import correct  # noqa: E402
from fragor import FRAGOR  # noqa: E402
from ekodekodning import Engine, write_draft  # noqa: E402


def first_sentences(t, n=2):
    import re
    return " ".join(re.split(r"(?<=[.!?])\s", t.strip())[:n])


def main():
    ixp, poolp, lib, model, tokp, outp = sys.argv[1:7]
    ix = Index(ixp)
    pools = json.load(open(poolp))
    res = {"sok_top1": [], "sok_top3": [], "domare": [], "las_svara_girig": [], "las_svara_sampel": [],
           "utan_las_girig": []}
    hits = {}
    for q, keys in FRAGOR:
        top = ix.search(q, 3)
        hits[q] = top
        res["sok_top1"].append(correct(top[0][0] + " " + top[0][1], keys))
        res["sok_top3"].append(any(correct(t + " " + l, keys) for t, l, _ in top))
    # 2. Wikipedia som domare bland utkasten
    for r in pools:
        q = r["q"]
        support_words = {}
        for rank, (t, lead, s) in enumerate(hits[q]):
            for w in set(words(t + " " + lead)):
                support_words[w] = support_words.get(w, 0) + 1.0 / (rank + 1)
        qw = set(words(q))
        scores = []
        for p in r["pool"][:6]:
            ws = set(words(p["text"])) - qw
            scores.append(sum(support_words.get(w, 0) for w in ws) / math.sqrt(1 + len(ws)))
        res["domare"].append(r["pool"][int(np.argmax(scores))]["ok"])
    # 3. Läsa och svara
    tok = Tokenizer.from_file(tokp)
    sp = {s: tok.token_to_id(s) for s in ("<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>")}
    banned = [sp["<|endoftext|>"], sp["<|user|>"], sp["<|assistant|>"]]
    eng = Engine(lib, model, threads=int(__import__("os").environ.get("LAS_THREADS", 1)))
    rng = np.random.default_rng(3)
    examples = []
    for q, keys in FRAGOR:
        t, lead, _ = hits[q][0]
        ctx = f"Läs texten och svara kort på frågan.\n\nText: {lead[:500]}\n\nFråga: {q}"
        for name, text_in, T in (("las_svara_girig", ctx, 0.0), ("las_svara_sampel", ctx, 0.7),
                                 ("utan_las_girig", q, 0.0)):
            prompt = [sp["<|user|>"]] + tok.encode(text_in).ids[-400:] + [sp["<|assistant|>"]]
            eng.reset()
            p0 = eng.eval(prompt)
            d, _ = write_draft(eng, rng, prompt, p0, 50, T, 40, banned, sp["<|end|>"], [prompt], None, True)
            ans = tok.decode(d.toks)
            ok = correct(first_sentences(ans), keys)
            res[name].append(ok)
            if name == "las_svara_girig":
                examples.append(dict(fraga=q, artikel=t, svar=ans, ratt=ok))
        print(f"{q} → {examples[-1]['svar'][:90]!r} ({'rätt' if examples[-1]['ratt'] else 'fel'})", flush=True)
    summary = {k: round(float(np.mean(v)), 3) for k, v in res.items()}
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    json.dump(dict(sammanfattning=summary, exempel=examples), open(outp, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
