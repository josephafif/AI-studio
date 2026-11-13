"""Inferens: laddar tränade modeller och strömmar genererad text till chatten."""
from __future__ import annotations

import threading
import time
from collections import OrderedDict

from ..core import AppError, models

_cache: "OrderedDict[tuple, tuple]" = OrderedDict()
_cache_lock = threading.Lock()
_MAX_CACHED = 4


def _load(model_id: str, checkpoint: str | None):
    from . import runtime
    from .tokenizer import Tokenizer

    mdir = models.model_dir(model_id)
    cfg = models.load_config(model_id)
    ckpts = models.list_checkpoints(model_id)
    if not ckpts:
        raise AppError(f"'{cfg['namn']}' är inte tränad ännu. Träna modellen innan du testar den.")
    if checkpoint in (None, "", "senaste"):
        chosen = ckpts[-1]
    elif checkpoint == "basta":
        chosen = next((c for c in ckpts if c["bast"]), ckpts[-1])
    else:
        chosen = next((c for c in ckpts if c["fil"] == checkpoint), None)
        if chosen is None:
            raise AppError("Den valda checkpointen finns inte längre")
    pt = mdir / "checkpoints" / chosen["fil"]
    key = (model_id, chosen["fil"], pt.stat().st_mtime_ns)
    with _cache_lock:
        if key in _cache:
            _cache.move_to_end(key)
            return (*_cache[key], cfg, chosen)
    tok_path = mdir / "tokenizer.json"
    if not tok_path.exists():
        raise AppError("Modellen saknar tokenizer.json")
    tokenizer = Tokenizer.load(tok_path)
    import os
    import torch
    # Få trådar: små modeller vinner inget på fler, och chatten ska inte strypa en pågående träning.
    torch.set_num_threads(max(1, min(4, (os.cpu_count() or 2) // 2)))
    model = runtime.build_model(mdir, cfg["arkitektur"])
    runtime.load_weights(model, pt, "cpu")
    model.eval()
    with _cache_lock:
        _cache[key] = (model, tokenizer)
        while len(_cache) > _MAX_CACHED:
            _cache.popitem(last=False)
    return model, tokenizer, cfg, chosen


def chat_stream(model_id: str, messages: list[dict], temperature: float = 0.7,
                max_tokens: int = 150, top_k: int = 40, checkpoint: str | None = None,
                mode: str = "chatt", stop=None):
    """Generator som ger händelser: ``{"typ": "start"|"token"|"klar", ...}``."""
    from . import runtime

    model, tokenizer, cfg, chosen = _load(model_id, checkpoint)
    ctx = model.context_length
    max_tokens = max(1, min(int(max_tokens), 4096))
    temperature = max(0.0, min(float(temperature), 2.0))
    messages = [m for m in messages if m.get("role") in ("user", "assistant") and m.get("content")]
    if not messages:
        raise AppError("Skriv ett meddelande först")

    if mode == "text":
        prompt = tokenizer.encode(messages[-1]["content"])
    else:
        # Behåll så mycket historik som ryms; lämna plats för svaret.
        budget = max(8, ctx - min(max_tokens, ctx // 2))
        history = list(messages)
        prompt = tokenizer.encode_chat(history, add_generation_prompt=True)
        while len(prompt) > budget and len(history) > 1:
            history = history[1:]
            while history and history[0]["role"] != "user" and len(history) > 1:
                history = history[1:]
            prompt = tokenizer.encode_chat(history, add_generation_prompt=True)

    yield {"typ": "start", "modell": cfg["namn"], "model_id": model_id,
           "checkpoint": chosen["fil"], "steg": chosen["step"], "prompt_tokens": len(prompt)}
    decode = tokenizer.stream_decoder()
    n, t0 = 0, time.time()
    for token_id in runtime.generate(model, tokenizer, prompt, max_tokens, temperature, top_k, "cpu", stop):
        n += 1
        piece = decode(token_id)
        if piece:
            yield {"typ": "token", "text": piece}
    dt = time.time() - t0
    yield {"typ": "klar", "tokens": n, "sekunder": round(dt, 2),
           "tokens_per_sek": round(n / dt, 1) if dt > 0 else None}


def clear_cache(model_id: str | None = None) -> None:
    with _cache_lock:
        for key in [k for k in _cache if model_id is None or k[0] == model_id]:
            del _cache[key]
