"""Hämtar svensk träningsdata från flera öppna källor och lägger in den som dataset i kontrollpanelen.

    python tools/hamta_data.py                 hämtar standardkällorna (wikipedia, lagar, swefaq)
    python tools/hamta_data.py wikipedia lagar hämtar bara de angivna källorna
    python tools/hamta_data.py --lista         visar källorna

Källor och licenser:

    wikipedia  Svenska Wikipedia (hela dumpen, filtrerad på IT och säkerhet)             CC BY-SA 4.0 (kräver pyarrow)
    lagar      Riksdagens öppna data: svenska lagar och förordningar om cybersäkerhet    fria (författningar)
    swefaq     SweFAQ: frågor och svar från svenska myndigheter                          CC BY-SA 4.0 (kräver pyarrow)
    mqa        MQA: svenska FAQ-sidor från webben, filtrerade på IT-frågor. Valfri –     CC0 enligt datasetet
               innehåller mycket reklam och maskinöversatt text, hämtas bara om den anges.

Varje källa blir ett eget dataset med källa och licens ifyllda. Till sist byggs datasetet
"Utökad träningsdata" som slår ihop allt med det medföljande cybersäkerhetsdatasetet.

Kräver pyarrow för wikipedia och swefaq:  pip install pyarrow
"""
from __future__ import annotations

import argparse
import gzip
import json
import random
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
for _p in (ROOT / ".paket", ROOT):
    if _p.exists() and str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aicc import paths  # noqa: E402
from aicc.core import datasets  # noqa: E402

USER_AGENT = "AIControlCenter-datahamtning/1.0 (lokalt verktyg; python-urllib)"


def cache_dir() -> Path:
    d = paths.data_root() / "hamtat"
    d.mkdir(parents=True, exist_ok=True)
    return d


def http(url: str, params: dict | None = None, retries: int = 5, timeout: int = 60) -> bytes:
    if params:
        url += "?" + urllib.parse.urlencode(params)
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"})
            with urllib.request.urlopen(req, timeout=timeout) as res:
                data = res.read()
                if res.headers.get("Content-Encoding") == "gzip":
                    data = gzip.decompress(data)
                return data
        except Exception as exc:  # noqa: BLE001
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1) + (10 if "429" in str(exc) else 0))
    return b""


def download(url: str, target: Path) -> Path:
    """Laddar ner en stor fil till cachen (hoppar över om den redan finns)."""
    if target.exists() and target.stat().st_size > 0:
        return target
    tmp = target.with_suffix(target.suffix + ".del")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=120) as res, open(tmp, "wb") as out:
        total = int(res.headers.get("Content-Length") or 0)
        done, last = 0, time.time()
        while True:
            chunk = res.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if time.time() - last > 5:
                last = time.time()
                print(f"    {done / 2**20:.0f} MB" + (f" av {total / 2**20:.0f} MB" if total else ""), flush=True)
    tmp.replace(target)
    return target


def register(dataset_id: str, records: list[dict], info: dict, split=(98, 1, 1)) -> dict | None:
    """Skriver posterna till en JSONL-fil och lägger in (eller ersätter) datasetet i kontrollpanelen."""
    if not records:
        print(f"  ! inga poster – {info['namn']} hoppas över")
        return None
    src = cache_dir() / f"{dataset_id}.jsonl"
    with open(src, "w", encoding="utf-8") as fh:
        for rec in records:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    if (paths.datasets_dir() / dataset_id / "meta.json").exists():
        datasets.delete_dataset(dataset_id)
    meta = datasets.import_dataset(src, src.name, {**info, "id": dataset_id})
    if meta["antal"] >= 100:
        meta = datasets.split(meta["id"], *split, seed=42)
    print(f"  ✓ {meta['namn']}: {meta['antal']:,} poster, {meta['tecken'] / 1e6:.1f} miljoner tecken".replace(",", " "))
    return meta


def qa(question: str, answer: str) -> dict:
    return {"fråga": question.strip(), "svar": answer.strip()}


# ───────────────────────────────────────────────────────────── Wikipedia
WIKI_FILES = 5  # 20231101.sv/train-0000N-of-00005.parquet
_WIKI_IT = re.compile(
    r"dator|programvara|mjukvara|hårdvara|operativsystem|internet|nätverk|krypter|kryptografi|kryptologi|"
    r"lösenord|datasäkerhet|it-säkerhet|informationssäkerhet|säkerhetshål|sårbarhet|skadlig kod|skadeprogram|"
    r"sabotageprogram|datavirus|datorvirus|trojan|hackare|dataintrång|webbläsare|webbserver|server|protokoll|"
    r"programspråk|programmering|algoritm|databas|processor|linux|windows|unix|webbplats|e-post|ip-adress|"
    r"brandvägg|autentisering|malware|botnät|källkod|öppen källkod|molntjänst|digital signatur|"
    r"överbelastningsattack|nätfiske|phishing|spionprogram|antivirus|personuppgift|signalspaning", re.I)
_WIKI_SEC = re.compile(
    r"krypter|kryptografi|kryptologi|lösenord|datasäkerhet|it-säkerhet|informationssäkerhet|säkerhetshål|"
    r"sårbarhet|skadlig kod|skadeprogram|sabotageprogram|datavirus|datorvirus|trojan|hackare|dataintrång|"
    r"brandvägg|autentisering|malware|botnät|överbelastningsattack|nätfiske|phishing|spionprogram|antivirus|"
    r"signalspaning|digital signatur", re.I)
_SKIP_TITLE = re.compile(r"^Lista över|\(olika betydelser\)", re.I)
_PERSON = re.compile(r"\bfödd\b|\bf\.\s*\d", re.I)


def first_sentences(text: str, max_chars: int = 420) -> str:
    text = re.sub(r"\s+", " ", text.split("\n")[0]).strip()
    out = ""
    for sent in re.split(r"(?<=[.!?])\s+(?=[A-ZÅÄÖ0-9])", text):
        if out and len(out) + len(sent) + 1 > max_chars:
            break
        out = (out + " " + sent).strip()
        if len(out) > 160:
            break
    return out if len(out) <= max_chars + 80 else ""


def _trim(text: str, limit: int) -> str:
    """Kortar texten vid en styckegräns."""
    if len(text) <= limit:
        return text
    cut = text.rfind("\n\n", 0, limit)
    return text[:cut if cut > limit // 2 else limit].strip()


def source_wikipedia(args) -> None:
    print("Wikipedia (sv): läser hela artikeldumpen (ca 930 MB nedladdning första gången) …")
    try:
        import pyarrow.parquet as pq
    except ImportError:
        print("  ! pyarrow saknas – hoppar över. Installera med: pip install pyarrow")
        return
    base = "https://huggingface.co/datasets/wikimedia/wikipedia/resolve/main/20231101.sv"
    rng = random.Random(42)
    it_articles, general, n_read = [], [], 0
    for k in range(WIKI_FILES):
        name = f"train-{k:05d}-of-{WIKI_FILES:05d}.parquet"
        path = download(f"{base}/{name}", cache_dir() / f"svwiki-{name}")
        for batch in pq.ParquetFile(path).iter_batches(batch_size=2000, columns=["title", "text"]):
            for title, text in zip(batch.column("title").to_pylist(), batch.column("text").to_pylist()):
                n_read += 1
                if not text or len(text) < 400 or _SKIP_TITLE.search(title):
                    continue
                head = title + " " + text[:2000]
                hits = {m.lower() for m in _WIKI_IT.findall(head)}
                if len(hits) >= 3 or (len(hits) >= 1 and _WIKI_IT.search(title)):
                    score = len(hits) + 3 * len({m.lower() for m in _WIKI_SEC.findall(head)})
                    it_articles.append((score, title, text))
                elif len(text) >= 2500 and rng.random() < 0.08:
                    general.append((title, text))
        print(f"    fil {k + 1}/{WIKI_FILES}: {n_read:,} artiklar lästa, {len(it_articles):,} om IT".replace(",", " "),
              flush=True)

    it_articles.sort(key=lambda x: -x[0])
    it_articles = it_articles[:args.wiki_max]
    rng.shuffle(general)
    general = general[:args.wiki_allmant]

    qa_records, text_records = [], []
    q_what = ["Vad är {t}?", "Vad menas med {t}?", "Kan du förklara {t}?", "Berätta om {t}.", "Vad betyder {t}?"]
    q_who = ["Vem är {t}?", "Berätta om {t}.", "Vad vet du om {t}?"]
    for _, title, text in it_articles:
        clean_title = re.sub(r"\s*\(.*?\)\s*$", "", title)
        answer = first_sentences(text)
        if len(answer) >= 40 and len(clean_title) <= 60:
            for q in (q_who if _PERSON.search(text[:300]) else q_what):
                qa_records.append(qa(q.format(t=clean_title), answer))
            qa_records.append(qa(clean_title.lower(), answer))
        text_records.append({"text": _trim(text, args.wiki_tecken)})

    common = {"kalla": "Svenska Wikipedia, dump 2023-11-01 via wikimedia/wikipedia på Hugging Face",
              "kall_url": "https://huggingface.co/datasets/wikimedia/wikipedia",
              "licens": "CC BY-SA 4.0 (kräver erkännande och dela lika)"}
    register("wikipedia-fragor", qa_records, {**common, "namn": "Wikipedia: frågor och svar om IT",
             "beskrivning": "Frågor av typen \"Vad är X?\" med artikelns inledning som svar."})
    register("wikipedia-text", text_records, {**common, "namn": "Wikipedia: artikeltext om IT och säkerhet",
             "beskrivning": "Löpande text från artiklar som handlar om datorer, nätverk, kryptografi och IT-säkerhet."})
    register("wikipedia-allmant", [{"text": _trim(t, 3000)} for _, t in general], {
        **common, "namn": "Wikipedia: allmän svensk text",
        "beskrivning": "Slumpvis valda längre artiklar – ger modellen bredare svenska och allmänbildning."})


# ─────────────────────────────────────────────────────────────── Lagar
LAW_SEARCHES = ["cybersäkerhet", "säkerhetsskydd", "dataskydd", "informationssäkerhet", "elektronisk identifiering",
                "elektronisk kommunikation", "dataintrång", "kamerabevakning", "signalspaning"]


_LAW_TITLE = re.compile(
    r"cybersäkerhet|säkerhetsskydd|dataskydd|personuppgift|informationssäkerhet|elektronisk|kamerabevakning|"
    r"signalspaning|identifiering|betrodda tjänster|digital|brottsdatalag|offentlighets- och sekretess|"
    r"nätverk och informationssystem|datalagring|it-", re.I)


def source_lagar(args) -> None:
    print("Riksdagens öppna data: lagar och förordningar …")
    docs = {}
    for term in LAW_SEARCHES:
        data = json.loads(http("https://data.riksdagen.se/dokumentlista/",
                               {"sok": term, "doktyp": "sfs", "utformat": "json", "sz": str(args.lagar_per_sokning)}))
        for doc in (data.get("dokumentlista") or {}).get("dokument") or []:
            if doc.get("dokument_url_text") and _LAW_TITLE.search(doc.get("titel") or ""):
                docs[doc["beteckning"]] = (doc["titel"], "https:" + doc["dokument_url_text"])
        time.sleep(0.2)
    records = []
    for i, (title, url) in enumerate(docs.values()):
        try:
            text = http(url).decode("utf-8", errors="replace")
        except Exception as exc:  # noqa: BLE001
            print(f"    ! {title}: {exc}")
            continue
        body = text.split("Källa:", 1)[-1].split("\n", 1)[-1] if "Källa:" in text[:800] else text
        body = re.sub(r"(?<![.:\n])\n(?!\n)", " ", body.replace("\r", ""))  # radbrutna stycken
        for para in re.split(r"\n\s*\n", body):
            para = re.sub(r"[ \t]+", " ", para).strip()
            if len(para) >= 80:
                records.append({"text": f"{title}. {para}" if re.match(r"\d+ ?[a-z]? §", para) else para})
        time.sleep(0.15)
    print(f"    {len(docs)} författningar")
    register("svenska-lagar-cybersakerhet", records, {
        "namn": "Svenska lagar om cybersäkerhet och dataskydd",
        "beskrivning": "Paragrafer ur lagar och förordningar (SFS) som rör cybersäkerhet, säkerhetsskydd och dataskydd.",
        "kalla": "Riksdagens öppna data (data.riksdagen.se), Svensk författningssamling",
        "kall_url": "https://data.riksdagen.se/",
        "licens": "Fritt att använda – författningar saknar upphovsrättsskydd (9 § upphovsrättslagen)"})


# ────────────────────────────────────────────────────────────── SweFAQ
def source_swefaq(args) -> None:
    print("SweFAQ: frågor och svar från svenska myndigheter …")
    try:
        import pyarrow.parquet as pq
    except ImportError:
        print("  ! pyarrow saknas – hoppar över. Installera med: pip install pyarrow")
        return
    base = "https://huggingface.co/datasets/mteb/SweFaqRetrieval/resolve/main"
    tables = {}
    for part in ("corpus", "queries", "qrels"):
        path = download(f"{base}/{part}/test-00000-of-00001.parquet", cache_dir() / f"swefaq_{part}.parquet")
        tables[part] = pq.read_table(path).to_pylist()
    answers = {r["_id"]: r["text"] for r in tables["corpus"]}
    questions = {r["_id"]: r["text"] for r in tables["queries"]}
    records = []
    for rel in tables["qrels"]:
        q, a = questions.get(rel["query-id"]), answers.get(rel["corpus-id"])
        if q and a and len(a) <= 1500:
            records.append(qa(q, re.sub(r"\s+", " ", a)))
    register("swefaq", records, {
        "namn": "SweFAQ: myndigheternas frågor och svar",
        "beskrivning": "Vanliga frågor med svar från svenska myndigheter (ur SuperLim/SweFAQ).",
        "kalla": "SweFAQ, Språkbanken Text – via mteb/SweFaqRetrieval på Hugging Face",
        "kall_url": "https://huggingface.co/datasets/mteb/SweFaqRetrieval", "licens": "CC BY-SA 4.0"})


# ───────────────────────────────────────────────────────────────── MQA
_IT_WORDS = re.compile(  # måste finnas i själva frågan
    r"lösenord|virus|skadlig kod|hacka|bedrägeri|bluffmejl|nätfiske|phishing|krypter|brandvägg|\bvpn\b|backup|"
    r"säkerhetskopi|bankid|e-legitimation|logga in|inlogg|tvåfaktor|tvåstegs|gdpr|personuppgift|cookies|"
    r"\bkakor\b|skräppost|\bspam\b|antivirus|\bdator|nätverk|router|\bserver|molntjänst|molnet|programvara|"
    r"mjukvara|webbläsare|e-post|\bmejl|domännamn|\bdomän\b|\bssl\b|https|databas|it-säkerhet|cybersäkerhet|"
    r"cyberattack|webbhotell|wordpress|hemsida|webbplats|operativsystem|windows|linux|\bmac\b|android|iphone|"
    r"it-support|dataintrång|identitetsstöld|kapat konto|säkerhetsuppdatering|ransomware|malware", re.I)
_SPAM = re.compile(
    r"casino|kasino|bonus|free ?spins|odds|betting|spela|jackpot|slots?\b|poker|\blån|låna|kredit|ränta|"
    r"porr|\bsex|escort|dejt|viagra|cbd|vape|snus|tobak|bantning|krypto|bitcoin|forex|rabatt|kampanjkod|"
    r"flytt|städ|taxi|bilskrot|låssmed|hotell|hostel|hostal|resort|\binn\b|suites?\b|flyg|restaurang|boende|"
    r"hyrbil|biluthyrning|\btåg|incheckning|utcheckning|\bpool|parkering|strand|semester|\bresa\b|resor|"
    r"bläck|toner|patron|billig|\bpris|köpa|\bköp\b|leverans|frakt|retur|covid|recension|betyg|"
    r"[#*✔►•→|]", re.I)
_SWEDISH = re.compile(r"[åäö]")


def _sentence_case(text: str) -> str:
    """MQA är helt i gemener – sätt stor bokstav i början av varje mening."""
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"(^|[.!?]\s+)([a-zåäö])", lambda m: m.group(1) + m.group(2).upper(), text)


def source_mqa(args) -> None:
    print("MQA: svenska FAQ-sidor (stor fil, ca 300 MB) …")
    path = download("https://huggingface.co/datasets/clips/mqa/resolve/main/data/data.sv.faq.json.gz",
                    cache_dir() / "mqa.sv.faq.json.gz")
    it_records, general, seen = [], [], set()
    rng = random.Random(42)
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        for n, line in enumerate(fh):
            if n % 100_000 == 0 and n:
                print(f"    {n:,} sidor lästa, {len(it_records):,} IT-frågor".replace(",", " "), flush=True)
            try:
                page = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not str(page.get("language") or "").lower().startswith("sv"):
                continue
            for item in (page.get("questions") or [])[:6]:  # få per sida – undviker mallade jättesidor
                q = (item.get("name") or "").strip()
                ans = next((a.get("text") for a in item.get("answers") or [] if a.get("text")), None)
                if not q or not ans:
                    continue
                a = re.sub(r"<[^>]+>", " ", ans)
                a = re.sub(r"\s+", " ", a).strip()
                if not (12 <= len(q) <= 140 and 40 <= len(a) <= 600):
                    continue
                both = q + " " + a
                if _SPAM.search(both) or "http" in both or "@" in both or not _SWEDISH.search(both):
                    continue
                key = q.lower()
                if key in seen:
                    continue
                seen.add(key)
                if not q.endswith("?"):
                    q += "?"
                rec = qa(_sentence_case(q), _sentence_case(a))
                if _IT_WORDS.search(q):
                    it_records.append(rec)
                elif args.mqa_allmant and rng.random() < 0.35:
                    general.append(rec)
    rng.shuffle(it_records)
    rng.shuffle(general)
    common = {"kalla": "MQA (clips/mqa på Hugging Face), svenska FAQ-sidor insamlade från webben via Common Crawl",
              "kall_url": "https://huggingface.co/datasets/clips/mqa",
              "licens": "CC0 1.0 enligt datasetet (texterna kommer från offentliga webbsidor)"}
    register("mqa-it", it_records[:args.mqa_it], {**common, "namn": "MQA: svenska frågor och svar om IT och säkerhet",
             "beskrivning": "Vanliga frågor från svenska webbplatser, filtrerade på IT- och säkerhetsord."})
    register("mqa-allmant", general[:args.mqa_allmant], {**common, "namn": "MQA: allmänna svenska frågor och svar",
             "beskrivning": "Blandade vanliga frågor – tränar modellen att förstå hur frågor ställs på svenska."})


# ─────────────────────────────────────────────────────────── kombinerat
def build_combined(args) -> None:
    print("Bygger det sammanslagna datasetet …")
    parts = [("svensk-cybersakerhet", args.egna_upprepningar), ("wikipedia-fragor", 1), ("wikipedia-text", 1), ("wikipedia-allmant", 1),
             ("svenska-lagar-cybersakerhet", 1), ("swefaq", 1), ("mqa-it", 1), ("mqa-allmant", 1)]
    records, used = [], []
    for dataset_id, repeat in parts:
        if not (paths.datasets_dir() / dataset_id / "meta.json").exists():
            continue
        recs = list(datasets.iter_records(dataset_id))
        records.extend(recs * repeat)
        meta = datasets.get_dataset(dataset_id)
        used.append(f"{meta['namn']} ({len(recs)} poster, {meta['licens']})")
    random.Random(42).shuffle(records)
    out = []
    for rec in records:
        if "messages" in rec:
            out.append({"fråga": rec["messages"][0]["content"], "svar": rec["messages"][1]["content"]}
                       if len(rec["messages"]) == 2 else {"messages": rec["messages"]})
        else:
            out.append(rec)
    register("utokad-traningsdata", out, {
        "namn": "Utökad träningsdata (alla källor)",
        "beskrivning": "Sammanslagning av: " + "; ".join(used) +
                       f". Det egna cybersäkerhetsdatasetet upprepas {args.egna_upprepningar} gånger för att väga tyngre.",
        "kalla": "Flera källor – se beskrivningen och de enskilda dataseten",
        "licens": "Blandad: CC BY-SA 4.0 (Wikipedia, SweFAQ), CC0 och fria författningar. "
                  "En modell som sprids vidare bör ange källorna."}, split=(99, 0.5, 0.5))


DEFAULT_SOURCES = ["wikipedia", "lagar", "swefaq"]  # mqa är valfri: python tools/hamta_data.py mqa
SOURCES = {"wikipedia": source_wikipedia, "lagar": source_lagar, "swefaq": source_swefaq, "mqa": source_mqa}


def main() -> int:
    ap = argparse.ArgumentParser(description="Hämtar svensk träningsdata till AI Control Center")
    ap.add_argument("kallor", nargs="*", help=f"vilka källor som ska hämtas ({', '.join(SOURCES)}); standardkällorna om inget anges")
    ap.add_argument("--lista", action="store_true", help="visa källorna och avsluta")
    ap.add_argument("--data", help="kontrollpanelens datamapp (standard: ./data)")
    ap.add_argument("--wiki-max", type=int, default=15_000, help="högst antal Wikipedia-artiklar om IT")
    ap.add_argument("--wiki-allmant", type=int, default=10_000, help="högst antal allmänna Wikipedia-artiklar")
    ap.add_argument("--wiki-tecken", type=int, default=5000, help="högst antal tecken per artikel")
    ap.add_argument("--lagar-per-sokning", type=int, default=40)
    ap.add_argument("--mqa-it", type=int, default=150_000, help="högst antal IT-frågor ur MQA")
    ap.add_argument("--mqa-allmant", type=int, default=0,
                    help="antal allmänna frågor ur MQA (standard 0: mest rese- och butiks-FAQ av låg kvalitet)")
    ap.add_argument("--egna-upprepningar", type=int, default=5)
    args = ap.parse_args()
    if args.lista:
        print(__doc__)
        return 0
    if args.data:
        import os
        os.environ["AICC_DATA"] = str(Path(args.data).resolve())
    unknown = [k for k in args.kallor if k not in SOURCES]
    if unknown:
        ap.error(f"okänd källa: {', '.join(unknown)}")
    datasets.seed_builtin()
    for name in args.kallor or DEFAULT_SOURCES:
        try:
            SOURCES[name](args)
        except Exception as exc:  # noqa: BLE001 – en källa som ligger nere ska inte stoppa resten
            print(f"  ! {name} misslyckades: {exc}")
    build_combined(args)
    print(f"\nKlart. Dataseten finns nu under Dataset i kontrollpanelen ({paths.datasets_dir()}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
