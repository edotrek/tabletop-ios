# Board Beam Cam — app fotocamera iPhone per Board Beam (ex "Tabletop iOS")

> Leggi tutto prima di iniziare, poi **`PROGRESS.md`** (stato, storia, indice dei file) e, se serve,
> **`NOTE.md`** (scoperte tecniche e misure). Comunica con l'utente **in italiano**: non è uno
> sviluppatore, spiega le cose in modo semplice e guidalo passo passo nelle operazioni che deve fare lui.

## 1. Contesto

**Board Beam** (si chiamava *Tabletop* fino al 2026-10-07; cartella `~/tabletop`, gestita da un **altro
agente**) è un tavolo da gioco ibrido: giochi da tavolo fisici con giocatori presenti e remoti. Un iPhone
su un braccio riprende il tavolo dall'alto; i remoti vedono lo stream video e "foto HD" del tabellone,
raddrizzate in prospettiva, aggiornate dopo ogni mossa.

**Questa app (Board Beam Cam)** gira sull'**iPhone 14 Pro Max** dell'utente e fa tutto da sola:
- foto **48 MP** (JPEG 8064×6048, senza ProRAW) inviate a Board Beam come dispositivo `photo-camera`
  (stesso protocollo dell'agente della reflex), su richiesta e **a fine mossa** (rilevata nell'app);
- **stream video** LiveKit dalla stessa fotocamera;
- comandi e stato dal **pannello Fotocamera** sul PC dell'host, log scaricabile dal pannello.

Qualità giudicata dall'utente **migliore della reflex Canon 600D**: obiettivo raggiunto.

## 2. Regole e vincoli

- **Non modificare `~/tabletop`** (puoi leggerlo). Le modifiche lato server si chiedono all'altro agente
  con un file `RICHIESTA-*.md` in questa cartella; lui risponde con `RISPOSTA-*.md` (o scrive lui una
  `RICHIESTA-*.md` per noi). L'utente fa da tramite.
- **Nessun Mac.** Si compila su **GitHub Actions** (macOS, Xcode 26): XcodeGen genera il progetto da
  `project.yml`, IPA **non firmato**. Repo **pubblico** `edotrek/tabletop-ios` (minuti macOS gratuiti).
- **Installazione sull'iPhone: dal PC Windows dell'utente con iTunes installato** (Sideloadly, consigliato
  all'inizio; l'utente non ha mai confermato il nome dello strumento), Apple ID gratuito
  (firma 7 giorni, max 3 app; l'utente ha un servizio che reinstalla da solo prima della scadenza).
  **atvloadly NON funziona per iPhone** (solo Apple TV). Al primo avvio servono "Autorizza" lo
  sviluppatore (Impostazioni → Generali → VPN e gestione dispositivo) e la Modalità sviluppatore.
- **Da non cambiare mai** (romperebbe abbinamento, impostazioni, QR): bundle id `com.edotrek.tabletopcam`,
  schema URL `tabletopcam://`, chiavi UserDefaults, nomi delle rotte e dei campi JSON. Nomi interni
  (target `TabletopCam`, classi `TabletopLink`…) restano "Tabletop": non li vede nessuno.
- **Nessun debugger**: tutto passa dal log dell'app (schermata Log → "Copia log", oppure pulsante
  **"Scarica log"** nel pannello Fotocamera di Board Beam sul PC, oppure iTunes → Condivisione file).
- **Regola dell'utente sul pannello**: lo stato (batteria, temperatura…) si misura e si invia **solo
  mentre un host ha il pannello aperto** (`reportStatus`). Eccezione concordata: la notifica di sistema
  sulla temperatura è sempre ascoltata per la protezione dal calore.
- Decisioni già prese dall'utente: JPEG qualità predefinita (uguale a 1.0 a occhio), niente ProRAW;
  allineamento video/foto con la **correzione manuale** di Board Beam (non cercare correzioni automatiche);
  niente copie leggere per i remoti (tutti in fibra).

## 3. Ciclo di lavoro

1. Modifica il codice, alza `MARKETING_VERSION` in `project.yml`, commit e push su `main`.
   Fine dei messaggi di commit come da istruzioni di sessione (Co-Authored-By).
2. La CI (`.github/workflows/build.yml`) compila; controlla l'esito con
   `gh run watch <id> --exit-status` e gli errori con `gh run view <id> --log | grep -E "error:|BUILD"`.
   Il passo fallisce davvero solo se manca `** BUILD SUCCEEDED **` (la cartella .app esiste anche se
   la compilazione fallisce: non usarla come prova).
3. Scarica l'IPA con `gh run download <id> -D ipa` (finisce in `ipa/TabletopCam-<n>/TabletopCam.ipa`,
   cartella ignorata da git) e indica all'utente dove prenderla (o dalla pagina Actions di GitHub).
4. L'utente installa con Sideloadly, prova e ti manda il log e le osservazioni.
5. Aggiorna `NOTE.md` (scoperte) e `PROGRESS.md` (stato).

Non si può compilare Swift su questa VM: scrivi con cura e lascia che la CI trovi gli errori.

## 4. Ambiente

- VM Ubuntu 26.04 (Node 22, Docker, git). `gh` è in **`~/.local/bin/gh`** (installato senza sudo; nel
  PATH), già autenticato come `edotrek` con permesso `workflow`. Niente sudo senza password.
- Niente Python PIL / ImageMagick: per convertire SVG → PNG (icona) si usa `sharp` di Board Beam in sola
  lettura: `NODE_PATH=$HOME/tabletop/node_modules node -e "require('sharp')(…)"`.
- Board Beam gira in Docker su questa VM: `cd ~/tabletop && ./tabletop.sh stato`.
  Server `https://10.0.10.129` (CA locale di Caddy, certificato radice già fidato sull'iPhone),
  LiveKit `wss://10.0.10.129/livekit`.
- Sorgenti LiveKit Swift di riferimento: si possono riclonare (`git clone --depth 1
  https://github.com/livekit/client-sdk-swift`) per controllare le API; versione usata 2.17.0.
