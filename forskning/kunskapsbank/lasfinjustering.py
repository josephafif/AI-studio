"""Lär Lennart 3.4 att läsa: finjustering på läsförståelsedata (lasdata.py) på CPU.

Bara de översta lagren tränas (resten frysta) och förlusten räknas bara på svaret, så att det går att
köra på en vanlig processor. Lennarts egna samtal blandas in så att han inte glömmer att prata.

Kör: python forskning/kunskapsbank/lasfinjustering.py <lennart3.pt> <tokenizer.json> <lasdata.jsonl> <utmapp>
Miljö: FT_STEPS (300), FT_BATCH (8), FT_LAYERS (8 översta lagren), FT_LR (3e-5), FT_THREADS (4)
"""
import json
import os
import random
import shutil
import sys
import time
from pathlib import Path

import torch
import torch.nn.functional as F
from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "moln" / "lennart3"))
import lennart3_train as L3  # noqa: E402

STEPS = int(os.environ.get("FT_STEPS", 300))
BATCH = int(os.environ.get("FT_BATCH", 8))
LAYERS = int(os.environ.get("FT_LAYERS", 8))
LR = float(os.environ.get("FT_LR", 3e-5))
torch.set_num_threads(int(os.environ.get("FT_THREADS", 4)))
MAXLEN = 448


def main():
    ckpt, tokp, datap, outdir = sys.argv[1:5]
    tok = Tokenizer.from_file(tokp)
    sp = {s: tok.token_to_id(s) for s in ("<|user|>", "<|assistant|>", "<|end|>")}
    ck = torch.load(ckpt, map_location="cpu", weights_only=False)
    cfg = ck["config"]
    m = L3.GPT(cfg)
    m.load_state_dict({k: v.float() for k, v in ck["model"].items()})
    for p in m.parameters():
        p.requires_grad = False
    train_params = []
    for blk in m.blocks[-LAYERS:]:
        for p in blk.parameters():
            p.requires_grad = True
            train_params.append(p)
    for p in m.ln_f.parameters():
        p.requires_grad = True
        train_params.append(p)
    opt = torch.optim.AdamW(train_params, lr=LR, betas=(0.9, 0.95), weight_decay=0.0)

    data = [json.loads(l) for l in open(datap)]
    chats = [json.loads(l) for l in open(ROOT / "moln" / "lennart3" / "lennart3_samtal.jsonl")]
    examples = []
    for e in data:
        examples.append(([sp["<|user|>"]] + tok.encode(e["user"]).ids, tok.encode(e["assistant"]).ids))
    for c in chats:  # {"fråga": …, "svar": …}
        for _ in range(3):
            examples.append(([sp["<|user|>"]] + tok.encode(c["fråga"]).ids, tok.encode(c["svar"]).ids))
    random.Random(0).shuffle(examples)
    print(f"{len(examples)} exempel, tränar {LAYERS} av {cfg['n_layer']} lager, {STEPS} steg × {BATCH}", flush=True)

    m.train()
    t0, k = time.time(), 0
    for step in range(1, STEPS + 1):
        lr = LR * min(1.0, step / 20)
        for g in opt.param_groups:
            g["lr"] = lr
        batch = [examples[(k + i) % len(examples)] for i in range(BATCH)]
        k += BATCH
        seqs, masks = [], []
        for u, a in batch:
            ids = (u + [sp["<|assistant|>"]])[-(MAXLEN - len(a) - 1):] + a + [sp["<|end|>"]]
            ids = ids[:MAXLEN + 1]
            n_ans = len(a) + 1
            seqs.append(ids)
            masks.append(n_ans)
        T = max(len(s) for s in seqs) - 1
        x = torch.zeros(len(seqs), T, dtype=torch.long)
        y = torch.full((len(seqs), T), -100, dtype=torch.long)
        for i, (s, na) in enumerate(zip(seqs, masks)):
            L = len(s) - 1
            x[i, :L] = torch.tensor(s[:-1])
            tgt = torch.tensor(s[1:])
            y[i, L - na:L] = tgt[L - na:L]
        # framåt utan att räkna logits för alla positioner: bara där svaret ska förutsägas
        t = x.shape[1]
        h = m.wte(x) + m.wpe(torch.arange(t))
        with torch.no_grad():
            for blk in m.blocks[:-LAYERS]:
                h = blk(h)
        h = h.detach()
        for blk in m.blocks[-LAYERS:]:
            h = blk(h)
        sel = y != -100
        logits = F.linear(m.ln_f(h[sel]), m.wte.weight)
        loss = F.cross_entropy(logits, y[sel])
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(train_params, 1.0)
        opt.step()
        if step % 10 == 0:
            el = time.time() - t0
            print(f"steg {step}/{STEPS} · loss {loss.item():.3f} · {el / step:.1f} s/steg · ~{(STEPS - step) * el / step / 60:.0f} min kvar",
                  flush=True)
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    cfg = dict(cfg, name="Lennart 3.4 läsare")
    torch.save({"model": {k_: v.half() for k_, v in m.state_dict().items()}, "config": cfg}, out / "lennart3.pt")
    shutil.copy(tokp, out / "tokenizer.json")
    st = json.load(open(Path(ckpt).parent / "status.json"))
    st["lasfinjustering"] = dict(steg=STEPS, batch=BATCH, lager=LAYERS, lr=LR)
    json.dump(st, open(out / "status.json", "w"), ensure_ascii=False, indent=1)
    print("sparad", out, flush=True)


if __name__ == "__main__":
    main()
