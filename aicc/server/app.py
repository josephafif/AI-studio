"""Lokalt HTTP-API + statiska filer för gränssnittet.

Servern lyssnar bara på 127.0.0.1 och bygger enbart på Pythons standardbibliotek.
Den innehåller ingen affärslogik – varje rutt anropar ``aicc.core`` (hantering)
eller ``aicc.engine.inference`` (chatt).
"""
from __future__ import annotations

import json
import mimetypes
import os
import re
import tempfile
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

from .. import paths
from ..core import AppError, NotFound, codegen, datasets, models, sessions, system, training

MAX_UPLOAD = 4 * 1024**3
ROUTES: list[tuple[str, re.Pattern, callable]] = []


def route(method: str, pattern: str):
    regex = re.compile("^" + re.sub(r"<(\w+)>", r"(?P<\1>[^/]+)", pattern) + "$")

    def deco(fn):
        ROUTES.append((method, regex, fn))
        return fn
    return deco


class Raw:
    """Svar som inte är JSON (t.ex. filnedladdning)."""

    def __init__(self, body: bytes, content_type: str, filename: str | None = None):
        self.body, self.content_type, self.filename = body, content_type, filename


class Stream:
    """Server-sent events; ``events`` är en generator av dictar."""

    def __init__(self, events):
        self.events = events


# ------------------------------------------------------------------ system
@route("GET", "/api/system")
def _system(req):
    return system.status()


@route("GET", "/api/overview")
def _overview(req):
    runs = training.list_runs()
    return {
        "system": system.status(),
        "modeller": _models_with_state(runs),
        "aktiv_modell": models.get_active(),
        "dataset": datasets.list_datasets(),
        "korningar": runs[:30],
    }


def _models_with_state(runs=None):
    runs = training.list_runs() if runs is None else runs
    active = {r["model_id"]: r for r in runs if r["aktiv"]}
    out = []
    for m in models.list_models():
        run = active.get(m["id"])
        m["tranar"] = bool(run)
        m["aktiv_korning"] = run["run_id"] if run else None
        out.append(m)
    return out


# ---------------------------------------------------------------- modeller
@route("GET", "/api/presets")
def _presets(req):
    return {"mallar": codegen.PRESETS, "arkitekturer": codegen.ARCHITECTURES,
            "externa_arkitekturer": codegen.EXTERNAL_ARCHITECTURES,
            "standard_traning": training.default_params()}


@route("POST", "/api/models/estimate")
def _estimate(req):
    return codegen.resolve_architecture(req.json())


@route("GET", "/api/models")
def _models(req):
    return {"modeller": _models_with_state(), "aktiv_modell": models.get_active()}


@route("POST", "/api/models")
def _create_model(req):
    model = models.create_model(req.json())
    if not models.get_active():
        models.set_active(model["id"])
    return model


@route("POST", "/api/models/import")
def _import_model(req):
    with req.upload() as tmp:
        return models.import_model(tmp, req.query("namn"))


@route("POST", "/api/models/import-lennart3")
def _import_lennart3(req):
    """Flera filer i samma uppladdning: ?delar=namn:storlek,namn:storlek och filerna efter varandra."""
    parts = []
    for item in (req.query("delar") or "").split(","):
        fname, _, size = item.rpartition(":")
        if fname not in models.LENNART3_FILES or not size.isdigit():
            raise AppError(f"Oväntad fil: {fname or item}")
        parts.append((fname, int(size)))
    with req.upload() as tmp, tempfile.TemporaryDirectory(prefix="aicc-l3-") as folder:
        if tmp.stat().st_size != sum(size for _, size in parts):
            raise AppError("Uppladdningen blev ofullständig – försök igen")
        files = {}
        with open(tmp, "rb") as src:
            for fname, size in parts:
                target = Path(folder) / fname
                with open(target, "wb") as dst:
                    left = size
                    while left:
                        chunk = src.read(min(1 << 20, left))
                        dst.write(chunk)
                        left -= len(chunk)
                files[fname] = target
        return models.import_lennart3(files, req.query("namn"))


@route("POST", "/api/active-model")
def _set_active(req):
    models.set_active(req.json().get("id"))
    return {"aktiv_modell": models.get_active()}


@route("GET", "/api/models/<mid>")
def _model(req, mid):
    m = models.get_model(mid)
    run = training.active_run_for_model(mid)
    m["tranar"] = bool(run)
    m["aktiv_korning"] = run["run_id"] if run else None
    return m


@route("PATCH", "/api/models/<mid>")
def _update_model(req, mid):
    patch = req.json()
    if any(k in patch for k in ("architecture", "n_layers", "n_heads", "context_length",
                                "vocab_size", "d_model", "target_params")):
        if training.active_run_for_model(mid):
            raise AppError("Modellen tränas just nu")
    return models.update_model(mid, patch)


@route("DELETE", "/api/models/<mid>")
def _delete_model(req, mid):
    if training.active_run_for_model(mid):
        raise AppError("Modellen tränas just nu – avbryt träningen innan du tar bort den")
    models.delete_model(mid)
    _inference().clear_cache(mid)
    return {"ok": True}


@route("GET", "/api/models/<mid>/export")
def _export_model(req, mid):
    name, data = models.export_model(mid, req.query("optimerare") == "1")
    return Raw(data, "application/zip", name)


@route("GET", "/api/models/<mid>/file")
def _model_file(req, mid):
    return {"namn": req.query("namn"), "innehall": models.read_file(mid, req.query("namn") or "")}


@route("GET", "/api/models/<mid>/checkpoints")
def _checkpoints(req, mid):
    return {"checkpoints": models.list_checkpoints(mid)}


@route("DELETE", "/api/models/<mid>/checkpoints/<name>")
def _delete_checkpoint(req, mid, name):
    if training.active_run_for_model(mid):
        raise AppError("Modellen tränas just nu")
    models.delete_checkpoint(mid, name)
    return {"checkpoints": models.list_checkpoints(mid)}


# ----------------------------------------------------------------- dataset
@route("GET", "/api/datasets")
def _datasets(req):
    return {"dataset": datasets.list_datasets()}


@route("POST", "/api/datasets/import")
def _import_dataset(req):
    filename = req.query("filnamn") or "dataset.txt"
    info = {k: req.query(k) or "" for k in ("namn", "beskrivning", "kalla", "kall_url", "licens")}
    with req.upload() as tmp:
        return datasets.import_dataset(tmp, filename, info)


@route("GET", "/api/datasets/<did>")
def _dataset(req, did):
    return datasets.get_dataset(did)


@route("PATCH", "/api/datasets/<did>")
def _update_dataset(req, did):
    return datasets.update_dataset(did, req.json())


@route("DELETE", "/api/datasets/<did>")
def _delete_dataset(req, did):
    if any(r["aktiv"] and r.get("dataset_id") == did for r in training.list_runs()):
        raise AppError("Datasetet används i en pågående träning")
    datasets.delete_dataset(did)
    return {"ok": True}


@route("GET", "/api/datasets/<did>/preview")
def _preview(req, did):
    return datasets.preview(did, req.query("del") or "alla", int(req.query("offset") or 0),
                            int(req.query("limit") or 20))


@route("POST", "/api/datasets/<did>/dedupe")
def _dedupe(req, did):
    return datasets.dedupe(did)


@route("POST", "/api/datasets/<did>/split")
def _split(req, did):
    b = req.json()
    if b.get("ta_bort"):
        return datasets.remove_split(did)
    return datasets.split(did, b.get("train", 80), b.get("val", 10), b.get("test", 10), b.get("seed", 42))


# ----------------------------------------------------------------- träning
@route("GET", "/api/training/runs")
def _runs(req):
    return {"korningar": training.list_runs()}


@route("POST", "/api/training/start")
def _start(req):
    b = req.json()
    if not b.get("model_id") or not b.get("dataset_id"):
        raise AppError("Välj både modell och dataset")
    status = training.start_run(b["model_id"], b["dataset_id"], b.get("params"),
                                b.get("resume_from"), bool(b.get("restart")))
    _inference().clear_cache(b["model_id"])
    return status


@route("GET", "/api/training/runs/<rid>")
def _run(req, rid):
    return training.get_run(rid, int(req.query("metrics_from") or 0), int(req.query("log_offset") or 0))


@route("POST", "/api/training/runs/<rid>/<command>")
def _control(req, rid, command):
    if command == "kill":
        return training.kill(rid)
    return training.control(rid, command)


@route("DELETE", "/api/training/runs/<rid>")
def _delete_run(req, rid):
    training.delete_run(rid)
    return {"ok": True}


# ------------------------------------------------------------------- chatt
def _inference():
    from ..engine import inference
    return inference


@route("POST", "/api/chat")
def _chat(req):
    b = req.json()
    if not b.get("model_id"):
        raise AppError("Välj en modell")
    models.model_dir(b["model_id"])
    events = _inference().chat_stream(
        b["model_id"], b.get("messages") or [], float(b.get("temperature", 0.7)),
        int(b.get("max_tokens", 150)), int(b.get("top_k", 40)), b.get("checkpoint"),
        b.get("mode") or "chatt", stop=lambda: req.disconnected)
    return Stream(events)


@route("GET", "/api/sessions")
def _sessions(req):
    return {"sessioner": sessions.list_sessions()}


@route("POST", "/api/sessions")
def _save_session(req):
    return sessions.save_session(req.json())


@route("GET", "/api/sessions/<sid>")
def _session(req, sid):
    return sessions.get_session(sid)


@route("DELETE", "/api/sessions/<sid>")
def _delete_session(req, sid):
    sessions.delete_session(sid)
    return {"ok": True}


# ------------------------------------------------------------------ server
class _Upload:
    def __init__(self, handler):
        self.handler = handler
        self.path = None

    def __enter__(self) -> Path:
        length = int(self.handler.headers.get("Content-Length") or 0)
        if length <= 0:
            raise AppError("Ingen fil skickades")
        if length > MAX_UPLOAD:
            raise AppError("Filen är för stor")
        fd, name = tempfile.mkstemp(prefix="aicc-upload-")
        self.path = Path(name)
        with os.fdopen(fd, "wb") as out:
            remaining = length
            while remaining > 0:
                chunk = self.handler.rfile.read(min(1 << 20, remaining))
                if not chunk:
                    raise AppError("Uppladdningen avbröts")
                out.write(chunk)
                remaining -= len(chunk)
        self.handler._body_read = True
        return self.path

    def __exit__(self, *exc):
        if self.path:
            self.path.unlink(missing_ok=True)
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = "AIControlCenter"
    protocol_version = "HTTP/1.0"
    disconnected = False
    _body_read = False

    def log_message(self, fmt, *args):  # tyst – allt relevant visas i gränssnittet
        if os.environ.get("AICC_DEBUG"):
            super().log_message(fmt, *args)

    # ---- hjälpare som rutterna använder
    def query(self, key: str) -> str | None:
        values = self._query.get(key)
        return values[0] if values else None

    def json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        self._body_read = True
        if length <= 0:
            return {}
        if length > 64 * 1024**2:
            raise AppError("För stor förfrågan")
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise AppError("Ogiltig JSON")
        if not isinstance(data, dict):
            raise AppError("Ogiltig förfrågan")
        return data

    def upload(self) -> _Upload:
        return _Upload(self)

    # ---- skydd: bara anrop från det egna gränssnittet på den här datorn
    def _allowed(self) -> bool:
        host = (self.headers.get("Host") or "").split(":")[0].lower()
        if host not in ("127.0.0.1", "localhost"):
            return False
        origin = self.headers.get("Origin")
        if origin and origin != "null":
            o = urlparse(origin)
            if o.hostname not in ("127.0.0.1", "localhost") or o.port != self.server.server_address[1]:
                return False
        elif self.command != "GET" and self.headers.get("Sec-Fetch-Site") not in (None, "same-origin", "none"):
            return False
        return True

    def _send(self, code: int, body: bytes, content_type: str, extra: dict | None = None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def _dispatch(self):
        parsed = urlparse(self.path)
        self._query = parse_qs(parsed.query)
        path = unquote(parsed.path)
        try:
            if not self._allowed():
                return self._json(403, {"fel": "Åtkomst nekad"})
            if not path.startswith("/api/"):
                if self.command != "GET":
                    return self._json(405, {"fel": "Metoden stöds inte"})
                return self._static(path)
            for method, regex, fn in ROUTES:
                if method != self.command:
                    continue
                match = regex.match(path)
                if match:
                    result = fn(self, **match.groupdict())
                    if isinstance(result, Stream):
                        return self._stream(result)
                    if isinstance(result, Raw):
                        extra = {}
                        if result.filename:
                            extra["Content-Disposition"] = f'attachment; filename="{result.filename}"'
                        return self._send(200, result.body, result.content_type, extra)
                    return self._json(200, result)
            self._json(404, {"fel": "Okänd adress"})
        except NotFound as exc:
            self._json(404, {"fel": str(exc)})
        except (AppError, ValueError) as exc:
            self._json(400, {"fel": str(exc)})
        except (BrokenPipeError, ConnectionError):
            pass
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc()
            try:
                self._json(500, {"fel": f"Internt fel: {exc}"})
            except Exception:  # noqa: BLE001
                pass

    def _stream(self, stream: Stream):
        events = stream.events
        try:
            first = next(events)  # fel innan första händelsen blir vanliga JSON-fel
        except StopIteration:
            first = None
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        def emit(event):
            self.wfile.write(b"data: " + json.dumps(event, ensure_ascii=False).encode("utf-8") + b"\n\n")
            self.wfile.flush()
        try:
            if first is not None:
                emit(first)
            for event in events:
                emit(event)
        except (BrokenPipeError, ConnectionError, OSError):
            self.disconnected = True
            events.close()
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc()
            try:
                emit({"typ": "fel", "fel": str(exc)})
            except Exception:  # noqa: BLE001
                pass

    def _static(self, path: str):
        rel = "index.html" if path in ("", "/") else path.lstrip("/")
        target = (paths.UI_DIR / rel).resolve()
        if paths.UI_DIR.resolve() not in target.parents or not target.is_file():
            return self._json(404, {"fel": "Filen finns inte"})
        ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if target.suffix == ".js":
            ctype = "text/javascript"
        if ctype.startswith("text/") or ctype == "application/json":
            ctype += "; charset=utf-8"
        self._send(200, target.read_bytes(), ctype)

    do_GET = do_POST = do_PATCH = do_DELETE = _dispatch


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def create_server(port: int = 0) -> Server:
    """Skapar servern (port 0 = välj en ledig port). Förbereder även datamappen."""
    paths.data_root().mkdir(parents=True, exist_ok=True)
    datasets.seed_builtin()
    models.seed_examples()
    server = Server(("127.0.0.1", port), Handler)
    threading.Thread(target=system.devices, daemon=True).start()
    return server
