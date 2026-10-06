# Richiesta dall'agente di Tabletop — pannello "Fotocamera" sul PC dell'host

> Scritta dall'agente di Tabletop (`~/tabletop`) il 2026-10-06. Lato Tabletop è **già pubblicato e
> collaudato** con un'app finta: manca solo la parte dell'app. Le versioni attuali dell'app continuano a
> funzionare (i campi nuovi delle risposte vengono ignorati).
> Riferimenti nel codice di Tabletop (solo lettura): `packages/protocol/src/index.ts` (`DeviceCommands`,
> `PhotoCamCommand`, `PhotoCamStatus`, `PHOTOCAM_FPS`), `apps/server/src/deviceCommands.ts`,
> `apps/server/src/devices.ts` (rotta `/api/devices/status`), `apps/web/src/room/photocamPanel.tsx`,
> collaudo `tests/e2e/photocam.mjs` (contiene un'app finta che fa esattamente quanto descritto qui).

## Perché

Il telefono sta sul braccio sopra il tavolo e non si vuole toccarlo durante la partita. L'host ha ora
sul PC un pannello **Fotocamera** (pulsante con la macchina fotografica nella barra in basso) che mostra
lo stato dell'app e la comanda, come già fatto per lo scanner delle carte.

## Regola principale (richiesta esplicita dell'utente): lo stato SOLO a pannello aperto

**I dati extra si inviano solo mentre un host ha il pannello aperto**, per non consumare batteria e non
scaldare il telefono quando nessuno li guarda.

- Ogni risposta di `GET /api/devices/poll` contiene ora `reportStatus: true|false`. **Vale l'ultimo
  ricevuto.**
- `reportStatus: true` → invia **subito** lo stato completo, poi **solo quando cambia qualcosa**
  (nessun invio periodico, nessun timer).
- `reportStatus: false` → **smetti di inviare** lo stato **e smetti di misurarlo**: niente
  `UIDevice.isBatteryMonitoringEnabled`, niente osservatori di temperatura o batteria attivi.
  Riattivali solo quando torna `true`.
- Quando l'host apre o chiude il pannello il server **risponde subito** al polling in corso (non
  serve aspettare i 25 s). Se il PC si scollega con il pannello aperto il server lo considera chiuso.
- Nessuna anteprima o immagine extra: il video passa già da LiveKit e le foto dal loro canale.
- I **comandi** invece funzionano sempre, a pannello aperto o chiuso (arrivano solo quando l'host preme
  un pulsante, quindi non costano nulla).

## 1. Risposta del polling (già attiva sul server)

```json
{ "capture": false, "reportStatus": true, "commands": [ { "command": "focus-lock" } ] }
```

- `capture`: come prima (scatta e invia la foto con `reason=request`). Il pulsante **Scatta ora** del
  pannello usa questo.
- `commands` (facoltativo): da eseguire **in ordine**. Valori possibili:

| comando | effetto nell'app |
|---|---|
| `{"command":"focus-lock"}` | metti a fuoco al **centro** e blocca AF/AE/WB (come il tocco + blocco di oggi) |
| `{"command":"focus-unlock"}` | torna a fuoco/esposizione automatici continui (`setLocked(false)`) |
| `{"command":"auto-capture","on":true\|false}` | "Scatto automatico a fine mossa" (`link.autoCapture`) |
| `{"command":"video","on":true\|false}` | "Trasmetti video" (`streamer.enabled`) |
| `{"command":"fps","fps":30\|20\|15\|10\|5}` | "Fluidità video" (`streamer.fps`) |
| `{"command":"black-screen","on":true\|false}` | schermo nero (come `setBlackScreen`) |

I comandi sconosciuti vanno ignorati (in futuro se ne potranno aggiungere). Ogni comando eseguito va
anche nel log dell'app, es. "Dal PC: fuoco bloccato".

## 2. Invio dello stato (solo con `reportStatus: true`)

`POST /api/devices/status`, intestazione `x-device-token`, `Content-Type: application/json`, corpo
(tutti i campi facoltativi, massimo 4 KB):

```json
{
  "app": "0.6",
  "focusLocked": true,
  "autoCapture": true,
  "video": true,
  "videoLive": true,
  "fps": 15,
  "capturing": false,
  "blackScreen": false,
  "battery": 0.82,
  "charging": true,
  "thermal": "fair",
  "error": null
}
```

- `video` = scelta dell'utente ("Trasmetti video"); `videoLive` = il video è davvero in onda su LiveKit.
- `capturing` = scatto o invio di una foto in corso (true all'inizio, false alla fine).
- `battery` 0–1 (`null` se non disponibile), `charging` da `UIDevice.batteryState`.
- `thermal` da `ProcessInfo.thermalState`: `nominal` | `fair` | `serious` | `critical`.
- `error`: ultimo errore da mostrare all'host (es. "Fotocamera non disponibile"), `null` quando risolto.
- Risposta: `{ "reportStatus": true|false }` (stessa informazione del polling).
- Invia l'oggetto **completo** ogni volta (è piccolo), ma **solo quando un valore cambia**. Per batteria
  e temperatura bastano le notifiche di sistema (`batteryLevelDidChange`, `batteryStateDidChange`,
  `thermalStateDidChangeNotification`), registrate solo a pannello aperto; se l'invio fallisce non ritentare
  in ciclo: il prossimo cambiamento lo rimanda.
- 401 = dispositivo scollegato (come per il polling).

## 3. Cosa resta solo sul telefono

Modalità JPEG/HEIC/ProRAW, risoluzione, qualità JPEG, scatti di prova, serie, diagnosi, log e
**Scollega**: non servono durante la partita e restano nell'app.

## Come proveremo

1. Con il pannello chiuso: nel log dell'app nessun invio di stato.
2. Apro il pannello sul PC → entro un secondo compaiono batteria, temperatura, fuoco, video.
3. Pulsanti del pannello: Metti a fuoco e blocca / Sblocca, scatto automatico, video on/off,
   fluidità, schermo nero, Scatta ora → l'app esegue e il pannello si aggiorna.
4. Chiudo il pannello → l'app smette di inviare (verificabile dal log).
