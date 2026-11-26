"""Bygger raknare.html: den fristående räknarsidan (raknare.js inlagd i mall.html). Kör: python webb/bygg.py

Webbversionen av hela Lennart byggs med webb/app/bygg.py och hamnar i webb/lennart.html."""
from pathlib import Path

HERE = Path(__file__).resolve().parent
js = (HERE / "raknare.js").read_text(encoding="utf-8").replace('if (typeof module !== "undefined") module.exports = { rakna };', "")
html = (HERE / "mall.html").read_text(encoding="utf-8").replace("/*RAKNARE*/", js.strip())
(HERE / "raknare.html").write_text(html, encoding="utf-8")
print("skrev", HERE / "raknare.html", len(html), "byte")
