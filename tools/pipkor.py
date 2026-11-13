"""Kör pip från mappen .paket. Används av installera.bat när Python saknar venv och pip."""
import runpy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / ".paket"))
sys.argv = ["pip"] + sys.argv[1:]
runpy.run_module("pip", run_name="__main__")
