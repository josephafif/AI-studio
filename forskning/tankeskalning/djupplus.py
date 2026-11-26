"""Djup+: bygg svaret mening för mening av de bästa delarna ur upp till 20 utkast.

För varje mening skrivs upp till 5 kandidater från samma början (KV-cachen spolas tillbaka). Den
kandidat väljs som bäst stämmer med de andra (konsensus) och som modellen är säker på, med straff för
upprepning. Sedan fortsätter alla nya kandidater från den valda meningen. Om tre kandidater blir
identiska räcker det: modellen är överens med sig själv.

Jämförs med frågebankens tidigare resultat (pool_lennart34_analys.json).

Kör: python forskning/tankeskalning/djupplus.py <lib> <modell.lmod> <tokenizer.json> <ut.json> [frön]
"""
import json
import sys
import time
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "ekodekodning"))
sys.path.insert(0, str(HERE))
from ekodekodning import Engine, dist, raw_logprob  # noqa: E402
from tankeskalning import consensus, correct  # noqa: E402
from fragor import FRAGOR  # noqa: E402

BUDGET, PER_SENTENCE, MAX_SENTENCES = 20, 5, 6


def repetition(t):
    if len(t) < 6:
        return 0.0
    seen, dup = set(), 0
    for i in range(len(t) - 2):
        k = (t[i], t[i + 1], t[i + 2])
        dup += k in seen
        seen.add(k)
    return dup / (len(t) - 2)


def sentence(eng, rng, tok, base_logits, prefix, T, banned, end_id, max_tok):
    cur, toks, lps, ended = base_logits, [], [], False
    while len(toks) < max_tok:
        p = dist(cur, T, 40, prefix + toks, banned)
        x = int(rng.choice(len(p), p=p))
        lps.append(raw_logprob(cur, x))
        if x == end_id:
            ended = True
            break
        toks.append(x)
        piece = tok.decode([x])
        if len(toks) >= 3 and piece.rstrip()[-1:] in ".!?" and tok.decode(toks).rstrip()[-1:] in ".!?":
            break
        cur = eng.eval([x])
    return dict(toks=toks, text=tok.decode(toks), mean=float(np.mean(lps)), ended=ended)


def djupplus(eng, tok, sp, q, rng, T=0.7, limit=60):
    banned = [sp["<|endoftext|>"], sp["<|user|>"], sp["<|assistant|>"]]
    prompt = [sp["<|user|>"]] + tok.encode(q).ids + [sp["<|assistant|>"]]
    eng.reset()
    cur = eng.eval(prompt)
    answer, used, trace = [], 0, []
    for s in range(MAX_SENTENCES):
        base = eng.pos
        cands = []
        k = min(PER_SENTENCE, max(1, BUDGET - used))
        for c in range(k):
            eng.rewind(base)
            t = 0.35 if c == 0 else T
            cands.append(sentence(eng, rng, tok, cur, answer, t, banned, sp["<|end|>"], max(1, limit - len(answer))))
            used += 1
            texts = [x["text"].strip() for x in cands]
            if len(cands) >= 3 and texts.count(texts[-1]) >= 3:
                break  # tre likadana: modellen är överens med sig själv
        cons = consensus([x["text"] for x in cands]) if len(cands) > 1 else [0.0]
        scores = [x["mean"] + 1.0 * cn - 2.0 * repetition(answer + x["toks"]) - (0.5 if len(x["toks"]) < 3 and not x["ended"] else 0)
                  for x, cn in zip(cands, cons)]
        best = cands[int(np.argmax(scores))]
        trace.append(dict(mening=s, kandidater=[x["text"] for x in cands], vald=int(np.argmax(scores))))
        eng.rewind(base)
        if best["toks"]:
            answer += best["toks"]
            cur = eng.eval(best["toks"])
        if best["ended"] or len(answer) >= limit or eng.pos >= eng.ctx - 2:
            break
    return tok.decode(answer), used, trace


def main():
    lib, model, tokp, outp = sys.argv[1:5]
    seeds = [int(s) for s in (sys.argv[5].split(",") if len(sys.argv) > 5 else ["11", "22"])]
    tok = Tokenizer.from_file(tokp)
    sp = {s: tok.token_to_id(s) for s in ("<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>")}
    eng = Engine(lib, model)
    rows, t0 = [], time.time()
    for seed in seeds:
        rng = np.random.default_rng(seed)
        for i, (q, keys) in enumerate(FRAGOR):
            eng.passes = 0
            a, used, trace = djupplus(eng, tok, sp, q, rng)
            ok = correct(a, keys)
            rows.append(dict(seed=seed, q=q, svar=a, ok=ok, utkast=used, pass_=eng.passes, spar=trace))
            print(f"[{seed}] {i + 1}/{len(FRAGOR)} {'RÄTT' if ok else 'fel '} {q} → {a[:80]!r} ({used} utkast, {time.time() - t0:.0f}s)",
                  flush=True)
    acc = float(np.mean([r["ok"] for r in rows]))
    print(f"Djup+: {acc:.1%} rätt, i snitt {np.mean([r['utkast'] for r in rows]):.1f} utkast, "
          f"{np.mean([r['pass_'] for r in rows]):.0f} pass per fråga")
    json.dump(dict(traffsakerhet=acc, rader=rows), open(outp, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
