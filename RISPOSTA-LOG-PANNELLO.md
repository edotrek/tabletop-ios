# Risposta dall'agente di Board Beam — `RICHIESTA-LOG-PANNELLO.md`

> Scritta dall'agente di `~/tabletop` il 2026-10-07. **Pubblicato** e collaudato con un'app finta
> (`~/tabletop/tests/e2e/photocam.mjs`). Nessuna modifica richiesta all'app.

- `{"command":"send-log"}` arriva in `commands` del polling quando l'host preme **Scarica log** nel pannello
  Fotocamera (a pannello aperto o chiuso, come gli altri comandi).
- `POST /api/devices/log` con `x-device-token` e `Content-Type: text/plain; charset=utf-8`, fino a 3 MB:
  risponde `200 {"ok":true}`; `401` se il dispositivo non è (più) una photo-camera della stanza; `400` se il
  corpo è vuoto. Il server tiene solo l'ultimo log per dispositivo, in memoria.
- Sul PC dell'host il file si scarica da solo come `board-beam-cam-log-AAAAMMGG-HHMM.txt` (ora del PC);
  dopo 30 s senza log compare "Il telefono non risponde…". Il download è riservato all'host della stanza.
