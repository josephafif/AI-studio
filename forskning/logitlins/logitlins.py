"""Logitlins: när "bestämmer sig" Lennart? Och kan tidiga lager skissa åt hela modellen?

Efter varje lager l läses modellens mellanläge av genom slutnormaliseringen och utmatningen
(logits_l = ln_f(x_l) · wteᵀ). Vi mäter:

  * samstämmighet: hur ofta lager l:s toppgissning redan är densamma som slutlagrets
  * träff: hur ofta lager l:s toppgissning är rätt nästa token
  * p_slut(gissning_l): sannolikheten som hela modellen ger lager l:s gissning – det är exakt
    sannolikheten att ett förslag från lager l godtas med ekodekodningens kontroll (vid T=1)

Dessutom testas en "lagerbrygga": en linjär avbildning (ridge-regression, sluten form) från lager l:s
tillstånd till slutlagrets, tränad på hälften av texterna och utvärderad på andra hälften.

Kör: python forskning/logitlins/logitlins.py <lennart3.pt> <tokenizer.json> <svwiki.parquet> <ut.json>
"""
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import torch
import torch.nn.functional as F
from tokenizers import Tokenizer

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "moln" / "lennart3"))
import lennart3_train as L3  # noqa: E402

torch.set_num_threads(4)
SEQ = 256


def load(path):
    ck = torch.load(path, map_location="cpu", weights_only=False)
    cfg = ck["config"]
    m = L3.GPT(cfg)
    m.load_state_dict({k: v.float() for k, v in ck["model"].items()})
    return m.eval(), cfg


@torch.no_grad()
def hidden_states(m, idx):
    """Tillstånd efter inbäddning och efter varje lager: lista med (1, T, d)."""
    t = idx.shape[1]
    x = m.wte(idx) + m.wpe(torch.arange(t))
    hs = [x]
    for blk in m.blocks:
        x = blk(x)
        hs.append(x)
    return hs


def texts(tok, parquet, n, seed=0):
    t = pq.read_table(parquet, columns=["text"]).column("text").to_pylist()
    rng = np.random.default_rng(seed)
    out = []
    for i in rng.permutation(len(t)):
        ids = tok.encode(t[i]).ids
        if len(ids) >= SEQ + 1:
            out.append(ids[: SEQ + 1])
        if len(out) >= n:
            break
    return out


@torch.no_grad()
def main():
    ckpt, tokp, parquet, outp = sys.argv[1:5]
    tok = Tokenizer.from_file(tokp)
    m, cfg = load(ckpt)
    nl = cfg["n_layer"]
    seqs = texts(tok, parquet, 48)
    train, test = seqs[:24], seqs[24:]
    t0 = time.time()

    def collect(group):
        H = [[] for _ in range(nl + 1)]
        Y = []
        for s in group:
            idx = torch.tensor([s[:-1]])
            hs = hidden_states(m, idx)
            for l in range(nl + 1):
                H[l].append(hs[l][0])
            Y.append(torch.tensor(s[1:]))
        return [torch.cat(h) for h in H], torch.cat(Y)

    Htr, _ = collect(train)
    Hte, Yte = collect(test)
    print(f"tillstånd insamlade på {time.time() - t0:.0f}s: {Htr[0].shape[0]} + {Hte[0].shape[0]} tokens", flush=True)

    W = m.wte.weight

    def logits(h):
        return F.linear(m.ln_f(h), W)

    final = logits(Hte[nl])
    pf = final.softmax(-1)
    top_final = final.argmax(-1)
    res = {"lager": [], "brygga": []}
    # Lagerbrygga: X·A ≈ slutlagrets tillstånd (ridge, sluten form), tränad på andra texter.
    for l in range(nl + 1):
        lg = logits(Hte[l])
        g = lg.argmax(-1)
        agree = (g == top_final).float().mean().item()
        acc = (g == Yte).float().mean().item()
        p_acc = pf.gather(1, g[:, None]).mean().item()
        kl = F.kl_div(lg.log_softmax(-1), pf, reduction="batchmean").item()
        row = dict(lager=l, samstammighet=agree, traff=acc, godtas=p_acc, kl=kl)
        if 0 < l < nl:
            X = torch.cat([Htr[l], torch.ones(Htr[l].shape[0], 1)], 1)
            Ytr = Htr[nl]
            lam = 1e-2 * X.shape[0]
            A = torch.linalg.solve(X.T @ X + lam * torch.eye(X.shape[1]), X.T @ Ytr)
            Xb = torch.cat([Hte[l], torch.ones(Hte[l].shape[0], 1)], 1)
            lgb = logits(Xb @ A)
            gb = lgb.argmax(-1)
            row.update(brygga_samstammighet=(gb == top_final).float().mean().item(),
                       brygga_traff=(gb == Yte).float().mean().item(),
                       brygga_godtas=pf.gather(1, gb[:, None]).mean().item(),
                       brygga_kl=F.kl_div(lgb.log_softmax(-1), pf, reduction="batchmean").item())
        res["lager"].append(row)
        print(" ".join(f"{k}={v:.3f}" if isinstance(v, float) else f"{k}={v}" for k, v in row.items()), flush=True)
    res["slutlager_traff"] = (top_final == Yte).float().mean().item()
    res["tokens_test"] = int(Yte.shape[0])
    json.dump(res, open(outp, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
