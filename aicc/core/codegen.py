"""Genererar modellkod (model.py), konfiguration och modellkort för nya modeller.

Parameterantalet räknas analytiskt här så att gränssnittet kan visa en exakt
uppskattning utan att PyTorch behöver laddas.
"""
from __future__ import annotations

from . import AppError

MIN_VOCAB = 260

ARCHITECTURES = {
    "gpt": {
        "label": "Transformer (GPT, decoder-only)",
        "description": "Självuppmärksamhet med attention heads. Bäst kvalitet, rekommenderas.",
        "uses_heads": True,
    },
    "lstm": {
        "label": "LSTM (rekurrent)",
        "description": "Klassiskt rekurrent nätverk. Snabb på CPU, sämre på långa sammanhang.",
        "uses_heads": False,
    },
    "gru": {
        "label": "GRU (rekurrent)",
        "description": "Enklare rekurrent nätverk med färre parametrar per lager än LSTM.",
        "uses_heads": False,
    },
}

LIMITS = {
    "n_layers": (1, 48),
    "n_heads": (1, 64),
    "context_length": (16, 8192),
    "vocab_size": (MIN_VOCAB, 65536),
    "d_model": (8, 4096),
    "target_params": (10_000, 2_000_000_000),
}


def count_params(arch: str, vocab: int, d: int, layers: int, context: int) -> int:
    """Exakt antal tränbara parametrar för de genererade arkitekturerna."""
    if arch == "gpt":
        # delad in-/ut-embedding, positionsembedding, block, avslutande LayerNorm
        return vocab * d + context * d + layers * (12 * d * d + 13 * d) + 2 * d
    if arch == "lstm":
        return vocab * d + layers * (8 * d * d + 8 * d) + vocab
    if arch == "gru":
        return vocab * d + layers * (6 * d * d + 6 * d) + vocab
    raise AppError(f"Okänd arkitektur: {arch}")


def _check(name: str, value, label: str) -> int:
    lo, hi = LIMITS[name]
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise AppError(f"{label} måste vara ett heltal")
    if not lo <= value <= hi:
        raise AppError(f"{label} måste vara mellan {lo} och {hi}")
    return value


def resolve_architecture(spec: dict) -> dict:
    """Validerar en arkitekturspecifikation och räknar ut d_model och parametrar.

    Om ``d_model`` saknas väljs den bredd som hamnar närmast ``target_params``.
    """
    arch = spec.get("architecture", "gpt")
    if arch not in ARCHITECTURES:
        raise AppError(f"Okänd arkitektur: {arch}")
    layers = _check("n_layers", spec.get("n_layers", 4), "Antal lager")
    context = _check("context_length", spec.get("context_length", 256), "Context length")
    vocab = _check("vocab_size", spec.get("vocab_size", 1024), "Ordförrådets storlek")
    heads = _check("n_heads", spec.get("n_heads", 4), "Attention heads") if arch == "gpt" else 1
    try:
        dropout = float(spec.get("dropout", 0.1))
    except (TypeError, ValueError):
        raise AppError("Dropout måste vara ett tal")
    if not 0 <= dropout < 0.9:
        raise AppError("Dropout måste vara mellan 0 och 0,9")

    step = heads * 2 if arch == "gpt" and heads % 2 else heads  # d_model jämnt och delbart med heads
    step = max(step, 2)

    if spec.get("d_model"):
        d = _check("d_model", spec["d_model"], "Modellbredd (d_model)")
        if arch == "gpt" and d % heads:
            raise AppError(f"Modellbredden ({d}) måste vara delbar med antal attention heads ({heads})")
        target = None
    else:
        target = _check("target_params", spec.get("target_params", 1_000_000), "Antal parametrar")
        lo, hi = LIMITS["d_model"]
        best, best_diff = None, None
        d = step
        while d <= hi:
            if d >= lo:
                diff = abs(count_params(arch, vocab, d, layers, context) - target)
                if best is None or diff < best_diff:
                    best, best_diff = d, diff
                elif diff > best_diff:
                    break  # parametrarna växer monotont med d
            d += step
        d = best

    return {
        "architecture": arch,
        "n_layers": layers,
        "n_heads": heads,
        "d_model": d,
        "context_length": context,
        "vocab_size": vocab,
        "dropout": dropout,
        "target_params": target,
        "n_params": count_params(arch, vocab, d, layers, context),
    }


# ---------------------------------------------------------------------------
# Kodmallar
# ---------------------------------------------------------------------------

_HEADER = '''"""Modellkod för {name!r}.

Genererad automatiskt av AI Control Center – {arch_label}.
Hyperparametrarna läses från config.json i samma mapp.

    lager: {n_layers}   bredd (d_model): {d_model}   attention heads: {n_heads}
    context length: {context_length}   ordförråd: {vocab_size}   parametrar: {n_params:,}
"""
import math

import torch
import torch.nn as nn
import torch.nn.functional as F

'''

_GPT = '''
class CausalSelfAttention(nn.Module):
    def __init__(self, cfg):
        super().__init__()
        self.n_heads = cfg["n_heads"]
        self.dropout = cfg["dropout"]
        self.qkv = nn.Linear(cfg["d_model"], 3 * cfg["d_model"])
        self.proj = nn.Linear(cfg["d_model"], cfg["d_model"])
        self.resid_drop = nn.Dropout(cfg["dropout"])

    def forward(self, x):
        B, T, C = x.shape
        q, k, v = self.qkv(x).split(C, dim=2)
        q = q.view(B, T, self.n_heads, C // self.n_heads).transpose(1, 2)
        k = k.view(B, T, self.n_heads, C // self.n_heads).transpose(1, 2)
        v = v.view(B, T, self.n_heads, C // self.n_heads).transpose(1, 2)
        y = F.scaled_dot_product_attention(
            q, k, v, is_causal=True, dropout_p=self.dropout if self.training else 0.0
        )
        y = y.transpose(1, 2).contiguous().view(B, T, C)
        return self.resid_drop(self.proj(y))


class Block(nn.Module):
    def __init__(self, cfg):
        super().__init__()
        d = cfg["d_model"]
        self.ln1 = nn.LayerNorm(d)
        self.attn = CausalSelfAttention(cfg)
        self.ln2 = nn.LayerNorm(d)
        self.fc = nn.Linear(d, 4 * d)
        self.out = nn.Linear(4 * d, d)
        self.drop = nn.Dropout(cfg["dropout"])

    def forward(self, x):
        x = x + self.attn(self.ln1(x))
        x = x + self.drop(self.out(F.gelu(self.fc(self.ln2(x)))))
        return x


class Model(nn.Module):
    """Decoder-only Transformer (GPT) med delad in- och ut-embedding."""

    def __init__(self, cfg):
        super().__init__()
        self.cfg = cfg
        self.context_length = cfg["context_length"]
        d = cfg["d_model"]
        self.tok_emb = nn.Embedding(cfg["vocab_size"], d)
        self.pos_emb = nn.Embedding(cfg["context_length"], d)
        self.drop = nn.Dropout(cfg["dropout"])
        self.blocks = nn.ModuleList([Block(cfg) for _ in range(cfg["n_layers"])])
        self.ln_f = nn.LayerNorm(d)
        self.head = nn.Linear(d, cfg["vocab_size"], bias=False)
        self.head.weight = self.tok_emb.weight
        self.apply(self._init)
        for name, p in self.named_parameters():
            if name.endswith("proj.weight") or name.endswith("out.weight"):
                nn.init.normal_(p, mean=0.0, std=0.02 / math.sqrt(2 * cfg["n_layers"]))

    @staticmethod
    def _init(module):
        if isinstance(module, (nn.Linear, nn.Embedding)):
            nn.init.normal_(module.weight, mean=0.0, std=0.02)
        if isinstance(module, nn.Linear) and module.bias is not None:
            nn.init.zeros_(module.bias)

    def forward(self, idx, targets=None):
        B, T = idx.shape
        pos = torch.arange(T, device=idx.device)
        x = self.drop(self.tok_emb(idx) + self.pos_emb(pos))
        for block in self.blocks:
            x = block(x)
        logits = self.head(self.ln_f(x))
        loss = None
        if targets is not None:
            loss = F.cross_entropy(logits.view(-1, logits.size(-1)), targets.view(-1))
        return logits, loss
'''

_RNN = '''
class Model(nn.Module):
    """Rekurrent språkmodell ({rnn_cls}) med delad in- och ut-embedding."""

    def __init__(self, cfg):
        super().__init__()
        self.cfg = cfg
        self.context_length = cfg["context_length"]
        d = cfg["d_model"]
        self.tok_emb = nn.Embedding(cfg["vocab_size"], d)
        self.drop = nn.Dropout(cfg["dropout"])
        self.rnn = nn.{rnn_cls}(
            d, d, num_layers=cfg["n_layers"], batch_first=True,
            dropout=cfg["dropout"] if cfg["n_layers"] > 1 else 0.0,
        )
        self.head = nn.Linear(d, cfg["vocab_size"])
        self.head.weight = self.tok_emb.weight
        nn.init.normal_(self.tok_emb.weight, mean=0.0, std=1.0 / math.sqrt(d))
        nn.init.zeros_(self.head.bias)

    def forward(self, idx, targets=None):
        x = self.drop(self.tok_emb(idx))
        x, _ = self.rnn(x)
        logits = self.head(self.drop(x))
        loss = None
        if targets is not None:
            loss = F.cross_entropy(logits.view(-1, logits.size(-1)), targets.view(-1))
        return logits, loss
'''

_FOOTER = '''

def build_model(cfg):
    """Skapar modellen från innehållet i config.json (nyckeln "arkitektur")."""
    return Model(cfg)


def count_parameters(model):
    return sum(p.numel() for p in model.parameters() if p.requires_grad)
'''


def generate_model_code(name: str, arch_cfg: dict) -> str:
    arch = arch_cfg["architecture"]
    header = _HEADER.format(name=name, arch_label=ARCHITECTURES[arch]["label"], **arch_cfg)
    if arch == "gpt":
        body = _GPT
    else:
        body = _RNN.replace("{rnn_cls}", "LSTM" if arch == "lstm" else "GRU")
    return header + body.lstrip("\n") + _FOOTER


def generate_readme(cfg: dict) -> str:
    a = cfg["arkitektur"]
    return f"""# {cfg['namn']}

{cfg.get('beskrivning') or '_Ingen beskrivning._'}

| Egenskap | Värde |
|---|---|
| Användningsområde | {cfg.get('anvandningsomrade') or '–'} |
| Språk | {cfg.get('sprak') or '–'} |
| Arkitektur | {ARCHITECTURES[a['architecture']]['label']} |
| Parametrar | {a['n_params']:,} |
| Lager | {a['n_layers']} |
| Attention heads | {a['n_heads'] if a['architecture'] == 'gpt' else '–'} |
| Modellbredd (d_model) | {a['d_model']} |
| Context length | {a['context_length']} tokens |
| Ordförråd | {a['vocab_size']} (byte-nivå BPE) |
| Skapad | {cfg['skapad']} |

## Filer

- `config.json` – modellens konfiguration och metadata
- `model.py` – genererad modellkod (PyTorch)
- `tokenizer.json` – tokenizer, skapas vid första träningen
- `checkpoints/` – sparade vikter från träning
- `traningshistorik.json` – logg över genomförda träningskörningar

Modellen är skapad och hanteras av AI Control Center.
"""


PRESETS = [
    {
        "id": "lennart",
        "label": "Lennart – svensk cybersäkerhet (~1 M)",
        "namn": "Lennart",
        "beskrivning": "Svensk AI-assistent inriktad på cybersäkerhet och IT-säkerhet. "
                       "Besvarar frågor och för enklare samtal.",
        "anvandningsomrade": "Cybersäkerhet och IT-säkerhet",
        "sprak": "Svenska",
        "architecture": "gpt",
        "target_params": 1_000_000,
        "n_layers": 4,
        "n_heads": 4,
        "context_length": 128,
        "vocab_size": 1024,
        "dropout": 0.05,
        "dataset": "svensk-cybersakerhet",
        "training": {"max_steps": 4000, "batch_size": 32, "learning_rate": 0.001},
    },
    {
        "id": "liten",
        "label": "Liten textmodell (~250 k)",
        "namn": "",
        "beskrivning": "Liten och snabbtränad modell för experiment.",
        "anvandningsomrade": "Experiment",
        "sprak": "Svenska",
        "architecture": "gpt",
        "target_params": 250_000,
        "n_layers": 3,
        "n_heads": 4,
        "context_length": 128,
        "vocab_size": 512,
        "dropout": 0.1,
    },
    {
        "id": "mellan",
        "label": "Mellanstor GPT (~5 M)",
        "namn": "",
        "beskrivning": "Större modell som kräver mer data och gärna GPU.",
        "anvandningsomrade": "Allmän text",
        "sprak": "Svenska",
        "architecture": "gpt",
        "target_params": 5_000_000,
        "n_layers": 6,
        "n_heads": 8,
        "context_length": 512,
        "vocab_size": 4096,
        "dropout": 0.1,
    },
    {
        "id": "lstm",
        "label": "LSTM-baslinje (~500 k)",
        "namn": "",
        "beskrivning": "Rekurrent baslinje att jämföra transformer-modeller mot.",
        "anvandningsomrade": "Jämförelse",
        "sprak": "Svenska",
        "architecture": "lstm",
        "target_params": 500_000,
        "n_layers": 2,
        "n_heads": 1,
        "context_length": 128,
        "vocab_size": 512,
        "dropout": 0.1,
    },
]
