"""Testar stödet för Lennart 3-modeller från Kaggle: import, chatt, låst träning och export.

Bygger en liten modell med samma kod som Kaggle-träningen (moln/lennart3/lennart3_train.py).

    python -m pytest tests -q
"""
import json
import os
import sys
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "moln" / "lennart3"))

tokenizers = pytest.importorskip("tokenizers")
torch = pytest.importorskip("torch")

SPECIAL = ["<|endoftext|>", "<|user|>", "<|assistant|>", "<|end|>"]


@pytest.fixture(scope="module")
def kaggle_files(tmp_path_factory):
    """lennart3.pt, tokenizer.json och status.json så som Kaggle-körningen sparar dem."""
    out = tmp_path_factory.mktemp("kaggle")
    tok = tokenizers.Tokenizer(tokenizers.models.BPE())
    tok.pre_tokenizer = tokenizers.pre_tokenizers.ByteLevel(add_prefix_space=False)
    tok.decoder = tokenizers.decoders.ByteLevel()
    trainer = tokenizers.trainers.BpeTrainer(
        vocab_size=400, special_tokens=SPECIAL, show_progress=False,
        initial_alphabet=tokenizers.pre_tokenizers.ByteLevel.alphabet())
    tok.train_from_iterator(["Hej! Vad är nätfiske? Nätfiske är bedrägerier via e-post."] * 50, trainer=trainer)
    tok.save(str(out / "tokenizer.json"))

    import lennart3_train as L3
    cfg = {"name": "Lennart 3", "vocab_size": 400, "block_size": 32, "n_embd": 32, "n_head": 4, "n_layer": 2,
           "special_tokens": {s: tok.token_to_id(s) for s in SPECIAL}}
    torch.manual_seed(0)
    model = L3.GPT(cfg)
    cfg["parameters"] = sum(p.numel() for p in model.parameters())
    torch.save({"model": {k: v.half() for k, v in model.state_dict().items()}, "config": cfg}, out / "lennart3.pt")
    (out / "status.json").write_text(json.dumps({"step": 7491, "tokens_seen": 1000, "val_web": 3.4,
                                                 "val_chat": 2.7, "sessions": 1, "time": "2026-11-19 17:58"}))
    return out, model


@pytest.fixture(scope="module")
def app(tmp_path_factory):
    os.environ["AICC_DATA"] = str(tmp_path_factory.mktemp("data"))
    from aicc.core import datasets, models, training
    from aicc.engine import inference
    datasets.seed_builtin()
    return type("App", (), dict(datasets=datasets, models=models, training=training, inference=inference))


def test_import_chatt_och_lasning(app, kaggle_files):
    folder, ref = kaggle_files
    files = {n: folder / n for n in ("lennart3.pt", "tokenizer.json", "status.json")}
    m = app.models.import_lennart3(files)
    assert m["namn"] == "Lennart 3"
    assert m["arkitektur"]["architecture"] == "gpt-l3"
    assert m["arkitektur"]["n_params"] == sum(p.numel() for p in ref.parameters())
    assert m["steg"] == 7491 and m["tranad"]

    # Den genererade modellkoden ger samma utdata som träningskoden.
    from aicc.engine import runtime
    mdir = app.models.model_dir(m["id"])
    gen = runtime.build_model(mdir, m["arkitektur"])
    runtime.load_weights(gen, mdir / "checkpoints" / m["checkpoints"][0]["fil"])
    ref_half = type(ref)(ref.cfg)
    ref_half.load_state_dict({k: v.half().float() for k, v in ref.state_dict().items()})
    x = torch.randint(0, 400, (1, 20))
    with torch.no_grad():
        assert torch.allclose(gen.eval()(x)[0], ref_half.eval()(x)[0], atol=1e-5)

    events = list(app.inference.chat_stream(m["id"], [{"role": "user", "content": "Vad är nätfiske?"}],
                                            temperature=0.0, max_tokens=60))
    assert events[0]["typ"] == "start" and events[-1]["typ"] == "klar"
    assert events[-1]["tokens"] >= 1

    from aicc.core import AppError
    with pytest.raises(AppError, match="Kaggle"):
        app.training.start_run(m["id"], "svensk-cybersakerhet", {})

    # Konfigurering ändrar inte arkitekturen.
    m2 = app.models.update_model(m["id"], {"namn": "Lennart 3b", "architecture": "gpt", "n_layers": 9})
    assert m2["namn"] == "Lennart 3b" and m2["arkitektur"]["n_layers"] == 2

    # Export → import behåller formatet.
    fname, data = app.models.export_model(m["id"])
    zpath = folder / fname
    zpath.write_bytes(data)
    again = app.models.import_model(zpath, "Lennart 3 kopia")
    assert again["arkitektur"]["architecture"] == "gpt-l3" and again["tranad"]


def test_fortsattning_far_versionsnummer(app, kaggle_files, tmp_path):
    folder, _ = kaggle_files
    status = tmp_path / "status.json"
    status.write_text(json.dumps({"step": 15000, "sessions": 2}))
    m = app.models.import_lennart3({"lennart3.pt": folder / "lennart3.pt",
                                    "tokenizer.json": folder / "tokenizer.json", "status.json": status})
    assert m["namn"] == "Lennart 3.1" and m["steg"] == 15000


def test_zip_fran_kaggle_och_felaktiga_filer(app, kaggle_files, tmp_path):
    folder, _ = kaggle_files
    z = tmp_path / "lennart3.zip"
    with zipfile.ZipFile(z, "w") as zf:
        for n in ("lennart3.pt", "tokenizer.json"):
            zf.write(folder / n, f"lennart3/{n}")
    m = app.models.import_model(z, "Från zip")
    assert m["arkitektur"]["architecture"] == "gpt-l3"

    from aicc.core import AppError
    with pytest.raises(AppError, match="tokenizer.json"):
        app.models.import_lennart3({"lennart3.pt": folder / "lennart3.pt"})
    bad = tmp_path / "fel.pt"
    torch.save({"vikter": torch.zeros(2)}, bad)
    with pytest.raises(AppError, match="Lennart 3"):
        app.models.import_lennart3({"lennart3.pt": bad, "tokenizer.json": folder / "tokenizer.json"})
