"""Modellhantering: skapa, lista, konfigurera, importera, exportera och ta bort modeller.

Varje modell är en egen mapp under ``data/modeller/<id>/``:

    config.json            metadata + arkitektur
    model.py               genererad modellkod
    README.md              modellkort
    tokenizer.json         skapas vid första träningen
    traningshistorik.json  en rad per träningskörning
    checkpoints/           ckpt_<steg>.pt (+ .json med mätvärden), optimizer.pt
"""
from __future__ import annotations

import io
import shutil
import zipfile
from pathlib import Path

from .. import paths
from . import AppError, NotFound, codegen

DEFAULT_GENERATION = {"temperature": 0.7, "max_tokens": 150, "top_k": 40}
_META_FIELDS = ("namn", "beskrivning", "anvandningsomrade", "sprak")
_ARCH_FIELDS = ("architecture", "target_params", "d_model", "n_layers", "n_heads",
                "context_length", "vocab_size", "dropout")
_IMPORT_SUFFIXES = {".json", ".md", ".py", ".pt", ".txt"}


def model_dir(model_id: str) -> Path:
    path = paths.models_dir() / paths.safe_id(model_id)
    if not (path / "config.json").exists():
        raise NotFound(f"Modellen '{model_id}' finns inte")
    return path


def models_dir_exists(model_id: str) -> bool:
    try:
        return (paths.models_dir() / paths.safe_id(model_id) / "config.json").exists()
    except ValueError:
        return False


def load_config(model_id: str) -> dict:
    cfg = paths.read_json(model_dir(model_id) / "config.json")
    if not cfg:
        raise NotFound(f"Modellen '{model_id}' saknar giltig config.json")
    return cfg


# ------------------------------------------------------------- checkpoints
def list_checkpoints(model_id: str) -> list[dict]:
    ckpt_dir = model_dir(model_id) / "checkpoints"
    out = []
    for pt in sorted(ckpt_dir.glob("ckpt_*.pt")):
        meta = paths.read_json(pt.with_suffix(".json"), {}) or {}
        try:
            step = int(meta.get("step", pt.stem.split("_")[1]))
        except (ValueError, IndexError):
            continue
        out.append({
            "fil": pt.name,
            "step": step,
            "train_loss": meta.get("train_loss"),
            "val_loss": meta.get("val_loss"),
            "tid": meta.get("tid"),
            "run_id": meta.get("run_id"),
            "dataset": meta.get("dataset"),
            "storlek": pt.stat().st_size,
        })
    out.sort(key=lambda c: c["step"])
    vals = [c for c in out if c["val_loss"] is not None]
    best = min(vals, key=lambda c: c["val_loss"])["fil"] if vals else None
    for c in out:
        c["bast"] = c["fil"] == best
        c["senaste"] = c is out[-1]
    return out


def delete_checkpoint(model_id: str, filename: str) -> None:
    ckpt_dir = model_dir(model_id) / "checkpoints"
    if "/" in filename or "\\" in filename or not filename.startswith("ckpt_") or not filename.endswith(".pt"):
        raise AppError("Ogiltigt checkpoint-namn")
    pt = ckpt_dir / filename
    if not pt.exists():
        raise NotFound("Checkpointen finns inte")
    pt.unlink()
    pt.with_suffix(".json").unlink(missing_ok=True)


# ------------------------------------------------------------------ läsning
def _summary(model_id: str, detailed: bool = False) -> dict:
    mdir = model_dir(model_id)
    cfg = load_config(model_id)
    ckpts = list_checkpoints(model_id)
    history = paths.read_json(mdir / "traningshistorik.json", []) or []
    latest = ckpts[-1] if ckpts else None
    info = {
        **cfg,
        "id": model_id,
        "generering": {**DEFAULT_GENERATION, **(cfg.get("generering") or {})},
        "tranad": bool(ckpts),
        "steg": latest["step"] if latest else 0,
        "senaste_loss": latest["train_loss"] if latest else None,
        "senaste_val_loss": latest["val_loss"] if latest else None,
        "antal_checkpoints": len(ckpts),
        "antal_korningar": len(history),
        "har_tokenizer": (mdir / "tokenizer.json").exists(),
    }
    if detailed:
        info["checkpoints"] = ckpts
        info["historik"] = history
        info["mapp"] = str(mdir)
        info["storlek"] = paths.dir_size(mdir)
        info["filer"] = sorted(
            ({"namn": p.relative_to(mdir).as_posix(), "storlek": p.stat().st_size}
             for p in mdir.rglob("*") if p.is_file() and "__pycache__" not in p.parts),
            key=lambda f: f["namn"],
        )
    return info


def list_models() -> list[dict]:
    out = []
    for d in sorted(paths.models_dir().iterdir()):
        if d.is_dir() and (d / "config.json").exists():
            try:
                out.append(_summary(d.name))
            except AppError:
                continue
    out.sort(key=lambda m: m.get("skapad", ""))
    return out


def get_model(model_id: str) -> dict:
    return _summary(model_id, detailed=True)


def read_file(model_id: str, name: str) -> str:
    mdir = model_dir(model_id)
    target = (mdir / name).resolve()
    if mdir.resolve() not in target.parents or target.suffix not in {".py", ".json", ".md"}:
        raise AppError("Filen kan inte visas")
    if not target.exists():
        raise NotFound("Filen finns inte")
    return target.read_text(encoding="utf-8", errors="replace")[:400_000]


# ----------------------------------------------------------------- skrivning
def _clean_meta(spec: dict) -> dict:
    meta = {}
    for key in _META_FIELDS:
        if key in spec:
            meta[key] = str(spec[key] or "").strip()[:2000]
    return meta


def _write_generated(mdir: Path, cfg: dict) -> None:
    (mdir / "model.py").write_text(
        codegen.generate_model_code(cfg["namn"], cfg["arkitektur"]), encoding="utf-8")
    (mdir / "README.md").write_text(codegen.generate_readme(cfg), encoding="utf-8")


def create_model(spec: dict) -> dict:
    meta = _clean_meta(spec)
    name = meta.get("namn", "")
    if not name:
        raise AppError("Modellen måste ha ett namn")
    if any(m["namn"].lower() == name.lower() for m in list_models()):
        raise AppError(f"Det finns redan en modell som heter '{name}'")
    arch = codegen.resolve_architecture(spec)
    model_id = paths.unique_id(paths.models_dir(), name, "modell")
    mdir = paths.models_dir() / model_id
    (mdir / "checkpoints").mkdir(parents=True)
    now = paths.now_iso()
    cfg = {
        "id": model_id,
        "namn": name,
        "beskrivning": meta.get("beskrivning", ""),
        "anvandningsomrade": meta.get("anvandningsomrade", ""),
        "sprak": meta.get("sprak", ""),
        "ursprung": "skapad",
        "skapad": now,
        "andrad": now,
        "arkitektur": arch,
        "generering": dict(DEFAULT_GENERATION),
    }
    if isinstance(spec.get("training"), dict) or spec.get("dataset"):
        # Mallens förslag på dataset och träningsparametrar (förifylls i träningsvyn)
        cfg["forslag"] = {"dataset": spec.get("dataset"), "traning": spec.get("training") or {}}
    paths.write_json(mdir / "config.json", cfg)
    paths.write_json(mdir / "traningshistorik.json", [])
    _write_generated(mdir, cfg)
    return get_model(model_id)


def update_model(model_id: str, patch: dict) -> dict:
    """Byter namn, ändrar metadata/genereringsinställningar – och arkitektur om modellen är otränad."""
    mdir = model_dir(model_id)
    cfg = load_config(model_id)
    meta = _clean_meta(patch)
    if "namn" in meta:
        if not meta["namn"]:
            raise AppError("Modellen måste ha ett namn")
        if any(m["namn"].lower() == meta["namn"].lower() and m["id"] != model_id for m in list_models()):
            raise AppError(f"Det finns redan en modell som heter '{meta['namn']}'")
    cfg.update(meta)

    if isinstance(patch.get("generering"), dict):
        gen = {**DEFAULT_GENERATION, **(cfg.get("generering") or {})}
        g = patch["generering"]
        try:
            if "temperature" in g:
                gen["temperature"] = min(2.0, max(0.0, float(g["temperature"])))
            if "max_tokens" in g:
                gen["max_tokens"] = min(4096, max(1, int(g["max_tokens"])))
            if "top_k" in g:
                gen["top_k"] = min(1000, max(0, int(g["top_k"])))
        except (TypeError, ValueError):
            raise AppError("Ogiltiga genereringsinställningar")
        cfg["generering"] = gen

    arch_patch = {k: patch[k] for k in _ARCH_FIELDS if k in patch}
    if arch_patch and codegen.is_external(cfg["arkitektur"]):
        arch_patch = {}  # importerad färdig modell – arkitekturen är fast
    if arch_patch:
        old = cfg["arkitektur"]
        merged = {**{k: old.get(k) for k in _ARCH_FIELDS}, **arch_patch}
        if "target_params" in arch_patch and "d_model" not in arch_patch:
            merged["d_model"] = None
        elif "d_model" not in arch_patch and "target_params" not in arch_patch and old.get("target_params"):
            merged["d_model"] = None  # bredden följer fortfarande målparametrarna
        new = codegen.resolve_architecture(merged)
        if any(new[k] != old.get(k) for k in ("architecture", "n_layers", "n_heads", "d_model",
                                                "context_length", "vocab_size")):
            if list_checkpoints(model_id) or (mdir / "tokenizer.json").exists():
                raise AppError("Arkitekturen kan bara ändras innan modellen har tränats. "
                               "Skapa en ny modell för en annan arkitektur.")
        cfg["arkitektur"] = new

    cfg["andrad"] = paths.now_iso()
    paths.write_json(mdir / "config.json", cfg)
    _write_generated(mdir, cfg)
    return get_model(model_id)


def delete_model(model_id: str) -> None:
    shutil.rmtree(model_dir(model_id))
    if get_active() == model_id:
        set_active(None)


# -------------------------------------------------------- export och import
def export_model(model_id: str, include_optimizer: bool = False) -> tuple[str, bytes]:
    mdir = model_dir(model_id)
    cfg = load_config(model_id)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for p in sorted(mdir.rglob("*")):
            if not p.is_file() or "__pycache__" in p.parts:
                continue
            if p.name == "optimizer.pt" and not include_optimizer:
                continue
            zf.write(p, p.relative_to(mdir).as_posix())
    return f"{paths.slugify(cfg['namn'], 'modell')}.aicc-modell.zip", buf.getvalue()


def import_model(zip_path: Path, name: str | None = None) -> dict:
    """Importerar en exporterad modell (.zip).

    Modellkoden i arkivet körs aldrig: ``model.py`` genereras om från config.json.
    """
    try:
        zf = zipfile.ZipFile(zip_path)
    except zipfile.BadZipFile:
        raise AppError("Filen är inte ett giltigt zip-arkiv")
    with zf:
        names = [n for n in zf.namelist() if not n.endswith("/")]
        l3 = [n for n in names if Path(n).name == "lennart3.pt"]
        if l3:
            return _import_lennart3_zip(zf, names, name)
        cfg_names = [n for n in names if n == "config.json" or n.endswith("/config.json")]
        if not cfg_names:
            raise AppError("Arkivet innehåller ingen config.json – är det en exporterad modell?")
        cfg_name = min(cfg_names, key=len)
        prefix = cfg_name[: -len("config.json")]
        try:
            import json
            cfg = json.loads(zf.read(cfg_name).decode("utf-8"))
            if codegen.is_external(cfg["arkitektur"]):
                arch = codegen.resolve_external(cfg["arkitektur"])
            else:
                arch = codegen.resolve_architecture(
                    {k: cfg["arkitektur"].get(k) for k in _ARCH_FIELDS if k != "target_params"})
        except AppError:
            raise
        except Exception:
            raise AppError("config.json i arkivet kunde inte läsas")

        base_name = (name or cfg.get("namn") or "Importerad modell").strip()
        existing = {m["namn"].lower() for m in list_models()}
        final, n = base_name, 2
        while final.lower() in existing:
            final = f"{base_name} ({n})"
            n += 1

        model_id = paths.unique_id(paths.models_dir(), final, "modell")
        mdir = paths.models_dir() / model_id
        (mdir / "checkpoints").mkdir(parents=True)
        try:
            for member in names:
                if not member.startswith(prefix):
                    continue
                rel = Path(member[len(prefix):])
                if rel.is_absolute() or ".." in rel.parts or rel.suffix not in _IMPORT_SUFFIXES:
                    continue
                if len(rel.parts) > 2 or (len(rel.parts) == 2 and rel.parts[0] != "checkpoints"):
                    continue
                target = mdir / rel
                with zf.open(member) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)
        except Exception:
            shutil.rmtree(mdir, ignore_errors=True)
            raise AppError("Arkivet kunde inte packas upp")

    if not codegen.is_external(arch):
        arch["target_params"] = (cfg.get("arkitektur") or {}).get("target_params")
    now = paths.now_iso()
    new_cfg = {
        "id": model_id,
        "namn": final,
        "beskrivning": str(cfg.get("beskrivning", "")),
        "anvandningsomrade": str(cfg.get("anvandningsomrade", "")),
        "sprak": str(cfg.get("sprak", "")),
        "ursprung": "importerad",
        "skapad": cfg.get("skapad") or now,
        "importerad": now,
        "andrad": now,
        "arkitektur": arch,
        "generering": {**DEFAULT_GENERATION, **(cfg.get("generering") or {})},
    }
    paths.write_json(mdir / "config.json", new_cfg)
    if not (mdir / "traningshistorik.json").exists():
        paths.write_json(mdir / "traningshistorik.json", [])
    _write_generated(mdir, new_cfg)
    return get_model(model_id)


# ------------------------------------------------------- Lennart 3 (Kaggle)
LENNART3_FILES = ("lennart3.pt", "tokenizer.json", "config.json", "status.json")


def _import_lennart3_zip(zf: zipfile.ZipFile, names: list[str], name: str | None) -> dict:
    """Zip med lennart3.pt och tokenizer.json (t.ex. mappen lennart3/ från Kaggle)."""
    import tempfile
    pt_name = min((n for n in names if Path(n).name == "lennart3.pt"), key=len)
    folder = pt_name[: -len("lennart3.pt")]
    with tempfile.TemporaryDirectory(prefix="aicc-l3-") as tmp:
        files = {}
        for fname in LENNART3_FILES:
            member = folder + fname
            if member in names:
                target = Path(tmp) / fname
                with zf.open(member) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                files[fname] = target
        return import_lennart3(files, name)


def import_lennart3(files: dict[str, Path], name: str | None = None) -> dict:
    """Importerar en färdigtränad Lennart 3 från Kaggle-träningen (moln/lennart3).

    ``files`` innehåller sökvägar till lennart3.pt och tokenizer.json, och valfritt status.json.
    Vikterna läses med ``weights_only=True`` och model.py genereras av panelen.
    """
    import json
    if "lennart3.pt" not in files or "tokenizer.json" not in files:
        raise AppError("Välj både lennart3.pt och tokenizer.json från Kaggle-körningens Output")
    try:
        tok = json.loads(Path(files["tokenizer.json"]).read_text(encoding="utf-8"))
        added = {t.get("content") for t in tok.get("added_tokens", [])}
    except (OSError, ValueError, AttributeError):
        raise AppError("tokenizer.json kunde inte läsas")
    if not {"<|user|>", "<|assistant|>", "<|end|>"} <= added:
        raise AppError("tokenizer.json hör inte till en Lennart 3-modell (chattokens saknas)")

    from ..engine import extern  # PyTorch behövs för att läsa vikterna
    info = extern.read_lennart3(Path(files["lennart3.pt"]))
    arch = codegen.resolve_external(info["arkitektur"])
    vocab_in_tok = len(tok.get("model", {}).get("vocab", {})) or arch["vocab_size"]
    if vocab_in_tok > arch["vocab_size"]:
        raise AppError("tokenizer.json har större ordförråd än modellen – fel tokenizer?")
    status = {}
    if "status.json" in files:
        status = paths.read_json(Path(files["status.json"]), {}) or {}
    step = int(status.get("step") or 0)

    base_name = (name or info.get("namn") or "Lennart 3").strip()
    existing = {m["namn"].lower() for m in list_models()}
    final, n = base_name, 2
    while final.lower() in existing:
        final = f"{base_name} ({n})"
        n += 1
    model_id = paths.unique_id(paths.models_dir(), final, "modell")
    mdir = paths.models_dir() / model_id
    (mdir / "checkpoints").mkdir(parents=True)
    try:
        shutil.copyfile(files["tokenizer.json"], mdir / "tokenizer.json")
        ckpt = mdir / "checkpoints" / f"ckpt_{step:07d}.pt"
        shutil.copyfile(files["lennart3.pt"], ckpt)
        paths.write_json(ckpt.with_suffix(".json"), {
            "step": step, "train_loss": None, "val_loss": status.get("val_chat"),
            "val_loss_lopttext": status.get("val_web"), "tid": status.get("time") or paths.now_iso(),
            "dataset": "Wikipedia, FineWeb-2 och svenska samtal (Kaggle)",
            "tokens": status.get("tokens_seen")})
    except Exception:
        shutil.rmtree(mdir, ignore_errors=True)
        raise AppError("Modellfilerna kunde inte kopieras – finns det plats på disken?")
    now = paths.now_iso()
    new_cfg = {
        "id": model_id, "namn": final,
        "beskrivning": "Svensk GPT tränad på Kaggle med 2× T4 på Wikipedia, FineWeb-2 och svenska samtal. "
                       "Svarar på frågor och kan extra mycket om cybersäkerhet.",
        "anvandningsomrade": "Allmän assistent och cybersäkerhet", "sprak": "Svenska",
        "ursprung": "importerad", "format": "lennart3", "skapad": now, "importerad": now, "andrad": now,
        "arkitektur": arch,
        "generering": {**DEFAULT_GENERATION, "temperature": 0.6, "max_tokens": 200, "top_k": 40},
    }
    paths.write_json(mdir / "config.json", new_cfg)
    history = []
    if status:
        history.append({"run_id": "kaggle", "dataset": "Kaggle: Wikipedia, FineWeb-2 och samtal",
                        "start": status.get("time"), "slut": status.get("time"), "status": "completed",
                        "steg_fran": 0, "steg_till": step, "loss": status.get("val_web"),
                        "val_loss": status.get("val_chat"), "enhet": "Kaggle 2× T4",
                        "sekunder": None, "tokens": status.get("tokens_seen")})
    paths.write_json(mdir / "traningshistorik.json", history)
    _write_generated(mdir, new_cfg)
    return get_model(model_id)


# -------------------------------------------------------------- aktiv modell
def _settings_path() -> Path:
    return paths.data_root() / "installningar.json"


def get_active() -> str | None:
    active = (paths.read_json(_settings_path(), {}) or {}).get("aktiv_modell")
    if active and (paths.models_dir() / active / "config.json").exists():
        return active
    return None


def set_active(model_id: str | None) -> None:
    if model_id is not None:
        model_dir(model_id)
    settings = paths.read_json(_settings_path(), {}) or {}
    settings["aktiv_modell"] = model_id
    paths.write_json(_settings_path(), settings)


# ------------------------------------------------------ medföljande modeller
def seed_examples() -> None:
    """Lägger in medföljande färdigtränade modeller (mappen exempel/) första gången programmet startas."""
    marker = paths.data_root() / ".medfoljande_modeller.json"
    done = paths.read_json(marker, []) or []
    changed = False
    for src in sorted((paths.APP_ROOT / "exempel").glob("*.aicc-modell.zip")):
        if src.name in done:
            continue
        try:
            model = import_model(src)
            if not get_active():
                set_active(model["id"])
        except AppError:
            pass
        done.append(src.name)
        changed = True
    if changed:
        paths.write_json(marker, done)
