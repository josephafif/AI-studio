"""Läser färdigtränade modeller från andra format, t.ex. lennart3.pt från Kaggle-träningen."""
from __future__ import annotations

from pathlib import Path

from ..core import AppError


def read_lennart3(pt_path: Path) -> dict:
    """Returnerar modellens arkitektur från filen. ``weights_only=True`` – ingen kod i filen körs."""
    import torch
    try:
        ck = torch.load(pt_path, map_location="cpu", weights_only=True)
    except Exception as e:  # noqa: BLE001
        raise AppError(f"Filen kunde inte läsas som en PyTorch-modell ({type(e).__name__})")
    if not isinstance(ck, dict) or "model" not in ck or not isinstance(ck.get("config"), dict):
        raise AppError("Filen är inte en Lennart 3-modell (saknar 'model' och 'config')")
    cfg, sd = ck["config"], ck["model"]
    try:
        arch = {"architecture": "gpt-l3", "n_layers": int(cfg["n_layer"]), "n_heads": int(cfg["n_head"]),
                "d_model": int(cfg["n_embd"]), "context_length": int(cfg["block_size"]),
                "vocab_size": int(cfg["vocab_size"])}
    except (KeyError, TypeError, ValueError):
        raise AppError("Modellfilens konfiguration är ofullständig")
    expected = {"wte.weight": (arch["vocab_size"], arch["d_model"]),
                "wpe.weight": (arch["context_length"], arch["d_model"]),
                f"blocks.{arch['n_layers'] - 1}.qkv.weight": (3 * arch["d_model"], arch["d_model"])}
    for key, shape in expected.items():
        if key not in sd or tuple(sd[key].shape) != shape:
            raise AppError(f"Vikterna stämmer inte med konfigurationen ({key})")
    return {"arkitektur": arch, "namn": cfg.get("name"),
            "n_params": int(sum(t.numel() for t in sd.values()))}
