"""Träningsprocessen. Körs alltid som en egen process:

    python -m aicc.engine.train_worker <körningsmapp>

Kommunikationen med kontrollpanelen sker enbart via filer i körningsmappen:

    config.json    (in)   vad som ska tränas och med vilka parametrar
    control.json   (in)   kommandon: pause / resume / stop
    status.json    (ut)   aktuellt tillstånd
    metrics.jsonl  (ut)   loss-värden per loggintervall
    train.log      (ut)   läsbar logg
"""
from __future__ import annotations

import json
import math
import os
import random
import signal
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path

DEFAULT_PARAMS = {
    "max_steps": 2000,
    "batch_size": 32,
    "learning_rate": 1e-3,
    "weight_decay": 0.01,
    "warmup_steps": 100,
    "grad_clip": 1.0,
    "eval_interval": 200,
    "eval_batches": 20,
    "checkpoint_interval": 500,
    "keep_checkpoints": 5,
    "log_interval": 20,
    "device": "auto",
    "seed": 1337,
    "threads": 0,
    "mixed_precision": True,
}


class Run:
    def __init__(self, run_dir: Path):
        self.dir = run_dir
        self.cfg = json.loads((run_dir / "config.json").read_text(encoding="utf-8"))
        self.params = {**DEFAULT_PARAMS, **(self.cfg.get("params") or {})}
        self.status = {
            "run_id": self.cfg["run_id"],
            "model_id": self.cfg["model_id"],
            "dataset_id": self.cfg["dataset_id"],
            "state": "starting",
            "message": "Startar träningsprocessen …",
            "pid": os.getpid(),
            "step": 0,
            "max_steps": int(self.params["max_steps"]),
            "start_step": 0,
            "global_step": 0,
            "loss": None,
            "val_loss": None,
            "best_val_loss": None,
            "lr": None,
            "tokens_per_sec": None,
            "elapsed": 0.0,
            "eta": None,
            "device": None,
            "started": datetime.now().isoformat(timespec="seconds"),
            "error": None,
        }
        self._log = open(run_dir / "train.log", "a", encoding="utf-8", buffering=1)
        self._metrics = open(run_dir / "metrics.jsonl", "a", encoding="utf-8", buffering=1)
        self._control_mtime = None
        self.stop_requested = False

    def log(self, msg: str) -> None:
        self._log.write(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}\n")

    def metric(self, **values) -> None:
        self._metrics.write(json.dumps(values) + "\n")

    def write_status(self, **updates) -> None:
        from ..paths import write_json
        self.status.update(updates)
        self.status["updated"] = datetime.now().isoformat(timespec="seconds")
        write_json(self.dir / "status.json", self.status)

    def poll_control(self) -> str | None:
        """Returnerar ett nytt kommando om kontrollfilen har ändrats."""
        path = self.dir / "control.json"
        try:
            mtime = path.stat().st_mtime_ns
        except OSError:
            return None
        if mtime == self._control_mtime:
            return None
        self._control_mtime = mtime
        try:
            return json.loads(path.read_text(encoding="utf-8")).get("command")
        except (OSError, json.JSONDecodeError):
            self._control_mtime = None
            return None


def main(run_dir: Path) -> int:
    run = Run(run_dir)
    run.write_status()
    signal.signal(signal.SIGTERM, lambda *_: setattr(run, "stop_requested", True))
    try:
        train(run)
        return 0
    except Exception as exc:  # noqa: BLE001 – allt ska hamna i loggen
        run.log("FEL: " + "".join(traceback.format_exception(exc)))
        run.write_status(state="failed", message="Träningen misslyckades", error=str(exc) or type(exc).__name__)
        return 1


def train(run: Run) -> None:
    import torch

    from .. import paths
    from ..core import datasets, models
    from . import runtime
    from .tokenizer import Tokenizer

    p = run.params
    model_id, dataset_id = run.cfg["model_id"], run.cfg["dataset_id"]
    mdir = models.model_dir(model_id)
    cfg = models.load_config(model_id)
    arch = cfg["arkitektur"]
    ds_meta = datasets.get_dataset(dataset_id)
    ckpt_dir = mdir / "checkpoints"
    ckpt_dir.mkdir(exist_ok=True)

    seed = int(p["seed"])
    random.seed(seed)
    torch.manual_seed(seed)
    if int(p["threads"]) > 0:
        torch.set_num_threads(int(p["threads"]))

    device, warning = runtime.resolve_device(p["device"])
    dev_label = str(device)
    if device.type == "cuda":
        dev_label = f"{device} ({torch.cuda.get_device_name(device)})"
    run.log(f"Modell: {cfg['namn']} · {arch['n_params']:,} parametrar · {arch['architecture'].upper()}")
    run.log(f"Dataset: {ds_meta['namn']} ({ds_meta['antal']} poster)")
    run.log(f"Enhet: {dev_label}" + (f" · {torch.get_num_threads()} trådar" if device.type == "cpu" else ""))
    if warning:
        run.log("VARNING: " + warning)
    run.write_status(state="preparing", message="Läser in data …", device=dev_label,
                     n_params=arch["n_params"])

    # ---------------------------------------------------------------- data
    if ds_meta.get("uppdelning"):
        train_recs = list(datasets.iter_records(dataset_id, "train"))
        val_recs = list(datasets.iter_records(dataset_id, "val"))
        run.log(f"Använder datasetets uppdelning: {len(train_recs)} träning, {len(val_recs)} validering")
    else:
        recs = list(datasets.iter_records(dataset_id))
        random.Random(seed).shuffle(recs)
        n_val = max(1, len(recs) // 20) if len(recs) >= 20 else 0
        train_recs, val_recs = recs[n_val:], recs[:n_val]
        run.log(f"Datasetet är inte uppdelat – håller automatiskt undan {n_val} poster för validering")
    if not train_recs:
        raise RuntimeError("Datasetet innehåller ingen träningsdata")

    # ----------------------------------------------------------- tokenizer
    tok_path = mdir / "tokenizer.json"
    if tok_path.exists():
        tokenizer = Tokenizer.load(tok_path)
        run.log(f"Använder befintlig tokenizer ({len(tokenizer.merges)} merges)")
    else:
        tokenizer = Tokenizer(arch["vocab_size"])
        if tokenizer.max_merges > 0:
            run.write_status(message="Tränar tokenizer (BPE) …")
            t0 = time.time()
            tokenizer.train(datasets.record_text(r) for r in train_recs)
            run.log(f"Tokenizer tränad: {len(tokenizer.merges)} merges av max {tokenizer.max_merges} "
                    f"({time.time() - t0:.1f} s)")
        tokenizer.save(tok_path)
    if tokenizer.vocab_size != arch["vocab_size"]:
        raise RuntimeError("Tokenizerns ordförråd matchar inte modellens konfiguration")

    run.write_status(message="Kodar träningsdata till tokens …")
    order = list(range(len(train_recs)))
    random.Random(seed).shuffle(order)
    t0 = time.time()
    train_ids = runtime.to_tensor(runtime.encode_records(
        tokenizer, (train_recs[i] for i in order),
        lambda n: run.write_status(message=f"Kodar träningsdata till tokens … {n:,} av {len(train_recs):,} poster"
                                   .replace(",", " "))))
    val_ids = runtime.to_tensor(runtime.encode_records(tokenizer, val_recs[:5000]))
    if time.time() - t0 > 5:
        run.log(f"Data kodad på {time.time() - t0:.0f} s")
    block = min(arch["context_length"], len(train_ids) - 1)
    if block < 8:
        raise RuntimeError("Träningsdatat är för litet (färre än 9 tokens)")
    val_block = min(block, len(val_ids) - 1)
    has_val = val_block >= 8
    run.log(f"Träningsdata: {len(train_ids):,} tokens · validering: {len(val_ids):,} tokens · "
            f"sekvenslängd {block}")
    if block < arch["context_length"]:
        run.log("VARNING: datat är kortare än modellens context length – använder kortare sekvenser.")

    # -------------------------------------------------------------- modell
    model = runtime.build_model(mdir, arch).to(device)
    start_step = 0
    optimizer = torch.optim.AdamW(model.parameters(), lr=float(p["learning_rate"]),
                                  weight_decay=float(p["weight_decay"]), betas=(0.9, 0.99))
    use_amp = device.type == "cuda" and bool(p.get("mixed_precision", True))
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)
    if use_amp:
        run.log("Blandad precision (float16) används på GPU")
    resume = run.cfg.get("resume_from")
    if resume:
        ckpt = runtime.load_weights(model, ckpt_dir / resume, device)
        start_step = int(ckpt.get("step", 0))
        run.log(f"Fortsätter från checkpoint {resume} (steg {start_step})")
        opt_path = ckpt_dir / "optimizer.pt"
        if opt_path.exists():
            try:
                opt = torch.load(opt_path, map_location=device, weights_only=True)
                if int(opt.get("step", -1)) == start_step:
                    optimizer.load_state_dict(opt["optimizer"])
                    run.log("Optimerarens tillstånd återställt")
            except Exception:  # noqa: BLE001
                run.log("Optimerarens tillstånd kunde inte läsas – startar med ny optimerare")
    else:
        run.log("Startar från slumpmässigt initierade vikter")

    max_steps = int(p["max_steps"])
    batch_size = int(p["batch_size"])
    base_lr = float(p["learning_rate"])
    warmup = min(int(p["warmup_steps"]), max(0, max_steps // 2))
    log_iv = max(1, int(p["log_interval"]))
    eval_iv = max(1, int(p["eval_interval"]))
    ckpt_iv = max(1, int(p["checkpoint_interval"]))
    keep = max(1, int(p["keep_checkpoints"]))

    def lr_at(step: int) -> float:
        if step < warmup:
            return base_lr * (step + 1) / warmup
        progress = (step - warmup) / max(1, max_steps - warmup)
        return base_lr * (0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * min(1.0, progress))))

    def batch(data, blk, generator=None):
        ix = torch.randint(len(data) - blk, (batch_size,), generator=generator)
        x = torch.stack([data[i:i + blk] for i in ix]).long()
        y = torch.stack([data[i + 1:i + 1 + blk] for i in ix]).long()
        return x.to(device), y.to(device)

    @torch.no_grad()
    def evaluate() -> float | None:
        if not has_val:
            return None
        model.eval()
        gen = torch.Generator().manual_seed(1234)
        losses = []
        for _ in range(int(p["eval_batches"])):
            x, y = batch(val_ids, val_block, gen)
            losses.append(model(x, y)[1].item())
        model.train()
        return sum(losses) / len(losses)

    def sample() -> str | None:
        first = train_recs[0]
        if "messages" in first:
            question = first["messages"][0]["content"]
            prompt = tokenizer.encode_chat([{"role": "user", "content": question}], True)
        else:
            question = first["text"][:40]
            prompt = tokenizer.encode(question)
        out = list(runtime.generate(model, tokenizer, prompt, 60, 0.5, 20, device))
        return f"{question!r} → {tokenizer.decode(out)!r}"

    best_val = None
    last_val = None
    last_train = None

    def save_checkpoint(step_in_run: int) -> str:
        gstep = start_step + step_in_run
        name = f"ckpt_{gstep:07d}.pt"
        tmp = ckpt_dir / (name + ".tmp")
        torch.save({"model": model.state_dict(), "step": gstep}, tmp)
        os.replace(tmp, ckpt_dir / name)
        paths.write_json((ckpt_dir / name).with_suffix(".json"), {
            "step": gstep, "train_loss": last_train, "val_loss": last_val,
            "tid": paths.now_iso(), "run_id": run.cfg["run_id"], "dataset": ds_meta["namn"],
        })
        tmp = ckpt_dir / "optimizer.pt.tmp"
        torch.save({"optimizer": optimizer.state_dict(), "step": gstep}, tmp)
        os.replace(tmp, ckpt_dir / "optimizer.pt")
        ckpts = models.list_checkpoints(model_id)
        for old in ckpts[:-keep]:
            if not old["bast"]:
                models.delete_checkpoint(model_id, old["fil"])
        run.log(f"Checkpoint sparad: {name}")
        return name

    # ---------------------------------------------------------- träningsloop
    model.train()
    run.write_status(state="running", message="Tränar", start_step=start_step, global_step=start_step,
                     train_tokens=len(train_ids), val_tokens=len(val_ids))
    run.log(f"Träning startar: {max_steps} steg · batch {batch_size} · lr {base_lr:g}")

    step = 0
    active_time = 0.0
    tick = time.time()
    window, window_t0, window_steps = [], time.time(), 0
    saved_at = -1
    final_state = "completed"

    while step < max_steps:
        command = run.poll_control()
        if run.stop_requested:
            command = "stop"
        if command == "pause":
            active_time += time.time() - tick
            if saved_at != step and step > 0:
                save_checkpoint(step)
                saved_at = step
            run.log("Träningen pausad")
            run.write_status(state="paused", message="Pausad", elapsed=active_time, eta=None,
                             step=step, global_step=start_step + step)
            while True:
                time.sleep(0.3)
                command = run.poll_control()
                if run.stop_requested:
                    command = "stop"
                if command in ("resume", "stop"):
                    break
            if command == "resume":
                run.log("Träningen återupptas")
                run.write_status(state="running", message="Tränar")
            tick = time.time()
            window, window_t0, window_steps = [], time.time(), 0
        if command == "stop":
            final_state = "stopped"
            run.log("Träningen avbryts på användarens begäran")
            break

        lr = lr_at(step)
        for group in optimizer.param_groups:
            group["lr"] = lr
        x, y = batch(train_ids, block)
        with torch.autocast(device_type=device.type, dtype=torch.float16, enabled=use_amp):
            _, loss = model(x, y)
        if not torch.isfinite(loss):
            raise RuntimeError("Loss blev oändlig/NaN – prova en lägre inlärningshastighet")
        optimizer.zero_grad(set_to_none=True)
        scaler.scale(loss).backward()
        if float(p["grad_clip"]) > 0:
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(), float(p["grad_clip"]))
        scaler.step(optimizer)
        scaler.update()
        step += 1
        window.append(loss.item())
        window_steps += 1

        is_last = step == max_steps
        if step % log_iv == 0 or is_last or step == 1:
            now = time.time()
            active_time += now - tick
            tick = now
            last_train = sum(window) / len(window)
            tps = window_steps * batch_size * block / max(1e-6, now - window_t0)
            eta = (max_steps - step) * active_time / step
            run.metric(step=start_step + step, loss=round(last_train, 5), lr=lr, t=round(active_time, 2))
            run.write_status(step=step, global_step=start_step + step, loss=last_train, lr=lr,
                             tokens_per_sec=tps, elapsed=active_time, eta=eta)
            if step % (log_iv * 5) == 0 or is_last or step == 1:
                run.log(f"steg {step}/{max_steps} · loss {last_train:.4f} · lr {lr:.2e} · {tps:,.0f} tokens/s")
            window, window_t0, window_steps = [], now, 0

        if step % eval_iv == 0 or is_last:
            last_val = evaluate()
            if last_val is not None:
                if best_val is None or last_val < best_val:
                    best_val = last_val
                run.metric(step=start_step + step, val_loss=round(last_val, 5))
                run.write_status(val_loss=last_val, best_val_loss=best_val)
                run.log(f"validering vid steg {step}: val-loss {last_val:.4f} (bästa {best_val:.4f})")
            try:
                text = sample()
                if text:
                    run.log("exempel: " + text)
            except Exception:  # noqa: BLE001 – exempeltext får aldrig stoppa träningen
                pass
            tick = time.time()  # räkna inte utvärderingen som träningstid

        if step % ckpt_iv == 0 or is_last:
            save_checkpoint(step)
            saved_at = step
            tick = time.time()

    active_time += time.time() - tick
    if step > 0 and saved_at != step:
        run.write_status(state="stopping", message="Sparar checkpoint …")
        save_checkpoint(step)

    if step > 0:
        hist_path = mdir / "traningshistorik.json"
        history = paths.read_json(hist_path, []) or []
        history.append({
            "run_id": run.cfg["run_id"], "dataset_id": dataset_id, "dataset": ds_meta["namn"],
            "start": run.status["started"], "slut": paths.now_iso(), "status": final_state,
            "steg_fran": start_step, "steg_till": start_step + step,
            "loss": last_train, "val_loss": last_val, "enhet": dev_label,
            "sekunder": round(active_time, 1), "parametrar": {k: p[k] for k in DEFAULT_PARAMS},
        })
        paths.write_json(hist_path, history)

    if final_state == "completed":
        run.log(f"Träningen klar: {step} steg på {active_time:.0f} s")
        run.write_status(state="completed", message="Träningen är klar", elapsed=active_time, eta=0,
                         step=step, global_step=start_step + step)
    else:
        run.write_status(state="stopped", message=f"Avbruten vid steg {step}", elapsed=active_time, eta=None,
                         step=step, global_step=start_step + step)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Användning: python -m aicc.engine.train_worker <körningsmapp>")
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1])))
