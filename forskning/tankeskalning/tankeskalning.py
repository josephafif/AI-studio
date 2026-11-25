"""Tankeskalning: blir en liten modell smartare av att tänka (skriva flera utkast och välja)?

För varje fråga i fragor.py skrivs en pool med 6 utkast (som nivån Djup: första försiktigt, T=0,35,
resten T=0,7) plus ett girigt svar (T=0). Olika urvalsregler utvärderas sedan på samma pool:

  snabb       – ett vanligt sampel (T=0,7), som nivån Snabb
  girig       – alltid mest sannolika token
  medel/djup  – appens regel: bäst poäng (medel-logsannolikhet, upprepning, avslut) bland 3 / 6 utkast
  konsensus   – det utkast som mest liknar de andra (ordöverlapp) – "majoritetsrösten" för fritext
  hybrid      – konsensus + poäng
  orakel      – något av utkasten är rätt (övre gräns för vad ett urval kan nå)

Dessutom: kan modellen veta när den inte vet? Hur väl förutsäger poäng/konsensus att svaret är rätt (AUROC)?

Kör: python forskning/tankeskalning/tankeskalning.py <lib> <modell.lmod> <tokenizer.json> <ut.json> [frön]
"""
import json
import re
import sys
import time
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "ekodekodning"))
sys.path.insert(0, str(HERE))
from ekodekodning import Engine, write_draft  # noqa: E402
from fragor import FRAGOR  # noqa: E402


def correct(answer, keys):
    a = " " + re.sub(r"[^\wåäöéü₂ -]", " ", answer.lower()) + " "
    return any(re.search(r"(?<![\wåäö])" + re.escape(k) + r"(?![\wåäö])", a) for k in keys)


def words(t):
    return {w for w in re.findall(r"[\wåäö]+", t.lower()) if len(w) > 2}


def consensus(texts):
    """Medel-Jaccardlikhet mot övriga utkast."""
    ws = [words(t) for t in texts]
    out = []
    for i, a in enumerate(ws):
        sims = [len(a & b) / max(1, len(a | b)) for j, b in enumerate(ws) if j != i]
        out.append(float(np.mean(sims)) if sims else 0.0)
    return out


def main():
    lib, model, tokp, outp = sys.argv[1:5]
    seeds = [int(s) for s in (sys.argv[5].split(",") if len(sys.argv) > 5 else ["11", "22"])]
    tok = Tokenizer.from_file(tokp)
    sp = {s: tok.token_to_id(s) for s in ("<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>")}
    banned = [sp["<|endoftext|>"], sp["<|user|>"], sp["<|assistant|>"]]
    eng = Engine(lib, model)
    rows = []
    t0 = time.time()
    for seed in seeds:
        rng = np.random.default_rng(seed)
        for qi, (q, keys) in enumerate(FRAGOR):
            prompt = [sp["<|user|>"]] + tok.encode(q).ids + [sp["<|assistant|>"]]
            eng.reset()
            p0 = eng.eval(prompt)
            P = len(prompt)
            pool, sources = [], [prompt]
            for i in range(7):  # 0–5 = utkast som i Djup, 6 = girigt
                eng.rewind(P)
                T = 0.0 if i == 6 else (0.35 if i == 0 else 0.7)
                d, _ = write_draft(eng, rng, prompt, p0, 60, T, 40, banned, sp["<|end|>"], sources, None, True)
                text = tok.decode(d.toks)
                pool.append(dict(text=text, score=d.score(), mean_lp=d.mean(), n=len(d.toks),
                                 ok=correct(text, keys)))
                sources.append(prompt + d.toks)
            rows.append(dict(seed=seed, q=q, keys=keys, pool=pool))
            print(f"[{seed}] {qi + 1}/{len(FRAGOR)} {q} → {pool[6]['text'][:70]!r} "
                  f"({sum(p['ok'] for p in pool)}/7 rätt) {time.time() - t0:.0f}s", flush=True)
    json.dump(rows, open(outp, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
