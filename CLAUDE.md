# Tabletop iOS — app fotocamera per iPhone (progetto sperimentale)

> Documento di passaggio scritto dall'agente che sviluppa **Tabletop** (`~/tabletop`).
> Leggilo tutto prima di iniziare. Comunica con l'utente **in italiano**: non è uno sviluppatore,
> spiega le cose in modo semplice e guidalo passo passo nelle operazioni che deve fare lui.

## 1. Contesto

**Tabletop** (`~/tabletop`, già funzionante, vedi `~/tabletop/SPEC.md`) è un tavolo da gioco ibrido:
giochi da tavolo fisici con alcuni giocatori presenti e altri da remoto. Un iPhone su un braccio riprende
il tavolo dall'alto; i giocatori remoti vedono lo stream e delle **"foto HD"** del tabellone, raddrizzate
in prospettiva, che si aggiornano dopo ogni mossa.

Oggi le foto HD arrivano da:
- **iPhone via Safari** (pagina web): limitato a fotogrammi video **4K (8 MP)**, perché il browser non dà
  accesso alla fotocamera fotografica. Qualità giudicata insufficiente dall'utente.
- **Reflex Canon EOS 600D (18 MP)** comandata da un agente sul PC: molto meglio, ma per l'utente
  **18 MP sono ancora pochi**.

**Obiettivo di questo progetto:** un'app iOS nativa che faccia scattare all'**iPhone 14 Pro Max**
foto alla massima risoluzione possibile (fotocamera principale da **48 MP**) e le invii a Tabletop,
comportandosi come la reflex. È un progetto di **prova**: prima si verifica cosa si ottiene davvero,
poi si decide se integrarlo.

## 2. Vincoli importanti

- **Nessun Mac.** Si lavora su una VM Ubuntu (questa). La compilazione iOS va fatta su **GitHub Actions**
  (runner macOS), producendo un **IPA non firmato** (`CODE_SIGNING_ALLOWED=NO`), impacchettato come
  `Payload/<App>.app` zippato in `.ipa`, scaricabile come artifact.
- **Installazione**: ATTENZIONE, atvloadly funziona solo per Apple TV, NON per iPhone (scoperto il 2026-10-03). Metodo per iPhone da definire (vedi NOTE.md). Con Apple ID gratuito
  (e reinstalla ogni 7 giorni) l'IPA sull'iPhone. Con l'Apple ID gratuito: firma valida 7 giorni,
  massimo 3 app, niente capability a pagamento (la fotocamera va bene). Usare un bundle id univoco.
- **Nessun debugger/console Xcode**: prevedi nell'app una **schermata di log** con pulsante
  "Copia log", così l'utente può incollarti cosa è successo.
- Serve un **account GitHub** e `gh auth login` su questa VM (guida l'utente). Nota sui minuti: i repo
  **pubblici** hanno runner macOS gratuiti senza limiti pratici; quelli **privati** hanno pochi minuti macOS
  gratuiti al mese (contano 10×). Fai scegliere all'utente, spiegando la differenza.
- Per generare il progetto Xcode senza Xcode si consiglia **XcodeGen** (`project.yml`) eseguito nella CI,
  app in **SwiftUI**, nessuna dipendenza esterna all'inizio.
- **Non modificare `~/tabletop`**: è gestito dall'altro agente. Puoi leggerlo come riferimento.
  Se servono modifiche lato server, descrivile all'utente che le passerà all'altro agente.

## 3. Piano consigliato

### Fase A — Prova di fattibilità (senza Tabletop)
App minima: anteprima della fotocamera principale, pulsante "Scatta", foto alla **massima risoluzione
disponibile**, poi mostra a schermo dimensioni in pixel, peso del file e tempo di scatto, con
condivisione/salvataggio per esaminarla.

Da verificare e riportare all'utente:
- risoluzione ottenibile **senza ProRAW** sul 14 Pro Max: `AVCapturePhotoOutput` con
  `maxPhotoDimensions` (iOS 16+), sessione con preset `.photo`, `photoQualityPrioritization = .quality`.
  48 MP (8064×6048) potrebbe essere disponibile solo in certe configurazioni o versioni di iOS:
  **verificalo sul dispositivo** elencando i `supportedMaxPhotoDimensions` del formato attivo e
  scrivendoli nel log;
- in alternativa **ProRAW 48 MP** (DNG, file enormi): valuta se ha senso convertirlo in JPEG sul telefono;
- tempi di scatto, calore, autonomia (il telefono sarà alimentato);
- **messa a fuoco ed esposizione bloccabili** (il tavolo è fermo: blocco AF/AE dopo la prima messa a fuoco).

### Fase B — Integrazione con Tabletop (nessuna modifica al server necessaria)
L'app si comporta **esattamente come l'agente della reflex** (dispositivo di tipo `photo-camera`).
Riferimento: `~/tabletop/apps/server/agent/tabletop-reflex.cmd` (PowerShell) e
`~/tabletop/apps/server/src/devices.ts`, `deviceCommands.ts`.

- Server: `https://10.0.10.129` (rete locale, certificato emesso dall'autorità locale di Caddy).
  L'utente ha già installato e reso attendibile il certificato radice sull'iPhone
  (`https://10.0.10.129/certificato.crt`), quindi `URLSession` dovrebbe fidarsi. Se non basta,
  gestisci la fiducia nel delegate di `URLSession` **solo per quell'host**.
- **Rete locale**: dichiara `NSLocalNetworkUsageDescription` in Info.plist (iOS chiede il permesso per
  gli IP locali), oltre a `NSCameraUsageDescription`.
- **Abbinamento**: `POST /api/devices/pair` con JSON `{"pairingCode": "..."}` →
  `{ roomId, deviceId, deviceToken, kind }`. Il codice si ottiene dal pannello di Tabletop:
  *Collega reflex* → il link "Scarica l'agente" è `/api/devices/agent?code=CODICE` (vale 10 minuti, una volta).
  Per la prova l'utente può copiare il codice dal link; in futuro l'altro agente può mostrare un QR.
  Conserva il `deviceToken` (Keychain o UserDefaults) per i riavvii.
- **Comandi**: long polling `GET /api/devices/poll` con intestazione `x-device-token: <token>`;
  risponde entro ~25 s con `{"capture": true|false}`. Se `capture` è true: scatta e invia.
  Un 401 significa che il dispositivo è stato scollegato dal pannello → torna alla schermata di abbinamento.
- **Invio foto**: `POST /api/devices/frame?reason=request`, intestazione `x-device-token`,
  `Content-Type: image/jpeg`, corpo = byte del **JPEG** (non HEIC: il server usa `sharp`, che non legge
  HEIC/HEVC). Limiti server: lato massimo 8192 px, 40 MB. Il server applica l'orientamento EXIF e
  ricomprime a qualità 92 (se la ricompressione peggiora troppo la qualità, segnalarlo: si può cambiare).
- **Scatto automatico a fine mossa**: oggi lo decide l'iPhone in Safari (stream video). Se l'app diventa
  la fotocamera del tavolo, quella pagina non può girare insieme (fotocamera esclusiva). Opzioni da
  valutare con l'utente: (1) l'app rileva da sola la fine di una mossa confrontando i fotogrammi
  dell'anteprima (scena cambiata e poi ferma ~1 s, vedi `startHdFrames` in
  `~/tabletop/apps/web/src/pages/CapturePage.tsx`) e invia la foto; (2) un secondo telefono fa lo stream.
- L'app deve **impedire lo standby** (`isIdleTimerDisabled`) e restare in primo piano.

### Fase C — (eventuale, da decidere dopo) Video + foto nella stessa app
Stream video via **LiveKit Swift SDK** (stesso server LiveKit di Tabletop, token da
`POST /api/media-token` con `{"participantToken": deviceToken}`) e foto ad alta risoluzione dalla
stessa `AVCaptureSession`. Complesso: affrontarlo solo se la Fase B convince.

## 4. Ciclo di lavoro con l'utente
1. Scrivi/aggiorna il codice qui, fai commit e push su GitHub.
2. La CI compila e pubblica l'IPA come artifact (scaricabile anche con `gh run download`).
3. L'utente installa l'IPA (metodo da definire, non atvloadly) sull'iPhone e prova.
4. L'utente ti incolla il log copiato dall'app e le sue osservazioni.

Tieni un file `NOTE.md` con le scoperte (risoluzioni ottenute, tempi, problemi): servirà a decidere se
e come integrare l'app in Tabletop.

## 5. Ambiente
- VM Ubuntu 26.04 (Node 22, Docker, git disponibili). Nessun Xcode.
- Tabletop gira in Docker su questa stessa VM: `cd ~/tabletop && ./tabletop.sh stato`.
- iPhone 14 Pro Max (iOS aggiornato), sulla stessa rete locale della VM.
