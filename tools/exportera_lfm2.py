"""Gör om en LFM2-modell (Liquid AI, t.ex. LFM2.5-350M) till Lennarts format: .lmod + .tok.json + .lennart.

    python tools/exportera_lfm2.py <hf-mapp> <utmapp> [--id lfm2-5-350m] [--namn "LFM2.5 350M"] [--ctx 2048] [--float]

<hf-mapp> innehåller config.json, model.safetensors, tokenizer.json och LICENSE (som på Hugging Face).
Motorn (mobil/engine/lmengine.c) läser formatversion 2: korta faltningar och grupperad attention i blandade
lager, RMSNorm, SwiGLU och RoPE. Vikterna sparas som int8 med en skala per grupp om 64 vikter (kvantläge 2), utom normer och
faltningskärnor. En skala per rad (som Lennart 3) gav för stort fel för den här modellen (KL 0,011 mot 0,003).

Licens: LFM Open License v1.0. Den följer med i paketet (entry.licens_text) och som LICENS-LFM.txt, med en
notering om vad som är ändrat, så som licensen kräver (§4 a–b).
"""
import argparse
import json
import struct
import sys
from pathlib import Path

import torch
from safetensors.torch import load_file

sys.path.insert(0, str(Path(__file__).resolve().parent))
from exportera_mobil import Writer, _b64, _bytes_to_unicode, write_package  # noqa: E402

# Samma uppdelning som modellens förtokenisering, men utan (?i:…) som Dart och JavaScript inte kan.
LFM2_PATTERN = (r"'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD]|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}"
                r"| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+")

ANDRINGAR = """Ändringar (enligt LFM Open License v1.0, §4 b):
Filen {id}.lmod är konverterad från {kalla} av AI Studio (Lennart-projektet):
vikterna är omsorterade till Lennarts .lmod-format och matriserna avrundade till int8 med en skala per 64 vikter.
Tokeniseraren är omskriven till Lennarts JSON-format. Inga vikter är tränade eller ändrade i övrigt.
"""


def f32bits(x: float) -> int:
    return struct.unpack("<i", struct.pack("<f", x))[0]


def mat_grupp(w: Writer, t, gs: int = 64):
    """int8 med en skala per grupp om gs vikter (kvantläge 2): vikterna, sedan skalorna [rader][kolumner/gs]."""
    t = t.detach().float().cpu()
    r, c = t.shape
    assert c % gs == 0, (r, c)
    x = t.reshape(r, c // gs, gs)
    scale = x.abs().amax(dim=2).clamp(min=1e-12) / 127.0
    q = torch.round(x / scale[:, :, None]).clamp(-127, 127).to(torch.int8).reshape(r, c)
    w._pad()
    w.fh.write(q.numpy().tobytes())
    w.f32(scale.reshape(-1))


def lfm_tokenizer(tok: dict, vocab_size: int) -> dict:
    vocab: dict[str, int] = tok["model"]["vocab"]
    if tok["model"].get("type") != "BPE" or tok["model"].get("ignore_merges"):
        raise SystemExit("Tokeniseraren är inte en vanlig BPE – stöds inte")
    b2u = _bytes_to_unicode()
    u2b = {c: b for b, c in b2u.items()}
    added = {t["content"]: t for t in tok["added_tokens"]}
    tokens = [b""] * vocab_size
    for s, i in vocab.items():
        if s in added:
            # Specialtecken blir ingen text; andra tillagda (t.ex. <think>) skrivs som de är.
            tokens[i] = b"" if added[s]["special"] else s.encode("utf-8")
        else:
            tokens[i] = bytes(u2b[c] for c in s)
    merges = []
    for m in tok["model"]["merges"]:
        a, b = m.split(" ") if isinstance(m, str) else m
        merges.append([vocab[a], vocab[b], vocab[a + b]])
    sp = {t["content"]: t["id"] for t in tok["added_tokens"]}
    slut = sp["<|im_end|>"]
    return {
        "format": "lennart-tok-1",
        "pattern": LFM2_PATTERN,
        "byte_to_id": [vocab[b2u[b]] for b in range(256)],
        "merges": merges,
        "tokens": [_b64(t) for t in tokens],
        # ChatML: <|startoftext|><|im_start|>user\n…<|im_end|>\n<|im_start|>assistant\n
        "chat": "chatml",
        "special": {"pad": sp["<|pad|>"], "bos": sp["<|startoftext|>"], "user": sp["<|im_start|>"],
                    "assistant": sp["<|im_start|>"], "end": slut},
        # Specialtecken som aldrig ska skrivas i ett svar.
        "banned": sorted(t["id"] for t in tok["added_tokens"] if t["special"] and t["id"] != slut),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--id", default="lfm2-5-350m")
    ap.add_argument("--namn", default="LFM2.5 350M")
    ap.add_argument("--kalla", default="LiquidAI/LFM2.5-350M")
    ap.add_argument("--ctx", type=int, default=2048, help="kontext i appen (minne: KV- och faltningscache)")
    ap.add_argument("--float", action="store_true", help="float32 i stället för int8 (för kontroller)")
    ap.add_argument("--per-rad", action="store_true", help="int8 med en skala per rad (sämre; för jämförelser)")
    ap.add_argument("--beskrivning", default="Liquid AI:s LFM2.5-350M, konverterad men inte vidaretränad. Grunden för Lennart 4.0 – svenskan är svag än så länge.")
    ap.add_argument("--hue", type=int, default=28)
    ap.add_argument("--badge", default="LFM", help="texten i modellens ikon (högst 3–4 tecken)")
    ap.add_argument("--inget-paket", action="store_true")
    a = ap.parse_args()

    cfg = json.loads((a.src / "config.json").read_text())
    if cfg.get("model_type") != "lfm2":
        raise SystemExit("Inte en LFM2-modell")
    sd = load_file(str(a.src / "model.safetensors"))
    d, layers, heads, kv = cfg["hidden_size"], cfg["num_hidden_layers"], cfg["num_attention_heads"], cfg["num_key_value_heads"]
    vocab, L = cfg["vocab_size"], cfg["conv_L_cache"]
    typer = cfg["layer_types"]
    ff = sd["model.layers.0.feed_forward.w1.weight"].shape[0]
    theta = (cfg.get("rope_parameters") or {}).get("rope_theta", cfg.get("rope_theta", 1e6))
    eps = cfg.get("norm_eps", 1e-5)
    mask = sum(1 << i for i, t in enumerate(typer) if t == "full_attention")
    assert cfg.get("tie_embedding", True), "Motorn förutsätter delade in- och utvikter"
    quant = not a.float
    lage = 0 if a.float else 1 if a.per_rad else 2  # kvantläge i huvudet
    a.out.mkdir(parents=True, exist_ok=True)
    w = Writer(a.out / f"{a.id}.lmod", [2, vocab, d, layers, heads, a.ctx, kv, ff, lage, 1, L, mask, f32bits(theta), f32bits(eps)])
    g = lambda k: sd[k].float()  # noqa: E731
    mat = (lambda t: mat_grupp(w, t)) if lage == 2 else (lambda t: w.mat(t, quant))  # noqa: E731
    mat(g("model.embed_tokens.weight"))
    for i in range(layers):
        p = f"model.layers.{i}."
        w.f32(g(p + "operator_norm.weight"))
        w.f32(g(p + "ffn_norm.weight"))
        if typer[i] == "full_attention":
            for n in ["q_proj", "k_proj", "v_proj", "out_proj"]:
                mat(g(p + f"self_attn.{n}.weight"))
            w.f32(g(p + "self_attn.q_layernorm.weight"))
            w.f32(g(p + "self_attn.k_layernorm.weight"))
        else:
            mat(g(p + "conv.in_proj.weight"))
            w.f32(g(p + "conv.conv.weight").reshape(d, L))
            mat(g(p + "conv.out_proj.weight"))
        for n in ["w1", "w3", "w2"]:
            mat(g(p + f"feed_forward.{n}.weight"))
    w.f32(g("model.embedding_norm.weight"))
    w.close()

    tok = lfm_tokenizer(json.loads((a.src / "tokenizer.json").read_text()), vocab)
    (a.out / f"{a.id}.tok.json").write_text(json.dumps(tok), encoding="utf-8")
    licens = (a.src / "LICENSE").read_text(encoding="utf-8")
    andringar = ANDRINGAR.format(id=a.id, kalla=a.kalla)
    (a.out / "LICENS-LFM.txt").write_text(licens + "\n\n" + andringar, encoding="utf-8")
    params = sum(t.numel() for t in sd.values())
    entry = {
        "id": a.id, "name": a.namn, "description": a.beskrivning, "params": params, "steps": 0, "context": a.ctx, "vocab": vocab,
        "quant": ["float32", "int8", "int8-g64"][lage], "temperature": 0.3, "max_tokens": 300, "top_k": 40, "hue": a.hue, "badge": a.badge,
        "arkitektur": "lfm2", "kalla": f"https://huggingface.co/{a.kalla}",
        "licens": "LFM Open License v1.0", "licens_text": licens, "andringar": andringar,
    }
    (a.out / f"{a.id}.modell.json").write_text(json.dumps(entry, ensure_ascii=False, indent=1), encoding="utf-8")
    if not a.inget_paket:
        print("paket:", write_package(a.out, entry))
    print(f"klart: {a.out / (a.id + '.lmod')} ({(a.out / (a.id + '.lmod')).stat().st_size / 1e6:.0f} MB), {params / 1e6:.1f} M parametrar")
    return 0


if __name__ == "__main__":
    sys.exit(main())
