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
