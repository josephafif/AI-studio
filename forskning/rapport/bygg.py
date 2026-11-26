"""Bygger forskningsrapporten (rapport.html) av resultatfilerna i forskning/.

Kör: python forskning/rapport/bygg.py
"""
import json
from pathlib import Path

F = Path(__file__).resolve().parents[1]


def load(p, default=None):
    try:
        return json.load(open(F / p))
    except Exception:
        return default


def main():
    lens = load("logitlins/resultat_lennart34.json", {"lager": []})
    las = load("kunskapsbank/las_resultat.json", {})
    pilots = {v: load(f"arkitekturpilot/resultat_{v}.json") for v in ("lennart3", "modern", "modern+skiss")}
    data = {
        "eko": {"niva": ["Snabb", "Medel", "Djup"], "utan": [19.4, 51.8, 102.2], "med": [21.6, 39.8, 74.0]},
        "kostnad": {"k": [1, 2, 4, 8], "fore": [1.0, 1.28, 1.96, 3.34], "efter": [1.0, 1.20, 1.28, 1.93]},
        "urval": [
            ["Ett svar (Snabb)", 30.9], ["Girigt svar", 32.4], ["Appens poäng, 3 utkast", 28.7],
            ["Appens poäng, 6 utkast", 29.4], ["Frågevinst", 30.9], ["Bakåtkontroll", 30.1],
            ["Wikipedia som domare", 31.6], ["Konsensus, 6 utkast", 33.1], ["Lärd domare", 34.6],
            ["Orakel: något utkast rätt", 55.1]],
        "kalib": {"niva": ["Snabb", "Medel", "Djup"], "over": [70, 71, 67], "under": [21, 11, 10],
                  "andel": [20, 30, 34]},
        "lins": {"lager": [r["lager"] for r in lens["lager"]],
                 "utan": [round(100 * r["samstammighet"], 1) for r in lens["lager"]],
                 "brygga": [round(100 * r.get("brygga_samstammighet", r["samstammighet"]), 1) for r in lens["lager"]]},
        "las": {k: v["traffsakerhet"] for k, v in las.items()} if las else {},
        "las_exempel": [],
        "pilot": {v: [(round(r["tokens"] / 1e6, 2), round(r["bits_per_byte"], 3), round(100 * r["mittlager_samstammighet"], 1),
                       round(r["tokens_per_s"])) for r in p["steg"]] for v, p in pilots.items() if p},
        "diag": [["Lennart 3.4", 37, 0], ["Lennart 3.4 läsare", 62, 44]],
        "pilot_params": {v: round(p["params_utan_inbaddning"] / 1e6, 2) for v, p in pilots.items() if p},
    }
    if las:
        reader = list(las.values())[-1]
        base = list(las.values())[0]
        want = ["Vad är huvudstaden i Finland?", "Vilket är Sveriges högsta berg?", "Vad är huvudstaden i Norge?",
                "Vad är huvudstaden i Tyskland?"]
        for a, b in zip(base["exempel"], reader["exempel"]):
            if b["fraga"] in want:
                data["las_exempel"].append(dict(fraga=b["fraga"], fore=a["med_3"][:150], efter=b["med_3"][:150]))
        data["las_samtal"] = {k: v["samtal"] for k, v in las.items()}
    html = (F / "rapport" / "mall.html").read_text()
    html = html.replace("/*DATA*/", "const DATA = " + json.dumps(data, ensure_ascii=False) + ";")
    (F / "rapport" / "rapport.html").write_text(html)
    print("skrev", F / "rapport" / "rapport.html", len(html), "byte")


if __name__ == "__main__":
    main()
