# Analisi refresh dati CarPlay — Alpha DPF Monitor

- **Task**: t_1e4456b3 — "Analizza il meccanismo attuale di refresh dei dati su CarPlay"
- **Data analisi**: 14 agosto 2026
- **Branch di lavoro**: `analysis/carplay-refresh-t_1e4456b3` (worktree, nessuna modifica di produzione)
- **HEAD analizzato**: `6a22919` (origin/codex/full-review-ui-functional-refresh)
- **Risultato suite standalone**: 268 PASS / 0 FAIL

---

## Sintesi (risposta diretta)

1. **Sì, l'intervallo è realmente di 10 secondi.** È definito in `CarPlayRefreshPolicy.interval = .seconds(10)` (`Sources/Models.swift:242-244`) e usato dal loop di refresh della scena CarPlay (`Sources/CarPlaySceneDelegate.swift:355-367`). Un test automatico lo vincola a `>= 10` secondi (`Tests/main.swift:192-193`).
2. **Non è una scelta nostra: è un limite Apple per le Driving Task app.** La guida ufficiale (CarPlay Developer Guide, giugno 2026) dice testualmente: *"Do not periodically refresh data items in the CarPlay UI more than once every 10 seconds (for example, no real- time engine data)."* [1] L'esempio esplicito "no real-time engine data" riguarda esattamente questa app.
3. **L'architettura attuale è già corretta**: CarPlay non interroga mai l'OBD; campiona lo stato condiviso del `MonitorSession`. L'acquisizione ECU (ogni ~2 s) è separata dalla presentazione (10 s), come prescritto.
4. **Si può migliorare la reattività percepita** con un approccio ibrido: refresh **event-driven con throttle a 10 s** per i dati telemetrici + aggiornamenti immediati (non periodici) per azioni utente e alert di rigenerazione + sfruttare la **Live Activity** già presente per dati più freschi "at a glance".
5. **Non ridurre sotto i 10 s** per i dati periodici: viola la linea guida e può costare il rifiuto in App Review.

---

## 1. Componenti che aggiornano i dati su CarPlay

| Componente | File:riga | Ruolo |
|---|---|---|
| `CarPlayRefreshPolicy.interval` | `Sources/Models.swift:242-244` | Costante condivisa: 10 s |
| `CarPlaySceneDelegate.startRefreshing()` | `Sources/CarPlaySceneDelegate.swift:355-367` | Loop `Task` che ogni 10 s chiama `refreshDashboard()` |
| `CarPlaySceneDelegate.refreshDashboard()` | `Sources/CarPlaySceneDelegate.swift:378-408` | Aggiorna titolo, griglia (8 tile), bar buttons, dettaglio e tracker alert |
| `makeGridButtons()` | `Sources/CarPlaySceneDelegate.swift:417-495` | Ricostruisce le 8 tile da `session.carPlayDPFState` |
| `MonitorSession.carPlayDPFState` | `Sources/MonitorSession.swift:95-102` | Stato mostrato: live reale, oppure ultimo stato persistito, oppure vuoto |
| `CarPlayTelemetryPolicy` | `Sources/Models.swift:376-397` | Decide live vs cached |
| `DPFMonitor` | `Sources/DPFMonitor.swift:80-88, 97-260` | Acquisizione ECU: poll ogni 2 s, pubblica `snapshot` |
| `MonitorSession` pollTask | `Sources/MonitorSession.swift:543-573` | Copia lo snapshot dell'actor in `dpf` + `hasLiveTelemetry` ogni ~1 s |
| `acceptLive(_:)` | `Sources/MonitorSession.swift:576-646` | Aggiorna `dpf`, storico, Live Activity |
| `DPFLiveActivityController` | `Sources/DPFLiveActivityController.swift` | Live Activity aggiornata a ogni campione accettato (`MonitorSession.swift:557`) |

## 2. Sorgente dati, polling ed eventi disponibili

- **Sorgente**: ELM327 via BLE GATT (notify) o Wi-Fi TCP (adattatore 192.168.0.10:35000 di default, `Sources/Models.swift:110-127`).
- **Polling OBD**: `DPFMonitor.start(interval: .seconds(2))` (`MonitorSession.swift:529`; default in `DPFMonitor.swift:80`). Ogni ciclo legge: avanzamento rigenerazione, carico DPF, temperatura scarico (PID critici) e, a rotazione ogni 5 cicli, distanza/contatore/olio/tensione (`DPFMonitor.swift:199-237`); tensione anche a ogni ciclo durante rigenerazione attiva.
- **Snapshot actor**: `DPFMonitorSnapshot` (stato, pollSequence, PID freschi/falliti, timestamp) pubblicato 2 volte per ciclo (`DPFMonitor.swift:188-195, 252-259`).
- **Copiatura nel MainActor**: il `pollTask` di `MonitorSession` campiona lo snapshot ogni 1 s (`MonitorSession.swift:543-573`); `hasRecentCoreTelemetry()` usa un max-age di 8 s (`DPFMonitor.swift:21-25`).
- **Eventi già disponibili nel modello** (nessun nuovo canale necessario):
  - `RegenEvent` (started/finished) emesso dal tracker su edge (`DPFMonitor.swift:149-172`) → `AlertService` notifiche locali + `CarPlayRegenerationAlertTracker` per i CPAlert in-app;
  - transizioni `status` (idle/connecting/running/failed) — già lette ad ogni render per il pulsante Connetti/Annulla/Disconnetti (`CarPlaySceneDelegate.swift:721-739, 968-988`);
  - `hasLiveTelemetry` e `dpf` cambiano ad ogni campione accettato.
- **Oggi la scena CarPlay non osserva questi cambiamenti**: usa solo il polling a 10 s (`CarPlaySceneDelegate.swift:355-367`). `MonitorSession` è `@Observable`, quindi un'osservazione event-driven è tecnicamente banale.

## 3. Limiti imposti da CarPlay/iOS (verificati su fonti primarie)

- **Refresh periodico**: niente più di una volta ogni 10 s per i "data items" in UI Driving Task [1] — citazione integrale sopra.
- **Esempio Apple**: "no real-time engine data" [1] → dati motore in tempo reale in una Driving Task app sono esplicitamente l'uso vietato. Le app che "mostrano in tempo reale" su CarPlay o sono Live Activity/widget (non scene Driving Task) o appartengono ad altre categorie (audio/navigation) con regole diverse.
- **Template consentiti** per Driving Task: Action sheet, Alert, Grid, List, Tab bar, Information (esclusi mappa/now playing/POI/search); "Attempting to use an unsupported template triggers an exception at runtime." [1]
- **Profondità gerarchia**: Driving Task limitata a 2 template (iOS ≤26.3) o 3 (iOS 26.4+) inclusa la root [1]. L'app usa root grid + 1 dettaglio = 2 → compatibile.
- **Limiti di contenuto**: max 8 grid buttons; `CPInformationTemplate` max 10 items ("The template can display 10 items maximum") [2]. L'app usa 8 tile e ≤4 item di dettaglio.
- **iPhone bloccato**: "CarPlay is frequently used while iPhone is in a locked state" [1]; niente file `NSFileProtectionComplete`/`CompleteUnlessOpen` né Keychain `WhenUnlocked*`. L'app salva lo snapshot con UserDefaults standard (classe di protezione di default `NSFileProtectionCompleteUntilFirstUserAuthentication`) → OK.
- **Notifiche**: supportate per le Driving Task da iOS 18.4; "notifications are not read aloud in CarPlay" in generale [1].
- **Background BLE**: `bluetooth-central` permette di essere svegliati per eventi BLE, ma "Even if your app supports one or both of the Core Bluetooth background execution modes, it can't run forever. At some point, the system may need to terminate your app" [3]. **L'app non configura State Preservation/Restoration** (`CBCentralManager` creato senza `CBCentralManagerOptionRestoreIdentifierKey`, `BLEConnection.swift:156`): dopo una termination il sistema non può riprendere la sessione BLE da solo.
- **Wi-Fi**: nessun background mode per socket arbitrari; `MonitorSession` tratta già una caduta TCP post-ready come terminale (`MonitorSession.swift:681-689`). Con iPhone bloccato in CarPlay il trasporto Wi-Fi resta fragile — documentato, non introdotto da questa analisi.

## 4. Impatto atteso su batteria, rete e rate limit

Numeri di progetto (upper bound teorici, ignorando la latenza dei comandi ECU):

| Voce | Valore | Note |
|---|---|---|
| Cicli OBD | ≤ 30/min (uno ogni 2 s + durata comando) | `DPFMonitor.swift:80-88` |
| Richieste PID critiche | ~90/min (3 per ciclo) | progress, clogging, temperatura |
| Richieste PID secondarie | ~24/min (0,8 per ciclo) | ogni 5° ciclo |
| Render CarPlay | 6/min (ogni 10 s) | `CarPlayRefreshPolicy.interval` |
| Richieste OBD dalla scena CarPlay | 0 | la scena legge solo lo stato condiviso |
| Traffico di rete CarPlay | 0 | nessuna URLSession nella scena |

- **Batteria**: il costo dominante è il polling ECU a 2 s (già voluto per la rilevazione rigenerazioni), non i 6 render/min di CarPlay. Ogni render ridisegna 8 tile + 3 bar buttons (artwork 80 pt, `CarPlaySceneDelegate.swift:78-136`): costo CPU modesto e accettabile; un refresh a 1 Hz sarebbe 10× questo costo.
- **Rete**: nessuna dipendenza da servizi esterni → nessun rate limit di rete. Il vincolo è solo la guida CarPlay (App Review).
- **Rate limit ECU**: non esiste un limite Apple; il collo di bottiglia è l'adattatore ELM (latency seriale). Il codice già protegge con `pidRetryAfter` (30 s) e backoff (`DPFMonitor.swift:308-352`).
- **Timers**: la guida energia Apple raccomanda eventi invece di polling: "Apps often use timers unnecessarily. If you use timers in your app, consider whether you truly need them" e "Waking the system from an idle state incurs an energy cost" [4]. Rilevante: un loop a 10 s per la presentazione è accettabile; renderizzare solo su cambiamento riduce il lavoro inutile.

## 5. Proposta: approccio event-driven con throttle a 10 s (raccomandato)

Obiettivo: *percezione* di dati più freschi senza violare la linea guida.

1. **Mantieni 10 s come vincolo per i dati periodici** (`CarPlayRefreshPolicy.interval` + test esistente).
2. **Rendi la dashboard reattiva agli eventi**:
   - Osserva `MonitorSession` (`@Observable`: `dpf`, `hasLiveTelemetry`, `status`) in `CarPlaySceneDelegate`;
   - su un cambiamento rilevante (nuovo campione accettato con valori diversi, transizione di stato), se è passato ≥10 s dall'ultimo render → renderizza subito; altrimenti programma il render al momento consentito (coalescing con `Task.sleep(for: .seconds(10))` rimanente).
3. **Aggiornamenti immediati NON periodici** (permessi dalla guida, che vieta solo i refresh *periodici* [1]): pulsanti azione utente (Connetti/Annulla/Disconnetti, campanella, test) e alert di evento rigenerazione — già immediati oggi tramite il tracker (`CarPlaySceneDelegate.swift:389-407`). Da confermare in review con la formulazione "user-triggered updates are not periodic refreshes". [unverified: interpretazione della guida]
4. **Deduplicazione**: renderizza solo se i valori mostrati cambiano (confronta i valori formattati delle 8 tile tra un render e il successivo); nessun `updateGridButtons` a vuoto.
5. **Zero traffico OBD aggiuntivo**: la scena continua a leggere `carPlayDPFState`.
6. **Log/metriche osservabili**: log "CarPlay render" con timestamp e intervallo effettivo (per t_28709c8d: "intervallo osservato prima e dopo"); nessun dato sensibile (niente VIN, nessun valore raw non necessario).
7. **Comportamento altre piattaforme invariato**: il cambiamento tocca solo `CarPlaySceneDelegate` (+ eventuale helper puro in `Models.swift` testabile standalone).

**Rischi**
- Complessità di coalescing (MainActor; attenzione a non introdurre race con `refreshTask`).
- Rischio di interpretare male l'esenzione "non periodico" e rendere più veloce di 10 s i dati telemetrici: **mantenere comunque il throttle a 10 s per i valori ECU**; l'event-driven accorcia la *latenza* (render subito dopo un cambio), non la *frequenza massima*.
- L'osservazione di `@Observable` dal delegate richiede `withObservationTracking` o un `Task` dedicato: testare la sequenza (nessun render prima dei 10 s, uno subito dopo).
- File condiviso: `CarPlaySceneDelegate.swift` è il punto di modifica anche per i task successivi — mantenere la policy in `Models.swift` per testabilità.

**Criteri di successo**
- Intervallo osservato (log): 10 s per i dati periodici, con primo render subito dopo un cambio di stato.
- Zero render duplicati a parità di valori.
- Latenza percepita su transizione connessione/rigenerazione: < 1 s.
- Nessun cambiamento per iPhone/widget; suite standalone verde; nessuna nuova richiesta OBD dalla scena.

## 6. Alternativa sconsigliata: ridurre sotto i 10 s

Violazione diretta della guida [1] con esempio applicabile ("no real-time engine data"); rischio concreto di rifiuto in App Review e di perdita dell'entitlement Driving Task. L'eventuale "tempo reale" in auto va ottenuto con i meccanismi pensati per quello (Live Activity/ActivityKit), non con la scena Driving Task.

## 7. Percorso complementare: Live Activity (già attiva)

La Live Activity viene aggiornata a ogni campione accettato (`MonitorSession.swift:557`) e, con iOS 26+, può apparire su CarPlay anche senza essere una CarPlay app [1]. È il canale corretto per dati "at a glance" aggiornati fuori dal limite dei 10 s della scena Driving Task. Budget di aggiornamento ActivityKit (locale/push) non verificato in questa analisi: misurare prima di promettere frequenze. [unverified]

## 8. Cosa NON fare

- Nessun poll OBD dalla scena CarPlay (seconda coda ELM vietata).
- Nessun template non consentito per Driving Task [1].
- Nessun dato simulato/cached spacciato per live (già protetto da `carPlayDPFState`).
- Nessuna modifica a `DPFMonitor`/PID (analisi read-only; l'implementazione spetta a t_abfcf27c).

## 9. Verifiche eseguite

- Lettura completa dei sorgenti (CarPlaySceneDelegate, MonitorSession, DPFMonitor, Models, BLEConnection) e del commit di origine della dashboard CarPlay (`b6bde39`).
- Suite standalone: compilata ed eseguita (`swiftc ... -o /tmp/alfadpf_refresh_analysis_tests`): **268 PASS / 0 FAIL**, incluso il test `carplay: periodic dashboard refresh respects Apple's 10-second minimum`.
- Guida Apple ufficiale scaricata e citata (CarPlay Developer Guide, giugno 2026, PDF) [1].
- Build Xcode: **non eseguita** (analisi read-only; `xcode-select` punta a CommandLineTools). La verifica su device/simulatore spetta a t_28709c8d.

## Sources

[1] https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf — CarPlay Developer Guide (June 2026)
    > "Do not periodically refresh data items in the CarPlay UI more than once every 10 seconds (for example, no real- time engine data)."
[2] https://developer.apple.com/documentation/carplay/cpinformationtemplate/items — CPInformationTemplate.items (docc)
    > "The template can display 10 items maximum. If the array contains more items, the template uses only the first 10."
[3] https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html — Core Bluetooth Background Processing for iOS Apps
    > "Even if your app supports one or both of the Core Bluetooth background execution modes, it can’t run forever. At some point, the system may need to terminate your app to free up memory for the current foreground app—causing any active or pending connections to be lost, for instance."
[4] https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html — Energy Efficiency Guide for iOS Apps — Minimize Timer Use
    > "Waking the system from an idle state incurs an energy cost when the CPU and other systems are awakened from their low-power, idle states. If a timer causes the system to wake, it incurs that cost. Apps often use timers unnecessarily."
