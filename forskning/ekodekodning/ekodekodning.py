"""Ekodekodning – återvunna utkast som gratis förslag (eget experiment).

Bakgrund: när Lennart "tänker" (nivåerna Medel och Djup i appen) skriver den flera utkast till
samma fråga och väljer det bästa. Utkasten blir ofta nästan likadana, men varje token räknas ändå
om från början, ett helt framåtpass per token. På en telefon kostar ett pass i praktiken lika mycket
för 1 som för 8 tokens, eftersom tiden går åt till att läsa in vikterna (~300 MB) från minnet.

Idé: när ett nytt utkast skrivs, slå upp var det senaste stycket text redan förekommit – i tidigare
utkast eller i frågan – och föreslå fortsättningen därifrån. Alla förslag kontrolleras i ett enda pass
(lm_eval_all) och godtas med exakt rätt sannolikhet:

    förslaget d godtas med sannolikhet p(d)        (förslaget är deterministiskt, q = 1)
    vid avslag dras en ny token ur p där d är bortplockad och normaliserad

Det ger exakt samma fördelning över svar som vanlig sampling (spekulativ sampling med en
punktfördelning som förslag), men med färre pass när utkasten upprepar varandra.

Kör: python forskning/ekodekodning/ekodekodning.py <lib> <modell.lmod> <tokenizer.json>
"""
import ctypes as C
import json
import math
import sys
import time

import numpy as np
from tokenizers import Tokenizer


class Engine:
    def __init__(self, lib, path, threads=4):
        self.L = C.CDLL(lib)
        L = self.L
        L.lm_load.restype = C.c_void_p
        L.lm_load.argtypes = [C.c_char_p, C.c_int, C.c_char_p, C.c_int]
        for f in ("lm_reset",):
            getattr(L, f).argtypes = [C.c_void_p]
        L.lm_pos.argtypes = [C.c_void_p]
        L.lm_rewind.argtypes = [C.c_void_p, C.c_int]
        L.lm_eval.argtypes = [C.c_void_p, C.POINTER(C.c_int32), C.c_int]
        L.lm_eval_all.argtypes = [C.c_void_p, C.POINTER(C.c_int32), C.c_int, C.POINTER(C.c_float)]
        L.lm_logits.restype = C.POINTER(C.c_float)
        L.lm_logits.argtypes = [C.c_void_p]
        L.lm_info.argtypes = [C.c_void_p, C.POINTER(C.c_int32)]
        err = C.create_string_buffer(256)
        self.h = L.lm_load(path.encode(), threads, err, 256)
        if not self.h:
            raise RuntimeError(err.value.decode())
        info = (C.c_int32 * 8)()
        L.lm_info(self.h, info)
        self.vocab, self.ctx = info[0], info[4]
        self.passes = 0          # antal framåtpass (= antal gånger vikterna läses)
        self.tokens_in = 0       # antal tokens som matats in
        self._buf = np.zeros((16, self.vocab), dtype=np.float32)

    def reset(self):
        self.L.lm_reset(self.h)

    @property
    def pos(self):
        return self.L.lm_pos(self.h)

    def rewind(self, p):
        assert self.L.lm_rewind(self.h, p) == 0

    def logits(self):
        return np.ctypeslib.as_array(self.L.lm_logits(self.h), shape=(self.vocab,)).copy()

    def eval(self, toks):
        a = (C.c_int32 * len(toks))(*toks)
        assert self.L.lm_eval(self.h, a, len(toks)) == 0
        self.passes += 1
        self.tokens_in += len(toks)
        return self.logits()

    def eval_all(self, toks):
        n = len(toks)
        a = (C.c_int32 * n)(*toks)
        if n > len(self._buf):
            self._buf = np.zeros((n, self.vocab), dtype=np.float32)
        out = self._buf[:n]
        assert self.L.lm_eval_all(self.h, a, n, out.ctypes.data_as(C.POINTER(C.c_float))) == 0
        self.passes += 1
        self.tokens_in += n
        return out.copy()


PENALTY = 1.12


def dist(row, temperature, top_k, recent, banned):
    """Samplingsfördelningen exakt som i appen: upprepningsstraff, förbjudna tokens, top-k, temperatur."""
    lg = row.astype(np.float64)
    for t in set(recent[-64:]):
        lg[t] = lg[t] / PENALTY if lg[t] > 0 else lg[t] * PENALTY
    lg[banned] = -np.inf
    if temperature <= 1e-6:
        p = np.zeros_like(lg)
        p[int(np.argmax(lg))] = 1
        return p
    if 0 < top_k < len(lg):
        kth = np.partition(lg, -top_k)[-top_k]
        lg[lg < kth] = -np.inf
    z = (lg - lg.max()) / temperature
    p = np.exp(z)
    return p / p.sum()


def raw_logprob(row, x):
    m = row.max()
    return float(row[x] - m - math.log(np.exp(row - m).sum()))


class Draft:
    def __init__(self):
        self.toks, self.lp, self.ended, self.pruned = [], 0.0, False, False

    def mean(self):
        return self.lp / len(self.toks) if self.toks else -10

    def rep(self):
        t = self.toks
        if len(t) < 6:
            return 0
        seen, dup = set(), 0
        for i in range(len(t) - 2):
            k = (t[i], t[i + 1], t[i + 2])
            dup += k in seen
            seen.add(k)
        return dup / (len(t) - 2)

    def score(self):
        s = self.mean() - 2 * self.rep() + (0.15 if self.ended else -0.25)
        if len(self.toks) < 3:
            s -= 1
        return s + 0.08 * min(1, len(self.toks) / 30)


def lookup(sources, seq, k, max_n=3):
    """Föreslår upp till k tokens: hitta senaste stycket av seq (3, 2 eller 1 token) i någon källa
    och returnera det som kom efter. Källorna är frågan och tidigare utkast (inklusive prompten)."""
    for n in range(max_n, 0, -1):
        if len(seq) < n:
            continue
        key = seq[-n:]
        best = None
        for src in sources:
            for i in range(len(src) - n, -1, -1):  # senaste förekomsten först
                if src[i:i + n] == key and i + n < len(src):
                    cand = src[i + n:i + n + k]
                    if best is None or len(cand) > len(best):
                        best = cand
                    break
        if best:
            return best
    return []


def write_draft(eng, rng, prompt, p0_logits, limit, T, top_k, banned, end_id, sources, prune_below, recycle, k=4):
    """Ett utkast. recycle=False: vanlig sampling, en token per pass. recycle=True: ekodekodning."""
    d = Draft()
    P = len(prompt)
    cur = p0_logits
    stats = {"proposed": 0, "accepted": 0}

    def emit(x, row):
        d.toks.append(x)
        d.lp += raw_logprob(row, x)

    def pruned():
        if prune_below is not None and len(d.toks) >= 24 and d.mean() - 2 * d.rep() < prune_below - 0.6:
            d.pruned = True
            return True
        return False

    while len(d.toks) < limit:
        p = dist(cur, T, top_k, d.toks, banned)
        prop = lookup(sources, prompt + d.toks, k) if recycle else []
        prop = prop[: max(0, min(limit - len(d.toks), eng.ctx - eng.pos - 1))]
        if prop:
            stats["proposed"] += 1
            x1 = prop[0]
            if rng.random() < p[x1]:
                # Första förslaget godtaget – kontrollera resten i ett pass.
                stats["accepted"] += 1
                emit(x1, cur)
                if x1 == end_id:
                    d.toks.pop(); d.ended = True
                    break
                if pruned():
                    break
                rows = eng.eval_all(prop)  # rad i = fördelningen efter prop[i]
                ok = 1
                stop = False
                for j in range(1, len(prop) + 1):
                    row = rows[j - 1]
                    if len(d.toks) >= limit:
                        stop = True
                        break
                    pj = dist(row, T, top_k, d.toks, banned)
                    if j < len(prop) and rng.random() < pj[prop[j]]:
                        stats["accepted"] += 1
                        emit(prop[j], row)
                        ok += 1
                        if prop[j] == end_id:
                            d.toks.pop(); d.ended = True
                            stop = True
                            break
                        if pruned():
                            stop = True
                            break
                        continue
                    # Avslag (eller slut på förslag): dra ur pj utan det avvisade förslaget.
                    q = pj.copy()
                    if j < len(prop):
                        q[prop[j]] = 0
                        q /= q.sum()
                    x = int(rng.choice(len(q), p=q))
                    eng.rewind(P + len(d.toks))  # kasta cache för avvisade förslag
                    if x == end_id:
                        d.ended = True
                        stop = True
                        break
                    emit(x, row)
                    if pruned():
                        stop = True
                        break
                    cur = eng.eval([x])
                    break
                if stop:
                    break
                continue
            # Första förslaget avvisat: dra ur p utan förslaget.
            q = p.copy()
            q[x1] = 0
            q /= q.sum()
            x = int(rng.choice(len(q), p=q))
        else:
            x = int(rng.choice(len(p), p=p))
        if x == end_id:
            d.ended = True
            break
        emit(x, cur)
        if pruned() or eng.pos >= eng.ctx:
            break
        cur = eng.eval([x])
    return d, stats


def think(eng, tok, question, drafts, recycle, rng, T=0.7, top_k=40, limit=120):
    sp = {s: tok.token_to_id(s) for s in ("<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>")}
    prompt = [sp["<|user|>"]] + tok.encode(question).ids + [sp["<|assistant|>"]]
    banned = [sp["<|endoftext|>"], sp["<|user|>"], sp["<|assistant|>"]]
    eng.reset()
    p0 = eng.eval(prompt)
    P = len(prompt)
    best, best_i, out = None, -1, []
    sources = [prompt]
    agg = {"proposed": 0, "accepted": 0}
    for i in range(drafts):
        if i > 0:
            eng.rewind(P)
        t = min(T, 0.35) if (i == 0 and drafts > 1) else (max(T, 0.5) if drafts > 1 else T)
        d, st = write_draft(eng, rng, prompt, p0, limit, t, top_k, banned, sp["<|end|>"], sources,
                            best.score() if best else None, recycle)
        for kk in agg:
            agg[kk] += st[kk]
        out.append(d)
        sources.append(prompt + d.toks)
        if not d.pruned and (best is None or d.score() > best.score()):
            best, best_i = d, i
    return best, out, agg


def main():
    lib, model, tokp = sys.argv[1:4]
    tok = Tokenizer.from_file(tokp)
    eng = Engine(lib, model)
    questions = [
        "Vad är nätfiske?", "Hur skapar jag ett starkt lösenord?", "Vad är en brandvägg?",
        "Någon har hackat mitt konto, vad gör jag?", "Vad är tvåfaktorsautentisering?", "Vad är ransomware?",
        "Hur vet jag om ett sms är bedrägeri?", "Vad är en VPN?", "Varför ska jag uppdatera min telefon?",
        "Vad är skadlig kod?", "Berätta om Astrid Lindgren.", "Varför är himlen blå?",
        "Ge mig tips för att sova bättre.", "Vad ska jag laga till middag?", "Vad är huvudstaden i Norge?",
        "Hur mår du?", "Vem är du?", "Vad är fotosyntes?", "Hur fungerar en dator?", "Vad är demokrati?",
    ]
    res = {}
    for level, drafts in (("Snabb", 1), ("Medel", 3), ("Djup", 6)):
        for recycle in (False, True):
            name = f"{level}{' + eko' if recycle else ''}"
            eng.passes = eng.tokens_in = 0
            rng = np.random.default_rng(1234)
            t0 = time.time()
            toks_out, scores, agg = 0, [], {"proposed": 0, "accepted": 0}
            for q in questions:
                best, ds, st = think(eng, tok, q, drafts, recycle, rng)
                toks_out += sum(len(d.toks) for d in ds)
                scores.append(best.score())
                for kk in agg:
                    agg[kk] += st[kk]
            dt = time.time() - t0
            gen_passes = eng.passes - len(questions)  # utan promptpasset
            res[name] = dict(sekunder=round(dt, 1), tokens=toks_out, pass_=gen_passes,
                             tokens_per_pass=round(toks_out / max(1, gen_passes), 2),
                             medelpoang=round(float(np.mean(scores)), 3),
                             godtagna_forslag=f"{agg['accepted']}/{agg['proposed']}")
            print(name, res[name], flush=True)
    json.dump(res, open(sys.argv[4] if len(sys.argv) > 4 else "resultat.json", "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
