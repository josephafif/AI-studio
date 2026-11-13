"""Systemstatus: CPU, minne, disk och vilka beräkningsenheter som finns."""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import threading

from .. import __version__, paths

try:
    import psutil
except ImportError:  # pragma: no cover
    psutil = None

_devices: dict | None = None
_devices_lock = threading.Lock()

_PROBE = r"""
import json, torch
out = {"torch": torch.__version__, "cuda": torch.cuda.is_available(), "gpus": [], "threads": torch.get_num_threads()}
if out["cuda"]:
    for i in range(torch.cuda.device_count()):
        p = torch.cuda.get_device_properties(i)
        out["gpus"].append({"id": "cuda:%d" % i, "namn": p.name, "minne": p.total_memory})
mps = getattr(torch.backends, "mps", None)
out["mps"] = bool(mps and mps.is_available())
print(json.dumps(out))
"""


def devices(refresh: bool = False) -> dict:
    """Frågar PyTorch (i en egen process) vilka enheter som kan användas för träning."""
    global _devices
    with _devices_lock:
        if _devices is not None and not refresh:
            return _devices
        info = {"torch": None, "cuda": False, "gpus": [], "mps": False, "threads": None, "fel": None}
        try:
            kwargs = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
            res = subprocess.run([sys.executable, "-c", _PROBE], capture_output=True, text=True,
                                 timeout=120, **kwargs)
            if res.returncode == 0:
                import json
                info.update(json.loads(res.stdout.strip().splitlines()[-1]))
            else:
                info["fel"] = (res.stderr or "PyTorch kunde inte laddas").strip().splitlines()[-1]
        except Exception as exc:  # noqa: BLE001
            info["fel"] = str(exc)
        options = [{"id": "auto", "namn": "Automatiskt (GPU om det finns)"},
                   {"id": "cpu", "namn": f"CPU ({os.cpu_count()} trådar)"}]
        for gpu in info["gpus"]:
            options.append({"id": gpu["id"], "namn": f"GPU: {gpu['namn']} ({gpu['minne'] / 2**30:.0f} GB)"})
        if info["mps"]:
            options.append({"id": "mps", "namn": "Apple GPU (MPS)"})
        info["val"] = options
        _devices = info
        return info


def status() -> dict:
    out = {
        "version": __version__,
        "os": f"{platform.system()} {platform.release()}",
        "python": platform.python_version(),
        "cpu": platform.processor() or platform.machine(),
        "cpu_karnor": os.cpu_count(),
        "datamapp": str(paths.data_root()),
        "cpu_procent": None, "minne_totalt": None, "minne_anvant": None,
    }
    if psutil is not None:
        out["cpu_procent"] = psutil.cpu_percent(interval=None)
        vm = psutil.virtual_memory()
        out["minne_totalt"], out["minne_anvant"] = vm.total, vm.total - vm.available
    try:
        du = shutil.disk_usage(paths.data_root() if paths.data_root().exists() else paths.APP_ROOT)
        out["disk_totalt"], out["disk_ledigt"] = du.total, du.free
    except OSError:
        out["disk_totalt"] = out["disk_ledigt"] = None
    out["enheter"] = _devices
    return out
