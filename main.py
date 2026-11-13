"""AI Control Center – startar den lokala servern och öppnar kontrollpanelen.

    python main.py              öppnar kontrollpanelen i ett eget fönster
    python main.py --browser    öppnar i webbläsaren i stället
    python main.py --no-window  startar bara servern (skriver ut adressen)
"""
from __future__ import annotations

import argparse
import os
import sys
import threading
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parent
# Paket som installera.bat lagt i .paket (används när Python saknar venv, t.ex. "embeddable").
for _p in (ROOT / ".paket", ROOT):
    if _p.exists() and str(_p) not in sys.path:
        sys.path.insert(0, str(_p))


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        # Träningsprocessen startas via den här filen så att sökvägarna ovan alltid gäller.
        from aicc.engine.train_worker import main as worker_main
        return worker_main(Path(sys.argv[2]))
    parser = argparse.ArgumentParser(description="AI Control Center")
    parser.add_argument("--port", type=int, default=0, help="port (standard: välj en ledig)")
    parser.add_argument("--browser", action="store_true", help="öppna i webbläsaren i stället för eget fönster")
    parser.add_argument("--no-window", action="store_true", help="starta bara servern")
    parser.add_argument("--data", help="mapp för modeller, dataset och körningar (standard: ./data)")
    args = parser.parse_args()
    if args.data:
        os.environ["AICC_DATA"] = str(Path(args.data).resolve())

    from aicc.server.app import create_server

    server = create_server(args.port)
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    print(f"AI Control Center körs på {url}", flush=True)

    if args.no_window:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        return 0

    threading.Thread(target=server.serve_forever, daemon=True).start()

    if not args.browser:
        try:
            import webview  # pywebview – använder Edge WebView2 på Windows
        except ImportError:
            print("pywebview är inte installerat – öppnar i webbläsaren i stället.")
        else:
            webview.settings["ALLOW_DOWNLOADS"] = True
            webview.create_window("AI Control Center", url, width=1440, height=920,
                                  min_size=(1100, 700), background_color="#0c1016")
            webview.start()
            server.shutdown()
            return 0

    webbrowser.open(url)
    print("Stäng det här fönstret (eller tryck Ctrl+C) för att avsluta kontrollpanelen.")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
