# PROGRESS — Board Beam Cam

> Stato al **2026-10-08**. Versione attuale **0.8** (CI build #22, tutte verdi). Dettagli tecnici e misure in `NOTE.md`.

## Stato per fase

| Fase | Stato | Note |
|---|---|---|
| A. Foto 48 MP | ✅ provata | JPEG 8064×6048 senza ProRAW (preset `.photo`, formato [59]); ~7 MB, pronta in ~1,4 s; qualità migliore della reflex |
| B. Integrazione come `photo-camera` | ✅ provata | abbinamento (QR in app o con la Fotocamera di iOS, o link incollato), long polling, invio foto, scatto a fine mossa |
| C. Stream video LiveKit | ✅ provata | 2880×2160 verticale + simulcast, 30/20/15/10/5 fps; Board Beam mostra video + foto HD |
| Schermo nero | ✅ provata | anteprima spenta, foto/video continuano |
| Allineamento video/foto | ✅ chiuso | nel telefono coincidono (diagnosi 0,0–0,2%); si usa la correzione manuale di Board Beam |
| Pannello Fotocamera sul PC (0.6) | ✅ provata | comandi + stato solo a pannello aperto |
| 0.7: nome, icona, firma, calore, reinvio, zona tabellone, zone cambiate, luce scarsa | 🟡 compilata, **da provare** | lato Board Beam tutto implementato (`RISPOSTA-BOARD-BEAM-0.7.md`) |
| 0.8: "Scarica log" dal pannello | 🟡 compilata, **da provare** | lato Board Beam fatto (`RISPOSTA-LOG-PANNELLO.md`) |

## Prossimi passi
1. L'utente installa la 0.8 e prova in una **partita vera sul braccio** (arrivato, stabile):
   scatto a fine mossa limitato al tabellone, zone cambiate illuminate, storico, reinvio foto
   (Wi-Fi spento/acceso), avviso luce scarsa, "Scarica log".
2. Regolare le soglie del rilevamento mosse (`MotionDetector.swift`) in base ai log della partita.
3. Partita lunga (3–4 ore): calore, batteria, memoria; verificare la protezione dal calore.

## Idee scartate o rimandate (decisioni dell'utente)
- Copie leggere delle foto per i remoti: non serve (fibra). Pulizia/refactoring del codice: più avanti.
- Rimettere a fuoco periodicamente: resta al pulsante del PC.
- ProRAW: ~9 s a foto, nessun vantaggio visibile.

## File del progetto

**Documenti (cartella principale)**
- `CLAUDE.md` — regole, vincoli, ciclo di lavoro, ambiente. `PROGRESS.md` — questo file.
- `NOTE.md` — scoperte, misure, decisioni tecniche per versione.
- `RICHIESTA-*.md` / `RISPOSTA-*.md` — scambi con l'agente di Board Beam (tutti chiusi):
  `RICHIESTA-TABLETOP-ALLINEAMENTO.md` (chiusa: correzione manuale), `RICHIESTA-PANNELLO-HOST.md`
  (pannello Fotocamera, fatto 0.6), `RICHIESTA-NOME-BOARD-BEAM.md` (fatto 0.7),
  `RICHIESTA-PER-BOARD-BEAM.md` + `RISPOSTA-BOARD-BEAM-0.7.md` (0.7), `RICHIESTA-LOG-PANNELLO.md` +
  `RISPOSTA-LOG-PANNELLO.md` (0.8).

**Build**
- `project.yml` — XcodeGen: versione, Info.plist (permessi, schema `tabletopcam://`, nome visibile),
  pacchetto LiveKit 2.17.0. `.github/workflows/build.yml` — CI che produce l'IPA.
- `Support/icon.svg` — sorgente dell'icona (meeple teletrasportato); PNG in
  `Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`. `Support/Info.plist` è generato (ignorato).
- `ipa/` — IPA scaricate dalla CI (ignorata da git).

**Codice (`Sources/`)**
- `TabletopCamApp.swift` — avvio, collega gli oggetti, link `tabletopcam://`.
- `CameraController.swift` — sessione fotocamera, formato 48 MP, scatti (prova/serie/Board Beam),
  fuoco/esposizione, luce scarsa, diagnosi allineamento.
- `MotionDetector.swift` — fotogrammi video: fine mossa, zona del tabellone, zone cambiate; passa i
  fotogrammi allo stream.
- `LiveStreamer.swift` — LiveKit (token, pubblicazione simulcast, riduzione a 2880×2160, protezione dal calore).
- `TabletopLink.swift` — protocollo Board Beam: abbinamento, polling, comandi del pannello, invio/reinvio
  foto, stato del pannello, invio log, certificato del server.
- `PhotoCamStatus.swift` — stato inviato al pannello. `Signature.swift` — scadenza della firma.
- `ScreenState.swift` — schermo nero. `Alignment.swift` — misura dello spostamento video/foto.
- Viste: `ContentView`, `CameraPreview`, `PairingView`, `QRScannerView`, `ResultView`, `LogView`;
  `LogStore.swift` (log su schermo e su file, con log dell'avvio precedente); `Helpers.swift`.
