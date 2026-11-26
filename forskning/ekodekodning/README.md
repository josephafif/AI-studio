# Ekodekodning – vår egen teknik för billigare "tänkande"

## Idén – från en egen observation

När Lennart tänker (nivåerna **Medel** och **Djup** i appen) skriver han flera utkast till samma fråga
och väljer det bästa. I testerna syntes något slösaktigt: utkasten blir ofta nästan likadana.

```
Utkast 1: Ett starkt lösenord är långt, gärna minst 14 tecken, och unikt för varje tjänst.
Utkast 3: Ett starkt lösenord är långt, gärna minst 14 tecken, och unikt för varje tjänst. En lösenfras …
```

Ändå räknas varje token ut från början, med ett helt framåtpass per token. Ett framåtpass läser alla
~300 MB vikter. Läser man in **flera** tokens i samma pass läses vikterna bara en gång.

**Ekodekodning:** när ett nytt utkast skrivs letar motorn upp var den senaste biten text redan har
förekommit, i frågan eller i ett tidigare utkast. Fortsättningen därifrån blir ett **förslag** på upp
till 4 tokens, och alla kontrolleras i ett enda pass (`lm_eval_all` i `mobil/engine/lmengine.c`).
Utkasten "ekar" varandra, därav namnet.

## Varför svaren inte blir sämre (exakthet)

Förslaget är deterministiskt, alltså bestämt av texten hittills. Det godtas med sannolikheten
**p(förslag)**, det vill säga exakt den sannolikhet modellen själv hade gett tokenen. Vid avslag dras en
ny token ur modellens fördelning där förslaget är bortplockat och resten normaliserat. Matematiskt
ger det **exakt samma fördelning över svar** som vanlig sampling. Detta är samma kontrollprincip som i
känd "spekulativ avkodning". Det egna i vår variant är *var förslagen kommer ifrån*: syskonutkasten inom
samma tänkande, och i experiment 2 ett minne av tidigare svar.

Kontrollerat empiriskt i `test_exakthet.py` med en leksaksmodell och 120 000 sampel per variant:

| Jämförelse | Skillnad i fördelning (total variation) |
|---|---|
| vanlig ↔ ekodekodning | 0,0155 |
| vanlig ↔ vanlig (bara slump) | 0,0158 |

Skillnaden är lika stor som slumpbruset. Ekodekodningen ändrar alltså inte vad Lennart säger, bara hur
mycket det kostar.

## Resultat på Lennart 3.4

20 frågor på varje tänkandenivå, samma frö (`resultat_k4.txt`). Tid på en processor med 4 kärnor:

| Nivå | Tid utan | Tid med | Pass | Tokens per pass |
|---|---|---|---|---|
| Snabb | 19,4 s | 21,6 s | 691 → 682 | 1,01 |
| Medel | 51,8 s | **39,8 s (−23 %)** | 1826 → 1360 | 1,33 |
| Djup | 102,2 s | **74,0 s (−28 %)** | 3693 → 2595 | 1,45 |

**Motorn först.** I första försöket kostade ett pass med 8 tokens 3,3× ett vanligt pass. Det gjorde Djup
*långsammare* trots 42 % färre pass. Matmul för flera tokens läste om varje vikt för varje token. Med
registerblockning (4 och 2 tokens per vikt-läsning, `lmengine.c`) blev kostnaden:

| Tokens per pass | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| Före | 1,00× | 1,28× | 1,96× | 3,34× |
| Efter | 1,00× | 1,20× | 1,28× | 1,93× |

Därför föreslås högst 4 tokens åt gången. Samma ändring gör att prompten läses in 1,4–1,6× snabbare
(`prefill.py`: 384 tokens 4,6 s → 3,4 s).

**Svarsminne** (`svarsminne.py`): svar på 15 frågor sparades, sedan ställdes omformulerade varianter.
Det gav 1,21 tokens per pass, alltså ~12 % snabbare per token. Det är blygsamt, eftersom en liten modell formulerar
sig olika varje gång. Tekniken gör mest nytta *inom* ett tänkande, där utkasten verkligen ekar varandra.

## Filer
| Fil | Vad |
|---|---|
| `ekodekodning.py` | Experimentet: 20 frågor × tre tänkandenivåer, med och utan ekodekodning (C-motorn via ctypes) |
| `test_exakthet.py` | Visar att fördelningen över svar inte ändras |
| `kostnad_per_pass.py` | Vad kostar ett pass med k tokens jämfört med 1? |
| `prefill.py` | Hur snabbt läses en prompt in, gammal mot ny motor |
| `svarsminne.py` | Experiment 2: tidigare svar på liknande frågor som förslag |
| `resultat_*.json`, `*.txt` | Uppmätta siffror |
