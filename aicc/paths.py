"""Sökvägar och små filhjälpare som delas av alla lager."""
from __future__ import annotations

import json
import os
import re
import time
import unicodedata
from datetime import datetime
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parent.parent
RESOURCES = APP_ROOT / "resources"
UI_DIR = Path(__file__).resolve().parent / "ui"


def data_root() -> Path:
    """Rotmappen för all användardata (modeller, dataset, körningar, sessioner)."""
    root = Path(os.environ.get("AICC_DATA") or (APP_ROOT / "data")).resolve()
    return root


def models_dir() -> Path:
    return _ensure(data_root() / "modeller")


def datasets_dir() -> Path:
    return _ensure(data_root() / "dataset")


def runs_dir() -> Path:
    return _ensure(data_root() / "korningar")


def sessions_dir() -> Path:
    return _ensure(data_root() / "sessioner")


def _ensure(p: Path) -> Path:
    p.mkdir(parents=True, exist_ok=True)
    return p


def now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def slugify(name: str, fallback: str = "objekt") -> str:
    text = name.strip().lower()
    for src, dst in (("å", "a"), ("ä", "a"), ("ö", "o")):
        text = text.replace(src, dst)
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text[:48] or fallback


def unique_id(parent: Path, name: str, fallback: str = "objekt") -> str:
    base = slugify(name, fallback)
    candidate, n = base, 2
    while (parent / candidate).exists():
        candidate = f"{base}-{n}"
        n += 1
    return candidate


_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,80}$")


def safe_id(value: str) -> str:
    """Validerar ett id som kommer utifrån så att det aldrig kan lämna datamappen."""
    if not isinstance(value, str) or not _ID_RE.match(value):
        raise ValueError(f"Ogiltigt id: {value!r}")
    return value


def read_json(path: Path, default=None):
    """Läser JSON. Tål att filen byts ut samtidigt av en annan process (Windows)."""
    for attempt in range(6):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except FileNotFoundError:
            return default
        except (PermissionError, json.JSONDecodeError):
            time.sleep(0.03 * (attempt + 1))
    return default


def write_json(path: Path, obj) -> None:
    """Atomisk skrivning: skriv till tempfil och byt sedan namn."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2)
    for attempt in range(20):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:  # läsare har filen öppen (Windows)
            time.sleep(0.02 * (attempt + 1))
    os.replace(tmp, path)


def dir_size(path: Path) -> int:
    total = 0
    for p in path.rglob("*"):
        try:
            if p.is_file():
                total += p.stat().st_size
        except OSError:
            pass
    return total
