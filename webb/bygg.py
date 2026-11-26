"""Bygger lennart.html: mallen med räknaren (raknare.js) inlagd. Kör: python webb/bygg.py"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
js = (HERE / "raknare.js").read_text(encoding="utf-8").replace('if (typeof module !== "undefined") module.exports = { rakna };', "")
html = (HERE / "mall.html").read_text(encoding="utf-8").replace("/*RAKNARE*/", js.strip())
(HERE / "lennart.html").write_text(html, encoding="utf-8")
print("skrev", HERE / "lennart.html", len(html), "byte")
