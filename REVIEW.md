# Full review — Alpha DPF Monitor

Data: 10 agosto 2026
Branch: `codex/full-review-ui-functional-refresh`

## Valutazione sintetica

Il progetto parte da una base tecnica insolitamente solida per un’app OBD:
parser e formule sono isolati, la sessione iPhone/CarPlay è condivisa, i dati
simulati non vengono confusi con quelli reali, lo storico resta locale e la
suite standalone copre già i casi diagnostici più delicati.

Le priorità emerse dalla review erano tre:

1. rendere coerente e più sicura la presentazione tra iPhone e CarPlay;
2. eliminare alcune ambiguità di stato nelle rigenerazioni e nel reconnect BLE;
3. portare connessione, storico e accessibilità allo stesso livello del core OBD.

## Miglioramenti inclusi nel branch

### Grafica e UX

- Dashboard “instrument cluster” più neutra: il rosso carrozzeria non domina
  più lo sfondo e resta distinguibile dai colori di allarme.
- Hero DPF responsivo con layout verticale automatico quando lo spazio o
  Dynamic Type lo richiedono.
- Soglie carico unificate con il modello condiviso da CarPlay:
  normale `<85%`, elevato `85–95%`, imminente `>95%`.
- Comando di connessione flottante finché serve connettere o riprovare; durante
  una sessione Live/Test diventa l’ultimo elemento della pagina e non copre i dati.
- Tile dei dati veicolo con altezza uniforme anche quando le traduzioni vanno
  su due righe; i valori restano allineati sul bordo inferiore.
- Conferma esplicita prima di disconnettersi durante una rigenerazione.
- Stato vuoto più utile: niente griglia di soli trattini e accesso diretto alla
  demo DPF.
- Target touch dell’header portati a 44 pt, griglia a una colonna alle taglie
  accessibilità, semantica VoiceOver per gauge e metriche, animazioni ridotte
  quando è attivo “Riduci movimento”.
- Onboarding notifiche scrollabile e saltabile; non suggerisce più di
  disattivare Full immersion Guida.

### Funzionalità

- Stima prudente del tempo residuo della rigenerazione. Compare soltanto dopo
  almeno due campioni con avanzamento significativo e viene scartata se il
  risultato è fuori da un intervallo credibile.
- Storico con durata media, calo medio del carico e percentuale di cicli
  completati. Cicli attivi o non verificati non alterano queste statistiche.
- Grafico storico interattivo con selezione del campione, temperatura, marker
  di rigenerazione, soglie coerenti e descrittore audio per VoiceOver.
- Feedback aptico su connessione riuscita e inizio rigenerazione.
- Nuove stringhe tradotte in italiano, inglese, francese e spagnolo.

### Affidabilità

- La logica live che alimenta lo storico conserva tre stati: un PID
  temporaneamente sconosciuto mantiene il ciclo attivo e non registra una
  falsa conclusione; i campioni persistiti restano volutamente semplici.
- Una perdita del link BLE dopo il bootstrap diventa terminale: “Riprova” crea
  una sessione ELM completa invece di riusare header e stato AT non più validi.
- La selezione GATT attende tutti i servizi, tollera errori sui servizi
  accessori e conserva l’identità del servizio, evitando che una coppia
  generica scoperta per prima prevalga su FFF0/FFE0.
- Dopo almeno un poll completato, il watchdog controlla il tempo reale anche
  mentre il poll successivo è bloccato e non dipende dal nuovo avanzamento di
  `pollSequence`.
- Un generation token impedisce a boot, poll e simulazioni cancellati di
  sovrascrivere lo stato di una sessione avviata successivamente.
- Test aggiunti per ETA, transizioni tri-state, statistiche e identità del
  servizio BLE.

## Finding ancora aperti

### Gate operativo — prima di qualunque release

- Verificare archive e firma su device reale: CarPlay Driving Task richiede
  entitlement approvato e i profili locali osservati durante la review non
  sono affidabili per una validazione release.

### P1 — prossimo ciclo tecnico

- Aggiungere un vero target `AlfaDPFTests` allo scheme. Oggi il runner
  `Tests/main.swift` è ampio ma `xcodebuild test` e Xcode Cloud non lo eseguono.
- Aggiungere una deadline end-to-end alla write di trasporto, non soltanto alla
  lettura della risposta ELM.

### P2 — evoluzione consigliata

- Distinguere errori di trasporto, `NO DATA` valido e payload non valido nella
  strategia di probing degli header, evitando retry duplicati e lenti.
- Spostare SQLite dietro un actor asincrono per non eseguire query sincrone sul
  `MainActor`.
- Aggiungere export diagnostico redatto con latenza, PID freschi/falliti,
  header scelto e profilo BLE.
- Portare lo storico da 24 ore a filtri Oggi/7 giorni/Tutto con retention
  esplicita ed export CSV.
- Completare il passaggio a text styles semantici nelle schermate secondarie e
  aggiungere snapshot QA per IT/EN/FR/ES e taglie Dynamic Type.

## App Store e prodotto

- Gli screenshot presenti mostrano una UI precedente e solo il set italiano;
  vanno rigenerati dalla build corrente, includendo storico, Live Activity e
  CarPlay, quindi replicati in inglese.
- L’icona attuale è efficace a grande formato ma troppo dettagliata a 60 pt.
  Una futura variante dovrebbe usare un arco DPF più bold, due colori e versioni
  dark/tinted, senza microtexture.
- README, checklist e release notes sono stati riallineati alla versione 1.3,
  build 18.

## Verifica eseguita

- Build Debug app + widget per simulatore, firma disabilitata: riuscita.
- Analisi statica Xcode di app + widget: riuscita.
- Runner standalone Swift/SQLite: tutti i test superati.
- Validazione JSON dei cataloghi localizzazione: riuscita.
- Ispezione visuale nel simulatore iPhone con scenari clean, rigenerazione,
  stato vuoto, storico e Dynamic Type alla taglia accessibilità massima; resta
  necessaria una prova su iPhone reale per luminosità, Bluetooth, haptics,
  notifiche e CarPlay.
