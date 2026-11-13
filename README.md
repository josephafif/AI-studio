# AI Control Center

En fristående, lokal kontrollpanel för Windows där du skapar, bygger, tränar, testar och
hanterar egna AI-språkmodeller. Allt körs på din egen dator – ingen data lämnar den.

## Kom igång (Windows)

1. Installera [Python 3.10 eller senare](https://www.python.org/downloads/) och kryssa i
   **Add python.exe to PATH**.
2. Dubbelklicka på **`installera.bat`**. Välj CPU- eller GPU-version (NVIDIA/CUDA) av PyTorch.
3. Dubbelklicka på **`starta.bat`**. Kontrollpanelen öppnas i ett eget fönster.

Om din Python saknar modulen `venv` (t.ex. den avskalade "embeddable"-varianten) lägger
installationen paketen i mappen `.paket\` i stället – inget annat behöver göras.

Saknas WebView2/pywebview öppnas panelen i webbläsaren i stället (`starta.bat --browser`
tvingar fram det). All data sparas i mappen `data\` bredvid programmet.

## Skapa Lennart

1. **Modeller → + Ny modell.** Mallen *Lennart – svensk cybersäkerhet (~1 M)* är förvald:
   svenska, cybersäkerhet och IT-säkerhet, GPT-arkitektur med 4 lager, 4 attention heads,
   context length 128 och 995 544 parametrar.
2. Datasetet *Svensk cybersäkerhet* är förvalt. Kryssa i **Starta träningen direkt** och
   klicka **Skapa modell**.
3. Följ loss-kurvan, loggen och checkpoints under **Träning**. 4 000 steg tar ungefär
   15–20 minuter på en fyrkärnig CPU.
4. Klicka **Testa i chatten** och fråga till exempel *Vad är nätfiske?*

En färdigtränad **Lennart** (4 000 steg, rätt svar på 154 av 160 undanhållna testfrågor)
läggs in automatiskt första gången programmet startas, så du kan chatta direkt under
**Testa modeller**. Vill du skapa och träna en egen från mallen enligt stegen ovan: ge den
ett annat namn, eller byt namn på eller ta bort den medföljande först.

Lennart är en helt vanlig modell i panelen. Du kan träna vidare från senaste checkpoint,
med samma data eller med ett nytt dataset, och skapa hur många andra modeller som helst.

> **Vad en modell på 1 miljon parametrar klarar:** Lennart lär sig sitt träningsdata i
> stort sett utantill och svarar bra på frågor som liknar dem – även omformulerade. Den
> resonerar inte fritt och ger osammanhängande svar på frågor långt utanför datat. Vill du
> ha en kunnigare modell behövs både mer data och fler parametrar.

## Funktioner

| Vy | Vad du kan göra |
|---|---|
| **Översikt** | Modeller, pågående träning, senaste körningar och systemstatus (CPU, minne, disk, GPU). |
| **Modeller** | Skapa, importera, exportera (.zip), byta namn på, konfigurera och ta bort modeller. Välj aktiv modell. Se parametrar, träningsstatus, genererad kod, checkpoints och träningshistorik. |
| **Träning** | Välj modell och dataset, ställ in parametrar, välj CPU eller GPU. Starta, pausa, fortsätt och avbryt. Live-graf över loss, logg och checkpoints. Fortsätt från valfri checkpoint. |
| **Testa modeller** | Chatta med valfri modell, byt modell mitt i samtalet, jämför upp till fyra modeller sida vid sida, ställ in temperatur, max tokens och top-k, spara och öppna testsessioner. |
| **Dataset** | Importera TXT, JSON och JSONL, förhandsgranska, rensa dubbletter, dela upp i träning/validering/test, dokumentera källa och licens. |

### Nya modeller

Du väljer namn, beskrivning, användningsområde, språk, arkitektur (Transformer/GPT, LSTM
eller GRU), antal parametrar, lager, attention heads, context length och ordförråd.
Panelen räknar ut den modellbredd som hamnar närmast det önskade parameterantalet och
visar det exakta antalet innan modellen skapas. Därefter skapas modellens mapp:

```
data\modeller\lennart\
    config.json             metadata och arkitektur
    model.py                genererad PyTorch-kod för just den här modellen
    README.md               modellkort
    tokenizer.json          byte-nivå BPE, tränas på datat vid första träningen
    traningshistorik.json   en post per träningskörning
    checkpoints\            ckpt_0001000.pt + mätvärden, optimizer.pt
```

### Datasetformat

- **JSONL / JSON** – poster med `fråga`/`svar`, `question`/`answer`, `prompt`/`response`,
  `instruction`/`input`/`output`, `messages` (roller `user`/`assistant`) eller `text`.
- **TXT** – delas upp i stycken (tomrad emellan) och används som löpande text.

Det medföljande datasetet *Svensk cybersäkerhet* (3 206 frågor och svar, 221 unika svar,
CC0) är skrivet för det här projektet och byggs av `tools/bygg_cybersak_dataset.py`.
Lägg till egna begrepp och frågor där och kör skriptet för att bygga om filen.

## Arkitektur

Gränssnitt, modellhantering och träning är åtskilda:

```
aicc/ui/        Gränssnittet (HTML/CSS/JS, inga externa beroenden). Pratar bara med API:t.
aicc/server/    Tunt lokalt HTTP-API på 127.0.0.1 (Pythons standardbibliotek).
aicc/core/      Hantering av modeller, dataset, körningar och sessioner. Importerar aldrig PyTorch.
aicc/engine/    Tokenizer, träningsprocess och inferens (PyTorch).
```

Varje träning körs som en **egen process** (`python -m aicc.engine.train_worker`).
Kontrollpanelen styr den enbart via filer i `data\korningar\<id>\` (`control.json` in,
`status.json`, `metrics.jsonl` och `train.log` ut). Träningen fortsätter därför även om
fönstret stängs, och visas igen nästa gång panelen startas.

Säkerhet: servern lyssnar bara på den egna datorn och avvisar anrop från andra
webbplatser. Checkpoints läses med `weights_only=True`, och vid import av en modell körs
aldrig koden i arkivet – `model.py` genereras om från konfigurationen.

## Utveckling

```
python main.py --browser          starta utan eget fönster
python main.py --data D:\aidata   använd en annan datamapp
python -m pytest tests -q         testar hela flödet: skapa → träna → pausa → fortsätt → chatta → exportera/importera
```
