"""Kontrollerar att ekodekodningen inte ändrar fördelningen över svar.

En leksaksmodell (bigram-logits med slumpade vikter, 10 tokens) ersätter Lennart. Samma utkast samplas
120 000 gånger med och utan ekodekodning (med förslag från ett tidigare "utkast" och frågan), och
fördelningarna över hela svaren jämförs. Skillnaden ska vara i nivå med slumpbruset.

Kör: python forskning/ekodekodning/test_exakthet.py
"""
from collections import Counter

import numpy as np

from ekodekodning import write_draft

V, END = 6, 5


class ToyEngine:
    def __init__(self, seed=0):
        r = np.random.default_rng(seed)
        self.W = r.normal(0, 1.6, (V, V)).astype(np.float32)  # logits för nästa token givet förra
        self.ctx, self.seq, self.passes = 64, [], 0

    @property
    def pos(self):
        return len(self.seq)

    def reset(self):
        self.seq = []

    def rewind(self, p):
        assert p <= len(self.seq)
        self.seq = self.seq[:p]

    def eval(self, toks):
        self.seq += list(toks)
        self.passes += 1
        return self.W[self.seq[-1]].copy()

    def eval_all(self, toks):
        self.seq += list(toks)
        self.passes += 1
        return np.stack([self.W[t] for t in toks]).copy()


def sample(recycle, n, seed):
    eng = ToyEngine()
    rng = np.random.default_rng(seed)
    prompt = [3, 1, 4, 1, 2]
    old = list(prompt)  # ett tidigare utkast som förslagskälla: modellens mest sannolika fortsättning
    for _ in range(6):
        old.append(int(np.argmax(eng.W[old[-1]][:END])))
    out = Counter()
    for _ in range(n):
        eng.reset()
        p0 = eng.eval(prompt)
        d, _ = write_draft(eng, rng, prompt, p0, 4, 0.8, 5, [0], END, [prompt, old], None, recycle, k=4)
        out[tuple(d.toks) + (("slut",) if d.ended else ())] += 1
    return out, eng.passes


def main():
    n = 120_000
    a, pa = sample(False, n, 1)
    b, pb = sample(True, n, 2)
    c, _ = sample(False, n, 3)  # en andra vanlig körning: hur stort är slumpbruset?
    keys = set(a) | set(b) | set(c)
    tv = 0.5 * sum(abs(a[k] - b[k]) for k in keys) / n
    noise = 0.5 * sum(abs(a[k] - c[k]) for k in keys) / n
    print(f"olika svar: {len(keys)}")
    print(f"total variation vanlig ↔ eko:    {tv:.4f}")
    print(f"total variation vanlig ↔ vanlig: {noise:.4f}  (slumpbrus)")
    print(f"pass: vanlig {pa}, eko {pb}")
    assert tv < 1.5 * noise + 0.005, "fördelningarna skiljer sig mer än slumpen förklarar"
    print("OK – ekodekodningen ger samma fördelning")


if __name__ == "__main__":
    main()
