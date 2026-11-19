"""Tränar Lennart 3 (GPT, ca 300 M parametrar) på flera GPU:er med DistributedDataParallel.

Startas med torchrun, en process per GPU:
    torchrun --standalone --nproc_per_node 2 lennart3_train.py

Data kommer från lennart3_data.py (web.bin, chat.bin, tokenizer.json …).

Schema – "warmup, stable, decay" (WSD):
  * Uppvärmning de första stegen, sedan konstant inlärningstakt.
  * Under sista delen av körningens tid sänks inlärningstakten och andelen samtalsdata ökar,
    så att den sparade modellen både skriver bra svenska och svarar som en assistent.
  * Innan sänkningen sparas resume_checkpoint.pt. Nästa körning fortsätter därifrån med full takt,
    så varje körning ger en färdig modell och samtidigt kan träningen fortsätta i flera omgångar.

Miljövariabler (standardvärden inom parentes):
    L3_DATA      mapp med web.bin m.m. (letas upp under /kaggle/input)
    L3_OUT       utmapp (/kaggle/working/lennart3)
    L3_RESUME    checkpoint att fortsätta från (letas upp under /kaggle/input)
    L3_PARAMS    önskat antal parametrar (300 000 000); antalet lager väljs för att hamna närmast
    L3_EMBD      bredd (1024)   L3_HEADS  attention heads (16)   L3_CONTEXT  kontextlängd (512)
    L3_MICRO     sekvenser per GPU och mikrosteg (8)   L3_ACCUM  mikrosteg per optimeringssteg (8)
    L3_LR        högsta inlärningstakt (3e-4)          L3_WARMUP uppvärmningssteg (500)
    L3_HOURS     tidsbudget i timmar räknat från L3_START (11.0)
    L3_DECAY     andel av tiden som används till sänkningen (0.12)
    L3_CHAT      andel samtalsdata under stabil fas (0.06) → L3_CHAT_END i slutet (0.45)
"""
from __future__ import annotations

import glob
import json
import math
import os
import time
from contextlib import nullcontext
from datetime import timedelta
from pathlib import Path

import numpy as np
import torch
import torch.distributed as dist
import torch.nn as nn
import torch.nn.functional as F
from torch.nn.parallel import DistributedDataParallel as DDP


def env(key, default, cast=str):
    v = os.environ.get(key)
    return cast(v) if v not in (None, "") else default


START = env("L3_START", time.time(), float)
HOURS = env("L3_HOURS", 11.0, float)
DECAY_FRAC = env("L3_DECAY", 0.12, float)
TARGET_PARAMS = env("L3_PARAMS", 300_000_000, int)
N_EMBD = env("L3_EMBD", 1024, int)
N_HEAD = env("L3_HEADS", 16, int)
BLOCK = env("L3_CONTEXT", 512, int)
MICRO = env("L3_MICRO", 8, int)
ACCUM = env("L3_ACCUM", 8, int)
MAX_LR = env("L3_LR", 3e-4, float)
MIN_LR_FRAC = 0.1
WARMUP = env("L3_WARMUP", 500, int)
CHAT_P = env("L3_CHAT", 0.06, float)
CHAT_P_END = env("L3_CHAT_END", 0.45, float)
EVAL_EVERY = env("L3_EVAL_EVERY", 250, int)
LOG_EVERY = env("L3_LOG_EVERY", 25, int)
CKPT_MINUTES = env("L3_CKPT_MIN", 40.0, float)
SAFETY_S = env("L3_SAFETY_S", 900.0, float)  # tid kvar för slutsparning och provsvar
SEED = 2026

TEST_PROMPTS = [
    "Hej! Vem är du?", "Hur mår du?", "Vad är nätfiske?", "Hur skapar jag ett starkt lösenord?",
    "Vad är huvudstaden i Norge?", "Varför är himlen blå?", "Ge mig tips för att sova bättre.",
    "Någon har hackat mitt konto, vad gör jag?", "Berätta om Astrid Lindgren.", "Vad är en brandvägg?",
]


# ───────────────────────────────────────────────────────── modell
def count_params(vocab: int, d: int, layers: int, block: int) -> int:
    per_layer = 12 * d * d + 4 * d  # qkv + proj + mlp (inga bias) + två LayerNorm
    return vocab * d + block * d + layers * per_layer + 2 * d


def choose_layers(vocab: int) -> int:
    return min(range(1, 97), key=lambda n: abs(count_params(vocab, N_EMBD, n, BLOCK) - TARGET_PARAMS))


class Block(nn.Module):
    def __init__(self, d, heads):
        super().__init__()
        self.heads = heads
        self.ln1 = nn.LayerNorm(d)
        self.qkv = nn.Linear(d, 3 * d, bias=False)
        self.proj = nn.Linear(d, d, bias=False)
        self.ln2 = nn.LayerNorm(d)
        self.fc = nn.Linear(d, 4 * d, bias=False)
        self.out = nn.Linear(4 * d, d, bias=False)

    def forward(self, x):
        b, t, c = x.shape
        q, k, v = self.qkv(self.ln1(x)).view(b, t, 3, self.heads, c // self.heads).permute(2, 0, 3, 1, 4)
        y = F.scaled_dot_product_attention(q, k, v, is_causal=True)
        x = x + self.proj(y.transpose(1, 2).reshape(b, t, c))
        return x + self.out(F.gelu(self.fc(self.ln2(x)), approximate="tanh"))


class GPT(nn.Module):
    def __init__(self, cfg):
        super().__init__()
        self.cfg = cfg
        d = cfg["n_embd"]
        self.wte = nn.Embedding(cfg["vocab_size"], d)
        self.wpe = nn.Embedding(cfg["block_size"], d)
        self.blocks = nn.ModuleList(Block(d, cfg["n_head"]) for _ in range(cfg["n_layer"]))
        self.ln_f = nn.LayerNorm(d)
        self.apply(self._init)
        for name, p in self.named_parameters():
            if name.endswith(("proj.weight", "out.weight")):
                nn.init.normal_(p, 0.0, 0.02 / math.sqrt(2 * cfg["n_layer"]))

    @staticmethod
    def _init(m):
        if isinstance(m, (nn.Linear, nn.Embedding)):
            nn.init.normal_(m.weight, 0.0, 0.02)

    def forward(self, idx, targets=None):
        t = idx.shape[1]
        x = self.wte(idx) + self.wpe(torch.arange(t, device=idx.device))
        for blk in self.blocks:
            x = blk(x)
        logits = F.linear(self.ln_f(x), self.wte.weight)  # delade vikter med inbäddningen
        if targets is None:
            return logits, None
        return logits, F.cross_entropy(logits.float().view(-1, logits.size(-1)), targets.view(-1))


# ───────────────────────────────────────────────────────── hjälp
def find_one(pattern: str) -> str | None:
    hits = sorted(glob.glob(pattern, recursive=True), key=os.path.getmtime, reverse=True)
    return hits[0] if hits else None


class Data:
    def __init__(self, folder: Path, seed: int):
        self.arr = {k: np.memmap(folder / f"{k}.bin", dtype=np.uint16, mode="r")
                    for k in ("web", "web_val", "chat", "chat_val")}
        self.rng = np.random.default_rng(seed)

    def batch(self, p_chat: float, val: bool, device):
        xs, ys = [], []
        for _ in range(MICRO):
            src = "chat" if self.rng.random() < p_chat else "web"
            arr = self.arr[src + ("_val" if val else "")]
            i = int(self.rng.integers(0, len(arr) - BLOCK - 1))
            chunk = np.asarray(arr[i:i + BLOCK + 1], dtype=np.int64)
            xs.append(chunk[:-1])
            ys.append(chunk[1:])
        x = torch.from_numpy(np.stack(xs)).pin_memory() if device.type == "cuda" else torch.from_numpy(np.stack(xs))
        y = torch.from_numpy(np.stack(ys)).pin_memory() if device.type == "cuda" else torch.from_numpy(np.stack(ys))
        return x.to(device, non_blocking=True), y.to(device, non_blocking=True)


@torch.no_grad()
def generate(model, tok, prompt_ids, device, max_new=120, temperature=0.7, top_k=40, stop_ids=()):
    model.eval()
    ids = list(prompt_ids)
    for _ in range(max_new):
        x = torch.tensor([ids[-BLOCK:]], device=device)
        with autocast(device):
            logits, _ = model(x)
        logits = logits[0, -1].float() / temperature
        kth = torch.topk(logits, top_k).values[-1]
        logits[logits < kth] = -float("inf")
        nxt = int(torch.multinomial(torch.softmax(logits, -1), 1))
        if nxt in stop_ids:
            break
        ids.append(nxt)
    model.train()
    return ids[len(prompt_ids):]


def autocast(device):
    return torch.autocast("cuda", dtype=torch.float16) if device.type == "cuda" else nullcontext()


def save_atomic(obj, path: Path):
    tmp = path.with_suffix(path.suffix + ".tmp")
    torch.save(obj, tmp)
    os.replace(tmp, path)


# ───────────────────────────────────────────────────────── träning
def main():
    ddp = "RANK" in os.environ
    if ddp:
        backend = "nccl" if torch.cuda.is_available() else "gloo"
        local = int(os.environ["LOCAL_RANK"])
        kw = {"device_id": torch.device(f"cuda:{local}")} if torch.cuda.is_available() else {}
        # Längre väntetid än standard (10 min): att spara en checkpoint på ca 3,6 GB kan ta en stund.
        dist.init_process_group(backend, timeout=timedelta(minutes=45), **kw)
        rank, world = dist.get_rank(), dist.get_world_size()
    else:
        rank, world, local = 0, 1, 0
    device = torch.device(f"cuda:{local}" if torch.cuda.is_available() else "cpu")
    if device.type == "cuda":
        torch.cuda.set_device(device)
    master = rank == 0

    def log(*a):
        if master:
            print(time.strftime("[%H:%M:%S]"), *a, flush=True)

    data_dir = Path(env("L3_DATA", "") or os.path.dirname(find_one("/kaggle/input/**/web.bin") or "."))
    out = Path(env("L3_OUT", "/kaggle/working/lennart3"))
    if master:
        out.mkdir(parents=True, exist_ok=True)
    meta = json.loads((data_dir / "meta.json").read_text(encoding="utf-8"))
    vocab = meta["vocab_size"]
    sp = meta["special_tokens"]
    n_layer = choose_layers(vocab)
    cfg = {"name": "Lennart 3", "architecture": "gpt", "vocab_size": vocab, "block_size": BLOCK, "n_embd": N_EMBD,
           "n_head": N_HEAD, "n_layer": n_layer, "special_tokens": sp,
           "chat_format": "<|user|>fråga<|assistant|>svar<|end|>"}

    torch.manual_seed(SEED)
    model = GPT(cfg).to(device)
    n_params = sum(p.numel() for p in model.parameters())
    cfg["parameters"] = n_params
    log(f"Lennart 3: {n_params:,} parametrar ({n_layer} lager, bredd {N_EMBD}, {N_HEAD} heads, kontext {BLOCK})")
    if device.type == "cuda":
        log("GPU:er:", ", ".join(torch.cuda.get_device_name(i) for i in range(torch.cuda.device_count())),
            f"– tränar på {world} st")
    tokens_per_step = MICRO * BLOCK * ACCUM * world
    log(f"Data: {meta['tokens']['web'] / 1e6:,.0f} M tokens löptext, {meta['tokens']['chat'] / 1e6:,.1f} M tokens "
        f"samtal · {tokens_per_step:,} tokens per steg")

    decay = [p for p in model.parameters() if p.dim() >= 2]
    no_decay = [p for p in model.parameters() if p.dim() < 2]
    opt = torch.optim.AdamW([{"params": decay, "weight_decay": 0.1}, {"params": no_decay, "weight_decay": 0.0}],
                            lr=MAX_LR, betas=(0.9, 0.95), eps=1e-8, fused=device.type == "cuda")
    scaler = torch.amp.GradScaler("cuda", enabled=device.type == "cuda")

    step, tokens_seen, train_seconds, sessions = 0, 0, 0.0, 0
    resume = env("L3_RESUME", "") or find_one("/kaggle/input/**/resume_checkpoint.pt")
    if resume and os.path.exists(resume):
        ck = torch.load(resume, map_location="cpu", weights_only=False)
        same = all(ck["config"].get(k) == cfg[k] for k in ("vocab_size", "block_size", "n_embd", "n_head", "n_layer"))
        if not same:
            raise SystemExit(f"Checkpointen {resume} har en annan modellstorlek än den här körningen.")
        model.load_state_dict(ck["model"])
        opt.load_state_dict(ck["optimizer"])
        scaler.load_state_dict(ck["scaler"])
        step, tokens_seen = ck["step"], ck["tokens_seen"]
        train_seconds, sessions = ck.get("train_seconds", 0.0), ck.get("sessions", 0)
        log(f"Fortsätter från {resume}: steg {step:,}, {tokens_seen / 1e6:,.0f} M tokens tränade hittills")
    else:
        log("Börjar från slumpmässiga vikter.")

    raw = model
    if ddp:
        model = DDP(model, device_ids=[local] if device.type == "cuda" else None, gradient_as_bucket_view=True)
    data = Data(data_dir, SEED + 1000 * rank + step)

    end_time = START + HOURS * 3600 - SAFETY_S
    decay_start = START + HOURS * 3600 * (1 - DECAY_FRAC) - SAFETY_S
    log(f"Tidsbudget: {HOURS:g} h från start · sänkning börjar om {(decay_start - time.time()) / 3600:.2f} h · "
        f"slut om {(end_time - time.time()) / 3600:.2f} h")

    def make_resume():
        return {"model": raw.state_dict(), "optimizer": opt.state_dict(), "scaler": scaler.state_dict(),
                "step": step, "tokens_seen": tokens_seen, "train_seconds": train_seconds,
                "sessions": sessions + 1, "config": cfg}

    @torch.no_grad()
    def evaluate():
        model.eval()
        res = []
        for p in (0.0, 1.0):
            vals = []
            for _ in range(8):
                x, y = data.batch(p, True, device)
                with autocast(device):
                    _, loss = model(x, y)
                vals.append(loss.float())
            res.append(torch.stack(vals).mean())
        t = torch.stack(res)
        if ddp:
            dist.all_reduce(t)
            t /= world
        model.train()
        return float(t[0]), float(t[1])

    metrics = open(out / "metrics.jsonl", "a", encoding="utf-8") if master else None
    model.train()
    last_ckpt = time.time()
    saved_stable = False
    t_log, tok_log = time.time(), 0
    session_t0 = time.time()
    loss_acc = 0.0
    while True:
        # Rank 0 bestämmer fas och takt utifrån klockan; alla processer får samma värden.
        now = time.time()
        if step < WARMUP:
            lr, p_chat = MAX_LR * (step + 1) / WARMUP, CHAT_P
        elif now < decay_start:
            lr, p_chat = MAX_LR, CHAT_P
        else:
            f = min(1.0, (now - decay_start) / max(1.0, end_time - decay_start))
            lr = MAX_LR * (1 - (1 - MIN_LR_FRAC) * f)
            p_chat = CHAT_P + (CHAT_P_END - CHAT_P) * f
        # Även beslutet om checkpoint fattas av rank 0 – annars kan processerna hamna i otakt
        # (en väntar vid sparningen medan den andra tränar vidare) och hänga sig.
        want_ckpt = now >= decay_start or now - last_ckpt > CKPT_MINUTES * 60
        ctrl = torch.tensor([lr, p_chat, float(now >= end_time), float(now >= decay_start), float(want_ckpt)],
                            device=device, dtype=torch.float64)
        if ddp:
            dist.broadcast(ctrl, 0)
        lr, p_chat, stop, in_decay = float(ctrl[0]), float(ctrl[1]), bool(ctrl[2]), bool(ctrl[3])
        want_ckpt = bool(ctrl[4])
        if stop:
            break
        if in_decay and not saved_stable:
            # Spara läget före sänkningen – nästa körning fortsätter härifrån med full takt.
            if master:
                save_atomic(make_resume(), out / "resume_checkpoint.pt")
                log(f"Sparade resume_checkpoint.pt vid steg {step:,} (före sänkningen)")
            saved_stable = True
            if ddp:
                dist.barrier()
        elif not in_decay and want_ckpt:
            if master:
                save_atomic(make_resume(), out / "resume_checkpoint.pt")
                log(f"Checkpoint sparad vid steg {step:,}")
            last_ckpt = time.time()
            if ddp:
                dist.barrier()

        for g in opt.param_groups:
            g["lr"] = lr
        opt.zero_grad(set_to_none=True)
        loss_sum = 0.0
        for micro in range(ACCUM):
            x, y = data.batch(p_chat, False, device)
            sync = nullcontext() if (not ddp or micro == ACCUM - 1) else model.no_sync()
            with sync:
                with autocast(device):
                    _, loss = model(x, y)
                scaler.scale(loss / ACCUM).backward()
            loss_sum += loss.detach().float()
        scaler.unscale_(opt)
        gnorm = torch.nn.utils.clip_grad_norm_(raw.parameters(), 1.0)
        scaler.step(opt)
        scaler.update()
        step += 1
        tokens_seen += tokens_per_step
        tok_log += tokens_per_step
        loss_acc += float(loss_sum) / ACCUM

        if step % LOG_EVERY == 0:
            dt = time.time() - t_log
            train_seconds += dt
            phase = "uppvärmning" if step <= WARMUP else ("sänkning" if in_decay else "stabil")
            log(f"steg {step:,} · loss {loss_acc / LOG_EVERY:.3f} · lr {lr:.2e} · samtal {p_chat:.0%} · "
                f"{tok_log / dt / 1000:,.1f}k tok/s · {tokens_seen / 1e6:,.0f} M tokens · {phase} · "
                f"kvar {(end_time - time.time()) / 3600:.2f} h")
            if master:
                metrics.write(json.dumps({"step": step, "loss": loss_acc / LOG_EVERY, "lr": lr, "p_chat": p_chat,
                                          "tokens": tokens_seen, "grad_norm": float(gnorm),
                                          "tok_s": tok_log / dt, "t": time.time()}) + "\n")
                metrics.flush()
            loss_acc, tok_log, t_log = 0.0, 0, time.time()
        if step % EVAL_EVERY == 0:
            web_l, chat_l = evaluate()
            log(f"validering steg {step:,}: löptext {web_l:.3f} · samtal {chat_l:.3f}")
            if master:
                metrics.write(json.dumps({"step": step, "val_web": web_l, "val_chat": chat_l}) + "\n")
                metrics.flush()

    # ───────── slut på den här körningen
    web_l, chat_l = evaluate()
    log(f"Klar för den här gången: steg {step:,}, {tokens_seen / 1e6:,.0f} M tokens totalt, "
        f"validering löptext {web_l:.3f} · samtal {chat_l:.3f}, {(time.time() - session_t0) / 3600:.2f} h")
    if master:
        if not saved_stable:
            save_atomic(make_resume(), out / "resume_checkpoint.pt")
        weights = {k: v.half() for k, v in raw.state_dict().items()}
        save_atomic({"model": weights, "config": cfg}, out / "lennart3.pt")
        (out / "config.json").write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
        tok_src = data_dir / "tokenizer.json"
        (out / "tokenizer.json").write_bytes(tok_src.read_bytes())
        status = {"step": step, "tokens_seen": tokens_seen, "parameters": n_params, "val_web": web_l,
                  "val_chat": chat_l, "sessions": sessions + 1, "time": time.strftime("%Y-%m-%d %H:%M")}
        (out / "status.json").write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
        log("Sparade lennart3.pt (färdig modell, fp16), resume_checkpoint.pt, tokenizer.json och config.json")

        from tokenizers import Tokenizer
        tok = Tokenizer.from_file(str(tok_src))
        stop = (sp["<|end|>"], sp["<|endoftext|>"], sp["<|user|>"])
        print("\n=== Provsvar ===", flush=True)
        for q in TEST_PROMPTS:
            ids = tok.encode(f"<|user|>{q}<|assistant|>").ids
            ans = tok.decode(generate(raw, tok, ids, device, stop_ids=stop))
            print(f"F: {q}\nS: {ans.strip()}\n", flush=True)
        ids = tok.encode("Sverige är ett land där").ids
        print("Textfortsättning: Sverige är ett land där" + tok.decode(generate(raw, tok, ids, device, 80)), flush=True)
    if ddp:
        dist.barrier()
        dist.destroy_process_group()


if __name__ == "__main__":
    main()
