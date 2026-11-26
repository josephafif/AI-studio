# Nattens forskning – hur Lennart fungerar i grunden, och hur han kan bli bättre

*Natten 25–26 november 2026. Alla siffror är uppmätta på Lennart 3.4 (298 M parametrar) här på en
vanlig processor (4 kärnor). Kod och rådata ligger i respektive mapp under `forskning/`.*

## Sammanfattning

| # | Fråga | Svar |
|---|---|---|
| 1 | Kan tänkandet bli billigare? | **Ja.** *Ekodekodning* (egen idé): utkasten återanvänder varandra, exakt utan kvalitetsförlust. Medel −23 %, Djup −28 % tid. Motorn blev också 1,4–1,6× snabbare på att läsa in frågor. |
| 2 | Blir Lennart smartare av att tänka? | **Nej, inte på fakta.** Rätt svar finns bland 6 utkast i 55 % av fallen, men varken Lennart själv eller fem andra urvalsregler hittar det (29–35 % mot 31 % utan tänkande). |
| 3 | Vet Lennart när han inte vet? | **Ja, förvånansvärt bra.** Hans egen säkerhet förutsäger rätt/fel med AUROC 0,85. Svar över gränsen är rätt i 71 % av fallen, under gränsen i 11 %. Nu finns det i appen som "Osäker – dubbelkolla gärna". |
| 4 | Var i modellen "bestämmer" han sig? | **Sent.** Halvvägs (lager 11 av 21) stämmer gissningen med slutsvaret bara i 28 % av fallen. Tidiga lager kan inte skissa åt de sena utan att träningen ändras. |
| 5 | Kan ett uppslagsverk ersätta minnet? | Sökning i svenska Wikipedia hittar svaret i 40–65 % av fallen, **men Lennart 3.4 kan inte läsa** (31 % med text, 32 % utan). |
| 6 | Kan han lära sig läsa? | LÄSRESULTAT |
| 7 | Vilken arkitektur för Lennart 4? | PILOTRESULTAT |

**Den stora insikten:** för en liten modell är flaskhalsen inte beräkningen och inte att formulera sig.
Det är **att lagra och kontrollera fakta**. Därför bör nästa Lennart byggas som ett *system*:
en liten modell som är bra på språk och på att läsa, ett sökbart uppslagsverk, en inbyggd
osäkerhetsspärr och billigt tänkande. Det ska inte vara en större modell som försöker minnas allt.

## 1. Ekodekodning – tänkande som återanvänder sig självt (`ekodekodning/`)

**Observation:** utkasten i tänkandet blir ofta nästan ord för ord lika. Ändå räknades varje ord om med
ett helt pass genom modellen, och ett pass läser alla 300 MB vikter.

**Idé:** slå upp var den senaste texten redan förekommit (i frågan eller ett tidigare utkast), föreslå
fortsättningen därifrån (upp till 4 tokens) och kontrollera alla förslag i *ett* pass. Ett förslag godtas
med exakt den sannolikhet modellen själv hade gett det. Vid avslag dras en ny token ur resten. Svaren får
därmed **exakt samma fördelning** som förut, kontrollerat med 120 000 sampel per variant (skillnad
0,0155 mot slumpbruset 0,0158).

**Motorn behövde en förbättring först.** Ett pass med 4 tokens kostade 2× ett vanligt pass, eftersom
varje vikt lästes om för varje token. Med registerblockning (4 tokens per vikt-läsning) kostar det nu
1,28×. Det gjorde också inläsningen av långa frågor 1,4–1,6× snabbare.

| Nivå (20 frågor) | Tid utan | Tid med | Pass |
|---|---|---|---|
| Snabb | 19,4 s | 21,6 s | −1 % (för lite att återanvända) |
| Medel | 51,8 s | **39,8 s (−23 %)** | −26 % |
| Djup | 102,2 s | **74,0 s (−28 %)** | −30 % |

**Svarsminne:** gamla svar på liknande frågor som förslag gav bara 1,21 tokens per pass (~12 % per token).
En liten modell formulerar sig för olika varje gång. Det fungerar bäst *inom* samma tänkande.

Ekodekodningen är inbyggd i appens motor (`engine.dart`). Där räcker 125 pass till 215 tokens på Djup.

**Varför det kan spela roll utanför Lennart:** stora AI-tjänster låter ofta modellen skriva många svar
till samma fråga och välja eller rösta fram ett. Det är vanligt för resonerande modeller och gör dem
dyra. Där ekar svaren varandra på samma sätt, och tekniken ändrar inte vad modellen säger. Det är inte
testat i stor skala, men principen är densamma: ju mer modellen tänker, desto mer kan återanvändas.

## 2. Tankeskalning – blir en liten modell smartare av att tänka? (`tankeskalning/`)

68 faktafrågor med facit (geografi, historia, naturvetenskap, cybersäkerhet) × 2 omgångar.
Rättningen (facitord i svaret) kontrollerades för hand på 40 slumpvisa svar: 40 av 40 stämde.

| Urvalsregel | Träffsäkerhet |
|---|---|
| Snabb (ett svar) | 30,9 % |
| Girig (mest sannolikt) | 32,4 % |
| Medel, appens poäng (3 utkast) | 28,7 % |
| Djup, appens poäng (6 utkast) | 29,4 % |
| Konsensus (det utkast som mest liknar de andra) | 33,1–33,8 % |
| Frågevinst, log P(svar\|fråga) − log P(svar) | 24–31 % |
| Bakåtkontroll, log P(fråga\|svar) | 28–30 % |
| Wikipedia som domare | 31,6 % |
| Lärd domare (alla signaler, korsvaliderad) | 34,6 % |
| **Orakel: något av de 6 utkasten är rätt** | **55,1 %** |

Felmarginal ±4 procentenheter. **Inget urval slår ett enda svar på ett säkert sätt.** Rätt svar finns ofta
bland utkasten, men modellen ser inte vilket det är. Att *komma på* svaret är inte problemet. Att
*känna igen* det är. Därför ger tänkandet bättre svar på öppna frågor (färre förvirrade svar, se
lösenordsexemplet), men inte fler rätt på faktafrågor.

## 3. Osäkerhet – Lennart vet när han gissar

Samma poäng som inte kan välja *mellan* utkast skiljer mycket väl *mellan frågor*: AUROC 0,85
(0,5 vore slump, 1 perfekt). Svar med poäng ≥ −0,5:

| Nivå | Andel besvarade | Rätt över gränsen | Rätt under gränsen |
|---|---|---|---|
| Snabb | 20 % | 70 % | 21 % |
| Medel | 30 % | 71 % | 11 % |
| Djup | 34 % | 67 % | 10 % |

Poängen speglar alltså *hur svår frågan är för modellen*, inte vilket av utkasten som är rätt.
Förklaringen: mellan frågor domineras poängen av hur *bekant* ämnet är för modellen, och bekanta ämnen
besvaras oftare rätt. Inom en fråga skiljer sig utkasten mest i formulering och längd. Där belönar
poängen flyt, inte sanning. **Modellens säkerhet mäter förtrogenhet, inte korrekthet.** Det duger för
att varna, men inte för att välja.
**Inbyggt i appen:** svar under gränsen får markeringen "Osäker – dubbelkolla gärna".

## 4. Logitlins – var bestämmer sig Lennart? (`logitlins/`)

Efter varje lager läses modellens "tankar" av genom utmatningen (6 144 tokens svensk Wikipedia, ej använda för bryggan):

| Lager (av 21) | 5 | 8 | 11 | 14 | 16 | 19 | 20 | 21 |
|---|---|---|---|---|---|---|---|---|
| Samma gissning som slutet | 6 % | 17 % | 28 % | 44 % | 55 % | 71 % | 77 % | 100 % |
| med lagerbrygga | 18 % | 26 % | 38 % | 54 % | 65 % | 81 % | 86 % | – |

Lennart bygger upp svaret gradvis genom hela djupet. En *lagerbrygga* (linjär översättning, räknad i
sluten form) lyfter de tidiga lagren med ~10 procentenheter. Det räcker ändå inte för att tidiga lager
ska kunna skissa ord som hela modellen sedan kontrollerar: kalkylen ger *lägre* hastighet för Lennart 3.
Det måste tränas in från början (se pilot, variant C).

## 5. Uppslagsverk i stället för minne (`kunskapsbank/`)

En egen sökmotor (BM25 med svensk ordstamning, 727 000 artikelinledningar, byggd på 87 s):

| | Rätt |
|---|---|
| Svaret står i första träffen | 39,7 % |
| Svaret står bland tre första träffarna | 64,7 % |
| Lennart 3.4 utan text | 32,4 % |
| Lennart 3.4 med första träffen som text | 30,9 % |

Kunskapen *finns* i uppslagsverket, men Lennart har aldrig tränats att läsa en text och svara ur den.

## 6. Lästräning – formen lärs in före förståelsen

3 000 läsövningar skapades automatiskt ur Wikipedia (`lasdata.py`), med 0–2 vilseledande artiklar och
frågor gjorda av första meningen ("Vad är X?" och baklänges "Vad är [beskrivning]?"). De 8 översta lagren
i Lennart 3.4 tränades i 300 steg på processorn (35 min).

| Frågebanken (68 frågor) | Utan text | 1 träff | 3 träffar |
|---|---|---|---|
| Lennart 3.4 | 32,4 % | 35,3 % | 36,8 % |
| Lennart 3.4 läsare | 25,0 % | 13,2 % | 14,7 % |

| Nya övningar av samma slag som träningen (60 st) | Rätt artikel vald | Baklängesfrågor |
|---|---|---|
| Lennart 3.4 | 37 % | 0 av 32 |
| Lennart 3.4 läsare | 62 % | 14 av 32 |

**Han lärde sig läsa, men bara i övningarnas form.** På övningar som liknar träningen hittar han rätt
artikel betydligt oftare. På riktiga frågor har han i stället lärt sig mallen "[namn ur texten] är
[frågans ord]", och då blir det säkert framförda fel: "Uurainen är huvudstad i Finland",
"Storvätteshågna är Sveriges högsta berg" (Kebnekaise stod i texten). Han glömde också en del av det han
kunde, så träffsäkerheten utan text sjönk från 32 % till 25 %.

**Lärdom till Lennart 4:** läsning måste tränas med *varierade* frågor där svaret står mitt i texten, med
övningar där texten *inte* innehåller svaret ("det står inte i texten") och med vanlig data inblandad så att
han inte glömmer. Mallgenererade frågor lär ut formen, inte förståelsen. Ett uppslagsverk hjälper ändå
lite redan nu: vanliga Lennart 3.4 går från 32 % till 37 % med tre träffar i frågan.

PILOTDETALJER

