"""En liten sökmotor (BM25) över svenska Wikipedia – Lennarts uppslagsverk.

Indexerar titel + inledning (första ~700 tecknen) för artiklar som inte är stubbar.
Bygger på en kärna och numpy, ingen extern sökmotor behövs.

    python forskning/kunskapsbank/sok.py bygg <svwiki-mapp> <index.npz>
    python forskning/kunskapsbank/sok.py fråga <index.npz> "Vilket är Sveriges högsta berg?"
"""
import glob
import pickle
import re
import sys
import time

import numpy as np
import pyarrow.parquet as pq

STOP = set("""och i att det som en på är av för med till den har de inte om ett han men var jag sig från vi så
kan man när år hon under även eller efter vid nu också vara blir blev skulle då där vad vilket vilken vilka hur
många mycket heter kallas står vem varför ska mitt min din ditt sitt sin dess deras detta denna dessa här
ut upp in ner över mellan mot utan genom alla allt andra annan annat bara bland både än sedan samt
""".split())
WORD = re.compile(r"[a-zåäöéüæø0-9]+")
K1, B = 1.2, 0.75


SUFFIX = ("arnas", "ernas", "ornas", "arna", "erna", "orna", "ande", "ende", "heten", "het", "aste", "are", "ens",
          "ets", "en", "et", "na", "er", "ar", "or", "s")


def stem(w):
    """Enkel svensk ordstam: huvudstaden → huvudstad, Sveriges → sverige."""
    for suf in SUFFIX:
        if w.endswith(suf) and len(w) - len(suf) >= 4:
            return w[: -len(suf)]
    return w


def words(text):
    return [stem(w) for w in WORD.findall(text.lower()) if w not in STOP and len(w) > 1]


def build(folder, out):
    t0 = time.time()
    titles, leads = [], []
    for f in sorted(glob.glob(f"{folder}/sv*.parquet")):
        t = pq.read_table(f, columns=["title", "text"])
        for title, text in zip(t.column("title").to_pylist(), t.column("text").to_pylist()):
            if len(text) < 600:
                continue
            titles.append(title)
            leads.append(text[:700])
    print(f"{len(titles):,} artiklar ({time.time() - t0:.0f}s)", flush=True)
    vocab, postings_doc, postings_tf, dl = {}, [], [], np.zeros(len(titles), np.float32)
    for d, (title, lead) in enumerate(zip(titles, leads)):
        ws = words(title + " " + title + " " + lead)  # titeln räknas dubbelt
        dl[d] = len(ws)
        counts = {}
        for w in ws:
            counts[w] = counts.get(w, 0) + 1
        for w, c in counts.items():
            i = vocab.get(w)
            if i is None:
                i = vocab[w] = len(postings_doc)
                postings_doc.append([])
                postings_tf.append([])
            postings_doc[i].append(d)
            postings_tf[i].append(c)
        if d % 200_000 == 0:
            print(f"  {d:,} ({time.time() - t0:.0f}s)", flush=True)
    offsets = np.zeros(len(postings_doc) + 1, np.int64)
    offsets[1:] = np.cumsum([len(p) for p in postings_doc])
    docs = np.fromiter((d for p in postings_doc for d in p), np.int32, offsets[-1])
    tfs = np.fromiter((c for p in postings_tf for c in p), np.float32, offsets[-1])
    with open(out, "wb") as fh:
        pickle.dump(dict(vocab=vocab, offsets=offsets, docs=docs, tfs=tfs, dl=dl, titles=titles, leads=leads), fh,
                    protocol=5)
    print(f"klart: {len(vocab):,} ord, {offsets[-1]:,} poster ({time.time() - t0:.0f}s)", flush=True)


class Index:
    def __init__(self, path):
        with open(path, "rb") as fh:
            self.__dict__.update(pickle.load(fh))
        self.N = len(self.titles)
        self.avgdl = float(self.dl.mean())

    def search(self, query, k=3):
        scores = np.zeros(self.N, np.float32)
        for w in set(words(query)):
            i = self.vocab.get(w)
            if i is None:
                continue
            a, b = self.offsets[i], self.offsets[i + 1]
            docs, tf = self.docs[a:b], self.tfs[a:b]
            idf = np.log(1 + (self.N - len(docs) + 0.5) / (len(docs) + 0.5))
            scores[docs] += idf * tf * (K1 + 1) / (tf + K1 * (1 - B + B * self.dl[docs] / self.avgdl))
        top = np.argpartition(-scores, k)[:k]
        top = top[np.argsort(-scores[top])]
        return [(self.titles[d], self.leads[d], float(scores[d])) for d in top]


if __name__ == "__main__":
    if sys.argv[1] == "bygg":
        build(sys.argv[2], sys.argv[3])
    else:
        ix = Index(sys.argv[2])
        for t, lead, s in ix.search(sys.argv[3]):
            print(f"[{s:.1f}] {t}: {lead[:200]!r}")
