# Note e scoperte — Tabletop Cam (iPhone 14 Pro Max)

## Fase A — Prova di fattibilità

App: anteprima fotocamera principale, modalità JPEG / HEIC / ProRAW→JPEG, scelta risoluzione
(tra i `supportedMaxPhotoDimensions` del formato attivo), blocco AF/AE/WB, serie di scatti per
misurare tempi e calore, log copiabile. Le foto finiscono anche in File → Sul mio iPhone → Tabletop Cam → Foto.

Configurazione: preset `.photo`; se un altro formato della fotocamera permette foto più grandi
viene scelto quello (preferendo 4:3 e 420f). `maxPhotoQualityPrioritization = .quality`,
`photoQualityPrioritization = .quality` per JPEG/HEIC.

### Risultati sul dispositivo — prova del 2026-10-04 (build 2, iPhone15,3, iOS 26.6.2)

- **48 MP senza ProRAW: SÌ.** Con il solo preset `.photo` il formato attivo è già il [59]
  (video 4032x3024 420f 30fps, foto [4032x3024, 8064x6048], HQ). Nessun cambio formato necessario.
  È l'unico formato (insieme al gemello 420v) che arriva a 48 MP; tutti gli altri si fermano a 12 MP o meno.
- Uscita foto: codec jpeg + hvc1, `maxPhotoQualityPrioritization` = quality, zero shutter lag attivo,
  ProRAW supportato (formato RAW `l64r` quando attivo). Attivare/disattivare ProRAW: ~0,2 s.
- **JPEG 48 MP** (qualità predefinita): 8064×6048, 6,9–7,1 MB, otturatore 0,01–0,03 s,
  foto pronta in **1,3–1,45 s**. Orientamento tramite EXIF (8064×6048 + tag).
- **JPEG 12 MP**: 4032×3024, 1,6 MB, pronta in 1,15 s.
- **ProRAW 48 MP → JPEG sul telefono**: scatto 2,7 s + conversione **6,5 s** ≈ 9 s totali;
  JPEG 6048×8064 (già raddrizzato), 9,1 MB. Lento: ha senso solo se la qualità è nettamente migliore.
- Luce della prova scarsa: con AF/AE bloccati ISO 957 a 1/40 s. A ISO alti la riduzione rumore cancella
  dettaglio (e i JPEG pesano poco: ~1,2 bit/pixel). Ripetere con luce del tavolo vera.
- Blocco AF/AE/WB: funziona (tocco → messa a fuoco → blocco).
- Compatibilità server: 8064 px < limite 8192 px, 7 MB < 40 MB → nessuna modifica necessaria.
- **Giudizio dell'utente (2026-10-04): qualità migliore della reflex Canon 600D (18 MP) → Fase A superata.**
- Qualità JPEG "predefinita" indistinguibile da 1.0 → usare la predefinita (~7 MB).
- Serie da 20 scatti a 48 MP: retta bene, senza scaldare troppo.
- Scelte per la Fase B: JPEG 48 MP, qualità predefinita, niente ProRAW.

## Fase B — Integrazione con Tabletop (versione 0.2)

- L'app è un dispositivo `photo-camera` come l'agente della reflex: abbinamento con `POST /api/devices/pair`
  (accetta codice, link "Scarica l'agente" o `tabletopcam://pair?server=…&code=…`), token in UserDefaults,
  long polling `GET /api/devices/poll`, invio `POST /api/devices/frame?reason=request|change`.
  Nessuna modifica al server.
- Foto inviate: sempre JPEG 48 MP, qualità predefinita (~7 MB), orientamento via EXIF.
- All'avvio/abbinamento invia subito una foto (conferma anche che il server accetta il token).
- **Fine mossa** rilevata nell'app come in `startHdFrames` (CapturePage.tsx): miniatura 64 px di luminanza
  dal flusso video (AVCaptureVideoDataOutput, 2 controlli/s), scena ferma (diff < 2,5) da 1 s e
  diversa dall'ultima foto inviata (diff > 4) → scatto con `reason=change`. Attivo solo se collegata.
- Certificato: se iOS non si fida già della CA di Caddy, l'app accetta il certificato solo per l'host del server.
- Proposta per l'altro agente (facoltativa): nel riquadro "Collega reflex" mostrare anche un QR con
  `tabletopcam://pair?server=<origin>&code=<codice>`: inquadrandolo con la Fotocamera dell'iPhone
  si apre l'app e si abbina da sola (oggi bisogna far arrivare il link sull'iPhone a mano).
