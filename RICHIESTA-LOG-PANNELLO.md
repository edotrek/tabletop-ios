# Richiesta dall'agente dell'app iPhone (Board Beam Cam) — scaricare il log dal PC

> Scritta dall'agente di `~/tabletop-ios` il 2026-10-07. Richiesta dell'utente: poter scaricare sul PC
> il log dell'app **senza toccare il telefono** (che sta sul braccio). Lato app è **già fatto** (0.8);
> manca la parte Board Beam. Riferimento nell'app: `uploadLog()` in `Sources/TabletopLink.swift`.

## Come funziona lato app (già pronto)

1. Nuovo comando del pannello, nella lista `commands` della risposta di `GET /api/devices/poll`:
   ```json
   { "command": "send-log" }
   ```
   (da aggiungere a `PhotoCamCommand`). Come gli altri comandi, funziona a pannello aperto o chiuso.
2. Ricevuto il comando, l'app fa:
   ```
   POST /api/devices/log
   x-device-token: <token>
   Content-Type: text/plain; charset=utf-8
   ```
   Corpo: testo UTF-8, **al massimo ~2 MB** (l'app taglia l'inizio se più lungo), così composto:
   ```
   Board Beam Cam 0.8 · iPhone15,3 · iOS 26.6.2

   === Log di questo avvio ===
   …
   === Log dell'avvio precedente ===
   …            ← utile se l'app si è chiusa da sola
   ```
3. Risposte attese: `200` = ok (corpo qualsiasi), `401` = dispositivo scollegato (l'app torna
   all'abbinamento), altro = l'app lo scrive nel log e basta (nessun nuovo tentativo).

## Cosa serve in Board Beam

- **Rotta `POST /api/devices/log`**: token di un dispositivo `photo-camera`, `text/plain` fino a ~2 MB
  (serve un content-type parser per `text/plain` con `bodyLimit` adeguato). Basta tenere **l'ultimo log
  per dispositivo** (in memoria o su disco), con l'ora di arrivo.
- **Pannello Fotocamera dell'host**: pulsante **"Scarica log"** → manda `send-log` al dispositivo
  (come gli altri comandi); quando il log arriva (evento realtime), il browser lo **scarica come file**
  `board-beam-cam-log-AAAAMMGG-HHMM.txt`. Se dopo ~30 s non arriva nulla, un messaggio tipo
  "Il telefono non risponde: è acceso e con l'app aperta?".
- Il download del file solo per l'host della stanza (il log contiene indirizzo del server e dettagli tecnici,
  non il token).
