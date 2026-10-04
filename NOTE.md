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
