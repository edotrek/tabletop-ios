# Richiesta dall'agente di Board Beam (ex Tabletop) — nuovo nome

> Scritta dall'agente di `~/tabletop` il 2026-10-07. Decisione dell'utente.

## Cosa è cambiato

Il progetto **Tabletop** si chiama ora **Board Beam**, e l'app iPhone diventa **Board Beam Cam**.
Sul server sono cambiati **solo i testi visibili**: nel pannello dell'host ora si legge "l'app Board Beam Cam"
(dialogo "Collega reflex", messaggi delle finestre, pannello Fotocamera). Indirizzi, API, protocollo e
schema del QR sono **identici**: l'app attuale continua a funzionare senza modifiche.

## Cosa serve nell'app

1. **Nome visibile**: `CFBundleDisplayName` → `Board Beam Cam` (sotto l'icona e in File → Sul mio iPhone).
2. **Testi dell'interfaccia e del log**: "Tabletop" → "Board Beam", "Tabletop Cam" → "Board Beam Cam".
   Da una ricerca veloce (solo lettura) risultano in `ContentView.swift` ("Scatto e invio a Tabletop…",
   "Non collegata a Tabletop", "Collegamento a Tabletop…", "Collegata a Tabletop · …", "Tabletop non
   raggiungibile"), `PairingView.swift` (istruzioni e titolo "Collega a Tabletop", con il riferimento al
   QR "per l'app Tabletop Cam" → ora "per l'app Board Beam Cam"), `TabletopLink.swift` (motivi di
   scollegamento e log), `CameraController.swift`, `TabletopCamApp.swift` (log di avvio),
   `ResultView.swift` (percorso in File).

## Cosa NON cambiare (per non rompere ciò che è già collegato)

- Lo **schema `tabletopcam://`** (`CFBundleURLSchemes`): il QR del pannello usa ancora
  `tabletopcam://pair?server=…&code=…`. Se un giorno si vorrà anche `boardbeamcam://`, va aggiunto
  **in più**, e prima va chiesto all'agente del server di generarlo.
- Il **bundle id** `com.edotrek.tabletopcam`: cambiarlo crea un'app diversa (si perdono abbinamento,
  impostazioni e foto salvate, e occupa un'altra delle 3 app consentite dall'Apple ID gratuito).
- Le chiavi di UserDefaults/Keychain, i nomi dei file e delle classi Swift, il nome del target
  (`TabletopCam`) e del repository: sono interni, non li vede nessuno.
- Le rotte del server (`/api/devices/...`) e i nomi dei campi JSON.

## Come proveremo

L'app si installa sopra la vecchia (stesso bundle id), resta collegata, sotto l'icona compare
"Board Beam Cam" e nell'app non si legge più "Tabletop".
