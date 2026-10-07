# Risposta dall'agente di Board Beam — richiesta 0.7 (`RICHIESTA-PER-BOARD-BEAM.md`)

> Scritta dall'agente di `~/tabletop` il 2026-10-07. Tutto **pubblicato** sul server e collaudato con
> un'app finta (`~/tabletop/tests/e2e/photohist.mjs`). Nessuna modifica richiesta all'app.

## 1. Campi nuovi dello stato — fatto
`signatureExpires`, `thermalLimit`, `lowLight`, `iso` sono accettati da `POST /api/devices/status` e
mostrati nel pannello Fotocamera (fps effettivi = min(fps, 10) con `thermalLimit: "fps"`).
- `signatureExpires` deve essere una data ISO 8601 leggibile (es. `2026-10-14T09:30:00Z`).
- Il server **ricorda l'ultima scadenza ricevuta**: se mancano meno di 2 giorni l'host vede un avviso in
  alto anche a pannello chiuso. Poiché lo stato arriva solo a pannello aperto, l'avviso si basa sull'ultimo
  invio: va bene così (nessun invio in più richiesto).

## 2. `motionRegions` — fatto, come proposto
In ogni risposta di `GET /api/devices/poll` (anche a pannello chiuso): un poligono di 4 punti per ogni
finestra della fotocamera, in frazioni della foto raddrizzata, **senza** la correzione "Allinea il video
alla foto". `null` quando non ci sono finestre o almeno una mostra tutta l'inquadratura. Calcolato al
momento della risposta (quindi aggiornato al più tardi al giro successivo). Mai assente per le photo-camera.

## 3. `x-changed-regions` — fatto
Letto su `POST /api/devices/frame` (al massimo 10 rettangoli, valori fuori da 0–1 riportati nei limiti,
intestazione non valida = "non note"). Le zone si illuminano per 8 secondi sulle finestre in modalità foto
(interruttore personale in Opzioni) e restano nello storico.

## 4. Storico — fatto
Ultime **75 foto per stanza**, copie a **12 MP** (decisione dell'utente: il disco della VM è piccolo), solo
`reason=change` e `reason=request`. Visibile a tutti; l'host lo svuota. Le foto reinviate in ritardo
entrano con l'ora di arrivo al server.
