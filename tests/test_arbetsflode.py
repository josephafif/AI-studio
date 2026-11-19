"""Testar hela arbetsflödet: skapa modell → importera data → träna → pausa/fortsätt →
chatta → exportera/importera. Körs mot riktiga modeller (små, så att det går fort).

    python -m pytest tests -q
"""
import json
import os
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


@pytest.fixture(scope="module")
def app(tmp_path_factory):
    os.environ["AICC_DATA"] = str(tmp_path_factory.mktemp("data"))
    from aicc.core import datasets, models, sessions, training
    from aicc.engine import inference
    datasets.seed_builtin()
    return type("App", (), dict(datasets=datasets, models=models, sessions=sessions,
                                training=training, inference=inference))


def wait(app, run_id, until, timeout=240):
    t0 = time.time()
    while time.time() - t0 < timeout:
        status = app.training.get_run(run_id)["status"]
        if until(status):
            return status
        assert status["state"] != "failed", status.get("error")
        time.sleep(0.3)
    raise AssertionError(f"timeout, senaste status: {status}")


def test_parameterberakning_stammer_med_pytorch(app, tmp_path):
    from aicc.core import codegen
    from aicc.engine import runtime
    for arch in ("gpt", "lstm", "gru"):
        m = app.models.create_model({"namn": f"Räkna {arch}", "architecture": arch, "target_params": 60_000,
                                     "n_layers": 2, "n_heads": 2, "context_length": 32, "vocab_size": 300})
        model = runtime.build_model(app.models.model_dir(m["id"]), m["arkitektur"])
        actual = sum(p.numel() for p in model.parameters())
        assert actual == m["arkitektur"]["n_params"], arch
        assert abs(actual - 60_000) < 12_000
        app.models.delete_model(m["id"])
    lennart = codegen.resolve_architecture(codegen.PRESETS[0])
    assert 950_000 < lennart["n_params"] < 1_050_000


def test_tokenizer_tur_och_retur():
    from aicc.engine.tokenizer import Tokenizer
    tok = Tokenizer(400)
    text = "Vad är nätfiske? Åäö och 🔒 fungerar – även <|end|> som vanlig text."
    tok.train([text * 20])
    assert tok.merges
    assert tok.decode(tok.encode(text)) == text
    assert max(tok.encode(text)) < tok.pad_id


def test_dataset_import_dubbletter_och_uppdelning(app, tmp_path):
    src = tmp_path / "data.json"
    rows = [{"question": f"Fråga {i}?", "answer": f"Svar {i}."} for i in range(40)]
    rows += [{"question": "fråga 1?", "answer": "Svar 1."}, {"instruction": "Säg hej", "output": "Hej"},
             {"messages": [{"role": "user", "content": "A"}, {"role": "assistant", "content": "B"}]}, 17]
    src.write_text(json.dumps(rows), encoding="utf-8")
    ds = app.datasets.import_dataset(src, "data.json", {"namn": "Test", "licens": "CC0", "kalla": "Egen"})
    assert ds["antal"] == 43 and ds["overhoppade"] == 1 and ds["typ"] == "chatt"
    assert app.datasets.dedupe(ds["id"])["borttagna"] == 1
    meta = app.datasets.split(ds["id"], 80, 10, 10, seed=1)
    u = meta["uppdelning"]
    assert u["train"] + u["val"] + u["test"] == 42 and u["val"] == 4
    assert app.datasets.preview(ds["id"], "val")["totalt"] == 4
    assert app.datasets.get_dataset(ds["id"])["licens"] == "CC0"

    txt = tmp_path / "text.txt"
    txt.write_text("Första stycket.\n\nAndra stycket.\n\nTredje.", encoding="utf-8")
    assert app.datasets.import_dataset(txt, "text.txt")["antal"] == 3
    jl = tmp_path / "rader.jsonl"
    jl.write_text('{"text": "a"}\ninte json\n{"fråga": "q", "svar": "s"}\n', encoding="utf-8")
    d = app.datasets.import_dataset(jl, "rader.jsonl")
    assert d["antal"] == 2 and d["overhoppade"] == 1 and d["typ"] == "blandat"


def test_hela_arbetsflodet(app, tmp_path):
    m = app.models.create_model({"namn": "Testmodell", "sprak": "Svenska", "anvandningsomrade": "Test",
                                 "architecture": "gpt", "target_params": 120_000, "n_layers": 2,
                                 "n_heads": 2, "context_length": 64, "vocab_size": 512})
    mdir = app.models.model_dir(m["id"])
    assert (mdir / "model.py").exists() and (mdir / "config.json").exists() and (mdir / "README.md").exists()
    assert not m["tranad"]

    # Träna, pausa, fortsätt
    params = {"max_steps": 120, "batch_size": 16, "eval_interval": 40, "checkpoint_interval": 40,
              "log_interval": 5, "device": "cpu"}
    run = app.training.start_run(m["id"], "svensk-cybersakerhet", params)
    with pytest.raises(Exception):
        app.training.start_run(m["id"], "svensk-cybersakerhet", params)  # redan igång
    wait(app, run["run_id"], lambda s: s["state"] == "running" and s["step"] >= 10)
    app.training.control(run["run_id"], "pause")
    paused = wait(app, run["run_id"], lambda s: s["state"] == "paused")
    time.sleep(1.0)
    assert app.training.get_run(run["run_id"])["status"]["step"] == paused["step"]
    app.training.control(run["run_id"], "resume")
    done = wait(app, run["run_id"], lambda s: not s["aktiv"])
    assert done["state"] == "completed" and done["step"] == 120

    data = app.training.get_run(run["run_id"])
    losses = [x["loss"] for x in data["metrics"] if "loss" in x]
    assert losses[-1] < losses[0] - 1.0, "loss ska sjunka"
    assert any("val_loss" in x for x in data["metrics"])
    assert "Checkpoint sparad" in data["log"]
    ckpts = app.models.list_checkpoints(m["id"])
    assert ckpts[-1]["step"] == 120 and (mdir / "tokenizer.json").exists()

    # Fortsätt från checkpoint, avbryt mitt i
    run2 = app.training.start_run(m["id"], "svensk-cybersakerhet", {**params, "max_steps": 5000}, "senaste")
    wait(app, run2["run_id"], lambda s: s["state"] == "running" and s["step"] >= 10)
    app.training.control(run2["run_id"], "stop")
    stopped = wait(app, run2["run_id"], lambda s: not s["aktiv"])
    assert stopped["state"] == "stopped" and stopped["start_step"] == 120
    info = app.models.get_model(m["id"])
    assert info["steg"] == 120 + stopped["step"] and len(info["historik"]) == 2

    # Chatta (fast slumpfrö: annars kan modellen ibland välja sluttoken direkt och svara tomt)
    import torch
    torch.manual_seed(0)
    events = list(app.inference.chat_stream(m["id"], [{"role": "user", "content": "Vad är nätfiske?"}],
                                            temperature=0.5, max_tokens=20))
    assert events[0]["typ"] == "start" and events[-1]["typ"] == "klar"
    assert 0 < events[-1]["tokens"] <= 20
    assert "".join(e["text"] for e in events if e["typ"] == "token")

    # Spara session
    ses = app.sessions.save_session({"namn": "Test", "paneler": [{"model_id": m["id"], "modell": "Testmodell",
                                     "meddelanden": [{"role": "user", "content": "Hej"}]}]})
    assert app.sessions.get_session(ses["id"])["paneler"][0]["meddelanden"][0]["content"] == "Hej"

    # Byt namn, exportera, importera, ta bort
    assert app.models.update_model(m["id"], {"namn": "Omdöpt"})["namn"] == "Omdöpt"
    with pytest.raises(Exception):
        app.models.update_model(m["id"], {"n_layers": 3})  # arkitekturen är låst efter träning
    name, blob = app.models.export_model(m["id"])
    z = tmp_path / name
    z.write_bytes(blob)
    imported = app.models.import_model(z)
    assert imported["namn"] == "Omdöpt (2)" and imported["ursprung"] == "importerad"
    assert imported["steg"] == info["steg"]
    out = list(app.inference.chat_stream(imported["id"], [{"role": "user", "content": "Hej"}], 0, 5))
    assert out[-1]["typ"] == "klar"
    app.models.delete_model(imported["id"])
    app.models.delete_model(m["id"])
    assert not mdir.exists()
