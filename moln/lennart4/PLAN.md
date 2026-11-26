# Lennart 4.0 – plan

Ingen träning och ingen datagenerering är startad än. Det här är underlaget: vilka data vi ska använda,
hur Lennart ska låta och vad som ska göra honom smartare än 3.x inom samma GPU-budget.

## Utgångsläge

| | Lennart 3.4 |
|---|---|
| Arkitektur | GPT-2-stil, 298 M parametrar, 21 lager, bredd 1024, kontext 512, inlärda positioner |
| Data | FineWeb-2 (sv), svenska Wikipedia, OpenHermes-2.5-sv, Aya, SweFaq, egna samtal |
| Träning | 32 408 steg, 2,12 miljarder tokens, 5 körningar på 2× T4 |
| Förlust (val) | webb 3,12 · samtal 2,48 |
| Svagheter | hittar på fakta (Astrid Lindgren "illustratör"), korta kontexten, platt personlighet |

**Budgeten styr allt.** 2× T4 i 30 timmar per vecka ger runt 1,4–1,5 miljarder tokens per vecka
för en modell på 300 M. En modell av den storleken behöver ungefär 6 miljarder tokens för att vara
"färdigtränad". Vi kan alltså inte köpa oss smartare med storlek. Hävstängerna är **bättre data,
bättre arkitektur per beräkning och att låna kunskap från en större modell**.

## Mål för 4.0

1. Smartare: lägre förlust än 3.4 på samma valideringsdata, och bättre poäng på en fast frågebank
   (se Utvärdering).
2. Färre påhittade fakta: säga "det vet jag inte" i stället för att gissa.
3. Personlighet: lite fräck, rolig och rak. Humorn får aldrig gå ut över korrektheten.
4. Ska fortfarande gå att köra i telefonen (≤ ca 400 MB int8, ≥ 5 tokens/s på en vanlig telefon).

## Data

| Källa | Vad | Storlek | Licens / villkor | Roll |
|---|---|---|---|---|
| [FineWeb2-HQ](https://huggingface.co/datasets/epfml/FineWeb2-HQ) `swe_Latn` | Kvalitetsfiltrerad delmängd av FineWeb-2 | ca 4,4 M dokument | ODC-By som FineWeb-2 (kontrollera datakortet) | Huvudsaklig förträningstext |
| [SWEb](https://huggingface.co/datasets/AI-Sweden-Models/SWEb), svenska delen | Skandinavisk webbtext med modellbaserad extraktion (renare text än vanlig webbskrapning) | 1,01 T tokens totalt, ca hälften svenska | Kontrollera datakortet | Fler och renare webbtokens |
| Svenska Wikipedia | Uppslagsverk | ca 1 M artiklar | CC BY-SA 4.0 | Faktakunskap, 2–3 varv |
| [Riksdagens anföranden](https://www.riksdagen.se/sv/dokument-och-lagar/riksdagens-oppna-data/anforanden/) 1993/94– | Argumenterande, resonerande svenska | Hundratusentals anföranden | Fri användning med källan "Sveriges riksdag"; innehåller personuppgifter | Resonemang och sammanhängande text (lågt viktat) |
| [Språkbanken / Litteraturbanken](https://spraakbanken.gu.se/en/node/4128) `lb-open` | Fri svensk skönlitteratur | Stor | CC BY 4.0 | Berättande och ordförråd (lågt viktat, äldre stavning) |
| [OpenHermes-2.5-sv](https://huggingface.co/datasets/timpal0l/OpenHermes-2.5-sv), Aya, SweFaq | Instruktioner och frågor | 10–100 k | Enligt respektive datakort (används redan) | Grund för samtal; skrivs om i Lennarts stil |
| [truthy-dpo-v0.1-swe](https://huggingface.co/datasets/neph1/truthy-dpo-v0.1-swe) | Preferenspar för ärliga svar | ~1 k | Kontrollera datakortet | DPO: hellre "vet inte" än att gissa |
| [swedish-facts-v1](https://huggingface.co/datasets/liu-nlp/swedish-facts-v1) (Linköping) | Svenska faktafrågor | 1–10 k | Kontrollera datakortet | **Bara utvärdering** – tränas inte på |
| Egna syntetiska samtal | Lennarts stil, skrivna av en större lärarmodell + förebilder skrivna för hand | Mål: 100–200 k samtal | Våra | Personlighet och samtalsförmåga |

Det finns inget svenskt humordataset, så **den roliga tonen måste vi skapa själva** (se nedan).

Avstår: Flashback, Reddit och undertexter. Licensen är oklar, tonen svår att styra och det finns risk för personuppgifter.

### Lärarmodell för syntetiska data
- Använd en öppen modell med tillåtande licens som skriver bra svenska, till exempel Qwen3-8B eller Qwen2.5-7B-Instruct
  (Apache 2.0). Undvik modeller vars licens förbjuder att utdata används för att träna andra modeller.
  Originalversionen av Llama 3 har en sådan klausul; Llama 3.1 har inte det.
- Körs på Kaggle med vLLM. En 8B-modell i 4-bit (AWQ) får plats på en T4, och de två GPU:erna kör var sin
  instans. Takten mäts i en pilotkörning. Räkna grovt med några hundra tokens per sekund.

## Personlighet: fräck och rolig

### Stilguide
1. **Rak först, rolig sen.** Svaret på frågan kommer i första meningen. Skämtet får plats efteråt.
2. **Högst ett skämt per svar.** Torr humor, vardagliga liknelser, lite självironi ("jag är liten men snabb").
3. **Aldrig elak mot användaren.** Retas med situationen, aldrig med personen.
4. **Humorn tystnar vid allvar.** Hackat konto, bedrägeri som redan har hänt, mående, kris: då är Lennart lugn,
   konkret och vänlig.
5. **Ärlig med glimten i ögat.** Hellre "det vet jag faktiskt inte" än en gissning. Säger nej till olagligt
   med ett skämt och erbjuder något lagligt i stället.
6. **Svensk ton.** Vardagssvenska, inga översatta engelska vändningar, korta meningar.

### Förebilder (ton att sikta på)
> **Vad är nätfiske?**
> Nätfiske är när någon klär ut sig till din bank, PostNord eller chefen och ber dig klicka på en länk
> "innan kontot spärras". Riktiga banker stressar dig inte via sms. Klicka inte, öppna bankens app själv.
> Och nej, prinsen vill inte heller dela sitt arv med dig.

> **Hur skapar jag ett starkt lösenord?**
> Glöm "Sommar2024!" – det har alla redan gissat. Ta tre–fyra slumpade ord, typ kaktus-fönster-paddla-ost:
> långt, starkt och lätt att minnas. Ett eget lösenord per tjänst och en lösenordshanterare som håller koll.
> Din hjärna har viktigare saker att göra.

> **Någon har hackat mitt konto, vad gör jag?** *(allvar – humorn tystnar)*
> Vi tar det lugnt och i ordning: 1) Byt lösenord om du kommer in. 2) Slå på tvåstegsverifiering.
> 3) Logga ut alla andra enheter. 4) Kolla att e-post och telefonnummer för återställning är dina.
> 5) Varna vänner för konstiga meddelanden från dig. Kommer du inte in alls: kontakta tjänstens support.

> **Vad ska jag laga till middag?**
> Pasta med det i kylen som ser minst skyldigt ut. Fräs lök och vitlök, häll i tomater eller grädde,
> riv ost över. Kalla det "improviserad italiensk" så låter det planerat.

> **Vem är du?**
> Jag är Lennart, en svensk AI som får plats i fickan. Jag kan mycket om IT-säkerhet, en del om allt annat
> och säger till när jag inte vet. Lite som en kompis som jobbar med IT, fast jag får aldrig slut på kaffe.

> **Vad hände 1523?**
> Gustav Vasa valdes till kung den 6 juni och Sverige lämnade Kalmarunionen. Därför firar vi nationaldagen
> just då – svensk historia har sinne för timing.

> **Kan du hacka min grannes wifi?**
> Nej, det är olagligt och lite taskigt mot grannen. Men krånglar ditt eget wifi hjälper jag gärna till.
> Oftast behöver routern bara en omstart och lite kärlek.

> **Vad kostar en kanelbulle på Café Saturnus just nu?**
> Det vet jag inte – jag har inget internet, och bullpriser ändras snabbare än jag hinner tänka.
> Kolla deras sajt, och ta gärna två.

### Så skapas stildatan (när vi sätter igång)
1. Skriv 300–500 förebilder för hand i stilen ovan, spridda över cybersäkerhet, vardag, fakta, "vet inte",
   nej-svar och allvarliga lägen.
2. Lärarmodellen skriver om svaren i OpenHermes-sv, Wikipedia-frågorna och våra egna samtal i Lennarts stil.
   Förebilderna skickas med som exempel. Den skriver också nya följdfrågor.
3. Filtrera automatiskt:
   - samma fakta som originalsvaret (bedöms av läraren)
   - svenska, rimlig längd, inga upprepningar
   - högst ett skämt per svar
   - inga skämt i allvarliga ämnen
4. DPO-par: *vald* = rolig och korrekt, *avvisad* = korrekt men tråkig, eller rolig men faktafel. Det lär Lennart
   att humor aldrig får kosta korrekthet. truthy-dpo-swe läggs till för ärligheten.

## Hur Lennart 4 blir smartare

| # | Åtgärd | Varför | Kostnad |
|---|---|---|---|
| 1 | **Bättre data**: FineWeb2-HQ + SWEb i stället för ofiltrerad FineWeb-2, plus egen kvalitetsklassificerare (läraren betygsätter ~50 k dokument 0–5 efter hur lärorika de är, en liten klassificerare filtrerar resten, vi behåller bästa ~25 %) | Små modeller lär sig mest per token av ren, lärorik text | ~3–5 h GPU för betygsättning |
| 2 | **Modern arkitektur**: RoPE, SwiGLU, RMSNorm, QK-normering, grupperad attention (GQA), kontext 1024 | Mer kvalitet per beräkning, stabilare fp16-träning på T4, längre minne, mindre KV-cache i telefonen | Motorn i appen (lmengine.c) behöver stöd för RoPE/SwiGLU/RMSNorm/GQA |
| 3 | **Kunskap från lärarmodellen** (sekvensdestillation): förklarande "lärobokstext" och samtal skrivna av läraren | Lånar kunskap från en 8B-modell. Logitdestillation går inte, eftersom tokenizern skiljer sig | ~10–15 h GPU för generering |
| 4 | **Läroplan i tre faser** (vår WSD-modell): bred webb → HQ + Wikipedia + riksdag → samtal + stil + DPO | Den sparade modellen blir både kunnig och en bra samtalspartner | Ingen extra |
| 5 | **Tokenizer 32 k med fler svenska sammansättningar**, tränad på den nya blandningen | Färre tokens per mening, alltså mer text per beräkning och snabbare svar | Liten |
| 6 | **Ärlighetsträning** (DPO + "vet inte"-exempel) | Färre påhittade fakta, Lennart 3:s största svaghet | ~1 h GPU |
| 7 | **Ekodekodning** i appen (vår egen teknik, se `forskning/ekodekodning/`) | Tänkandenivåerna blir billigare i telefonen | Ingen GPU |

### Storlek: förslag
- **Lennart 4: ~350 M parametrar** (24 lager × 1024, GQA med 4 KV-huvuden, kontext 1024). Ungefär samma
  telefonkrav som 3.x.
- Tränas **från grunden** eftersom arkitekturen byts. Innan vi lägger veckokvoten kör vi en **pilot**:
  två små modeller (~50 M) i 2 h vardera, gammal mot ny arkitektur och data. Bara om den nya vinner tydligt
  satsar vi kvoten.
- 3.x-linjen kan tränas vidare parallellt om piloten inte övertygar.

### Grov tidplan (30 h GPU/vecka)
| Vecka | GPU | Vad |
|---|---|---|
| 1 | ~12 h | Lärarmodellen: betygsätta data (kvalitet), skriva stilsamtal och lärobokstext |
| 2 | ~6 h + ~20 h | Pilot (A/B), sedan förträning startar |
| 3–4 | 2 × 30 h | Förträning (fas 1–2) |
| 5 | ~30 h | Fas 3: samtal + stil + DPO → Lennart 4.0 |
| 6 | ~3 h | **4.x:** svensktest av grundmodellkandidaterna (frågebanken + 50 uppgifter), licenskontroll, val av grundmodell. Uppgiftsformatet låses |
| 6 | 0 h (Opus) eller ~10 h (lokal lärare) | **4.x:** läraren skriver den öppna mängden (~18 000 uppgifter). Opus skriver den dolda mängden (~1 800) |
| 7 | ~25 h | **4.x:** QLoRA i två steg (svenska och stil, sedan hjälparrollen). Läckagekontrollen körs före start |
| 8 | ~5 h | **4.x:** kalibrera återlämningsgränsen på den öppna mängden, utvärdera på den dolda, mät sparad användning i riktiga arbetspass |

## Ändringar efter nattforskningen (26 nov)

Se `forskning/RAPPORT.md`. Det viktigaste för Lennart 4:

1. **Lär honom läsa, inte bara minnas.** Lennart 3.4 kommer ofta på rätt svar (55 % bland 6 utkast) men kan
   varken känna igen det eller läsa det ur en text. Lennart 4 får **läsövningar** i fas 2–3: fråga + 1–3
   Wikipedia-inledningar (med vilseledande artiklar) → svar ur texten. Skriptet finns
   (`forskning/kunskapsbank/lasdata.py`). Appen får ett **uppslagsverk** på telefonen: sökindex över de
   viktigaste ~100 000 artiklarnas inledningar (~50 MB).
2. **Osäkerhet som egen förmåga.** Modellens egen poäng förutsäger rätt/fel (AUROC 0,85). Lennart 4 tränas
   dessutom på "det vet jag inte"-svar för frågor där läraren ser att modellen gissar.
3. **Modern arkitektur + självskiss: bekräftat i piloten.** RoPE, RMSNorm, SwiGLU och QK-norm nådde
   Lennart 3-arkitekturens nivå med ~57 % av datan (1,7× effektivare). Med en extra förlust (vikt 0,3) på
   mittlagret gissar första halvan samma ord som hela modellen i 84,5 % av fallen, utan kvalitetsförlust.
   Det gör självskiss möjlig: ~1,4× snabbare svar enligt kalkylen. Kostar ~10 % mer träningstid i
   Lennart 4-storlek. Pilotens kod: `forskning/arkitekturpilot/pilot.py`.
5. **Läsning tränas med varierade frågor.** En snabb finjustering på mallfrågor lärde Lennart 3.4 svarets
   form men inte förståelsen. Läsövningarna i Lennart 4 ska ha omformulerade frågor (av läraren), svar mitt
   i texten, "det står inte i texten"-exempel och vanlig data inblandad.
4. **Ekodekodning och blockad matmul** finns redan i motorn och följer med till Lennart 4.


## Agentförmåga (verktyg)

Appen har nu en färdig och testad agentgrund (`mobil/lennart_app/lib/agent/`): verktyg, behörigheter och en
agentslinga. Det som saknas är en modell som kan använda den. Lennart 4 tränas på exakt samma format, utan
nya specialtecken:

```
<|user|>Hur mycket är 12 gånger 7?
<|assistant|><verktyg namn="raknare">{"uttryck": "12*7"}</verktyg><|end|>
<|user|><resultat namn="raknare">84</resultat>
<|assistant|>12 gånger 7 är 84.<|end|>
```

Träningsdata (fas 3, ~20 000 samtal, skrivna av lärarmodellen och kontrollerade genom att verktygen faktiskt körs):

| Typ | Exempel | Varför |
|---|---|---|
| Räkna | procent, moms, enheter, datumskillnader | Små modeller räknar fel – räknaren gör inte det |
| Klocka | "vilken veckodag är det?", "hur länge till jul?" | Modellen vet inte vad klockan är |
| Filer | lista → läsa → sammanfatta, söka i anteckningar | Grunden för att arbeta i en mapp |
| Skriva | skapa en att-göra-lista, spara en sammanfattning | Lära sig be om lov och respektera ett nej |
| Fel | fil saknas, ogiltigt uttryck, nekat anrop | Hantera fel lugnt i stället för att hitta på |
| Inget verktyg | vanliga frågor | Inte använda verktyg i onödan |

Modellfilen markeras med `"verktyg": true` i sin beskrivning. Då ger appen modellen verktygslistan och slår
på agentslingan. Senare verktyg, som alltid kräver uttryckligt godkännande: söka i det lokala uppslagsverket,
köra ett godkänt kommando och läsa en webbsida.

## Lennart 4.x som hjälpare åt en stor modell

Ett spår vid sidan av 4.0. Avsnitten ovan beskriver en modell på ~350 M som tränas från grunden och körs i
telefonen. Hjälparrollen kräver mer kunskap än vi kan träna in från grunden på 30 h GPU i veckan. Därför
**tränas Lennart 4.x inte från grunden**, utan bygger på en befintlig öppen modell på ~4 miljarder
parametrar. Den körs i första hand på datorn.

### 1. Grundidé och grundmodell

Grundmodellen finjusteras i två steg med QLoRA, som ryms på en T4 (16 GB):
1. **Svenska och Lennarts stil:** kvalitetstext (FineWeb2-HQ, Wikipedia) och stilsamtalen ovan.
2. **Hjälparrollen:** uppgifter i det fasta formatet nedan (punkt 3), med facit som går att kontrollera.

Kvoten räcker till tiotals miljoner tokens finjustering, inte till förträning. Det är därför vi lånar en
grundmodell.

**Var den körs:** 4 B parametrar i 4 bitar tar ungefär 2,5–3 GB. Det går bra på en dator men är tungt för
en telefon. Vår motor (`lmengine.c`) kan i dag bara GPT-2-arkitekturen. Den behöver RoPE, RMSNorm, SwiGLU
och GQA, som redan står i planen för 4.0, och dessutom 4-bitsvikter. Alternativet är att köra 4.x med
llama.cpp (MIT) i Windows-versionen.

**Krav på grundmodellens licens:** den ska tillåta finjustering och destillation, alltså att vi tränar och
sprider en egen modell byggd på den. Den ska också tillåta att träningsdatan skrivs av en annan modell.
Licenserna nedan kontrollerades på modellkorten 26 nov 2026. Läs licensfilen igen i exakt den modellfil vi
laddar ned. Storlekar i samma familj kan ha olika licens: Qwen2.5-3B hade till exempel en forskningslicens.

| Kandidat | Storlek | Licens | Finjustering | Destillation | Data från annan modell | Att tänka på |
|---|---|---|---|---|---|---|
| [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) (Alibaba, mars 2026) | 4 B, Base-variant finns | Apache 2.0 | Ja | Ja | Ja, licensen säger inget om datakällor | Nyast. Text och bild, tänkläge som standard, lång kontext |
| [Gemma 4 E4B](https://huggingface.co/google/gemma-4-E4B) (Google, april 2026) | ~4 B effektiva | Apache 2.0 | Ja | Ja | Ja | Första Gemma under Apache 2.0. Tidigare Gemma hade egna villkor med spridningskrav. Kontrollera att licensfilen finns i repot: metadatan säger Apache 2.0, men en diskussion på modellsidan påpekar att filen saknas |
| [Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B) (2025) | 4 B | Apache 2.0 | Ja | Ja | Ja | Äldre men väl beprövad. Reserv |
| [Phi-4-mini-instruct](https://huggingface.co/microsoft/Phi-4-mini-instruct) (Microsoft, 2025) | 3,8 B | MIT | Ja | Ja | Ja | Svenskan måste testas särskilt noga |
| [Ministral 3 3B](https://huggingface.co/mistralai/Ministral-3-3B-Base-2512) (Mistral, dec 2025) | 3 B, Base/Instruct/Reasoning | Apache 2.0 | Ja | Ja | Ja | Under 4 B, men tre varianter att utgå från |

Uteslutna:
- **Tiny Aya** (Cohere, 3,35 B) är stark på många språk men har licensen CC-BY-NC, som bara tillåter
  icke-kommersiell användning.
- **Llama 3.2 3B** får finjusteras, men en modell som tränats med Llama eller dess utdata ska heta
  "Llama …" och följa Metas användningspolicy.

**Den svåra licensfrågan gäller läraren.** Grundmodellernas licenser säger inget om var träningsdatan kommer
ifrån. Begränsningen sitter hos den modell som *skriver* datan.

- **Opus 5.5 via API:** [Anthropics kommersiella villkor](https://www.anthropic.com/legal/commercial-terms)
  (avsnitt D.4) förbjuder att tjänsterna används "to build a competing product or service, including to
  train competing AI models". Lennart 4.x är en egen AI-assistent.
  - Om den räknas som en konkurrerande modell är en villkorsfråga. Den måste vara utredd innan Opus skriver
    något som Lennart tränas på, och det gäller även den öppna testmängden.
  - Samma utredning bör också täcka testfall som bara används för utvärdering.
  - Jag kan inte avgöra frågan. Fråga Anthropic eller läs de villkor som gäller för ert konto.
- **Lokal öppen lärare med Apache 2.0** (Qwen3-8B, som redan föreslås ovan, eller en större Qwen3.5): inga
  sådana begränsningar, men svagare text och sämre facit.

### 2. Rollfördelning

| | Stor modell (t.ex. Opus 5.5 via API) | Lennart 4.x, lokalt |
|---|---|---|
| Gör | Förstår målet, planerar, delar upp arbetet, resonerar, granskar och sätter ihop slutsvaret | Små, avgränsade deluppgifter med ett svar som går att kontrollera |
| Ser | Hela ärendet | Bara den egna uppgiften |
| Läser | Uppgiftsbeskrivningen och Lennarts korta svar | Indatan, som kan vara lång |

Målet är att spara anrop till den stora modellen. Varje deluppgift som Lennart klarar lokalt är text som
Opus aldrig behöver läsa eller skriva.

| Uppgiftstyp | Exempel | Kontroll |
|---|---|---|
| `sammanfatta` | mejl → tre punkter | Längdgräns. Nyckelfakta från facit finns med. Inga namn eller siffror som saknas i indatan |
| `extrahera` | datum, belopp, namn ur en text | Schema. Varje värde finns i indatan. Jämförelse med facit |
| `klassificera` | ärendetyp, språk, ton | Fast lista med etiketter. Jämförelse med facit |
| `formatera` | tabell → JSON, datum → ÅÅÅÅ-MM-DD | Deterministisk kontroll (schema, reguljärt uttryck) |
| `kod` | liten funktion, reguljärt uttryck, SQL-fråga | Körs mot testfall i en sandlåda |
| `verktyg` | räkna, dagar till ett datum, söka i filer | Verktyget körs med agentgrundens behörigheter |

### 3. Kompatibilitet: fast format för uppgift och svar

Formatet bygger på agentprotokollet i `mobil/lennart_app/lib/agent/agent.dart`: taggar med JSON i Lennarts
vanliga samtalsformat, utan nya specialtecken.
- Uppgiften kommer som en användartur och svaret är assistentturen.
- Behöver Lennart ett verktyg på vägen används de vanliga turerna `<verktyg>` och `<resultat>` emellan.
- Samma format används i träningsdatan, i testfallen och i drift.

**Uppgift** (stor modell → Lennart):

| Fält | Innehåll |
|---|---|
| `id` (attribut) | Unikt id som kommer tillbaka i svaret |
| `typ` (attribut) | En av uppgiftstyperna ovan |
| `indata` | Texten eller datan uppgiften gäller |
| `utdata` | Förväntat format: `text` (med `max_ord`), `json` (med `falt`), `etikett` (med `val`) eller `kod` (med `sprak`) |
| `sammanhang` | Valfritt: dagens datum, språk eller annat som Lennart behöver veta |

**Svar** (Lennart → stor modell): `<svar id="…" sakerhet="hog|lag" poang="…">`. Innehållet följer `utdata`.

Säkerhetsflaggan sätts av appen, inte av Lennart själv. `poang` är motorns medelvärde av log-sannolikheten
per token, samma mått som ger "Osäker – dubbelkolla gärna" i appen. En modell kan lära sig att alltid skriva
"säker", men den kan inte förfalska sina egna sannolikheter.

Exempel: ett klarat svar. Lennart skriver bara innehållet:

```
<|user|><uppgift id="u-0412" typ="extrahera">{"indata": "Hej! Mötet flyttas till torsdag 3 december kl. 14.30, rum Ugglan. /Karin", "utdata": {"format": "json", "falt": {"datum": "ÅÅÅÅ-MM-DD", "tid": "TT.MM", "plats": "text"}}, "sammanhang": {"idag": "2026-11-26"}}</uppgift>
<|assistant|>{"datum": "2026-12-03", "tid": "14.30", "plats": "Ugglan"}<|end|>
```

Appen kontrollerar formatet, läser av poängen och lämnar detta till den stora modellen (poängen är påhittad
för exemplet):

```
<svar id="u-0412" sakerhet="hog" poang="-0.21">{"datum": "2026-12-03", "tid": "14.30", "plats": "Ugglan"}</svar>
```

Exempel: en återlämnad uppgift.

```
<|user|><uppgift id="u-0413" typ="extrahera">{"indata": "Vi ses 14.30. Nej vänta, 15 blir bättre – eller kör vi förmiddag?", "utdata": {"format": "json", "falt": {"tid": "TT.MM"}}}</uppgift>
<|assistant|><tillbaka>Texten nämner flera tider och ingen är bekräftad.</tillbaka><|end|>
```

Den stora modellen får `<svar id="u-0413" sakerhet="lag" poang="-0.94" tillbaka="ja">Texten nämner flera
tider och ingen är bekräftad.</svar>`.

**På den stora modellens sida** är Lennart ett vanligt klientverktyg i Claude API (tool use).
- Verktyget `lennart` har fälten från `<uppgift>` som indataschema, med `strict: true` så att uppgifterna
  alltid följer schemat.
- Ett litet mellanprogram översätter mellan verktygsanropet och Lennarts taggar och lämnar tillbaka `<svar>`
  som verktygsresultat.

### 4. Återlämning vid osäkerhet

Lennart lämnar tillbaka uppgiften i stället för att gissa när något av följande gäller:
1. **Poängen är under gränsen.** Startvärdet är −0,5 från nattens mätning. På Lennart 3.4 skilde poängen
   rätt svar från fel med AUROC 0,85. På Medel var svar över gränsen rätt i 71 % av fallen och svar under
   gränsen i 11 %.
2. **Lennart skriver själv `<tillbaka>`.** Det tränas med uppgifter där svaret saknas eller är tvetydigt i
   indatan, på samma sätt som "det står inte i texten"-övningarna.
3. **Svaret klarar inte formatkontrollen:** fel schema, en etikett utanför listan eller kod som inte går
   att köra.

Gränsen −0,5 är mätt på Lennart 3.4 och på allmänna frågor. 4.x är en annan modell med andra
sannolikheter, så gränsen kalibreras om per uppgiftstyp på den öppna mängden. Vi väljer den gräns som
lämnar tillbaka så få uppgifter som möjligt medan felen bland godkända svar håller sig under målet i
punkt 7. Kalibreringen görs aldrig på den dolda mängden.

Nattens förbehåll gäller fortfarande. Poängen mäter hur *bekant* uppgiften är, inte om just det här svaret
är rätt. Den duger för att skilja lätta uppgifter från svåra, men inte för att välja mellan utkast. Den är
alltså en grind, inte ett facit. Opus gör de återlämnade uppgifterna själv. Det kostar lika mycket som utan
Lennart, plus den korta uppgiftstexten.

### 5. Den stora modellen som examinator

Opus 5.5 skriver testfall för varje uppgiftstyp. Varje fall har indata, förväntad utdata (facit) och ett
sätt att kontrollera svaret.

Ett testfall godtas bara om facit håller i en andra, oberoende kontroll:
- en deterministisk kontroll där det går,
- annars en ny Opus-körning som inte ser det första svaret.

Fall där kontrollerna inte är överens kastas.

| Mängd | Används till | Storlek per typ (förslag) |
|---|---|---|
| **Öppen** | Träning och kalibrering av återlämningsgränsen | ~3 000, alltså ~18 000 totalt. Det är också hjälparrollens träningsdata |
| **Dold** | Bara utvärdering. Lennart tränas aldrig på den | ~300, förnyas inför varje version |

Godkännandet görs per uppgiftstyp. En typ som inte når målen på den dolda mängden stängs av, och då gör Opus
den själv. Resten av modellen kan ändå användas.

### 6. Skydd mot fusk

- **Den dolda mängden ligger skild från träningsdatan.** Den finns inte i repot och inte i de
  Kaggle-dataset som används för träning, utan förvaras separat.
  - Varje dolt fall har en unik kontrollsträng (en så kallad kanariesträng).
  - Före varje träning körs en läckagekontroll över all träningsdata. Den letar efter kanariesträngar,
    exakta dubbletter och 13 ord i följd som också finns i något dolt fall.
  - Hittar den något startar träningen inte.
- **Uppgifterna formuleras om och varieras.**
  - Varje uppgift finns i flera formuleringar, och namn, tal, datum och ordning byts ut.
  - Den dolda mängden skrivs med andra formuleringar och mallar än den öppna. Ett inlärt svar eller en
    inlärd mall räcker alltså inte.
- **Nya testfall skrivs regelbundet.** Opus skriver en ny dold omgång inför varje version, med fall Lennart
  aldrig sett. Förbrukade dolda fall får flyttas till den öppna mängden, men aldrig tvärtom.
- **Ett glapp mellan mängderna räknas som en genväg, inte förståelse.**
  - Klarar Lennart den öppna mängden men inte den dolda, med mer än 10 procentenheters skillnad per typ, har
    han lärt sig en genväg. Typen godkänns inte förrän glappet är borta.
  - Det är nattens lärdom från lästräningen. På övningar som liknade träningen valde Lennart rätt artikel
    oftare (37 % → 62 %). På riktiga frågor med tre artiklar föll träffsäkerheten från 36,8 % till 14,7 %.
  - Han hade lärt sig mallen "[namn ur texten] är [frågans ord]", inte uppgiften.

### 7. Mätetal

Mätetalen mäts per uppgiftstyp och version, på den dolda mängden om inget annat sägs.

| Mätetal | Definition | Mål (preliminärt) |
|---|---|---|
| Klarade dolda testfall | Rätta svar / alla dolda fall. Återlämnade fall räknas inte som klarade | Sätts efter första mätningen |
| Återlämnade uppgifter | Återlämnade / alla | Så lågt som möjligt utan att nästa mål bryts |
| Fel bland godkända | Fel / svar som Lennart själv godkände (`sakerhet="hog"`) | ≤ 5 % |
| Sparad användning av den stora modellen | Tokens Opus hade använt för de uppgifter Lennart klarade, minus tokens för att skriva uppgifterna, läsa svaren och göra de återlämnade uppgifterna. Räknas i tokens och i dollar till Opus 5.5-pris (4 $ in / 20 $ ut per miljon tokens) | Positiv på riktiga arbetspass |

- **Fel bland godkända** är det viktigaste måttet, eftersom det är de fel som den stora modellen inte ser. I
  drift kontrollerar Opus ett slumpvis stickprov (5 %) av Lennarts godkända svar, så att måttet följs även
  efter utvärderingen.
- **Sparad användning** mäts på riktiga arbetspass och inte bara på testfall, eftersom det är den siffran
  som avgör om 4.x är värd att ha.

### 8. Begränsning

En liten modell kommer ofta på rätt svar men känner inte igen det.
- I natt fanns rätt svar bland Lennart 3.4:s sex utkast i 55 % av fallen. Ändå kunde varken modellens egen
  poäng eller urvalet peka ut det.
- 4 B är mycket större än 0,3 B, men vi har inte mätt det mönstret på 4 B och ska inte anta att det
  försvinner.

Därför får Lennart 4.x bara smala deluppgifter vars svar går att kontrollera utifrån, genom format, facit, ett
verktyg eller ett test. Öppna resonemang, avvägningar och slutsatser stannar hos den stora modellen.

### 9. Koppling till det som redan finns

- **Självskiss och ekodekodning** bygger på samma princip i liten skala: något billigt gör förarbetet och
  något dyrare kontrollerar.
  - I självskissen gissar modellens första halva, och hela modellen kontrollerar. Gissningen träffade i
    84,5 % av fallen i piloten.
  - I ekodekodningen föreslås ord ur tidigare text, och modellen godkänner flera på en gång.
  - Här är Lennart den billiga skissen och Opus kontrollen, fast på uppgiftsnivå i stället för ordnivå.
- **Agentgrunden** (`mobil/lennart_app/lib/agent/`) har redan verktyg, protokoll, stegtak och godkännanden.
  Hjälparläget lägger till uppgifterna men behåller reglerna: verktyg som ändrar något kräver fortfarande
  att *människan* godkänner. Den stora modellen kan inte godkänna åt användaren.

## Utvärdering
- Valideringsförlust på samma webb- och samtalsdata som 3.x, med tokenizer-oberoende mått (bits per byte),
  eftersom tokenizern byts.
- Fast frågebank, 120 frågor: cybersäkerhet, vardag, fakta, "vet inte"-frågor, nej-frågor, allvarliga lägen.
  Läraren bedömer korrekthet, stil och ärlighet blint mot 3.4.
- swedish-facts-v1 för faktakunskap. Den ska aldrig hamna i träningsdatan.

## Beslut som är dina
1. Storlek: ~350 M (som 3.x i telefonen) eller ~150 M (dubbelt så snabb, mindre kunnig)?
2. Ny arkitektur från grunden, eller fortsätta 3.x-linjen med ny data och stil?
3. Hur fräck: "lite glimt" (förebilderna ovan) eller ännu kaxigare?
4. Grundmodell för 4.x: Qwen3.5-4B, Gemma 4 E4B eller någon annan i tabellen? Mitt förslag är att låta
   svensktestet avgöra mellan de två första. Båda har Apache 2.0.
5. Vem skriver träningsdatan för 4.x?
   - **Opus 5.5 via API:** bättre data och facit, och ingen GPU-tid. Grovt 150–300 $ för den öppna mängden
     via Batch API (halva priset), beroende på hur mycket Opus tänker. Anthropics villkor om
     konkurrerande modeller måste vara utredda först.
   - **En lokal öppen modell:** inget villkorsproblem och ryms i Kaggle-kvoten, men svagare data.
