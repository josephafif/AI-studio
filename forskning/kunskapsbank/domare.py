"""Lärd domare: kan en liten logistisk regression välja rätt utkast bättre än modellens egen poäng?

Egenskaper per utkast (normerade inom frågan, så att domaren jämför utkasten med varandra):
  poäng, medel-logsannolikhet, längd, frågevinst, bakåtkontroll, konsensus, Wikipedia-stöd.
Utvärderas med korsvalidering där en hel fråga (båda fröna) hålls utanför åt gången.

Kör: python forskning/kunskapsbank/domare.py <index.pkl> <pool_urval.json>
"""
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tankeskalning"))
from sok import Index, words  # noqa: E402
from tankeskalning import consensus  # noqa: E402

NAMES = ["poäng", "medel-logp", "längd", "frågevinst", "bakåt", "konsensus", "wiki-stöd"]


def features(ix, r):
    d = r["pool"][:6]
    hits = ix.search(r["q"], 3)
    sw = {}
    for rank, (t, lead, _) in enumerate(hits):
        for w in set(words(t + " " + lead)):
            sw[w] = sw.get(w, 0) + 1.0 / (rank + 1)
    qw = set(words(r["q"]))
    wiki = []
    for p in d:
        ws = set(words(p["text"])) - qw
        wiki.append(sum(sw.get(w, 0) for w in ws) / math.sqrt(1 + len(ws)))
    cons = consensus([p["text"] for p in d])
    X = np.array([[p["score"], p["mean_lp"], math.log(1 + p["n"]), p["cond"] - p["unc"], p["back"] / max(1, p["ntok"]),
                   c, w] for p, c, w in zip(d, cons, wiki)], float)
    X = (X - X.mean(0)) / (X.std(0) + 1e-6)  # jämför inom frågan
    y = np.array([p["ok"] for p in d], float)
    return X, y


def fit(X, y, lam=1.0, steps=600, lr=0.1):
    w = np.zeros(X.shape[1] + 1)
    Xb = np.hstack([X, np.ones((len(X), 1))])
    for _ in range(steps):
        p = 1 / (1 + np.exp(-Xb @ w))
        g = Xb.T @ (p - y) / len(y) + lam * np.r_[w[:-1], 0] / len(y)
        w -= lr * g
    return w


def main():
    ix = Index(sys.argv[1])
    rows = json.load(open(sys.argv[2]))
    data = [(r["q"], *features(ix, r)) for r in rows]
    qs = sorted({q for q, _, _ in data})
    hits, singles = [], {n: [] for n in NAMES}
    for q in qs:
        tr = [(X, y) for qq, X, y in data if qq != q]
        w = fit(np.vstack([X for X, _ in tr]), np.concatenate([y for _, y in tr]))
        for qq, X, y in data:
            if qq != q:
                continue
            s = np.hstack([X, np.ones((len(X), 1))]) @ w
            hits.append(y[int(np.argmax(s))])
            for i, n in enumerate(NAMES):
                singles[n].append(y[int(np.argmax(X[:, i]))])
    print(f"lärd domare (korsvaliderad): {np.mean(hits):.1%}  (n={len(hits)})")
    for n in NAMES:
        print(f"  bara {n:12s} {np.mean(singles[n]):.1%}")
    w = fit(np.vstack([X for _, X, _ in data]), np.concatenate([y for _, _, y in data]))
    print("vikter:", {n: round(float(v), 2) for n, v in zip(NAMES, w)})
    json.dump(dict(domare=float(np.mean(hits)), enskilda={n: float(np.mean(v)) for n, v in singles.items()},
                   vikter={n: float(v) for n, v in zip(NAMES, w)}),
              open(str(HERE / "domare_resultat.json"), "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
