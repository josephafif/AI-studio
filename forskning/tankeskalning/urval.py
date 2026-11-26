"""Bättre sätt att välja bland utkasten (på poolerna från tankeskalning.py).

Hypotes: appens poäng (medel-logsannolikhet) belönar svar som är *flytande* i allmänhet – inte svar
som besvarar *just den här frågan*. Om vi drar av hur sannolikt svaret är utan frågan blir det kvar
hur mycket frågan "förklarar" svaret:

  frågevinst = log P(svar | fråga) − log P(svar | ingen fråga)

Dessutom "bakåtkontroll": hur sannolik är frågan om man först har sett svaret?

  bakåt = log P(fråga | svar)

Allt räknas med C-motorn: ett pass per utkast och villkor (lm_eval_all).

Kör: python forskning/tankeskalning/urval.py <lib> <modell.lmod> <tokenizer.json> pool.json
"""
import json
import sys
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "ekodekodning"))
sys.path.insert(0, str(HERE))
from ekodekodning import Engine  # noqa: E402
from tankeskalning import consensus  # noqa: E402


def seq_logprob(eng, context, target):
    """Summa log P(target | context) och antal tokens."""
    eng.reset()
    first = eng.eval(context)
    rows = eng.eval_all(target) if len(target) > 1 else None
    lp = 0.0
    prev = first
    for i, t in enumerate(target):
        row = prev if i == 0 else rows[i - 1]
        m = row.max()
        lp += float(row[t] - m - np.log(np.exp(row - m).sum()))
    return lp


def main():
    lib, model, tokp, poolp = sys.argv[1:5]
    tok = Tokenizer.from_file(tokp)
    sp = {s: tok.token_to_id(s) for s in ("<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>")}
    eng = Engine(lib, model)
    rows = json.load(open(poolp))
    for n, r in enumerate(rows):
        q = tok.encode(r["q"]).ids
        for p in r["pool"]:
            a = tok.encode(p["text"].strip()).ids[:60] or [sp["<|end|>"]]
            cond = seq_logprob(eng, [sp["<|user|>"]] + q + [sp["<|assistant|>"]], a)
            unc = seq_logprob(eng, [sp["<|user|>"], sp["<|assistant|>"]], a)
            back = seq_logprob(eng, [sp["<|assistant|>"]] + a + [sp["<|end|>"], sp["<|user|>"]], q)
            p.update(cond=cond, unc=unc, back=back, ntok=len(a))
        if n % 20 == 0:
            print(f"{n}/{len(rows)}", flush=True)
    json.dump(rows, open(poolp.replace(".json", "_urval.json"), "w"), ensure_ascii=False, indent=1)

    rules = {
        "poäng (appen)": lambda p: p["score"],
        "frågevinst": lambda p: p["cond"] - p["unc"],
        "frågevinst per token": lambda p: (p["cond"] - p["unc"]) / p["ntok"],
        "bakåtkontroll": lambda p: p["back"],
        "frågevinst + bakåt": None,
        "konsensus": None,
    }
    for k in (3, 6):
        print(f"--- bland {k} utkast")
        for name, f in rules.items():
            hits = []
            for r in rows:
                d = r["pool"][:k]
                if name == "konsensus":
                    s = consensus([p["text"] for p in d])
                elif name == "frågevinst + bakåt":
                    a = np.array([p["cond"] - p["unc"] for p in d])
                    b = np.array([p["back"] for p in d])
                    s = (a - a.mean()) / (a.std() + 1e-6) + (b - b.mean()) / (b.std() + 1e-6)
                else:
                    s = [f(p) for p in d]
                hits.append(d[int(np.argmax(s))]["ok"])
            print(f"{name:24s} {np.mean(hits):6.1%}")


if __name__ == "__main__":
    main()
