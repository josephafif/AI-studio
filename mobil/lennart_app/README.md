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

Se kommentaren överst i `lib/agent/agent.dart` och `moln/lennart4/PLAN.md`. Formatet för verktygsanrop
passar Lennarts samtalsformat, så Lennart 4 kan tränas på det direkt.
