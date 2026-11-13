"""Sparade testsessioner från chatten (en JSON-fil per session)."""
from __future__ import annotations

from datetime import datetime
from pathlib import Path

from .. import paths
from . import AppError, NotFound


def _path(session_id: str) -> Path:
    return paths.sessions_dir() / f"{paths.safe_id(session_id)}.json"


def list_sessions() -> list[dict]:
    out = []
    for f in paths.sessions_dir().glob("*.json"):
        s = paths.read_json(f)
        if not s:
            continue
        out.append({
            "id": s["id"], "namn": s.get("namn"), "skapad": s.get("skapad"),
            "andrad": s.get("andrad"), "modeller": s.get("modeller", []),
            "antal_meddelanden": sum(len(p.get("meddelanden", [])) for p in s.get("paneler", [])),
        })
    out.sort(key=lambda s: s.get("andrad") or "", reverse=True)
    return out


def get_session(session_id: str) -> dict:
    s = paths.read_json(_path(session_id))
    if not s:
        raise NotFound("Sessionen finns inte")
    return s


def save_session(data: dict) -> dict:
    """Skapar en ny session, eller uppdaterar en befintlig om ``id`` anges."""
    panels = data.get("paneler")
    if not isinstance(panels, list) or not panels:
        raise AppError("Sessionen innehåller inga samtal")
    now = paths.now_iso()
    existing = None
    if data.get("id"):
        existing = paths.read_json(_path(data["id"]))
    name = str(data.get("namn") or "").strip() or f"Testsession {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    if existing:
        session_id, created = existing["id"], existing.get("skapad", now)
    else:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        session_id, n = stamp, 2
        while _path(session_id).exists():
            session_id = f"{stamp}-{n}"
            n += 1
        created = now
    clean_panels = []
    for p in panels[:8]:
        msgs = [{"role": m.get("role"), "content": str(m.get("content", "")), "info": m.get("info")}
                for m in (p.get("meddelanden") or []) if m.get("role") in ("user", "assistant")]
        clean_panels.append({"model_id": p.get("model_id"), "modell": p.get("modell"),
                             "checkpoint": p.get("checkpoint"), "meddelanden": msgs})
    session = {
        "id": session_id, "namn": name[:200], "skapad": created, "andrad": now,
        "installningar": data.get("installningar") or {},
        "modeller": [p.get("modell") for p in clean_panels if p.get("modell")],
        "paneler": clean_panels,
    }
    paths.write_json(_path(session_id), session)
    return session


def delete_session(session_id: str) -> None:
    path = _path(session_id)
    if not path.exists():
        raise NotFound("Sessionen finns inte")
    path.unlink()
