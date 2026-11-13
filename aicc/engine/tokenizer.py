"""Byte-nivå BPE-tokenizer i ren Python.

Ordförrådet består av de 256 byte-värdena, ett antal inlärda sammanslagningar
(merges) och fyra specialtecken sist. Eftersom basen är bytes kan all text
kodas, oavsett språk, och ordförrådets storlek är exakt den som valdes när
modellen skapades (vilket gör parameterantalet känt i förväg).

Med ``vocab_size = 260`` blir det en ren tecken-/byte-modell utan merges.
"""
from __future__ import annotations

import codecs
import heapq
import json
import re
from collections import Counter
from pathlib import Path

SPECIAL_TOKENS = ["<|pad|>", "<|user|>", "<|assistant|>", "<|end|>"]
MIN_VOCAB = 256 + len(SPECIAL_TOKENS)
_PRETOKEN_RE = re.compile(r" ?\S+|\s+")
_MAX_TRAIN_CHARS = 20_000_000


class Tokenizer:
    def __init__(self, vocab_size: int, merges: list[tuple[int, int]] | None = None):
        if vocab_size < MIN_VOCAB:
            raise ValueError(f"Ordförrådet måste vara minst {MIN_VOCAB}")
        self.vocab_size = int(vocab_size)
        self.merges: list[tuple[int, int]] = [tuple(m) for m in (merges or [])]
        self.pad_id = self.vocab_size - 4
        self.user_id = self.vocab_size - 3
        self.assistant_id = self.vocab_size - 2
        self.end_id = self.vocab_size - 1
        self._build_tables()

    # ------------------------------------------------------------------ setup
    @property
    def max_merges(self) -> int:
        return self.vocab_size - MIN_VOCAB

    def _build_tables(self) -> None:
        self._rank = {pair: i for i, pair in enumerate(self.merges)}
        self._bytes: list[bytes] = [bytes([i]) for i in range(256)]
        for a, b in self.merges:
            self._bytes.append(self._bytes[a] + self._bytes[b])
        self._cache: dict[str, list[int]] = {}

    # --------------------------------------------------------------- training
    def train(self, texts, progress=None) -> None:
        """Lär in merges från en iterator av textsträngar."""
        word_freq: Counter[str] = Counter()
        seen = 0
        for text in texts:
            word_freq.update(_PRETOKEN_RE.findall(text))
            seen += len(text)
            if seen > _MAX_TRAIN_CHARS:
                break

        words: list[list[int]] = []
        freqs: list[int] = []
        for w, f in word_freq.items():
            ids = list(w.encode("utf-8"))
            if len(ids) > 1:
                words.append(ids)
                freqs.append(f)

        pair_counts: Counter[tuple[int, int]] = Counter()
        pair_words: dict[tuple[int, int], set[int]] = {}
        for wi, ids in enumerate(words):
            f = freqs[wi]
            for pair in zip(ids, ids[1:]):
                pair_counts[pair] += f
                pair_words.setdefault(pair, set()).add(wi)

        heap = [(-c, p) for p, c in pair_counts.items()]
        heapq.heapify(heap)
        merges: list[tuple[int, int]] = []
        target = self.max_merges

        while len(merges) < target and heap:
            neg, pair = heapq.heappop(heap)
            count = pair_counts.get(pair, 0)
            if count != -neg:
                continue  # inaktuell post i heapen
            if count < 2:
                break
            new_id = 256 + len(merges)
            merges.append(pair)
            a, b = pair
            touched: set[tuple[int, int]] = set()
            for wi in list(pair_words.get(pair, ())):
                ids = words[wi]
                f = freqs[wi]
                for p in zip(ids, ids[1:]):
                    pair_counts[p] -= f
                    touched.add(p)
                out, i, n = [], 0, len(ids)
                while i < n:
                    if i < n - 1 and ids[i] == a and ids[i + 1] == b:
                        out.append(new_id)
                        i += 2
                    else:
                        out.append(ids[i])
                        i += 1
                words[wi] = out
                for p in zip(out, out[1:]):
                    pair_counts[p] += f
                    pair_words.setdefault(p, set()).add(wi)
                    touched.add(p)
            pair_words.pop(pair, None)
            pair_counts.pop(pair, None)
            for p in touched:
                c = pair_counts.get(p, 0)
                if c > 0:
                    heapq.heappush(heap, (-c, p))
            if progress and len(merges) % 100 == 0:
                progress(len(merges), target)

        self.merges = merges
        self._build_tables()

    # ---------------------------------------------------------------- encode
    def _encode_word(self, word: str) -> list[int]:
        ids = list(word.encode("utf-8"))
        rank = self._rank
        while len(ids) > 1:
            best, best_rank = None, None
            for pair in zip(ids, ids[1:]):
                r = rank.get(pair)
                if r is not None and (best_rank is None or r < best_rank):
                    best, best_rank = pair, r
            if best is None:
                break
            a, b = best
            new_id = 256 + best_rank
            out, i, n = [], 0, len(ids)
            while i < n:
                if i < n - 1 and ids[i] == a and ids[i + 1] == b:
                    out.append(new_id)
                    i += 2
                else:
                    out.append(ids[i])
                    i += 1
            ids = out
        return ids

    def encode(self, text: str) -> list[int]:
        """Kodar vanlig text. Specialtecken i texten behandlas som vanlig text."""
        out: list[int] = []
        cache = self._cache
        for word in _PRETOKEN_RE.findall(text):
            ids = cache.get(word)
            if ids is None:
                ids = self._encode_word(word)
                if len(cache) < 500_000:
                    cache[word] = ids
            out.extend(ids)
        return out

    def encode_chat(self, messages: list[dict], add_generation_prompt: bool = False) -> list[int]:
        """``<|user|>fråga<|assistant|>svar<|end|>`` för varje tur."""
        out: list[int] = []
        for msg in messages:
            role = msg.get("role")
            content = (msg.get("content") or "").strip()
            if role == "assistant":
                out.append(self.assistant_id)
                out.extend(self.encode(content))
                out.append(self.end_id)
            else:
                out.append(self.user_id)
                out.extend(self.encode(content))
        if add_generation_prompt:
            out.append(self.assistant_id)
        return out

    # ---------------------------------------------------------------- decode
    def token_bytes(self, token_id: int) -> bytes:
        if 0 <= token_id < len(self._bytes):
            return self._bytes[token_id]
        return b""

    def decode(self, ids) -> str:
        return b"".join(self.token_bytes(int(i)) for i in ids).decode("utf-8", errors="replace")

    def stream_decoder(self):
        """Inkrementell avkodare som hanterar tecken som delas över flera tokens."""
        dec = codecs.getincrementaldecoder("utf-8")(errors="replace")
        return lambda token_id: dec.decode(self.token_bytes(int(token_id)))

    # ------------------------------------------------------------------- I/O
    def save(self, path: Path) -> None:
        payload = {
            "type": "byte-bpe",
            "vocab_size": self.vocab_size,
            "special_tokens": {
                name: self.vocab_size - 4 + i for i, name in enumerate(SPECIAL_TOKENS)
            },
            "merges": [list(m) for m in self.merges],
        }
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)

    @classmethod
    def load(cls, path: Path) -> "Tokenizer":
        with open(path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        return cls(payload["vocab_size"], [tuple(m) for m in payload.get("merges", [])])
