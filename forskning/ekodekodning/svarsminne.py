"""Experiment 2: delat svarsminne – tidigare svar (till andra, liknande frågor) som förslag.

En server som tusentals personer frågar får samma sorts frågor om och om igen. Med ekodekodningens
exakta kontroll kan tidigare svar användas som förslag till nya svar utan att svaren ändras: utfallet
har exakt samma fördelning som utan minne, men liknande frågor kräver färre pass.

Här: först besvaras 15 frågor (minnet fylls), sedan 15 omformulerade varianter på nivån Snabb
– med och utan minnet som förslagskälla.

Kör: python forskning/ekodekodning/svarsminne.py <lib> <modell.lmod> <tokenizer.json> [resultat.json]
"""
import json
import sys
import time

import numpy as np
from tokenizers import Tokenizer

from ekodekodning import Engine, write_draft

PAIRS = [
    ("Vad är nätfiske?", "Kan du förklara vad phishing är?"),
    ("Hur skapar jag ett starkt lösenord?", "Hur gör man ett bra lösenord?"),
    ("Vad är en brandvägg?", "Vad gör en brandvägg?"),
    ("Vad är tvåfaktorsautentisering?", "Vad betyder tvåstegsverifiering?"),
    ("Vad är ransomware?", "Vad är utpressningsprogram?"),
    ("Hur vet jag om ett sms är bedrägeri?", "Hur känner jag igen ett bedrägeri-sms?"),
    ("Vad är en VPN?", "Vad används VPN till?"),
    ("Varför ska jag uppdatera min telefon?", "Är det viktigt att uppdatera mobilen?"),
    ("Vad är skadlig kod?", "Vad menas med malware?"),
    ("Någon har hackat mitt konto, vad gör jag?", "Mitt konto är hackat, hjälp!"),
    ("Varför är himlen blå?", "Varför ser himlen blå ut?"),
    ("Ge mig tips för att sova bättre.", "Hur kan jag sova bättre?"),
    ("Vad är fotosyntes?", "Förklara fotosyntesen."),
    ("Vad är demokrati?", "Vad betyder demokrati?"),
    ("Hur mår du?", "Hur är läget?"),
]


def answer(eng, tok, sp, q, sources, recycle, rng, T=0.7):
    prompt = [sp["<|user|>"]] + tok.encode(q).ids + [sp["<|assistant|>"]]
    banned = [sp["<|endoftext|>"], sp["<|user|>"], sp["<|assistant|>"]]
    eng.reset()
    p0 = eng.eval(prompt)
    d, st = write_draft(eng, rng, prompt, p0, 120, T, 40, banned, sp["<|end|>"], [prompt] + sources, None, recycle)
    return d, st


def main():
    lib, model, tokp = sys.argv[1:4]
    tok = Tokenizer.from_file(tokp)
    sp = {s: tok.token_to_id(s) for s in ("<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>")}
    eng = Engine(lib, model)
    rng = np.random.default_rng(7)
    memory = []
    for q, _ in PAIRS:  # fyll minnet med svar på originalfrågorna
        d, _ = answer(eng, tok, sp, q, [], False, rng)
        memory.append([sp["<|assistant|>"]] + d.toks + [sp["<|end|>"]])
    res = {}
    for recycle in (False, True):
        name = "med svarsminne" if recycle else "utan minne"
        eng.passes = 0
        rng = np.random.default_rng(99)
        t0, toks, acc, prop = time.time(), 0, 0, 0
        for _, q2 in PAIRS:
            d, st = answer(eng, tok, sp, q2, memory, recycle, rng)
            toks += len(d.toks)
            acc += st["accepted"]
            prop += st["proposed"]
        passes = eng.passes - len(PAIRS)
        res[name] = dict(sekunder=round(time.time() - t0, 1), tokens=toks, pass_=passes,
                         tokens_per_pass=round(toks / max(1, passes), 2), godtagna_forslag=f"{acc}/{prop}")
        print(name, res[name], flush=True)
    json.dump(res, open(sys.argv[4] if len(sys.argv) > 4 else "svarsminne.json", "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
