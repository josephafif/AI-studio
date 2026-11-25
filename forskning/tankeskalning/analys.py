"""Analys av poolerna från tankeskalning.py: träffsäkerhet per urvalsregel och kalibrering.

Kör: python forskning/tankeskalning/analys.py pool.json [fler.json ...]
"""
import json
import re
import sys

import numpy as np

from tankeskalning import consensus


def first_sentence(t):
    return re.split(r"(?<=[.!?])\s", t.strip(), maxsplit=1)[0]


def auroc(scores, labels):
    s, y = np.array(scores, float), np.array(labels, bool)
    if y.all() or (~y).all():
        return float("nan")
    order = np.argsort(s)
    ranks = np.empty(len(s))
    ranks[order] = np.arange(1, len(s) + 1)
    return float((ranks[y].sum() - y.sum() * (y.sum() + 1) / 2) / (y.sum() * (~y).sum()))


def main():
    rows = [r for p in sys.argv[1:] for r in json.load(open(p))]
    strat = {k: [] for k in ("snabb (1 sampel)", "girig", "medel: poäng (3)", "djup: poäng (6)",
                             "medel: konsensus (3)", "djup: konsensus (6)", "djup: hybrid (6)", "orakel (6)")}
    calib = {"poäng": ([], []), "konsensus": ([], [])}
    for r in rows:
        pool = r["pool"]
        d6, d3 = pool[:6], pool[:3]
        strat["snabb (1 sampel)"].append(pool[1]["ok"])
        strat["girig"].append(pool[6]["ok"])
        strat["medel: poäng (3)"].append(max(d3, key=lambda p: p["score"])["ok"])
        strat["djup: poäng (6)"].append(max(d6, key=lambda p: p["score"])["ok"])
        c3 = consensus([p["text"] for p in d3])
        c6 = consensus([p["text"] for p in d6])
        strat["medel: konsensus (3)"].append(d3[int(np.argmax(c3))]["ok"])
        strat["djup: konsensus (6)"].append(d6[int(np.argmax(c6))]["ok"])
        sc = np.array([p["score"] for p in d6])
        z = (sc - sc.mean()) / (sc.std() + 1e-6) + (np.array(c6) - np.mean(c6)) / (np.std(c6) + 1e-6)
        strat["djup: hybrid (6)"].append(d6[int(np.argmax(z))]["ok"])
        strat["orakel (6)"].append(any(p["ok"] for p in d6))
        # Kalibrering: förutsäger det valda svarets poäng / konsensus att det är rätt?
        best = int(np.argmax(c6))
        calib["poäng"][0].append(max(p["score"] for p in d6))
        calib["poäng"][1].append(max(d6, key=lambda p: p["score"])["ok"])
        calib["konsensus"][0].append(c6[best])
        calib["konsensus"][1].append(d6[best]["ok"])
    n = len(rows)
    out = {"antal": n, "traffsakerhet": {}, "kalibrering_auroc": {}}
    for k, v in strat.items():
        a = float(np.mean(v))
        se = math_se(a, n)
        out["traffsakerhet"][k] = [round(a, 3), round(se, 3)]
        print(f"{k:24s} {a:6.1%} ± {se:.1%}")
    for k, (s, y) in calib.items():
        out["kalibrering_auroc"][k] = round(auroc(s, y), 3)
        print(f"AUROC {k}: {auroc(s, y):.3f}")
    # Vet-inte-tröskel: om modellen svarar bara när konsensus är hög
    s, y = map(np.array, calib["konsensus"])
    for q in (0.0, 0.25, 0.5):
        thr = np.quantile(s, q)
        keep = s >= thr
        print(f"svarar på {keep.mean():.0%} (konsensus ≥ {thr:.2f}): rätt {y[keep].mean():.1%}")
        out.setdefault("vet_inte", []).append(dict(andel_besvarade=float(keep.mean()), traff=float(y[keep].mean())))
    json.dump(out, open(sys.argv[1].replace(".json", "_analys.json"), "w"), ensure_ascii=False, indent=1)


def math_se(p, n):
    return (p * (1 - p) / max(1, n)) ** 0.5


if __name__ == "__main__":
    main()
