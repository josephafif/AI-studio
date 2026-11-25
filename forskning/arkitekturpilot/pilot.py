"""Arkitekturpilot för Lennart 4 – små modeller tränade på svensk Wikipedia på CPU.

Varianter (samma data, samma ordning, samma antal tokens, ungefär samma antal parametrar):
  A  "lennart3"  – som Lennart 3: inlärda positioner, LayerNorm, GELU-MLP (4d)
  B  "modern"    – RoPE, RMSNorm, SwiGLU (8/3·d), QK-normering
  C  "modern+skiss" – som B, plus en extra förlust på mittlagret (genom samma utmatning), så att
                  modellens första halva lär sig gissa nästa token själv. Då kan första halvan skissa
                  förslag som hela modellen kontrollerar (självekodning) – snabbare svar utan extra modell.

Mäts: valideringsförlust (och bits per byte) under träningen, samt för C hur ofta mittlagrets gissning
stämmer med slutlagrets (= hur bra skisserna blir).

Kör: python forskning/arkitekturpilot/pilot.py <variant> <tokenizer.json> <svwiki.parquet> <ut.json> [steg]
"""
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import torch
import torch.nn as nn
import torch.nn.functional as F
from tokenizers import Tokenizer

torch.set_num_threads(4)
D, LAYERS, HEADS, CTX, BATCH = 256, 6, 4, 256, 16
LR, WARMUP = 2e-3, 100


def data(tokp, parquet, cache):
    if Path(cache).exists():
        z = np.load(cache)
        return z["train"], z["val"], float(z["bpt"])
    tok = Tokenizer.from_file(tokp)
    texts = pq.read_table(parquet, columns=["text"]).column("text").to_pylist()
    rng = np.random.default_rng(0)
    order = rng.permutation(len(texts))
    eos = tok.token_to_id("<|endoftext|>")
    ids, chars, toks = [], 0, 0
    val_n = 400
    val_ids, val_chars = [], 0
    k = 0
    for c in range(0, len(order), 2000):
        chunk = [texts[i] for i in order[c:c + 2000]]
        for t, enc in zip(chunk, tok.encode_batch(chunk)):
            e = enc.ids + [eos]
            if k < val_n:
                val_ids += e
                val_chars += len(t.encode("utf-8"))
            else:
                ids += e
            k += 1
        if len(ids) > 16_000_000:
            break
    bpt = val_chars / len(val_ids)  # byte per token i valideringen → bits per byte
    train, val = np.array(ids, np.int32), np.array(val_ids, np.int32)
    np.savez(cache, train=train, val=val, bpt=bpt)
    return train, val, bpt


class RMSNorm(nn.Module):
    def __init__(self, d):
        super().__init__()
        self.w = nn.Parameter(torch.ones(d))

    def forward(self, x):
        return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + 1e-6) * self.w


def rope(x, cos, sin):
    x1, x2 = x[..., ::2], x[..., 1::2]
    return torch.stack([x1 * cos - x2 * sin, x1 * sin + x2 * cos], -1).flatten(-2)


class Block(nn.Module):
    def __init__(self, modern):
        super().__init__()
        self.modern = modern
        Norm = RMSNorm if modern else nn.LayerNorm
        self.n1, self.n2 = Norm(D), Norm(D)
        self.qkv = nn.Linear(D, 3 * D, bias=False)
        self.proj = nn.Linear(D, D, bias=False)
        if modern:
            h = int(8 * D / 3 / 16) * 16
            self.gate, self.up, self.down = (nn.Linear(D, h, bias=False), nn.Linear(D, h, bias=False),
                                             nn.Linear(h, D, bias=False))
            self.qn, self.kn = RMSNorm(D // HEADS), RMSNorm(D // HEADS)
        else:
            self.fc, self.out = nn.Linear(D, 4 * D, bias=False), nn.Linear(4 * D, D, bias=False)

    def forward(self, x, cos, sin):
        b, t, c = x.shape
        q, k, v = self.qkv(self.n1(x)).view(b, t, 3, HEADS, c // HEADS).permute(2, 0, 3, 1, 4)
        if self.modern:
            q, k = rope(self.qn(q), cos, sin), rope(self.kn(k), cos, sin)
        y = F.scaled_dot_product_attention(q, k, v, is_causal=True)
        x = x + self.proj(y.transpose(1, 2).reshape(b, t, c))
        h = self.n2(x)
        if self.modern:
            return x + self.down(F.silu(self.gate(h)) * self.up(h))
        return x + self.out(F.gelu(self.fc(h), approximate="tanh"))


class Model(nn.Module):
    def __init__(self, vocab, modern):
        super().__init__()
        self.modern = modern
        self.wte = nn.Embedding(vocab, D)
        if not modern:
            self.wpe = nn.Embedding(CTX, D)
        self.blocks = nn.ModuleList(Block(modern) for _ in range(LAYERS))
        self.nf = RMSNorm(D) if modern else nn.LayerNorm(D)
        for n_, p in self.named_parameters():
            if p.dim() == 2:
                std = 0.02 / math.sqrt(2 * LAYERS) if n_.endswith(("proj.weight", "out.weight", "down.weight")) else 0.02
                nn.init.normal_(p, 0, std)
        hd = D // HEADS
        f = 1.0 / (10000 ** (torch.arange(0, hd, 2) / hd))
        ang = torch.outer(torch.arange(CTX).float(), f)
        self.register_buffer("cos", ang.cos(), persistent=False)
        self.register_buffer("sin", ang.sin(), persistent=False)

    def forward(self, idx, mid=None):
        t = idx.shape[1]
        x = self.wte(idx)
        if not self.modern:
            x = x + self.wpe(torch.arange(t))
        cos, sin = self.cos[:t], self.sin[:t]
        hm = None
        for i, blk in enumerate(self.blocks):
            x = blk(x, cos, sin)
            if mid is not None and i == mid - 1:
                hm = x
        out = F.linear(self.nf(x), self.wte.weight)
        return out, (F.linear(self.nf(hm), self.wte.weight) if hm is not None else None)


def main():
    variant, tokp, parquet, outp = sys.argv[1:5]
    steps = int(sys.argv[5]) if len(sys.argv) > 5 else 2000
    here = Path(outp).parent
    train, val, bpt = data(tokp, parquet, here / "data_cache.npz")
    tok = Tokenizer.from_file(tokp)
    torch.manual_seed(0)
    modern = variant != "lennart3"
    skiss = variant == "modern+skiss"
    MID = LAYERS // 2
    m = Model(tok.get_vocab_size(), modern)
    n_params = sum(p.numel() for p in m.parameters())
    n_body = n_params - m.wte.weight.numel()
    opt = torch.optim.AdamW(m.parameters(), lr=LR, betas=(0.9, 0.95), weight_decay=0.1)
    rng = np.random.default_rng(1)
    vrng = np.random.default_rng(2)
    vstarts = vrng.integers(0, len(val) - CTX - 1, 48)
    log = dict(variant=variant, params=n_params, params_utan_inbaddning=n_body, steg=[], bpt=bpt)
    print(f"{variant}: {n_params / 1e6:.1f} M parametrar ({n_body / 1e6:.2f} M utan inbäddning), "
          f"{len(train) / 1e6:.1f} M tränings-tokens", flush=True)

    @torch.no_grad()
    def evaluate():
        m.eval()
        losses, agree = [], []
        for i in range(0, len(vstarts), 16):
            xs = torch.from_numpy(np.stack([val[s:s + CTX] for s in vstarts[i:i + 16]]).astype(np.int64))
            ys = torch.from_numpy(np.stack([val[s + 1:s + CTX + 1] for s in vstarts[i:i + 16]]).astype(np.int64))
            lo, lm_ = m(xs, MID)
            losses.append(F.cross_entropy(lo.view(-1, lo.size(-1)), ys.view(-1)).item())
            agree.append((lm_.argmax(-1) == lo.argmax(-1)).float().mean().item())
        m.train()
        return float(np.mean(losses)), float(np.mean(agree))

    t0 = time.time()
    for step in range(1, steps + 1):
        lr = LR * min(1, step / WARMUP) * (0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * min(1, step / steps))))
        for g in opt.param_groups:
            g["lr"] = lr
        s = rng.integers(0, len(train) - CTX - 1, BATCH)
        x = torch.from_numpy(np.stack([train[i:i + CTX] for i in s]).astype(np.int64))
        y = torch.from_numpy(np.stack([train[i + 1:i + CTX + 1] for i in s]).astype(np.int64))
        lo, lm_ = m(x, MID if skiss else None)
        loss = F.cross_entropy(lo.view(-1, lo.size(-1)), y.view(-1))
        total = loss
        if skiss:
            total = loss + 0.3 * F.cross_entropy(lm_.view(-1, lm_.size(-1)), y.view(-1))
        opt.zero_grad(set_to_none=True)
        total.backward()
        torch.nn.utils.clip_grad_norm_(m.parameters(), 1.0)
        opt.step()
        if step % 250 == 0 or step == steps:
            vl, ag = evaluate()
            el = time.time() - t0
            row = dict(steg=step, tokens=step * BATCH * CTX, val_loss=vl, bits_per_byte=vl / math.log(2) / bpt,
                       mittlager_samstammighet=ag, sekunder=el, tokens_per_s=step * BATCH * CTX / el)
            log["steg"].append(row)
            print(f"steg {step} · tränings-loss {loss.item():.3f} · val {vl:.3f} ({row['bits_per_byte']:.3f} bpb) · "
                  f"mittlager={ag:.1%} · {row['tokens_per_s']:.0f} tok/s", flush=True)
            json.dump(log, open(outp, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
