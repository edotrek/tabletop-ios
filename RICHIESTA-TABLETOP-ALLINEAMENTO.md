# Richiesta dall'agente di Tabletop — video e foto 48 MP non coincidono

> Scritto dall'agente di Tabletop (`~/tabletop`), 2026-10-05.

## Il problema
Nelle finestre del tavolo c'è una **leggera differenza di posizione** tra lo stream video ("table") e la
foto a 48 MP della stessa fotocamera. Tabletop applica a entrambi gli **stessi quattro angoli in frazioni
dell'immagine** (video steso sull'intera finestra, foto deformata alle dimensioni native): se le due
immagini inquadrano esattamente la stessa scena coincidono. Verificato con una fotocamera simulata in cui
video e foto vengono dallo stesso fotogramma: coincidenza perfetta. Quindi la differenza nasce nell'iPhone.

Nel codice dell'app non c'è ritaglio (VTPixelTransferSession ridimensiona l'intero fotogramma, stesso
formato 4:3, stessa rotazione). Sospetti:

1. **Stabilizzazione video** sulla connessione dell'`AVCaptureVideoDataOutput` (`motion.output`): se è
   attiva ritaglia e sposta l'immagine. Impostare esplicitamente
   `connection.preferredVideoStabilizationMode = .off` (e loggare `activeVideoStabilizationMode`).
2. **Correzione della distorsione geometrica** (`AVCaptureDevice.isGeometricDistortionCorrectionEnabled`,
   se `isGeometricDistortionCorrectionSupported`): può essere applicata in modo diverso a foto e video.
   Loggarne il valore e provare sia `true` sia `false`, scegliendo quello per cui video e foto coincidono.
3. Eventuale **zoom/crop diverso** tra pipeline foto e video (es. `videoZoomFactor`, formati con FOV
   diverso): loggare `activeFormat.videoFieldOfView` e le dimensioni effettive di foto e fotogrammi.

## Come verificare
Su ogni finestra del tavolo di Tabletop c'è ora il pulsante **Confronta** (due quadrati sovrapposti):
1° clic = foto al 50% sopra il video, 2° clic = foto e video alternati ogni mezzo secondo, 3° = spento.
Inquadrare qualcosa di regolare (tabellone, foglio a quadretti) e guardare:
- **stesso spostamento ovunque** → ritaglio/stabilizzazione (punto 1);
- **differenza che cresce verso i bordi** → correzione della distorsione (punto 2);
- **leggero ingrandimento** → zoom/crop diverso (punto 3).

Se il problema non si può eliminare nell'app, Tabletop aggiungerà una calibrazione per dispositivo
(4 punti uguali indicati su video e foto). Riporta l'esito all'utente.

## Aggiornamento (stesso giorno)
Con il Confronta l'utente vede uno **spostamento lungo un solo asse, senza zoom né differenze che
crescono verso i bordi**. Tabletop ha ora una correzione manuale per dispositivo (frecce "Allinea il
video alla foto" durante il confronto), quindi non è bloccante. Se nell'app si trova la causa (es.
stabilizzazione o un offset tra il ritaglio del video e quello della foto), dopo la correzione l'utente
deve solo azzerare l'allineamento in Tabletop.
