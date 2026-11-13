"""Datasethantering: import (TXT/JSON/JSONL), förhandsgranskning, dubblettrensning,
uppdelning i tränings-/validerings-/testdata samt metadata om källa och licens.

Varje dataset är en mapp under ``data/dataset/<id>/``:

    meta.json        namn, källa, licens, statistik, uppdelning
    original.<ext>   den importerade filen, orörd
    poster.jsonl     normaliserade poster (en per rad)
    train.jsonl / val.jsonl / test.jsonl   skapas vid uppdelning

En normaliserad post är antingen ``{"messages": [{"role", "content"}, ...]}``
(fråga/svar och samtal) eller ``{"text": "..."}`` (löpande text).
"""
from __future__ import annotations

import json
import random
import re
import shutil
from pathlib import Path
from typing import Iterator

from .. import paths
from . import AppError, NotFound

SPLITS = ("train", "val", "test")
_USER_KEYS = ("question", "fråga", "fraga", "prompt", "instruction", "instruktion", "user",
              "användare", "anvandare", "q", "input")
_ASSISTANT_KEYS = ("answer", "svar", "response", "completion", "output", "assistant",
                   "assistent", "a")
_TEXT_KEYS = ("text", "content", "innehåll", "innehall", "body")
_ROLE_MAP = {"user": "user", "human": "user", "användare": "user", "anvandare": "user",
             "assistant": "assistant", "assistent": "assistant", "gpt": "assistant",
             "bot": "assistant", "model": "assistant"}
_META_FIELDS = ("namn", "beskrivning", "kalla", "kall_url", "licens", "anteckningar")


def dataset_dir(dataset_id: str) -> Path:
    path = paths.datasets_dir() / paths.safe_id(dataset_id)
    if not (path / "meta.json").exists():
        raise NotFound(f"Datasetet '{dataset_id}' finns inte")
    return path


# ------------------------------------------------------------ normalisering
def normalize_record(obj) -> dict | None:
    if isinstance(obj, str):
        text = obj.strip()
        return {"text": text} if text else None
    if isinstance(obj, list):
        return _from_messages(obj)
    if not isinstance(obj, dict):
        return None
    lower = {str(k).lower(): v for k, v in obj.items()}

    for key in ("messages", "conversations", "conversation", "dialog", "samtal"):
        if isinstance(lower.get(key), list):
            rec = _from_messages(lower[key])
            if rec:
                return rec

    user = next((lower[k] for k in _USER_KEYS if isinstance(lower.get(k), str) and lower[k].strip()), None)
    assistant = next((lower[k] for k in _ASSISTANT_KEYS
                      if isinstance(lower.get(k), str) and lower[k].strip()), None)
    if user and assistant:
        # Alpaca-format: instruction + input + output
        extra = lower.get("input")
        if isinstance(extra, str) and extra.strip() and extra is not user:
            user = f"{user.strip()}\n{extra.strip()}"
        return {"messages": [{"role": "user", "content": user.strip()},
                             {"role": "assistant", "content": assistant.strip()}]}

    for key in _TEXT_KEYS:
        if isinstance(lower.get(key), str) and lower[key].strip():
            return {"text": lower[key].strip()}
    parts = [v.strip() for v in obj.values() if isinstance(v, str) and v.strip()]
    return {"text": "\n".join(parts)} if parts else None


def _from_messages(items: list) -> dict | None:
    messages = []
    for item in items:
        if not isinstance(item, dict):
            continue
        role = _ROLE_MAP.get(str(item.get("role") or item.get("from") or "").lower())
        content = item.get("content") or item.get("value") or item.get("text")
        if role and isinstance(content, str) and content.strip():
            messages.append({"role": role, "content": content.strip()})
    if any(m["role"] == "assistant" for m in messages):
        return {"messages": messages}
    if messages:
        return {"text": "\n".join(m["content"] for m in messages)}
    return None


def _decode(raw: bytes) -> str:
    for enc in ("utf-8-sig", "utf-16", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def _parse_file(path: Path, fmt: str) -> tuple[list[dict], int]:
    """Returnerar (poster, antal rader/objekt som inte gick att tolka)."""
    text = _decode(path.read_bytes())
    records, skipped = [], 0
    if fmt == "jsonl":
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rec = normalize_record(json.loads(line))
            except json.JSONDecodeError:
                rec = None
            if rec:
                records.append(rec)
            else:
                skipped += 1
    elif fmt == "json":
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise AppError(f"JSON-filen kunde inte tolkas: {exc.msg} (rad {exc.lineno})")
        if isinstance(data, dict):
            lists = [v for v in data.values() if isinstance(v, list) and v]
            data = max(lists, key=len) if lists and "messages" not in data else [data]
        if not isinstance(data, list):
            data = [data]
        for item in data:
            rec = normalize_record(item)
            if rec:
                records.append(rec)
            else:
                skipped += 1
    else:  # txt
        blocks = [b.strip() for b in re.split(r"\n\s*\n", text.replace("\r\n", "\n")) if b.strip()]
        if len(blocks) == 1 and "\n" in blocks[0]:
            blocks = [ln.strip() for ln in blocks[0].split("\n") if ln.strip()]
        records = [{"text": b} for b in blocks]
    return records, skipped


# ---------------------------------------------------------------- hjälpare
def _write_records(path: Path, records) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        for rec in records:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def _read_records(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with open(path, "r", encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def record_text(rec: dict) -> str:
    if "messages" in rec:
        return "\n".join(m["content"] for m in rec["messages"])
    return rec.get("text", "")


def _stats(records: list[dict]) -> dict:
    chat = sum(1 for r in records if "messages" in r)
    kind = "chatt" if chat == len(records) and records else ("text" if chat == 0 else "blandat")
    return {"antal": len(records), "tecken": sum(len(record_text(r)) for r in records), "typ": kind}


def _load_meta(dataset_id: str) -> dict:
    meta = paths.read_json(dataset_dir(dataset_id) / "meta.json")
    if not meta:
        raise NotFound(f"Datasetet '{dataset_id}' saknar giltig meta.json")
    return meta


def _save_meta(dataset_id: str, meta: dict) -> None:
    meta["andrad"] = paths.now_iso()
    paths.write_json(paths.datasets_dir() / dataset_id / "meta.json", meta)


# --------------------------------------------------------------------- API
def list_datasets() -> list[dict]:
    out = []
    for d in sorted(paths.datasets_dir().iterdir()):
        meta = paths.read_json(d / "meta.json") if d.is_dir() else None
        if meta:
            out.append(meta)
    out.sort(key=lambda m: m.get("skapad", ""))
    return out


def get_dataset(dataset_id: str) -> dict:
    return _load_meta(dataset_id)


def import_dataset(src: Path, filename: str, info: dict | None = None) -> dict:
    info = info or {}
    ext = Path(filename).suffix.lower().lstrip(".")
    if ext not in ("txt", "json", "jsonl"):
        raise AppError("Filformatet stöds inte. Använd TXT, JSON eller JSONL.")
    records, skipped = _parse_file(src, ext)
    if not records:
        raise AppError("Filen innehåller inga poster som går att använda")
    name = str(info.get("namn") or Path(filename).stem).strip() or "Dataset"
    dataset_id = paths.unique_id(paths.datasets_dir(), info.get("id") or name, "dataset")
    ddir = paths.datasets_dir() / dataset_id
    ddir.mkdir(parents=True)
    shutil.copyfile(src, ddir / f"original.{ext}")
    _write_records(ddir / "poster.jsonl", records)
    meta = {
        "id": dataset_id,
        "namn": name,
        "beskrivning": str(info.get("beskrivning", "")),
        "kalla": str(info.get("kalla", "")),
        "kall_url": str(info.get("kall_url", "")),
        "licens": str(info.get("licens", "")),
        "anteckningar": str(info.get("anteckningar", "")),
        "format": ext,
        "originalfil": Path(filename).name,
        "skapad": paths.now_iso(),
        "overhoppade": skipped,
        "dubbletter_borttagna": 0,
        "uppdelning": None,
        "inbyggt": bool(info.get("inbyggt")),
        **_stats(records),
    }
    _save_meta(dataset_id, meta)
    return meta


def update_dataset(dataset_id: str, patch: dict) -> dict:
    meta = _load_meta(dataset_id)
    for key in _META_FIELDS:
        if key in patch:
            meta[key] = str(patch[key] or "").strip()[:4000]
    if not meta["namn"]:
        raise AppError("Datasetet måste ha ett namn")
    _save_meta(dataset_id, meta)
    return meta


def delete_dataset(dataset_id: str) -> None:
    shutil.rmtree(dataset_dir(dataset_id))


def split_path(dataset_id: str, split: str) -> Path:
    ddir = dataset_dir(dataset_id)
    if split in SPLITS:
        return ddir / f"{split}.jsonl"
    return ddir / "poster.jsonl"


def preview(dataset_id: str, split: str = "alla", offset: int = 0, limit: int = 20) -> dict:
    path = split_path(dataset_id, split)
    offset, limit = max(0, int(offset)), min(200, max(1, int(limit)))
    rows, total = [], 0
    if path.exists():
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                if not line.strip():
                    continue
                if offset <= total < offset + limit:
                    rows.append(json.loads(line))
                total += 1
    return {"poster": rows, "totalt": total, "offset": offset, "limit": limit, "del": split}


def _dedupe_key(rec: dict) -> str:
    if "messages" in rec:
        raw = "\x1f".join(f"{m['role']}:{m['content']}" for m in rec["messages"])
    else:
        raw = rec.get("text", "")
    return re.sub(r"\s+", " ", raw).strip().lower()


def dedupe(dataset_id: str) -> dict:
    """Tar bort exakta dubbletter (skiftläge och blanksteg ignoreras)."""
    ddir = dataset_dir(dataset_id)
    meta = _load_meta(dataset_id)
    records = _read_records(ddir / "poster.jsonl")
    seen, unique = set(), []
    for rec in records:
        key = _dedupe_key(rec)
        if key in seen:
            continue
        seen.add(key)
        unique.append(rec)
    removed = len(records) - len(unique)
    if removed:
        _write_records(ddir / "poster.jsonl", unique)
        meta.update(_stats(unique))
        meta["dubbletter_borttagna"] = meta.get("dubbletter_borttagna", 0) + removed
        _save_meta(dataset_id, meta)
        if meta.get("uppdelning"):
            u = meta["uppdelning"]
            return {**split(dataset_id, u["andel_train"], u["andel_val"], u["andel_test"], u["seed"]),
                    "borttagna": removed}
    return {**meta, "borttagna": removed}


def split(dataset_id: str, train: float = 80, val: float = 10, test: float = 10, seed: int = 42) -> dict:
    """Delar upp posterna slumpmässigt (men reproducerbart) i train/val/test."""
    try:
        train, val, test, seed = float(train), float(val), float(test), int(seed)
    except (TypeError, ValueError):
        raise AppError("Andelarna måste vara tal")
    if min(train, val, test) < 0 or train <= 0:
        raise AppError("Andelarna får inte vara negativa och träningsandelen måste vara större än 0")
    total = train + val + test
    ddir = dataset_dir(dataset_id)
    meta = _load_meta(dataset_id)
    records = _read_records(ddir / "poster.jsonl")
    if len(records) < 3:
        raise AppError("Datasetet har för få poster för att delas upp")
    order = list(range(len(records)))
    random.Random(seed).shuffle(order)
    n = len(order)
    n_val = int(round(n * val / total)) if val else 0
    n_test = int(round(n * test / total)) if test else 0
    if val and not n_val:
        n_val = 1
    if test and not n_test:
        n_test = 1
    n_train = n - n_val - n_test
    if n_train < 1:
        raise AppError("Uppdelningen lämnar ingen träningsdata kvar")
    parts = {
        "train": order[:n_train],
        "val": order[n_train:n_train + n_val],
        "test": order[n_train + n_val:],
    }
    for name, idx in parts.items():
        _write_records(ddir / f"{name}.jsonl", (records[i] for i in sorted(idx)))
    meta["uppdelning"] = {
        "train": n_train, "val": n_val, "test": n_test,
        "andel_train": train, "andel_val": val, "andel_test": test,
        "seed": seed, "tid": paths.now_iso(),
    }
    _save_meta(dataset_id, meta)
    return meta


def remove_split(dataset_id: str) -> dict:
    ddir = dataset_dir(dataset_id)
    meta = _load_meta(dataset_id)
    for name in SPLITS:
        (ddir / f"{name}.jsonl").unlink(missing_ok=True)
    meta["uppdelning"] = None
    _save_meta(dataset_id, meta)
    return meta


def iter_records(dataset_id: str, split: str = "alla") -> Iterator[dict]:
    path = split_path(dataset_id, split)
    if not path.exists():
        return
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                yield json.loads(line)


# ------------------------------------------------------- inbyggda dataset
BUILTIN = [
    {
        "fil": "svensk_cybersakerhet.jsonl",
        "id": "svensk-cybersakerhet",
        "namn": "Svensk cybersäkerhet (frågor och svar)",
        "beskrivning": "Frågor och svar på svenska om cybersäkerhet och IT-säkerhet samt enklare "
                       "samtalsfraser. Varje svar förekommer med flera olika frågeformuleringar.",
        "kalla": "Egenproducerat för AI Control Center (genereras av tools/bygg_cybersak_dataset.py)",
        "licens": "CC0 1.0 (fritt att använda)",
        "inbyggt": True,
    },
]


def seed_builtin() -> None:
    """Lägger in medföljande dataset första gången programmet startas."""
    marker = paths.data_root() / ".inbyggda_dataset.json"
    done = paths.read_json(marker, []) or []
    changed = False
    for item in BUILTIN:
        src = paths.RESOURCES / "datasets" / item["fil"]
        if item["id"] in done or not src.exists():
            continue
        if not (paths.datasets_dir() / item["id"]).exists():
            meta = import_dataset(src, item["fil"], item)
            split(meta["id"], 90, 5, 5, 42)
        done.append(item["id"])
        changed = True
    if changed:
        paths.write_json(marker, done)
