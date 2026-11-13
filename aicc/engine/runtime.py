"""Gemensamt för träning och inferens: ladda modellkod, välja enhet, koda data, generera text."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import torch

from .tokenizer import Tokenizer


def resolve_device(requested: str = "auto") -> tuple[torch.device, str | None]:
    """Returnerar (enhet, varning). Faller tillbaka på CPU om GPU saknas."""
    requested = (requested or "auto").lower()
    mps_ok = getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available()
    if requested == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda"), None
        return torch.device("cpu"), None
    if requested.startswith("cuda"):
        if torch.cuda.is_available():
            try:
                dev = torch.device(requested)
                if dev.index is None or dev.index < torch.cuda.device_count():
                    return dev, None
            except RuntimeError:
                pass
        return torch.device("cpu"), "Ingen kompatibel CUDA-GPU hittades – använder CPU i stället."
    if requested == "mps":
        if mps_ok:
            return torch.device("mps"), None
        return torch.device("cpu"), "MPS är inte tillgängligt – använder CPU i stället."
    return torch.device("cpu"), None


def load_model_module(model_dir: Path):
    """Importerar den genererade model.py från modellens mapp."""
    path = Path(model_dir) / "model.py"
    name = f"aicc_modell_{Path(model_dir).name.replace('-', '_')}_{int(path.stat().st_mtime_ns)}"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def build_model(model_dir: Path, arch_cfg: dict):
    module = load_model_module(model_dir)
    return module.build_model(arch_cfg)


def load_weights(model, ckpt_path: Path, device="cpu") -> dict:
    """Läser en checkpoint. ``weights_only=True`` gör att ingen kod i filen kan köras."""
    ckpt = torch.load(ckpt_path, map_location=device, weights_only=True)
    model.load_state_dict(ckpt["model"])
    return ckpt


def encode_records(tokenizer: Tokenizer, records, progress=None):
    """Gör om poster till en enda tokenström (kompakt ``array``). Varje post avslutas med <|end|>."""
    from array import array
    ids = array("i")
    n = 0
    for rec in records:
        if "messages" in rec:
            ids.extend(tokenizer.encode_chat(rec["messages"]))
            if rec["messages"] and rec["messages"][-1]["role"] != "assistant":
                ids.append(tokenizer.end_id)
        else:
            ids.extend(tokenizer.encode(rec.get("text", "")))
            ids.append(tokenizer.end_id)
        n += 1
        if progress and n % 20000 == 0:
            progress(n)
    return ids


def to_tensor(ids):
    """array('i') → int32-tensor utan att gå via Python-objekt."""
    if len(ids) == 0:
        return torch.zeros(0, dtype=torch.int32)
    return torch.frombuffer(ids, dtype=torch.int32).clone()


@torch.no_grad()
def generate(model, tokenizer: Tokenizer, prompt_ids: list[int], max_new_tokens: int = 100,
             temperature: float = 0.7, top_k: int = 40, device="cpu", stop=None):
    """Genererar tokens en i taget (generator). Avslutar vid <|end|>.

    ``stop`` är en valfri funktion som returnerar True när genereringen ska avbrytas.
    """
    was_training = model.training
    model.eval()
    try:
        ctx = model.context_length
        ids = list(prompt_ids)[-ctx:] or [tokenizer.end_id]
        banned = [tokenizer.pad_id, tokenizer.user_id, tokenizer.assistant_id]
        for _ in range(int(max_new_tokens)):
            if stop is not None and stop():
                return
            x = torch.tensor([ids[-ctx:]], dtype=torch.long, device=device)
            logits, _ = model(x)
            logits = logits[0, -1].float()
            logits[banned] = float("-inf")
            if temperature <= 1e-6:
                next_id = int(torch.argmax(logits))
            else:
                logits = logits / temperature
                if top_k and top_k > 0:
                    k = min(int(top_k), logits.numel())
                    kth = torch.topk(logits, k).values[-1]
                    logits[logits < kth] = float("-inf")
                probs = torch.softmax(logits, dim=-1)
                next_id = int(torch.multinomial(probs, 1))
            if next_id == tokenizer.end_id:
                return
            ids.append(next_id)
            yield next_id
    finally:
        if was_training:
            model.train()
