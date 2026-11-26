# Lennart – appen

Svensk AI som körs helt lokalt, på Android och Windows, med samma kod. Modellerna körs av den egna
motorn `../engine/lmengine.c` via `dart:ffi`.

## Delar

| Mapp | Vad |
|---|---|
| `lib/core/` | Motorn (isolat + FFI), tokenizer, modellkatalog, samtal, inställningar, självtest |
| `lib/ui/` | Chatten, ark/dialoger, ASCII-animationer, tema |
| `lib/agent/` | Agentgrunden: verktyg, verktygsprotokoll, agentslinga med godkännande |
| `android/` | Android (modellerna packas i APK:n och packas upp vid första start) |
| `windows/` | Windows (modellerna ligger i mappen `modeller` bredvid `Lennart.exe`) |
| `tool/` | Kontrollverktyg som kör motorn utan Flutter (`effort_check.dart` m.fl.) |
| `test/` | Agenttester och skärmdumpstest (`LENNART_PREVIEW=1 flutter test test/ui_preview_test.dart --update-goldens`) |

## Bygga

**Android:** `flutter build apk --release`. Modellerna läggs först i `assets/models/` med
`tools/exportera_mobil.py`.

**Windows:** byggs av GitHub Actions (`.github/workflows/lennart-windows.yml`), eftersom Flutter bara kan
bygga Windows-program på Windows. Flödet bygger `Lennart.exe` och motorn och kör sedan
`Lennart.exe --sjalvtest` på riktig Windows med två testmodeller. Programmet blir en artefakt. Därefter:

```
python tools/samla_modeller.py <modellmapp> <källor …>          # .lennart-paket eller exportmappar
python tools/paketera_windows.py <Release-artefakt> <modellmapp> <utmapp>
```

Det ger `Lennart-för-Windows.zip` plus en zip per extra modell, alla under 500 MB.

## Agentläget

Agentläget är på som standard. Lennart använder verktygen själv när du frågar, till exempel "vad är klockan?",
"hur många km är 3 mil?" eller "lägg till mjölk på inköpslistan". Dagens modeller är inte tränade på
verktygsprotokollet, så appens verktygssinne (`lib/agent/avsikt.dart`) känner igen frågorna och gör om dem till
verktygsanrop. Anropet, resultatet och svaret visas i samtalet. Svaret byggs av verktygets resultat, så siffrorna
blir alltid rätt. Verktyg som ändrar något frågar dig först.

Beräkningarna (`lib/agent/berakning.dart`) och verktygssinnet har inga beroenden till `dart:io`, så samma kod går
att kompilera till JavaScript för webbversionen.

Se också kommentaren överst i `lib/agent/agent.dart` och `moln/lennart4/PLAN.md`. Formatet för verktygsanrop
passar Lennarts samtalsformat, så Lennart 4 kan tränas på det direkt.
