# Tankeskalning – blir en liten modell smartare av att tänka?

| Fil | Vad |
|---|---|
| `fragor.py` | 68 faktafrågor med facit (nyckelord) |
| `tankeskalning.py` | Skriver 6 utkast + ett girigt svar per fråga med Lennart (C-motorn) |
| `analys.py` | Träffsäkerhet per urvalsregel, kalibrering (AUROC) och "vet inte"-gräns |
| `urval.py` | Frågevinst log P(svar\|fråga) − log P(svar) och bakåtkontroll log P(fråga\|svar) |
| `pool_lennart34_analys.json` | Resultat |

Resultat: se `../RAPPORT.md`, avsnitt 2–3. Kort sagt: tänkandet ger inte fler rätt på faktafrågor
(rätt svar finns bland utkasten i 55 % av fallen men hittas inte). Modellens egen poäng förutsäger däremot
väl om ett svar är rätt (AUROC 0,85), och det används nu i appen som osäkerhetsmarkering.
