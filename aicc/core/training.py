"""Körningshantering: startar träningsprocesser och följer dem via filer.

Kontrollpanelen tränar aldrig själv. Den skapar en körningsmapp under
``data/korningar/<id>/``, startar ``aicc.engine.train_worker`` som en egen
process och läser sedan status, mätvärden och logg från mappen. Träningen
fortsätter därför även om gränssnittet stängs.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

from .. import paths
from . import AppError, NotFound, datasets, models

try:
    import psutil
except ImportError:  # pragma: no cover
    psutil = None

ACTIVE_STATES = ("starting", "preparing", "running", "paused", "stopping")

PARAM_SPEC = {
    # namn: (typ, min, max, standard)
    "max_steps": (int, 1, 10_000_000, 2000),
    "batch_size": (int, 1, 4096, 32),
    "learning_rate": (float, 1e-7, 1.0, 1e-3),
    "weight_decay": (float, 0.0, 1.0, 0.01),
    "warmup_steps": (int, 0, 1_000_000, 100),
    "grad_clip": (float, 0.0, 100.0, 1.0),
    "eval_interval": (int, 1, 1_000_000, 200),
    "eval_batches": (int, 1, 1000, 20),
    "checkpoint_interval": (int, 1, 10_000_000, 500),
    "keep_checkpoints": (int, 1, 1000, 5),
    "log_interval": (int, 1, 100_000, 20),
    "seed": (int, 0, 2**31 - 1, 1337),
    "threads": (int, 0, 1024, 0),
}

_procs: dict[str, subprocess.Popen] = {}
_lock = threading.Lock()


def default_params() -> dict:
    return {**{k: v[3] for k, v in PARAM_SPEC.items()}, "device": "auto"}


def _validate_params(params: dict) -> dict:
    out = default_params()
    for key, (typ, lo, hi, _) in PARAM_SPEC.items():
        if key not in params or params[key] in ("", None):
            continue
        try:
            value = typ(params[key])
        except (TypeError, ValueError):
            raise AppError(f"Ogiltigt värde för {key}")
        if not lo <= value <= hi:
            raise AppError(f"{key} måste vara mellan {lo} och {hi}")
        out[key] = value
    device = str(params.get("device") or "auto").lower()
    if device not in ("auto", "cpu", "mps") and not device.startswith("cuda"):
        raise AppError("Okänd enhet")
    out["device"] = device
    return out


def run_dir(run_id: str) -> Path:
    path = paths.runs_dir() / paths.safe_id(run_id)
    if not (path / "config.json").exists():
        raise NotFound(f"Körningen '{run_id}' finns inte")
    return path


def _alive(run_id: str, pid) -> bool:
    proc = _procs.get(run_id)
    if proc is not None:
        return proc.poll() is None
    if not pid:
        return False
    if psutil is None:
        return True
    try:
        p = psutil.Process(int(pid))
        return p.is_running() and p.status() != psutil.STATUS_ZOMBIE
    except (psutil.Error, ValueError):
        return False


def _status(run_id: str) -> dict:
    rdir = run_dir(run_id)
    cfg = paths.read_json(rdir / "config.json", {}) or {}
    status = paths.read_json(rdir / "status.json") or {
        "run_id": run_id, "model_id": cfg.get("model_id"), "dataset_id": cfg.get("dataset_id"),
        "state": "starting", "message": "Startar träningsprocessen …", "step": 0,
        "max_steps": (cfg.get("params") or {}).get("max_steps", 0), "started": cfg.get("skapad"),
        "pid": cfg.get("pid"),
    }
    if status.get("state") in ACTIVE_STATES and not _alive(run_id, status.get("pid") or cfg.get("pid")):
        # Processen kan ha hunnit skriva sin slutstatus precis efter att vi läste – läs om en gång.
        time.sleep(0.15)
        fresh = paths.read_json(rdir / "status.json") or status
        if fresh.get("state") in ACTIVE_STATES:
            tail = ""
            try:
                tail = (rdir / "process.log").read_text(encoding="utf-8", errors="replace")[-600:].strip()
            except OSError:
                pass
            fresh.update(state="failed", message="Träningsprocessen avslutades oväntat",
                         error=tail or "Processen avslutades utan felmeddelande")
            paths.write_json(rdir / "status.json", fresh)
        status = fresh
    status["model_namn"] = cfg.get("model_namn")
    status["dataset_namn"] = cfg.get("dataset_namn")
    status["resume_from"] = cfg.get("resume_from")
    status["params"] = cfg.get("params")
    status["aktiv"] = status.get("state") in ACTIVE_STATES
    return status


def list_runs() -> list[dict]:
    out = []
    for d in paths.runs_dir().iterdir():
        if d.is_dir() and (d / "config.json").exists():
            try:
                out.append(_status(d.name))
            except AppError:
                continue
    out.sort(key=lambda s: s.get("started") or "", reverse=True)
    return out


def active_run_for_model(model_id: str) -> dict | None:
    return next((r for r in list_runs() if r["aktiv"] and r.get("model_id") == model_id), None)


def get_run(run_id: str, metrics_from: int = 0, log_offset: int = 0) -> dict:
    rdir = run_dir(run_id)
    status = _status(run_id)
    metrics, total = [], 0
    mpath = rdir / "metrics.jsonl"
    if mpath.exists():
        with open(mpath, "r", encoding="utf-8") as fh:
            for line in fh:
                if not line.endswith("\n"):
                    break  # halvskriven rad
                if total >= metrics_from:
                    try:
                        metrics.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
                total += 1
    log_text, new_offset = "", log_offset
    lpath = rdir / "train.log"
    if lpath.exists():
        size = lpath.stat().st_size
        if log_offset > size:
            log_offset = 0
        with open(lpath, "rb") as fh:
            fh.seek(max(log_offset, size - 200_000))
            log_text = fh.read().decode("utf-8", errors="replace")
        new_offset = size
    return {"status": status, "metrics": metrics, "metrics_total": total,
            "log": log_text, "log_offset": new_offset}


def start_run(model_id: str, dataset_id: str, params: dict | None = None,
              resume_from: str | None = None, restart: bool = False) -> dict:
    with _lock:
        cfg = models.load_config(model_id)
        ds = datasets.get_dataset(dataset_id)
        if active_run_for_model(model_id):
            raise AppError(f"'{cfg['namn']}' tränas redan. Vänta eller avbryt den körningen först.")
        clean = _validate_params(params or {})
        ckpts = models.list_checkpoints(model_id)
        mdir = models.model_dir(model_id)

        if resume_from in ("senaste", "latest"):
            if not ckpts:
                raise AppError("Modellen har inga checkpoints att fortsätta från")
            resume_from = ckpts[-1]["fil"]
        elif resume_from in ("basta", "best"):
            best = next((c for c in ckpts if c["bast"]), None)
            if not best:
                raise AppError("Modellen har ingen checkpoint med valideringsvärde")
            resume_from = best["fil"]
        elif resume_from:
            if not any(c["fil"] == resume_from for c in ckpts):
                raise NotFound("Checkpointen finns inte")
        else:
            resume_from = None
            if ckpts and not restart:
                raise AppError("Modellen är redan tränad. Välj en checkpoint att fortsätta från, "
                               "eller välj att börja om från början.")
            if ckpts or (mdir / "tokenizer.json").exists():
                # Börja om: gamla vikter och tokenizer tas bort så att allt byggs från det nya datat.
                shutil.rmtree(mdir / "checkpoints", ignore_errors=True)
                (mdir / "checkpoints").mkdir(exist_ok=True)
                (mdir / "tokenizer.json").unlink(missing_ok=True)

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        run_id = paths.unique_id(paths.runs_dir(), f"{stamp}-{model_id}", "korning")
        rdir = paths.runs_dir() / run_id
        rdir.mkdir(parents=True)
        run_cfg = {
            "run_id": run_id, "model_id": model_id, "model_namn": cfg["namn"],
            "dataset_id": dataset_id, "dataset_namn": ds["namn"],
            "resume_from": resume_from, "params": clean, "skapad": paths.now_iso(),
        }
        paths.write_json(rdir / "config.json", run_cfg)

        env = dict(os.environ)
        env["AICC_DATA"] = str(paths.data_root())
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        kwargs = {}
        if os.name == "nt":
            kwargs["creationflags"] = (subprocess.CREATE_NO_WINDOW
                                       | subprocess.CREATE_NEW_PROCESS_GROUP)
        else:
            kwargs["start_new_session"] = True
        python = sys.executable
        if os.name == "nt" and python.lower().endswith("pythonw.exe"):
            candidate = Path(python).with_name("python.exe")
            if candidate.exists():
                python = str(candidate)
        out = open(rdir / "process.log", "w", encoding="utf-8")
        try:
            proc = subprocess.Popen(
                [python, str(paths.APP_ROOT / "main.py"), "--worker", str(rdir)],
                cwd=str(paths.APP_ROOT), env=env, stdin=subprocess.DEVNULL,
                stdout=out, stderr=subprocess.STDOUT, **kwargs)
        finally:
            out.close()
        _procs[run_id] = proc
        run_cfg["pid"] = proc.pid
        paths.write_json(rdir / "config.json", run_cfg)
    return _status(run_id)


def control(run_id: str, command: str) -> dict:
    if command not in ("pause", "resume", "stop"):
        raise AppError("Okänt kommando")
    rdir = run_dir(run_id)
    status = _status(run_id)
    if not status["aktiv"]:
        raise AppError("Körningen är inte aktiv")
    paths.write_json(rdir / "control.json", {"command": command, "tid": paths.now_iso()})
    return status


def kill(run_id: str) -> dict:
    """Tvingar ner en träningsprocess som inte svarar på stopp."""
    rdir = run_dir(run_id)
    status = _status(run_id)
    if status["aktiv"]:
        proc = _procs.get(run_id)
        try:
            if proc is not None:
                proc.kill()
                proc.wait(timeout=5)
            elif psutil is not None and status.get("pid"):
                psutil.Process(int(status["pid"])).kill()
        except Exception:  # noqa: BLE001
            pass
        raw = paths.read_json(rdir / "status.json") or status
        raw.update(state="stopped", message="Tvångsavslutad", eta=None)
        paths.write_json(rdir / "status.json", raw)
    return _status(run_id)


def delete_run(run_id: str) -> None:
    rdir = run_dir(run_id)
    if _status(run_id)["aktiv"]:
        raise AppError("Aktiva körningar kan inte tas bort – avbryt träningen först")
    _procs.pop(run_id, None)
    shutil.rmtree(rdir, ignore_errors=True)
