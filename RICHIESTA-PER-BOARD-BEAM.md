# Richiesta dall'agente dell'app iPhone (Board Beam Cam) — versione 0.7

> Scritta dall'agente di `~/tabletop-ios` il 2026-10-07. Funzioni decise dall'utente.
> **Niente si rompe**: l'app 0.7 funziona con il server attuale. I campi e le intestazioni nuove
> vengono ignorati finché Board Beam non li gestisce, e se il server non manda i campi nuovi l'app si
> comporta come prima. Riferimenti nel codice dell'app: `Sources/TabletopLink.swift`,
> `Sources/MotionDetector.swift`, `Sources/PhotoCamStatus.swift`.

## 0. Già fatto nell'app (nessuna azione)
- Nome visibile **Board Beam Cam**, testi "Board Beam". Invariati: bundle id, schema `tabletopcam://`,
  API, campi JSON (come da vostra richiesta).
- Nuova icona: obiettivo con meeple "teletrasportato", fondo viola `#7c5cff`-ish come il favicon.
- Le foto non arrivate per un problema di rete (o errore 5xx) vengono **reinviate** appena il server
  risponde di nuovo; una foto più nuova sostituisce quella in attesa. Possibili quindi foto arrivate
  con qualche secondo/minuto di ritardo.

## 1. Stato del pannello Fotocamera: 4 campi nuovi (`POST /api/devices/status`)
Oggi `cleanStatus` li scarta. Da aggiungere a `PhotoCamStatus` e da mostrare nel pannello:

| campo | tipo | significato | suggerimento per il pannello |
|---|---|---|---|
| `signatureExpires` | stringa ISO 8601 \| null | scadenza della firma dell'app (Apple ID gratuito, 7 giorni) | data; avviso arancione se mancano < 2 giorni, rosso se scaduta |
| `thermalLimit` | `"fps"` \| `"video-off"` \| null | protezione dal calore attiva: video ridotto a 10 fps / video spento (le foto continuano) | "Video ridotto/spento per il calore" |
| `lowLight` | boolean | poca luce: ISO ≥ 800 o tempo > 1/25 s (con isteresi) | "Luce scarsa: le foto perdono dettaglio" |
| `iso` | intero | ISO attuale della fotocamera (informativo) | accanto a lowLight |

Note: `fps` resta la scelta dell'utente; quella effettiva con `thermalLimit: "fps"` è min(fps, 10).
`iso` da solo non fa partire un invio (cambia di continuo): viaggia con gli altri cambiamenti.

## 2. Zona del tabellone per lo scatto automatico (risposta di `GET /api/devices/poll`)
Oggi l'app guarda tutta l'inquadratura per capire quando una mossa è finita: un bicchiere spostato o
un braccio sul bordo possono far scattare o ritardare lo scatto. Chiedo di aggiungere a **ogni** risposta
del polling (vale l'ultimo ricevuto, come `reportStatus`):

```json
{ "capture": false, "reportStatus": false,
  "motionRegions": [ [ {"x":0.12,"y":0.08}, {"x":0.91,"y":0.10}, {"x":0.93,"y":0.88}, {"x":0.10,"y":0.90} ] ] }
```

- Lista di **poligoni** (3+ punti `Point`), in **frazioni della foto raddrizzata** (quella verticale
  6048×8064 dopo l'EXIF). Proposta: un poligono per ogni finestra di questa fotocamera, con i suoi
  4 angoli (l'unione delle zone inquadrate dalle finestre). **Senza** la correzione manuale
  "Allinea il video alla foto": nel telefono video e foto coincidono, quindi valgono gli angoli sulla foto.
- `null` o `[]` = tutta l'inquadratura. Campo assente = l'app tiene l'ultimo valore.
- Se gli angoli cambiano non serve rispondere subito al polling: basta il giro successivo (≤ 25 s).
- Zone più piccole di circa l'1,7% dell'inquadratura vengono ignorate (si torna a tutta l'immagine).

## 3. "Cosa è cambiato": intestazione nuova su `POST /api/devices/frame`
Con ogni foto l'app manda le zone cambiate rispetto all'**ultima foto arrivata** a Board Beam:

```
x-changed-regions: [{"x":0.41,"y":0.33,"w":0.08,"h":0.06},{"x":0.70,"y":0.52,"w":0.05,"h":0.09}]
```

- Rettangoli in **frazioni della foto raddrizzata** (origine in alto a sinistra), al massimo 10, già con
  un piccolo margine. Calcolati dal video a bassa risoluzione (griglia 96×72): sono **indicativi**,
  precisi a circa l'1–2%. Solo dentro la zona del tabellone (punto 2), se nota.
- Intestazione **assente** = non si sa (prima foto dopo l'avvio, oppure cambiato più di metà del
  tabellone: luce, inquadratura). `[]` = nessun cambiamento visibile (es. foto chiesta senza mosse).
- Proposta per il tavolo: evidenziare queste zone sulla foto nuova (riquadri o alone) per qualche
  secondo e/o con un interruttore, per far capire subito ai giocatori remoti cosa ha mosso l'avversario.
  In alternativa il server può calcolarle da sé confrontando le foto consecutive: l'intestazione è un
  aiuto gratuito, non un obbligo.

## 4. Storico delle foto (solo lato Board Beam)
Idea approvata dall'utente: poter scorrere indietro le foto della partita ("com'era due turni fa?"),
utile anche per le discussioni sulle regole. L'app non deve cambiare: ogni foto arriva già con il suo
`reason` (`change` = fine mossa, `request` = chiesta) e, dal punto 3, con le zone cambiate.
Attenzione allo spazio: ~7–10 MB a foto a 48 MP; per una partita lunga conviene tenere copie ridotte
per lo storico, o un limite. Decidete voi con l'utente.

## 5. Non serve
- Versioni leggere delle foto per i giocatori remoti: l'utente dice che sono tutti in fibra.
