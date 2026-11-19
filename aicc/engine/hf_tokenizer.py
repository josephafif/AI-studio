"""Tokenizer i Hugging Face-format (biblioteket ``tokenizers``), som Lennart 3 använder.

Har samma gränssnitt som panelens egen ``Tokenizer`` så att chatten fungerar likadant:
``encode``, ``encode_chat``, ``decode``, ``stream_decoder`` och id:n för specialtokens.
"""
from __future__ import annotations

import json
from pathlib import Path

from ..core import AppError

REQUIRED = ("<|user|>", "<|assistant|>", "<|end|>")


def is_hf_tokenizer(path: Path) -> bool:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except (OSError, ValueError):
        return False
    return isinstance(payload, dict) and isinstance(payload.get("model"), dict) and "added_tokens" in payload


class HFTokenizer:
    def __init__(self, path: Path):
        try:
            from tokenizers import Tokenizer
        except ImportError:
            raise AppError("Paketet 'tokenizers' saknas. Kör installera.bat igen, eller: "
                           "python -m pip install tokenizers")
        self._tok = Tokenizer.from_file(str(path))
        ids = {t: self._tok.token_to_id(t) for t in REQUIRED}
        if any(v is None for v in ids.values()):
            raise AppError("Tokenizern saknar chattokens (<|user|>, <|assistant|>, <|end|>)")
        self.user_id, self.assistant_id, self.end_id = (ids[t] for t in REQUIRED)
        eos = self._tok.token_to_id("<|endoftext|>")
        self.pad_id = eos if eos is not None else self.end_id
        self.vocab_size = self._tok.get_vocab_size()

    @staticmethod
    def _clean(text: str) -> str:
        # Text från användaren får inte kunna bli specialtokens som <|assistant|>.
        return text.replace("<|", "< |")

    def encode(self, text: str) -> list[int]:
        return self._tok.encode(self._clean(text)).ids

    def encode_chat(self, messages: list[dict], add_generation_prompt: bool = False) -> list[int]:
        """``<|user|>fråga<|assistant|>svar<|end|>`` – samma format som i träningen."""
        out: list[int] = []
        for msg in messages:
            content = (msg.get("content") or "").strip()
            if msg.get("role") == "assistant":
                out += [self.assistant_id, *self.encode(content), self.end_id]
            else:
                out += [self.user_id, *self.encode(content)]
        if add_generation_prompt:
            out.append(self.assistant_id)
        return out

    def decode(self, ids) -> str:
        return self._tok.decode([int(i) for i in ids])

    def stream_decoder(self):
        """Avkodar token för token; väntar när ett tecken är delat över flera tokens."""
        ids: list[int] = []
        done = [""]

        def step(token_id):
            ids.append(int(token_id))
            text = self._tok.decode(ids)
            if text.endswith("�"):
                return ""
            piece = text[len(done[0]):]
            done[0] = text
            return piece
        return step


def load_tokenizer(path: Path):
    """Läser panelens egna tokenizer eller en Hugging Face-tokenizer, beroende på filens format."""
    if is_hf_tokenizer(path):
        return HFTokenizer(path)
    from .tokenizer import Tokenizer
    return Tokenizer.load(path)
