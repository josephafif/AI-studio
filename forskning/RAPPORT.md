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
| 6 | Kan han lära sig läsa? | **Inte med malldata.** Två försök med 35 minuters lästräning lärde ut beteenden, inte förståelsen. Version 1 hittade på i rätt form (15 % mot 37 %), version 2 svarade "det står inte i texten" i 72 % av fallen. Lärdomen styr hur Lennart 4 ska tränas. |
| 7 | Vilken arkitektur för Lennart 4? | **Modern + självskiss.** RoPE, RMSNorm och SwiGLU når Lennart 3-arkitekturens nivå med ~57 % av datan (1,7× effektivare). En extra förlust på mittlagret gör att första halvan gissar rätt i 85 % av fallen, utan kvalitetsförlust. |

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

### Djup+ (tillagt efter natten)

Ny nivå som väljer per mening i stället för hela svar (`tankeskalning/djupplus.py`). Svaret byggs
mening för mening, och för varje mening skrivs upp till 5 kandidater från samma början. Kandidaten väljs
efter konsensus med de andra plus modellens säkerhet, med straff för upprepning. Tre likadana kandidater
räcker. Totalt högst 20 utkast.

| | Snabb | Djup | Konsensus (6) | **Djup+** | Orakel (6) |
|---|---|---|---|---|---|
| Rätt | 30,9 % | 29,4 % | 33,1 % | **36,0 %** | 55,1 % |

I snitt 10,8 utkast (median 9) och ungefär samma beräkning som Djup. Parvis mot Djup var Djup+ rätt
på 15 frågor där Djup var fel, och Djup på 6 där Djup+ var fel (p ≈ 0,08). Det är det bästa resultatet
av alla urval, men inte statistiskt säkert. Finns i appen från version 1.4.

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

**Version 2** rättade det diagnosen pekade på. Den hade alltid två vilseledande artiklar, en fjärdedel
övningar där svaret *inte* fanns i texten ("Det står inte i texten.") och en tredjedel repetition utan text.
Resultatet blev 1,5 % rätt med tre träffar: i 49 av 68 fall svarade den att det inte står i texten, trots att
svaret fanns där i ungefär två fall av tre. När den väl svarade använde den samma genväg som förut. På
övningar av träningens slag valde den rätt artikel i 45 % av fallen.

Version 1 lärde sig alltså att hitta på i rätt form, och version 2 lärde sig att avstå. **Ingen av dem lärde
sig läsa.** Mallgenererad data lär ut beteenden, inte förståelse.

**Lärdom till Lennart 4:** läsning måste tränas med *varierade* frågor där svaret står mitt i texten, med
övningar där texten *inte* innehåller svaret ("det står inte i texten") och med vanlig data inblandad så att
han inte glömmer. Mallgenererade frågor lär ut formen, inte förståelsen. Ett uppslagsverk hjälper ändå
lite redan nu: vanliga Lennart 3.4 går från 32 % till 37 % med tre träffar i frågan.

## 7. Arkitekturpilot för Lennart 4

Tre små modeller (13 M parametrar, 4,7–4,8 M utan inbäddning, 6 lager × 256) tränades med exakt samma
data och ordning på svensk Wikipedia (4 096 tokens per steg, cosinus-schema över 2 500 steg).

| Tokens | A, som Lennart 3 | B, modern | C, modern + självskiss |
|---|---|---|---|
| 3,1 M (750 steg) | 1,386 | 1,259 | 1,253 |
| 6,1 M (1 500 steg) | 1,185 | 1,096 | **1,089** |
| 10,2 M (2 500 steg) | 1,104 | **1,020** | (stoppad vid 1 500 för att hinna) |

*Bits per byte på valideringstext, lägre är bättre.*

**B lär sig klart snabbare.** Med RoPE, RMSNorm, SwiGLU och QK-normering når B A:s slutnivå efter
ungefär 57 % av träningen. Det motsvarar 1,7× fler tokens per beräkning. Per steg är B bara ~2 %
långsammare (3 380 mot 3 455 tokens/s i en ren mätning). Det här är den viktigaste siffran för
Lennart 4: samma GPU-vecka på Kaggle räcker till betydligt mer.

**C, självskiss:** med en extra förlust på mittlagret stämmer mittlagrets gissning med slutet i
84,5 % av fallen, mot 45,4 % i B, utan att slutkvaliteten blev sämre. C låg till och med något före B (1,089 mot 1,096), troligen för att mittlagret får en egen, direkt inlärningssignal. Räknat på
vår motor (utkast med halva modellen, kontroll av 4 tokens i ett pass på 1,28×, och de skissade
lagrens cache återanvänds) lönar sig självskiss först när omkring 70 % av skisserna godtas (vid 70 % ger det ~5 % snabbare, vid 80 % ~27 %). Med 84,5 % samstämmighet ger kalkylen omkring 1,4× snabbare svar vid girig avkodning. Vid sampling godtas färre skisser, så vinsten blir mindre. Det är räknat, inte uppmätt. Träningen kostade 67 % mer tid per steg i piloten, eftersom utmatningslagret är stort i en så liten modell. I Lennart 4-storlek (24 lager × 1024) blir tillägget ungefär 10 %.

En sak till syns i piloten: mittlagret i A stämmer allt *sämre* med slutet ju längre träningen pågår
(68 % → 41 %). Modellen flyttar mer och mer av arbetet till de sista lagren. Det förklarar varför
Lennart 3.4 med sina 21 lager bestämmer sig så sent.


