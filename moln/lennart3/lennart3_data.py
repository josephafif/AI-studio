"""Förbereder träningsdata för Lennart 3 (körs på CPU, t.ex. som Kaggle-körning utan GPU).

Skriver till utmappen:
    tokenizer.json   byte-nivå BPE (32 768 tokens) med chattokens <|user|> <|assistant|> <|end|>
    web.bin          löptext: svenska Wikipedia + FineWeb-2 (svenska), uint16
    web_val.bin      var 200:e dokument, för validering
    chat.bin         samtal i chattformat: <|user|>fråga<|assistant|>svar<|end|> … <|endoftext|>
    chat_val.bin     2 % av samtalen, för validering
    meta.json        mängder, källor och licenser

Inställningar via miljövariabler (standardvärden inom parentes):
    L3_OUT            utmapp (/kaggle/working)
    L3_WEB_TOKENS     mål för löptext i tokens (2 000 000 000)
    L3_HOURS          tidsgräns för hela förberedelsen i timmar (10.5); FineWeb slutar läsas i tid
    L3_WIKI_FILES     antal Wikipedia-filer att läsa, 1–5 (5)
    L3_TOK_CHARS      tecken att träna tokenizern på (40 000 000)
    L3_SMALL=1        litet provläge för lokal test
"""
from __future__ import annotations

import json
import os
import random
import re
import sys
import time
import urllib.request
from array import array
from pathlib import Path

T0 = time.time()
HERE = Path(__file__).resolve().parent
SMALL = os.environ.get("L3_SMALL") == "1"
OUT = Path(os.environ.get("L3_OUT", "/kaggle/working"))
WEB_TOKENS = int(os.environ.get("L3_WEB_TOKENS", 2_000_000 if SMALL else 2_000_000_000))
HOURS = float(os.environ.get("L3_HOURS", 10.5))
WIKI_FILES = int(os.environ.get("L3_WIKI_FILES", 1 if SMALL else 5))
TOK_CHARS = int(os.environ.get("L3_TOK_CHARS", 3_000_000 if SMALL else 40_000_000))
VOCAB = int(os.environ.get("L3_VOCAB", 32_768))
CACHE = Path(os.environ.get("L3_CACHE", "/tmp/l3cache"))
SPECIAL = ["<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>"]
rng = random.Random(2026)
OUT.mkdir(parents=True, exist_ok=True)
CACHE.mkdir(parents=True, exist_ok=True)


def log(*a):
    print(f"[{(time.time() - T0) / 60:6.1f} min]", *a, flush=True)


def time_left() -> float:
    return HOURS * 3600 - (time.time() - T0)


def fetch(url: str, target: Path) -> Path:
    if target.exists() and target.stat().st_size > 0:
        return target
    tmp = target.with_suffix(target.suffix + ".part")
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "lennart3-data/1.0"})
            with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as fh:
                while chunk := r.read(1 << 20):
                    fh.write(chunk)
            tmp.replace(target)
            return target
        except Exception as e:  # noqa: BLE001
            log(f"  nedladdning misslyckades ({e}), försök {attempt + 1}/6")
            time.sleep(10 * (attempt + 1))
    raise RuntimeError(f"Kunde inte hämta {url}")


def norm(text: str) -> str:
    return re.sub(r"[ \t]+", " ", re.sub(r"\n{3,}", "\n\n", text)).strip()


# ─────────────────────────────────────────────── samtal (chattdata)
# Varje samtal är en lista med (roll, text), roll = "user" | "assistant".
conversations: list[tuple[str, list[tuple[str, str]]]] = []  # (källa, samtal)


def add(source: str, turns: list[tuple[str, str]], times: int = 1):
    turns = [(r, norm(t)) for r, t in turns if t and t.strip()]
    if len(turns) >= 2 and turns[0][0] == "user" and turns[-1][0] == "assistant":
        for _ in range(times):
            conversations.append((source, turns))


def load_jsonl_qa(path: Path, source: str, times: int):
    n = 0
    for line in open(path, encoding="utf-8"):
        rec = json.loads(line)
        q = rec.get("fråga") or rec.get("question")
        a = rec.get("svar") or rec.get("answer")
        if q and a:
            add(source, [("user", q), ("assistant", a)], times)
            n += 1
    log(f"  ✓ {source}: {n:,} samtal (×{times})")


_BAD = re.compile(r"```|<p>|</?[a-z]+>|OpenAI|ChatGPT|GPT-?[34]|som en AI-språkmodell|som AI-språkmodell", re.I)


def source_openhermes():
    """timpal0l/OpenHermes-2.5-sv (MIT). Maskinöversatt – matte, kod och trasiga svar filtreras bort."""
    import pyarrow.parquet as pq
    path = fetch("https://huggingface.co/datasets/timpal0l/OpenHermes-2.5-sv/resolve/main/data/"
                 "train-00000-of-00001.parquet", CACHE / "openhermes-sv.parquet")
    kept = seen = 0
    limit = 3000 if SMALL else None
    for batch in pq.ParquetFile(path).iter_batches(batch_size=2000, columns=["conversations"]):
        for conv in batch.column("conversations").to_pylist():
            seen += 1
            turns = []
            ok = True
            for m in conv or []:
                role = {"human": "user", "gpt": "assistant"}.get(m.get("from"))
                text = m.get("value") or ""
                if role is None:
                    continue
                digits = sum(c.isdigit() for c in text)
                if _BAD.search(text) or (text and digits / len(text) > 0.05) or len(text) > 2200:
                    ok = False
                    break
                if role == "assistant" and len(text) < 20:
                    ok = False
                    break
                turns.append((role, text))
            if ok and turns:
                before = len(conversations)
                add("openhermes-sv", turns)
                kept += len(conversations) - before
            if limit and seen >= limit:
                break
        if limit and seen >= limit:
            break
    log(f"  ✓ OpenHermes-2.5-sv: {kept:,} av {seen:,} samtal behölls efter filtrering")


def source_aya():
    """CohereLabs/aya_dataset (Apache 2.0): svenska frågor och svar skrivna av människor."""
    import pyarrow.parquet as pq
    path = fetch("https://huggingface.co/api/datasets/CohereLabs/aya_dataset/parquet/default/train/0.parquet",
                 CACHE / "aya.parquet")
    n = 0
    for r in pq.read_table(path, columns=["inputs", "targets", "language"]).to_pylist():
        if "Swed" in (r["language"] or ""):
            add("aya-sv", [("user", r["inputs"]), ("assistant", r["targets"])], 2)
            n += 1
    log(f"  ✓ Aya (svenska): {n:,} samtal (×2)")


def source_swefaq():
    """SweFAQ via mteb/SweFaqRetrieval (CC BY-SA 4.0): myndigheters frågor och svar."""
    import pyarrow.parquet as pq
    base = "https://huggingface.co/datasets/mteb/SweFaqRetrieval/resolve/main"
    t = {p: pq.read_table(fetch(f"{base}/{p}/test-00000-of-00001.parquet", CACHE / f"swefaq_{p}.parquet")).to_pylist()
         for p in ("corpus", "queries", "qrels")}
    ans = {r["_id"]: r["text"] for r in t["corpus"]}
    qs = {r["_id"]: r["text"] for r in t["queries"]}
    n = 0
    for rel in t["qrels"]:
        q, a = qs.get(rel["query-id"]), ans.get(rel["corpus-id"])
        if q and a and len(a) <= 1500:
            add("swefaq", [("user", q), ("assistant", a)], 2)
            n += 1
    log(f"  ✓ SweFAQ: {n:,} samtal (×2)")


# ─────────────────────────────────────────────── Wikipedia
WIKI_BASE = "https://huggingface.co/datasets/wikimedia/wikipedia/resolve/main/20231101.sv"
_SKIP_TITLE = re.compile(r"^(Lista över|Förteckning|Mall:|Kategori:)|\(olika betydelser\)", re.I)
_PERSON = re.compile(r"\b(född|död)\b|\(\s*\d{1,2} \w+ \d{4}", re.I)
Q_WHAT = ["Vad är {t}?", "Berätta om {t}.", "Vad vet du om {t}?", "Kan du förklara vad {t} är?", "Vad menas med {t}?"]
WIKI_QA, WIKI_QA_MAX = {"n": 0}, int(os.environ.get("L3_WIKI_QA", 220_000))
Q_WHO = ["Vem är {t}?", "Berätta om {t}.", "Vad vet du om {t}?"]


def wiki_paths():
    return [fetch(f"{WIKI_BASE}/train-{k:05d}-of-00005.parquet", CACHE / f"svwiki-{k}.parquet")
            for k in range(WIKI_FILES)]


def iter_wiki():
    import pyarrow.parquet as pq
    for path in wiki_paths():
        for batch in pq.ParquetFile(path).iter_batches(batch_size=2000, columns=["title", "text"]):
            for title, text in zip(batch.column("title").to_pylist(), batch.column("text").to_pylist()):
                # Korta artiklar är oftast bot-genererade (arter, orter) – de hoppas över.
                if text and len(text) >= 1500 and not _SKIP_TITLE.search(title):
                    yield title, text


def lead(text: str, max_chars: int = 600) -> str:
    para = text.strip().split("\n")[0]
    if len(para) <= max_chars:
        return para
    cut = para[:max_chars]
    end = cut.rfind(". ")
    return cut[:end + 1] if end > 120 else cut


Q_MORE = ["Berätta mer.", "Kan du berätta mer?", "Vad mer vet du?", "Fortsätt gärna.", "Intressant, berätta mer!"]
Q_SUMMARY = ["Sammanfatta {t} kort.", "Ge mig en kort sammanfattning av {t}.", "Förklara {t} enkelt."]


def wiki_qa(title: str, text: str):
    """Frågor och svar från artikeln: inledningen, ibland en följdfråga med nästa stycke."""
    t = re.sub(r"\s*\(.*?\)\s*$", "", title)
    a = lead(text)
    if WIKI_QA["n"] >= WIKI_QA_MAX or not (60 <= len(a) and len(t) <= 60) or rng.random() >= 0.80:
        return
    WIKI_QA["n"] += 1
    r = rng.random()
    q = rng.choice(Q_WHO if _PERSON.search(text[:300]) else Q_WHAT).format(t=t)
    paras = [p.strip() for p in text.split("\n") if len(p.strip()) >= 120 and not p.strip().startswith("==")]
    if r < 0.25 and len(paras) >= 2:
        # Två turer: frågan, sedan en följdfråga som besvaras med nästa stycke.
        add("wikipedia-qa", [("user", q), ("assistant", a), ("user", rng.choice(Q_MORE)), ("assistant", lead(paras[1]))])
    elif r < 0.40:
        add("wikipedia-qa", [("user", rng.choice(Q_SUMMARY).format(t=t)), ("assistant", a)])
    else:
        add("wikipedia-qa", [("user", q), ("assistant", a)])


# ─────────────────────────────────────────────── FineWeb-2
def iter_fineweb():
    from datasets import load_dataset
    ds = load_dataset("HuggingFaceFW/fineweb-2", name="swe_Latn", split="train", streaming=True)
    for row in ds:
        text = row.get("text")
        if isinstance(text, str) and len(text) >= 300:
            yield text


# ─────────────────────────────────────────────── tokenizer
def chat_string(turns) -> str:
    s = "".join(("<|user|>" if r == "user" else "<|assistant|>") + t + ("<|end|>" if r == "assistant" else "")
                for r, t in turns)
    return s + "<|endoftext|>"


def train_tokenizer():
    from tokenizers import Tokenizer, decoders, models, pre_tokenizers, trainers
    path = OUT / "tokenizer.json"
    # Fortsatt träning kräver exakt samma tokenizer – lägg den i koddatasetet så återanvänds den.
    given = HERE / "tokenizer.json"
    if given.exists() and not path.exists():
        path.write_bytes(given.read_bytes())
    if path.exists():
        log("Tokenizer finns redan – återanvänds.")
        return Tokenizer.from_file(str(path))
    log(f"Tränar tokenizer ({VOCAB:,} tokens) på {TOK_CHARS / 1e6:.0f} miljoner tecken …")

    def sample():
        budget = {"wiki": TOK_CHARS * 0.35, "web": TOK_CHARS * 0.5, "chat": TOK_CHARS * 0.15}
        used = 0
        for _, text in iter_wiki():
            yield text
            used += len(text)
            if used >= budget["wiki"]:
                break
        used = 0
        for text in iter_fineweb():
            yield text
            used += len(text)
            if used >= budget["web"]:
                break
        used = 0
        for _, turns in rng.sample(conversations, len(conversations)):
            s = " ".join(t for _, t in turns)
            yield s
            used += len(s)
            if used >= budget["chat"]:
                break

    tok = Tokenizer(models.BPE())
    tok.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tok.decoder = decoders.ByteLevel()
    trainer = trainers.BpeTrainer(vocab_size=VOCAB, min_frequency=2, special_tokens=SPECIAL,
                                  initial_alphabet=pre_tokenizers.ByteLevel.alphabet(), show_progress=False)
    tok.train_from_iterator(sample(), trainer=trainer)
    tok.save(str(path))
    log(f"  ✓ tokenizer: {tok.get_vocab_size():,} tokens, specialtokens {[tok.token_to_id(s) for s in SPECIAL]}")
    return tok


class BinWriter:
    def __init__(self, path: Path):
        self.fh = open(path, "wb")
        self.n = 0

    def write(self, ids):
        a = array("H", ids)
        a.tofile(self.fh)
        self.n += len(a)

    def close(self):
        self.fh.close()


def encode_stream(tok, texts, train: BinWriter, val: BinWriter | None, eos: int, stop_tokens: int | None,
                  label: str, every: int = 200, batch_size: int = 512, deadline: float | None = None):
    buf, docs = [], 0
    last = time.time()

    def flush():
        nonlocal docs
        for enc in tok.encode_batch(buf):
            ids = enc.ids + [eos]
            docs += 1
            (val if val is not None and docs % every == 0 else train).write(ids)
        buf.clear()

    for text in texts:
        buf.append(text)
        if len(buf) >= batch_size:
            flush()
            if time.time() - last > 120:
                last = time.time()
                log(f"  {label}: {train.n / 1e6:,.0f} M tokens, {docs:,} dokument")
            if stop_tokens and train.n >= stop_tokens:
                break
            if deadline and time_left() < deadline:
                log(f"  {label}: tidsgränsen närmar sig – slutar läsa här.")
                break
    if buf:
        flush()
    return docs


def main():
    log(f"Lennart 3 – dataförberedelse → {OUT}  (mål {WEB_TOKENS / 1e6:,.0f} M tokens löptext)")
    persona = HERE / "lennart3_samtal.jsonl"
    cyber = next((p for p in (HERE / "svensk_cybersakerhet.jsonl",
                              HERE.parent.parent / "resources" / "datasets" / "svensk_cybersakerhet.jsonl")
                  if p.exists()), HERE / "svensk_cybersakerhet.jsonl")
    log("Samlar samtalsdata …")
    if persona.exists():
        load_jsonl_qa(persona, "lennart-persona", 20)
    if cyber.exists():
        load_jsonl_qa(cyber, "cybersakerhet", 1)
    for fn in (source_aya, source_swefaq, source_openhermes):
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            log(f"  ! {fn.__name__} misslyckades och hoppas över: {e}")

    tok = train_tokenizer()
    eos = tok.token_to_id("<|endoftext|>")
    assert tok.get_vocab_size() <= 65535

    log("Kodar svenska Wikipedia (artiklar ≥ 1 500 tecken) och bygger frågor och svar från dem …")
    web, web_val = BinWriter(OUT / "web.bin"), BinWriter(OUT / "web_val.bin")

    def wiki_texts():
        for title, text in iter_wiki():
            wiki_qa(title, text)
            yield text

    wiki_docs = encode_stream(tok, wiki_texts(), web, web_val, eos, None, "Wikipedia")
    wiki_tokens = web.n
    log(f"  ✓ Wikipedia: {wiki_docs:,} artiklar, {wiki_tokens / 1e6:,.0f} M tokens")

    log("Kodar FineWeb-2 (svenska webbtext) …")
    fw_docs = 0
    if WEB_TOKENS > web.n:
        try:
            fw_docs = encode_stream(tok, iter_fineweb(), web, web_val, eos, WEB_TOKENS, "FineWeb-2",
                                    deadline=0.6 * 3600)
        except Exception as e:  # noqa: BLE001
            log(f"  ! FineWeb-2 avbröts: {e} – fortsätter med det som hunnit kodas.")
    web.close()
    web_val.close()
    log(f"  ✓ FineWeb-2: {fw_docs:,} dokument, {(web.n - wiki_tokens) / 1e6:,.0f} M tokens")

    log(f"Kodar {len(conversations):,} samtal …")
    rng.shuffle(conversations)
    chat, chat_val = BinWriter(OUT / "chat.bin"), BinWriter(OUT / "chat_val.bin")
    n_val = max(50, len(conversations) // 50)
    counts: dict[str, int] = {}
    for i in range(0, len(conversations), 1024):
        part = conversations[i:i + 1024]
        for j, enc in enumerate(tok.encode_batch([chat_string(t) for _, t in part])):
            (chat_val if i + j < n_val else chat).write(enc.ids)
        for src, _ in part:
            counts[src] = counts.get(src, 0) + 1
    chat.close()
    chat_val.close()
    log(f"  ✓ samtal: {chat.n / 1e6:,.1f} M tokens (validering {chat_val.n / 1e6:,.2f} M)")

    meta = {
        "vocab_size": tok.get_vocab_size(),
        "special_tokens": {s: tok.token_to_id(s) for s in SPECIAL},
        "dtype": "uint16",
        "tokens": {"web": web.n, "web_val": web_val.n, "chat": chat.n, "chat_val": chat_val.n,
                   "wikipedia": wiki_tokens, "fineweb2": web.n - wiki_tokens},
        "samtal_per_kalla": counts,
        "chat_format": "<|user|>fråga<|assistant|>svar<|end|> … <|endoftext|>",
        "kallor": {
            "Svenska Wikipedia (wikimedia/wikipedia 20231101.sv)": "CC BY-SA 4.0",
            "FineWeb-2 swe_Latn (HuggingFaceFW/fineweb-2)": "ODC-By 1.0",
            "OpenHermes-2.5-sv (timpal0l/OpenHermes-2.5-sv)": "MIT",
            "Aya dataset, svenska (CohereLabs/aya_dataset)": "Apache 2.0",
            "SweFAQ (mteb/SweFaqRetrieval)": "CC BY-SA 4.0",
            "Svensk cybersäkerhet (AI Control Center)": "CC0",
            "Lennart-samtal (AI Control Center)": "CC0",
        },
        "tid_minuter": round((time.time() - T0) / 60, 1),
    }
    (OUT / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    log("Klart.", json.dumps(meta["tokens"]))


if __name__ == "__main__":
    sys.exit(main())
