# Kunskapsbank – uppslagsverk och läsförståelse

| Fil | Vad |
|---|---|
| `sok.py` | BM25-sökmotor med svensk ordstamning över inledningarna i svenska Wikipedia (727 000 artiklar, byggs på ~90 s) |
| `las.py` | Står svaret i träffarna? Kan Wikipedia välja utkast? Svarar Lennart 3.4 bättre med texten? |
| `domare.py` | Lärd domare (logistisk regression, korsvaliderad) över alla signaler |
| `lasdata.py` | Läsövningar skapade ur Wikipedia, med vilseledande artiklar och utan läckage från frågebanken |
| `lasfinjustering.py` | Lär Lennart 3.4 att läsa: de 8 översta lagren tränas på CPU, förlust bara på svaret |
| `las_utvardera.py` | Jämför vanlig Lennart och läsaren med 0, 1 och 3 Wikipedia-träffar |

Resultat: se `../RAPPORT.md`, avsnitt 5–6.
