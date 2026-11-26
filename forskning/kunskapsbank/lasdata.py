"""Läsförståelsedata från Wikipedia: lär Lennart att hitta svaret i en text i stället för att minnas det.

Varje exempel: 1–3 artikelinledningar (en relevant + vilseledande artiklar som sökmotorn tycker
liknar frågan) och en fråga som skapas automatiskt ur den relevanta artikelns första mening:
  framåt:  "Vad är Kebnekaise?"                  → "Kebnekaise är Sveriges högsta berg …"
  bakåt:   "Vad är Sveriges högsta berg?"        → samma mening
Svaret är meningen ur texten. Artiklar som rör frågebankens facit tas inte med (inget läckage).

Kör: python forskning/kunskapsbank/lasdata.py <index.pkl> <ut.jsonl> [antal]
"""
import json
import re
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tankeskalning"))
from sok import Index  # noqa: E402
from fragor import FRAGOR  # noqa: E402

PERSON = re.compile(r"\b(född|författare|politiker|skådespelare|musiker|konstnär|kung|drottning|regissör|sångare|"
                    r"fotbollsspelare|ishockeyspelare|präst|forskare|uppfinnare|kompositör|journalist|ämbetsman)\b")
BANNED_KEYS = {k for _, keys in FRAGOR for k in keys if len(k) >= 4 and not k.isdigit()}
PROMPT = "Läs texten och svara kort på frågan.\n\n{ctx}\n\nFråga: {q}"


def first_sentence(lead):
    lead = re.sub(r"\s*\([^)]{0,80}\)", "", lead.replace("\n", " "))  # bort med parenteser
    m = re.match(r"(.{20,220}?[a-zåäö0-9])\.(\s|$)", lead)
    return m.group(1).strip() + "." if m else None


def make(ix, rng, d):
    title, lead = ix.titles[d], ix.leads[d]
    if "  " in lead or re.search(r"är (en ort|ett släkte|en art|en sjö|ett berg|en ö|ett vattendrag|en kommun) i", lead[:200]):
        if rng.random() > 0.08:  # robotskrivna stubbar: bara några få
            return None
    s = first_sentence(lead)
    if not s or "(" in title or len(lead) < 250:
        return None
    low = s.lower()
    if any(re.search(r"(?<![\wåäö])" + re.escape(k) + r"(?![\wåäö])", low) for k in BANNED_KEYS):
        return None
    m = re.match(re.escape(title) + r"\s+(är|var)\s+(.+?)\.$", s)
    if not m:
        return None
    verb, rest = m.group(1), m.group(2)
    rest = re.split(r",| som | vilken | där ", rest)[0].strip()
    if not (4 <= len(rest.split()) <= 14):  # för korta omskrivningar ("en ort") blir tvetydiga
        return None
    who = "Vem" if PERSON.search(s) else "Vad"
    if rng.random() < 0.5:
        q = f"{who} {verb} {title}?"
    else:
        q = f"{who} {verb} {rest}?"
        q = q[0].upper() + q[1:]
    # vilseledande artiklar: det sökmotorn hittar för frågan (utom den rätta)
    others = [i for i, (t, _, _) in enumerate(ix.search(q, 4)) if t != title]
    hits = [h for h in ix.search(q, 4) if h[0] != title]
    n_other = int(rng.integers(0, 3))
    passages = [lead[:450]] + [h[1][:450] for h in hits[:n_other]]
    rng.shuffle(passages)
    return dict(user=PROMPT.format(ctx="\n\n".join(f"Text: {p}" for p in passages), q=q), assistant=s,
                titel=title, typ="framåt" if title in q else "bakåt")


def main():
    ix = Index(sys.argv[1])
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
    rng = np.random.default_rng(42)
    out, tried = [], 0
    for d in rng.permutation(ix.N):
        tried += 1
        ex = make(ix, rng, int(d))
        if ex:
            out.append(ex)
            if len(out) % 500 == 0:
                print(f"{len(out)} exempel (av {tried} försök)", flush=True)
        if len(out) >= n:
            break
    with open(sys.argv[2], "w") as f:
        for ex in out:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    for ex in out[:4]:
        print(json.dumps(ex, ensure_ascii=False)[:400])


if __name__ == "__main__":
    main()
