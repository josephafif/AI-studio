"""Lennart 4.0: tränar LFM2.5-350M (Liquid AI) på svenska.

Fas 1 (--fas cpt): fortsatt förträning på svensk text – FineWeb2-HQ (swe_Latn) och svenska Wikipedia – med
engelsk text från FineWeb-Edu inblandad, så att modellen inte glömmer det den redan kan. Förlusten mäts på
svensk och engelsk text som aldrig tränas på, före, under och efter.

Fas 2 (--fas sft, senare): samtal i ChatML (OpenHermes-2.5-sv, Lennarts stil- och verktygssamtal), förlust
bara på assistentens svar.

Körs på Kaggle (2× T4) eller lokalt. Startas skriptet utan torchrun och det finns flera GPU:er startar det om
sig självt med en process per GPU. Inställningar via flaggor eller miljövariabler (L4_*), se argument().

Licens: LFM2.5-350M omfattas av LFM Open License v1.0; den tränade modellen är en bearbetning och ska spridas
med licensen och en notering om ändringarna (tools/exportera_lfm2.py lägger med båda).
"""
import argparse
import glob
import json
import math
import os
import queue
import random
import subprocess
import sys
import threading
import time
from pathlib import Path

PA_KAGGLE = Path("/kaggle").exists()


def argument():
    e = os.environ.get
    ap = argparse.ArgumentParser()
    ap.add_argument("--fas", choices=["cpt", "sft"], default=e("L4_FAS", "cpt"))
    ap.add_argument("--modell", default=e("L4_MODELL", "LiquidAI/LFM2.5-350M"))
    ap.add_argument("--ut", default=e("L4_UT", "/kaggle/working/lennart4" if PA_KAGGLE else "ut-lennart4"))
    ap.add_argument("--minuter", type=float, default=float(e("L4_MINUTER", 60)), help="tid för träningsslingan")
    ap.add_argument("--tokens", type=float, default=float(e("L4_TOKENS", 2e8)), help="planerade tokens (styr lr-schemat)")
    ap.add_argument("--seq", type=int, default=int(e("L4_SEQ", 2048)))
    ap.add_argument("--micro", type=int, default=int(e("L4_MICRO", 4)), help="sekvenser per delsteg och GPU")
    ap.add_argument("--batch-tokens", type=int, default=int(e("L4_BATCH", 262144)), help="tokens per optimeringssteg, alla GPU:er")
    ap.add_argument("--lr", type=float, default=float(e("L4_LR", 1e-4)))
    ap.add_argument("--precision", default=e("L4_PREC", "auto"), choices=["auto", "fp16", "bf16", "fp32"])
    ap.add_argument("--blandning", default=e("L4_MIX", "sv_hq:0.70,sv_wiki:0.15,en_edu:0.15"))
    ap.add_argument("--eval-var", type=int, default=int(e("L4_EVAL", 100)), help="utvärdera var N:e steg")
    ap.add_argument("--eval-sekvenser", type=int, default=int(e("L4_EVAL_SEQ", 24)))
    ap.add_argument("--spara-var", type=float, default=float(e("L4_SPARA", 0)), help="spara modellen var N:e minut (0 = bara i slutet)")
    ap.add_argument("--lokal-text", default=e("L4_LOKAL", ""), help="glob med textfiler i stället för Hugging Face (test)")
    ap.add_argument("--samtal", default=e("L4_SAMTAL", ""), help="egna samtal (jsonl: fråga/svar eller messages), komma-separerade globbar")
    ap.add_argument("--upprepa-egna", type=int, default=int(e("L4_UPPREPA", 20)), help="hur många gånger de egna samtalen tas med")
    ap.add_argument("--max-hermes", type=int, default=int(e("L4_MAX_HERMES", 0)), help="högst så många samtal ur OpenHermes-2.5-sv (0 = alla)")
    return ap.parse_args()


# ───────────────────────────────────────────────────────────── start på flera GPU:er
def starta_om_med_torchrun():
    """Utan torchrun och med flera GPU:er: installera det som behövs och starta en process per GPU."""
    if "RANK" in os.environ:
        return
    if PA_KAGGLE:
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", "transformers>=5.0", "huggingface_hub>=1.0"], check=False)
    import torch

    n = torch.cuda.device_count()
    print("GPU:er:", ", ".join(torch.cuda.get_device_name(i) for i in range(n)) or "inga", flush=True)
    if n < 2:
        return
    kod = Path(globals().get("__file__") or sys.argv[0]).resolve()
    kopia = Path("/tmp/lfm_trana.py")
    kopia.write_text(kod.read_text())
    cmd = [sys.executable, "-m", "torch.distributed.run", "--standalone", f"--nproc_per_node={n}", str(kopia), *sys.argv[1:]]
    print("$", " ".join(cmd), flush=True)
    sys.exit(subprocess.run(cmd, env={**os.environ, "OMP_NUM_THREADS": "2"}).returncode)


# ───────────────────────────────────────────────────────────── data
KALLOR = {
    "sv_hq": ("epfml/FineWeb2-HQ", "swe_Latn/"),
    "sv_wiki": ("wikimedia/wikipedia", "20231101.sv/"),
    "en_edu": ("HuggingFaceFW/fineweb-edu", "sample/10BT/"),
}


def filer(kalla: str) -> list[str]:
    from huggingface_hub import HfApi

    repo, prefix = KALLOR[kalla]
    return sorted(f for f in HfApi().list_repo_files(repo, repo_type="dataset") if f.startswith(prefix) and f.endswith(".parquet"))


def dokument(kalla: str, lista: list[str], cache: str):
    """Texterna i parquet-filerna, en fil i taget; filen tas bort när den är läst."""
    import pyarrow.parquet as pq
    from huggingface_hub import hf_hub_download

    repo, _ = KALLOR[kalla]
    while True:
        for f in lista:
            p = hf_hub_download(repo, f, repo_type="dataset", cache_dir=cache)
            pf = pq.ParquetFile(p)
            for rg in range(pf.num_row_groups):
                for t in pf.read_row_group(rg, columns=["text"]).column("text").to_pylist():
                    if t and len(t) > 200:
                        yield t
            try:
                os.remove(os.path.realpath(p))
            except OSError:
                pass


def lokala_dokument(monster: str):
    texter = [Path(f).read_text(encoding="utf-8", errors="ignore") for f in sorted(glob.glob(monster, recursive=True))]
    texter = [t for t in texter if len(t) > 200]
    while True:
        yield from texter


class Packare(threading.Thread):
    """Blandar källorna, tokeniserar i bakgrunden och packar till sekvenser om seq tokens."""

    def __init__(self, tok, strommar: dict, vikter: dict, seq: int, micro: int, rank: int):
        super().__init__(daemon=True)
        self.tok, self.strommar, self.seq, self.micro = tok, strommar, seq, micro
        self.namn = list(vikter)
        self.vikter = [vikter[n] for n in self.namn]
        self.rng = random.Random(1234 + rank)
        self.q: queue.Queue = queue.Queue(maxsize=8)
        self.fel = None
        self.antal = {n: 0 for n in self.namn}

    def run(self):
        import torch

        try:
            bos = self.tok.convert_tokens_to_ids("<|startoftext|>")
            eos = self.tok.convert_tokens_to_ids("<|endoftext|>")
            buf: list[int] = []
            while True:
                val = self.rng.choices(self.namn, self.vikter, k=64)
                texter = [next(self.strommar[n]) for n in val]
                for n in val:
                    self.antal[n] += 1
                for ids in self.tok(texter, add_special_tokens=False)["input_ids"]:
                    buf.extend([bos, *ids, eos])
                while len(buf) >= self.seq * self.micro:
                    x = torch.tensor(buf[: self.seq * self.micro], dtype=torch.long).view(self.micro, self.seq)
                    del buf[: self.seq * self.micro]
                    # LFM2 behöver starttecknet först i varje sekvens (utan det: förlust 9,5 i stället för 2,4).
                    x[:, 0] = bos
                    self.q.put(x)
        except Exception as e:  # noqa: BLE001
            self.fel = e
            self.q.put(None)

    def nasta(self):
        x = self.q.get()
        if x is None:
            raise RuntimeError(f"Datainläsningen stannade: {self.fel!r}")
        return x


def valideringsdata(tok, texter: list[str], seq: int, n: int):
    """Sekvenser ur texter som aldrig tränas på, och antalet byte de motsvarar (för bits per byte)."""
    bos = tok.convert_tokens_to_ids("<|startoftext|>")
    eos = tok.convert_tokens_to_ids("<|endoftext|>")
    buf, byte = [], 0
    for t in texter:
        ids = tok(t, add_special_tokens=False)["input_ids"]
        buf.extend([bos, *ids, eos])
        byte += len(t.encode("utf-8"))
        if len(buf) >= seq * n:
            break
    andel = min(1.0, seq * n / max(1, len(buf)))
    seqs = [buf[i * seq:(i + 1) * seq] for i in range(min(n, len(buf) // seq))]
    for s in seqs:
        s[0] = bos  # som i träningen: starttecknet först
    return seqs, byte * andel


# ───────────────────────────────────────────────────────────── samtal (fas 2)
def las_samtal(a, cache: str) -> list[list[tuple[str, str]]]:
    """Samtal som listor av (roll, text) med rollerna system, user och assistant."""
    import pyarrow.parquet as pq
    from huggingface_hub import hf_hub_download

    samtal = []
    if a.max_hermes >= 0:
        p = hf_hub_download("timpal0l/OpenHermes-2.5-sv", "data/train-00000-of-00001.parquet", repo_type="dataset", cache_dir=cache)
        for r in pq.read_table(p, columns=["conversations"]).column("conversations").to_pylist():
            c = [({"human": "user", "gpt": "assistant", "system": "system"}.get(m["from"]), (m["value"] or "").strip()) for m in r]
            c = [(roll, t) for roll, t in c if roll and t]
            if any(roll == "assistant" for roll, _ in c):
                samtal.append(c)
            if a.max_hermes and len(samtal) >= a.max_hermes:
                break
    egna = []
    for monster in filter(None, a.samtal.split(",")):
        for f in sorted(glob.glob(monster, recursive=True)):
            for rad in Path(f).read_text(encoding="utf-8").splitlines():
                if not rad.strip():
                    continue
                j = json.loads(rad)
                if "messages" in j:
                    egna.append([(m["role"], m["content"]) for m in j["messages"]])
                elif "fråga" in j:
                    egna.append([("user", j["fråga"]), ("assistant", j["svar"])])
    return samtal + egna * a.upprepa_egna


def koda_samtal(tok, c: list[tuple[str, str]], seq: int):
    """ChatML exakt som appen (BpeTokenizer.encodeChat) och originalets mall; förlust bara på assistentens svar
    och dess <|im_end|>."""
    bos = tok.convert_tokens_to_ids("<|startoftext|>")
    start = tok.convert_tokens_to_ids("<|im_start|>")
    slut = tok.convert_tokens_to_ids("<|im_end|>")
    nl = tok("\n", add_special_tokens=False)["input_ids"]
    ids, lab = [bos], [-100]
    for roll, text in c:
        prefix = tok(f"{roll}\n", add_special_tokens=False)["input_ids"]
        hel = tok(f"{roll}\n{text}", add_special_tokens=False)["input_ids"]
        ids += [start, *hel, slut, *nl]
        if roll == "assistant":
            lab += [-100, *([-100] * len(prefix)), *hel[len(prefix):], slut, *([-100] * len(nl))]
        else:
            lab += [-100] * (len(hel) + 2 + len(nl))
    return ids[:seq], lab[:seq]


class SamtalsPackare(threading.Thread):
    """Packar samtal (med etiketter) till sekvenser om seq tokens, i blandad ordning, varv efter varv."""

    def __init__(self, tok, samtal, seq: int, micro: int, rank: int, world: int):
        super().__init__(daemon=True)
        self.tok, self.seq, self.micro = tok, seq, micro
        self.samtal = samtal[rank::world]
        self.rng = random.Random(99 + rank)
        self.q: queue.Queue = queue.Queue(maxsize=8)
        self.fel = None
        self.varv = 0
        self.antal = {}

    def run(self):
        import torch

        try:
            pad = self.tok.convert_tokens_to_ids("<|pad|>")
            ids, lab, rader = [], [], []
            while True:
                ordning = list(range(len(self.samtal)))
                self.rng.shuffle(ordning)
                for i in ordning:
                    a, b = koda_samtal(self.tok, self.samtal[i], self.seq)
                    if len(ids) + len(a) > self.seq:
                        rader.append((ids + [pad] * (self.seq - len(ids)), lab + [-100] * (self.seq - len(lab))))
                        ids, lab = [], []
                    ids, lab = ids + a, lab + b
                    if len(rader) == self.micro:
                        x = torch.tensor([r[0] for r in rader], dtype=torch.long)
                        y = torch.tensor([r[1] for r in rader], dtype=torch.long)
                        rader = []
                        self.q.put((x, y))
                self.varv += 1
        except Exception as e:  # noqa: BLE001
            self.fel = e
            self.q.put(None)

    def nasta(self):
        x = self.q.get()
        if x is None:
            raise RuntimeError(f"Datainläsningen stannade: {self.fel!r}")
        return x


# ───────────────────────────────────────────────────────────── träning
def main():
    starta_om_med_torchrun()
    import torch
    import torch.distributed as dist
    from transformers import AutoModelForCausalLM, AutoTokenizer

    a = argument()
    ddp = "RANK" in os.environ
    rank, world, lokal = (int(os.environ["RANK"]), int(os.environ["WORLD_SIZE"]), int(os.environ["LOCAL_RANK"])) if ddp else (0, 1, 0)
    if ddp:
        dist.init_process_group("nccl")
        torch.cuda.set_device(lokal)
    dev = torch.device(f"cuda:{lokal}" if torch.cuda.is_available() else "cpu")
    huvud = rank == 0
    ut = Path(a.ut)
    if huvud:
        ut.mkdir(parents=True, exist_ok=True)
    logg = open(ut / "logg.jsonl", "a") if huvud else None

    def skriv(**k):
        if huvud:
            k["t"] = round(time.time() - T0, 1)
            print(json.dumps(k, ensure_ascii=False), flush=True)
            logg.write(json.dumps(k, ensure_ascii=False) + "\n")
            logg.flush()

    T0 = time.time()
    torch.manual_seed(1234 + rank)
    if a.precision == "auto":
        try:
            bf16 = dev.type == "cuda" and torch.cuda.is_bf16_supported(including_emulation=False)
        except TypeError:
            bf16 = dev.type == "cuda" and torch.cuda.get_device_capability(dev)[0] >= 8
        a.precision = "bf16" if bf16 else ("fp16" if dev.type == "cuda" else "fp32")
    tok = AutoTokenizer.from_pretrained(a.modell)
    model = AutoModelForCausalLM.from_pretrained(a.modell, dtype=torch.float32).to(dev)
    model.config.use_cache = False
    if dev.type == "cuda":
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    rå = model
    if ddp:
        model = torch.nn.parallel.DistributedDataParallel(model, device_ids=[lokal])

    # Data: varje process får sina egna filer; sista filen i sv_hq och en_edu sparas för validering.
    cache = "/tmp/hf-data"
    vikter = {k: float(v) for k, v in (p.split(":") for p in a.blandning.split(","))}
    val_samtal = []
    if a.fas == "sft":
        alla = las_samtal(a, cache)
        random.Random(5).shuffle(alla)
        n_val = min(200, len(alla) // 10)
        val_samtal, alla = alla[:n_val], alla[n_val:]
        if not alla:
            raise SystemExit("Inga samtal att träna på")
        strommar, val_sv, val_en = {}, [], []
        if a.lokal_text:
            val_sv = val_en = [Path(f).read_text(errors="ignore") for f in sorted(glob.glob(a.lokal_text, recursive=True))[:3]]
    elif a.lokal_text:
        strommar = {k: lokala_dokument(a.lokal_text) for k in vikter}
        val_sv = val_en = [t for t in (Path(f).read_text(errors="ignore") for f in sorted(glob.glob(a.lokal_text, recursive=True))[:3])]
    else:
        strommar, val_sv, val_en = {}, [], []
        for k in vikter:
            lista = filer(k)
            if k in ("sv_hq", "en_edu"):
                val_fil, lista = lista[-1], lista[:-1]
            if k in ("sv_hq", "en_edu") and huvud:
                texter = []
                for t in dokument(k, [val_fil], cache):
                    texter.append(t)
                    if len(texter) >= 400:
                        break
                (val_sv if k == "sv_hq" else val_en).extend(texter)
            lista = [f for i, f in enumerate(lista) if i % world == rank]
            random.Random(7 + rank).shuffle(lista)
            strommar[k] = dokument(k, lista, cache)
    val = {"sv": valideringsdata(tok, val_sv, a.seq, a.eval_sekvenser), "en": valideringsdata(tok, val_en, a.seq, a.eval_sekvenser)}
    val_svar = [koda_samtal(tok, c, a.seq) for c in val_samtal]

    if a.fas == "sft":
        packare = SamtalsPackare(tok, alla, a.seq, a.micro, rank, world)
        if huvud:
            print(f"samtal: {len(alla)} för träning, {len(val_samtal)} för validering", flush=True)
    else:
        packare = Packare(tok, strommar, vikter, a.seq, a.micro, rank)
    packare.start()

    accum = max(1, a.batch_tokens // (a.seq * a.micro * world))
    steg_tot = max(1, int(a.tokens // (a.seq * a.micro * world * accum)))
    varm = max(10, steg_tot // 50)

    def lr_vid(s):
        """WSD: uppvärmning, platå och nedtrappning till 10 % under sista femtedelen – av stegen eller av tiden,
        det som kommer först, så att nedtrappningen alltid hinner bli klar innan tiden tar slut."""
        if s < varm:
            return a.lr * (s + 1) / varm
        andel = max(s / steg_tot, (time.time() - T_slinga) / max(1.0, a.minuter * 60))
        if andel > 0.8:
            return a.lr * (0.1 + 0.9 * max(0.0, 1.0 - andel) / 0.2)
        return a.lr

    beslut = [p for p in rå.parameters() if p.dim() >= 2]
    ovriga = [p for p in rå.parameters() if p.dim() < 2]
    opt = torch.optim.AdamW([{"params": beslut, "weight_decay": 0.1}, {"params": ovriga, "weight_decay": 0.0}],
                            lr=a.lr, betas=(0.9, 0.95), eps=1e-8, fused=dev.type == "cuda")
    autocast = dict(device_type=dev.type, dtype={"fp16": torch.float16, "bf16": torch.bfloat16}.get(a.precision, torch.float32),
                    enabled=a.precision in ("fp16", "bf16"))
    skalare = torch.amp.GradScaler(enabled=a.precision == "fp16")

    @torch.no_grad()
    def utvardera():
        rå.eval()
        res = {}
        for namn, (seqs, byte) in val.items():
            if not seqs:
                continue
            tot, n = 0.0, 0
            for s in seqs:
                x = torch.tensor([s], device=dev)
                with torch.autocast(**autocast):
                    loss = rå(input_ids=x, labels=x).loss.float().item()
                tot += loss * (len(s) - 1)
                n += len(s) - 1
            res[f"{namn}_forlust"] = round(tot / n, 4)
            res[f"{namn}_bpb"] = round(tot / math.log(2) / byte, 4)
        if val_svar:
            tot, n = 0.0, 0
            for ids, lab in val_svar[:100]:
                x, y = torch.tensor([ids], device=dev), torch.tensor([lab], device=dev)
                m = int((y[:, 1:] != -100).sum())
                if m == 0:
                    continue
                with torch.autocast(**autocast):
                    loss = rå(input_ids=x, labels=y).loss.float().item()
                tot += loss * m
                n += m
            res["svar_forlust"] = round(tot / max(1, n), 4)
        rå.train()
        return res

    def spara(slutlig: bool):
        """Modellen, tokeniseraren, licensen och noteringen om ändringar – så att mappen kan spridas som den är."""
        mapp = ut / "modell"
        rå.save_pretrained(mapp, safe_serialization=True)
        tok.save_pretrained(mapp)
        for f in ["LICENSE", "chat_template.jinja", "generation_config.json"]:
            try:
                lokal_fil = Path(a.modell) / f
                if lokal_fil.exists():
                    (mapp / f).write_bytes(lokal_fil.read_bytes())
                elif not Path(a.modell).exists():
                    from huggingface_hub import hf_hub_download

                    (mapp / f).write_bytes(Path(hf_hub_download(a.modell, f)).read_bytes())
            except Exception:  # noqa: BLE001
                pass
        tidigare = Path(a.modell) / "ANDRINGAR.txt"
        rad = ((f"Fortsatt förträning på svensk text (FineWeb2-HQ swe_Latn, svenska Wikipedia) med engelsk FineWeb-Edu "
                f"inblandad, {tokens / 1e6:.0f} M tokens") if a.fas == "cpt" else
               f"Finjustering på svenska samtal i ChatML (OpenHermes-2.5-sv och Lennarts egna samtal), {tokens / 1e6:.0f} M tokens")
        rad += ", av AI Studio (Lennart-projektet)." + ("" if slutlig else " (sparpunkt under träningen)")
        if tidigare.exists():
            text = tidigare.read_text(encoding="utf-8").rstrip() + "\n" + rad + "\n"
        else:
            text = f"Bearbetning av LiquidAI/LFM2.5-350M (LFM Open License v1.0, §4 b):\n{rad}\n"
        (mapp / "ANDRINGAR.txt").write_text(text, encoding="utf-8")
        skriv(handelse="sparad", mapp=str(mapp), slutlig=slutlig, tokens=tokens)

    if huvud:
        skriv(handelse="start", fas=a.fas, precision=a.precision, gpu=world, accum=accum, steg_planerade=steg_tot,
              tokens_per_steg=a.seq * a.micro * world * accum, **utvardera())
    if ddp:
        dist.barrier()
    model.train()
    steg, tokens, t_logg, tok_logg = 0, 0, time.time(), 0
    T_slinga = time.time()
    slut = T_slinga + a.minuter * 60
    senast_sparad = time.time()
    while steg < steg_tot and time.time() < slut:
        for g in opt.param_groups:
            g["lr"] = lr_vid(steg)
        summa = 0.0
        for i in range(accum):
            del_ = packare.nasta()
            x, y = (del_ if isinstance(del_, tuple) else (del_, del_))
            x, y = x.to(dev, non_blocking=True), y.to(dev, non_blocking=True)
            ctx = model.no_sync() if ddp and i < accum - 1 else torch.enable_grad()
            with ctx:
                with torch.autocast(**autocast):
                    loss = model(input_ids=x, labels=y).loss
                skalare.scale(loss / accum).backward()
            summa += loss.detach().float().item() / accum
            tokens += x.numel() * world
            tok_logg += x.numel() * world
        skalare.unscale_(opt)
        norm = torch.nn.utils.clip_grad_norm_(rå.parameters(), 1.0).item()
        skalare.step(opt)
        skalare.update()
        opt.zero_grad(set_to_none=True)
        steg += 1
        if steg % 5 == 0 or steg == 1:
            dt = time.time() - t_logg
            skriv(steg=steg, forlust=round(summa, 4), lr=round(lr_vid(steg), 7), norm=round(norm, 3),
                  tok_per_s=round(tok_logg / max(dt, 1e-9)), tokens=tokens, skala=skalare.get_scale() if skalare.is_enabled() else None,
                  minne_gb=round(torch.cuda.max_memory_allocated() / 1e9, 2) if dev.type == "cuda" else None)
            t_logg, tok_logg = time.time(), 0
        if a.eval_var and steg % a.eval_var == 0:
            if huvud:
                skriv(handelse="utvardering", steg=steg, tokens=tokens, **utvardera())
            if ddp:
                dist.barrier()
        if a.spara_var and time.time() - senast_sparad > a.spara_var * 60:
            # Sparpunkt: tar kvoten eller tiden slut finns det senaste kvar.
            if huvud:
                spara(slutlig=False)
            if ddp:
                dist.barrier()
            senast_sparad = time.time()
    if huvud:
        skriv(handelse="slut", steg=steg, tokens=tokens, data=packare.antal, varv=getattr(packare, "varv", None), **utvardera())
        spara(slutlig=True)
    if ddp:
        dist.barrier()
        dist.destroy_process_group()


if __name__ == "__main__":
    main()
