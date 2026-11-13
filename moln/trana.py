"""Tränar en modell utan gränssnitt – avsett för molndatorer med GPU (Colab, Kaggle m.fl.).

Använder exakt samma modellhantering och träningsprocess som kontrollpanelen. Resultatet
blir en .zip som importeras under Modeller → Importera modell på den egna datorn.

    # ny, större modell på all hämtad data
    python moln/trana.py --ny "Lennart 2" --parametrar 8000000 --lager 6 --heads 6 \
        --context 256 --ordforrad 8192 --steg 15000 --batch 64

    # träna vidare på en befintlig modell (exporterad från kontrollpanelen)
    python moln/trana.py --modell-zip Lennart.aicc-modell.zip --steg 20000

Körs kommandot igen med samma modellnamn fortsätter träningen från senaste checkpoint.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
for _p in (ROOT / ".paket", ROOT):
    if _p.exists() and str(_p) not in sys.path:
        sys.path.insert(0, str(_p))


def main() -> int:
    ap = argparse.ArgumentParser(description="Molnträning för AI Control Center")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--ny", metavar="NAMN", help="skapa (eller fortsätt på) en modell med det här namnet")
    src.add_argument("--modell-zip", metavar="FIL", help="träna vidare på en exporterad modell")
    ap.add_argument("--beskrivning", default="Svensk AI-assistent inriktad på cybersäkerhet och IT-säkerhet.")
    ap.add_argument("--anvandningsomrade", default="Cybersäkerhet och IT-säkerhet")
    ap.add_argument("--arkitektur", default="gpt", choices=["gpt", "lstm", "gru"])
    ap.add_argument("--parametrar", type=int, default=8_000_000)
    ap.add_argument("--lager", type=int, default=6)
    ap.add_argument("--heads", type=int, default=6)
    ap.add_argument("--context", type=int, default=256)
    ap.add_argument("--ordforrad", type=int, default=8192)
    ap.add_argument("--dropout", type=float, default=0.1)
    ap.add_argument("--dataset", default="utokad-traningsdata", help="datasetets id (se Dataset i panelen)")
    ap.add_argument("--steg", type=int, default=15_000)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--lr", type=float, default=6e-4)
    ap.add_argument("--enhet", default="auto")
    ap.add_argument("--checkpoint-var", type=int, default=2000)
    ap.add_argument("--validera-var", type=int, default=1000)
    ap.add_argument("--data", help="datamapp (standard: ./data)")
    ap.add_argument("--ut", help="var den färdiga modellen sparas (.zip)")
    ap.add_argument("--med-optimerare", action="store_true",
                    help="ta med optimerarens tillstånd i zip-filen (tre gånger större fil)")
    args = ap.parse_args()
    if args.data:
        os.environ["AICC_DATA"] = str(Path(args.data).resolve())

    from aicc.core import datasets, models, training

    datasets.seed_builtin()
    ds = datasets.get_dataset(args.dataset)

    if args.modell_zip:
        marker = Path(os.environ.get("AICC_DATA") or ROOT / "data") / f".moln-{Path(args.modell_zip).name}.id"
        if marker.exists() and (models.models_dir_exists(marker.read_text().strip())):
            model = models.get_model(marker.read_text().strip())
        else:
            model = models.import_model(Path(args.modell_zip))
            marker.write_text(model["id"])
    else:
        model = next((m for m in models.list_models() if m["namn"].lower() == args.ny.lower()), None)
        if model is None:
            model = models.create_model({
                "namn": args.ny, "beskrivning": args.beskrivning, "anvandningsomrade": args.anvandningsomrade,
                "sprak": "Svenska", "architecture": args.arkitektur, "target_params": args.parametrar,
                "n_layers": args.lager, "n_heads": args.heads, "context_length": args.context,
                "vocab_size": args.ordforrad, "dropout": args.dropout})
    a = model["arkitektur"]
    print(f"Modell: {model['namn']} – {a['n_params']:,} parametrar, {a['n_layers']} lager, d_model {a['d_model']}, "
          f"context {a['context_length']}, ordförråd {a['vocab_size']}".replace(",", " "))
    print(f"Dataset: {ds['namn']} – {ds['antal']:,} poster, {ds['tecken'] / 1e6:.0f} miljoner tecken".replace(",", " "))
    resume = "senaste" if models.list_checkpoints(model["id"]) else None
    if resume:
        print(f"Fortsätter från steg {models.list_checkpoints(model['id'])[-1]['step']}")

    run = training.start_run(model["id"], args.dataset, {
        "max_steps": args.steg, "batch_size": args.batch, "learning_rate": args.lr, "device": args.enhet,
        "warmup_steps": min(500, args.steg // 10), "eval_interval": args.validera_var,
        "checkpoint_interval": args.checkpoint_var, "keep_checkpoints": 3, "log_interval": 50}, resume)
    offset, last_line, status = 0, 0.0, {}
    try:
        while True:
            time.sleep(2)
            data = training.get_run(run["run_id"], 0, offset)
            status = data["status"]
            offset = data["log_offset"]
            for line in data["log"].splitlines():
                if "· loss" not in line:
                    print(line, flush=True)
            if status["state"] == "running" and time.time() - last_line > 30 and status.get("loss") is not None:
                last_line = time.time()
                eta = status.get("eta") or 0
                print(f"  steg {status['step']}/{status['max_steps']} · loss {status['loss']:.3f} · "
                      f"val {status['val_loss'] if status.get('val_loss') is None else round(status['val_loss'], 3)} · "
                      f"{(status.get('tokens_per_sec') or 0) / 1000:.0f}k tok/s · kvar {int(eta // 60)} min", flush=True)
            if not status["aktiv"]:
                break
    except KeyboardInterrupt:
        print("Avbryter – sparar checkpoint …")
        training.control(run["run_id"], "stop")
        while training.get_run(run["run_id"])["status"]["aktiv"]:
            time.sleep(1)
    if status.get("state") == "failed":
        print("TRÄNINGEN MISSLYCKADES:", status.get("error"))
        return 1

    name, blob = models.export_model(model["id"], include_optimizer=args.med_optimerare)
    out = Path(args.ut or name)
    out.write_bytes(blob)
    print(f"\nKlar. Modellen är sparad som {out.resolve()} ({len(blob) / 2**20:.0f} MB).")
    print("Ladda ner filen och välj Modeller → Importera modell i kontrollpanelen.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
