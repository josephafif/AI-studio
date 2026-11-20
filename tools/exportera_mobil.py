"""Exporterar Lennart-modeller till mobilappens format (mobil/lennart_app).

För varje modell skapas
    <id>.lmod       vikter för mobilmotorn (mobil/engine/lmengine.c), float32 eller int8 per rad
    <id>.tok.json   tokenizer i ett gemensamt format (byte-nivå BPE: regex, merges och bytes per token)
och en post i manifest.json.

Källor:
    --panel  <mapp eller .aicc-modell.zip>   modell från kontrollpanelen (Lennart, Lennart 2 …)
    --l3     <mapp med lennart3.pt, tokenizer.json, status.json>   Lennart 3-formatet från Kaggle

Exempel:
    python tools/exportera_mobil.py --ut mobil/lennart_app/assets/models \\
        --panel exempel/Lennart-tranad.aicc-modell.zip --panel exempel/Lennart-2-tranad.aicc-modell.zip \\
        --l3 nedladdat/lennart3 --l3 nedladdat/lennart3.1
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

import numpy as np
import torch

ALIGN = 64
GPT2_PATTERN = r"""'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"""


# ───────────────────────────────────────────────────────────── vikter
class Writer:
    def __init__(self, path: Path, header: list[int]):
        self.fh = open(path, "wb")
        # Huvud på exakt 64 byte: magiska 8 byte + 14 heltal (version, vocab, d, lager, heads, ctx, bias, gelu, kvant).
        self.fh.write(b"LMOD0001" + struct.pack("<14i", *(header + [0] * (14 - len(header)))))
        assert self.fh.tell() == 64

    def _pad(self):
        pos = self.fh.tell()
        self.fh.write(b"\0" * ((-pos) % ALIGN))

    def f32(self, t):
        self._pad()
        self.fh.write(np.ascontiguousarray(t.detach().float().cpu().numpy(), dtype="<f4").tobytes())

    def mat(self, t, quant: bool):
        t = t.detach().float().cpu()
        if not quant:
            return self.f32(t)
        scale = t.abs().amax(dim=1).clamp(min=1e-12) / 127.0
        q = torch.round(t / scale[:, None]).clamp(-127, 127).to(torch.int8)
        self._pad()
        self.fh.write(q.numpy().tobytes())
        self.f32(scale)

    def close(self):
        self.fh.close()


def write_lmod(path: Path, sd: dict, names: dict, a: dict, quant: bool):
    """``names`` översätter motorns lagerdelar till nycklarna i modellens state_dict."""
    has_bias = names["qkv_b"] is not None
    w = Writer(path, [1, a["vocab"], a["d"], a["layers"], a["heads"], a["ctx"], int(has_bias),
                      int(a["gelu_tanh"]), int(quant)])
    w.mat(sd[names["wte"]], quant)
    w.f32(sd[names["wpe"]][: a["ctx"]])
    for i in range(a["layers"]):
        g = lambda key: sd[names[key].format(i=i)]  # noqa: E731
        w.f32(g("ln1_w")); w.f32(g("ln1_b"))
        w.mat(g("qkv_w"), quant)
        if has_bias: w.f32(g("qkv_b"))
        w.mat(g("proj_w"), quant)
        if has_bias: w.f32(g("proj_b"))
        w.f32(g("ln2_w")); w.f32(g("ln2_b"))
        w.mat(g("fc_w"), quant)
        if has_bias: w.f32(g("fc_b"))
        w.mat(g("out_w"), quant)
        if has_bias: w.f32(g("out_b"))
    w.f32(sd[names["lnf_w"]]); w.f32(sd[names["lnf_b"]])
    w.close()


PANEL_NAMES = {
    "wte": "tok_emb.weight", "wpe": "pos_emb.weight", "lnf_w": "ln_f.weight", "lnf_b": "ln_f.bias",
    "ln1_w": "blocks.{i}.ln1.weight", "ln1_b": "blocks.{i}.ln1.bias",
    "qkv_w": "blocks.{i}.attn.qkv.weight", "qkv_b": "blocks.{i}.attn.qkv.bias",
    "proj_w": "blocks.{i}.attn.proj.weight", "proj_b": "blocks.{i}.attn.proj.bias",
    "ln2_w": "blocks.{i}.ln2.weight", "ln2_b": "blocks.{i}.ln2.bias",
    "fc_w": "blocks.{i}.fc.weight", "fc_b": "blocks.{i}.fc.bias",
    "out_w": "blocks.{i}.out.weight", "out_b": "blocks.{i}.out.bias",
}
L3_NAMES = {
    "wte": "wte.weight", "wpe": "wpe.weight", "lnf_w": "ln_f.weight", "lnf_b": "ln_f.bias",
    "ln1_w": "blocks.{i}.ln1.weight", "ln1_b": "blocks.{i}.ln1.bias", "qkv_w": "blocks.{i}.qkv.weight",
    "qkv_b": None, "proj_w": "blocks.{i}.proj.weight", "proj_b": None,
    "ln2_w": "blocks.{i}.ln2.weight", "ln2_b": "blocks.{i}.ln2.bias", "fc_w": "blocks.{i}.fc.weight",
    "fc_b": None, "out_w": "blocks.{i}.out.weight", "out_b": None,
}


# ───────────────────────────────────────────────────────────── tokenizer
def _b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def panel_tokenizer(tok: dict) -> dict:
    vocab = tok["vocab_size"]
    merges = [tuple(m) for m in tok.get("merges", [])]
    token_bytes = [bytes([i]) for i in range(256)]
    for a, b in merges:
        token_bytes.append(token_bytes[a] + token_bytes[b])
    token_bytes += [b""] * (vocab - len(token_bytes))
    return {
        "format": "lennart-tok-1", "pattern": r" ?\S+|\s+", "byte_to_id": list(range(256)),
        "merges": [[a, b, 256 + i] for i, (a, b) in enumerate(merges)],
        "tokens": [_b64(t) for t in token_bytes],
        "special": {"pad": vocab - 4, "user": vocab - 3, "assistant": vocab - 2, "end": vocab - 1},
    }


def _bytes_to_unicode() -> dict[int, str]:
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, map(chr, cs)))


def hf_tokenizer(tok: dict) -> dict:
    pre = json.dumps(tok.get("pre_tokenizer"))
    if '"ByteLevel"' not in pre or '"add_prefix_space": true' in pre:
        raise SystemExit("Tokenizern är inte en byte-nivå BPE utan prefix-mellanslag – stöds inte")
    vocab: dict[str, int] = tok["model"]["vocab"]
    b2u = _bytes_to_unicode()
    u2b = {c: b for b, c in b2u.items()}
    size = max(max(vocab.values()), max(t["id"] for t in tok["added_tokens"])) + 1
    tokens = [b""] * size
    specials = {t["content"]: t["id"] for t in tok["added_tokens"]}
    for s, i in vocab.items():
        if s not in specials:
            tokens[i] = bytes(u2b[c] for c in s)
    merges = []
    for m in tok["model"]["merges"]:
        a, b = m.split(" ") if isinstance(m, str) else m
        merges.append([vocab[a], vocab[b], vocab[a + b]])
    return {
        "format": "lennart-tok-1", "pattern": GPT2_PATTERN, "byte_to_id": [vocab[b2u[b]] for b in range(256)],
        "merges": merges, "tokens": [_b64(t) for t in tokens],
        "special": {"pad": specials["<|endoftext|>"], "user": specials["<|user|>"],
                    "assistant": specials["<|assistant|>"], "end": specials["<|end|>"]},
        "escape_specials": True,
    }


# ───────────────────────────────────────────────────────────── källor
def export_panel(src: Path, out: Path, quant: bool | None) -> dict:
    tmp = None
    if src.suffix == ".zip":
        tmp = tempfile.TemporaryDirectory()
        zipfile.ZipFile(src).extractall(tmp.name)
        src = Path(tmp.name)
    cfg = json.loads((src / "config.json").read_text(encoding="utf-8"))
    arch = cfg["arkitektur"]
    if arch["architecture"] != "gpt":
        raise SystemExit(f"{cfg['namn']}: bara GPT-modeller kan köras i appen (inte {arch['architecture']})")
    ckpts = sorted((src / "checkpoints").glob("ckpt_*.pt"))
    ck = torch.load(ckpts[-1], map_location="cpu", weights_only=True)
    meta = json.loads(ckpts[-1].with_suffix(".json").read_text()) if ckpts[-1].with_suffix(".json").exists() else {}
    a = {"vocab": arch["vocab_size"], "d": arch["d_model"], "layers": arch["n_layers"],
         "heads": arch["n_heads"], "ctx": arch["context_length"], "gelu_tanh": False}
    quant = (arch["n_params"] > 50_000_000) if quant is None else quant
    mid = re.sub(r"[^a-z0-9]+", "-", cfg["namn"].lower()).strip("-")
    write_lmod(out / f"{mid}.lmod", ck["model"], PANEL_NAMES, a, quant)
    tok = panel_tokenizer(json.loads((src / "tokenizer.json").read_text(encoding="utf-8")))
    (out / f"{mid}.tok.json").write_text(json.dumps(tok), encoding="utf-8")
    gen = cfg.get("generering") or {}
    entry = {"id": mid, "name": cfg["namn"], "description": cfg.get("beskrivning", ""),
             "params": arch["n_params"], "steps": int(meta.get("step") or ckpts[-1].stem.split("_")[1]),
             "context": a["ctx"], "vocab": a["vocab"], "quant": "int8" if quant else "float32",
             "temperature": gen.get("temperature", 0.7), "max_tokens": gen.get("max_tokens", 150),
             "top_k": gen.get("top_k", 40)}
    if tmp:
        tmp.cleanup()
    return entry


def export_l3(src: Path, out: Path, quant: bool | None, name: str | None) -> dict:
    ck = torch.load(src / "lennart3.pt", map_location="cpu", weights_only=True)
    c = ck["config"]
    status = json.loads((src / "status.json").read_text()) if (src / "status.json").exists() else {}
    sessions = int(status.get("sessions") or 1)
    name = name or (c.get("name", "Lennart 3") + (f".{sessions - 1}" if sessions > 1 else ""))
    a = {"vocab": c["vocab_size"], "d": c["n_embd"], "layers": c["n_layer"], "heads": c["n_head"],
         "ctx": c["block_size"], "gelu_tanh": True}
    quant = True if quant is None else quant
    mid = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    write_lmod(out / f"{mid}.lmod", ck["model"], L3_NAMES, a, quant)
    tok = hf_tokenizer(json.loads((src / "tokenizer.json").read_text(encoding="utf-8")))
    (out / f"{mid}.tok.json").write_text(json.dumps(tok), encoding="utf-8")
    params = int(sum(t.numel() for t in ck["model"].values()))
    tokens = status.get("tokens_seen")
    desc = (f"Svensk GPT med {params / 1e6:.0f} miljoner parametrar, tränad på Kaggle"
            + (f" på {tokens / 1e6:,.0f} miljoner tokens".replace(",", " ") if tokens else "")
            + ": Wikipedia, svensk webbtext och samtal. Kan extra mycket om cybersäkerhet.")
    return {"id": mid, "name": name, "description": desc, "params": params, "steps": int(status.get("step") or 0),
            "context": a["ctx"], "vocab": a["vocab"], "quant": "int8" if quant else "float32",
            "temperature": 0.6, "max_tokens": 200, "top_k": 40}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ut", required=True, type=Path)
    p.add_argument("--panel", action="append", default=[], type=Path)
    p.add_argument("--l3", action="append", default=[], type=Path)
    p.add_argument("--kvantisera", choices=["auto", "ja", "nej"], default="auto")
    args = p.parse_args()
    quant = {"auto": None, "ja": True, "nej": False}[args.kvantisera]
    args.ut.mkdir(parents=True, exist_ok=True)
    entries = [export_panel(s, args.ut, quant) for s in args.panel]
    entries += [export_l3(s, args.ut, quant, None) for s in args.l3]
    for e in entries:
        size = (args.ut / f"{e['id']}.lmod").stat().st_size
        print(f"  ✓ {e['name']}: {e['params']:,} parametrar, {e['quant']}, {size / 1e6:.0f} MB".replace(",", " "))
    (args.ut / "manifest.json").write_text(json.dumps({"models": entries}, ensure_ascii=False, indent=2),
                                           encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
