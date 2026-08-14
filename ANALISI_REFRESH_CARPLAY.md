# Analisi: meccanismo di refresh dei dati su CarPlay

Task: t_1e4456b3 — "Analizza il meccanismo attuale di refresh dei dati su CarPlay"
Data: 2026-08-14 · Stato: sola analisi, nessuna modifica al comportamento di produzione.
Repo: AlfaDPF-iOS (branch `analysis/carplay-refresh-t_1e4456b3`, HEAD 6a22919).

## Verdetto in una riga

L'intervallo di refresh dell'interfaccia CarPlay è **realmente 10 secondi**, ed è imposto
da una policy condivisa (`CarPlayRefreshPolicy.interval = .seconds(10)`) verificata da un
test. Non è un valore scelto a caso: Apple lo richiede come tetto massimo per il refresh
periodico dei data item in un Driving Task app ("Do not periodically refresh data items in
the CarPlay UI more than once every 10 seconds (for example, no real-time engine data)")[1].
Ridurre il polling periodico sotto i 10 s violerebbe le linee guida; l'unica strada
compatibile è un approccio **event-driven / change-driven**, descritto in fondo.

---

## 1. Componenti che aggiornano i dati mostrati su CarPlay

Il flusso è una catena a tre livelli con due anelli di polling separati:

```
ECU/Adattatore OBD
   └─ BLEConnection / OBDConnection (trasporto)
        └─ ELM327 (comandi Mode 22) ── DPFMonitor (actor, poll 2 s)
             └─ MonitorSession.shared (coordinator @MainActor, poll 1 s su snapshot)
                  └─ CarPlaySceneDelegate (CarPlay scene, poll 10 s)
                       └─ CPGridTemplate.updateGridButtons / updateTitle / items
```

1. **CarPlaySceneDelegate** (Sources/CarPlaySceneDelegate.swift)
   - `startRefreshing()` (righe 355-367): loop `Task` che chiama `refreshDashboard()` e poi
     `Task.sleep(for: CarPlayRefreshPolicy.interval)` — l'intervallo è il polso della UI.
   - `refreshDashboard()` (righe 378-408): aggiorna titolo, griglia (8 tile), bar buttons e,
     se presente, i dettagli `CPInformationTemplate.items`.
   - `makeGridButtons()` (righe 417-495): 8 `CPGridButton` con valore formattato per ogni
     metrica (DPF %, Regen, km, temperatura, avanzamento, conteggi, olio, batteria).
   - Il refresh periodico è l'unico meccanismo: non ci sono callback/observer che spingono
     aggiornamenti UI. Anche i bar buttons vengono ricreati a ogni tick.

2. **MonitorSession.shared** (Sources/MonitorSession.swift)
   - Unico coordinator condiviso tra iPhone e CarPlay (riga 13).
   - `pollTask` (righe 543-573): ogni 1 s legge `monitor.snapshot`, accetta nuovi campioni
     (`acceptLive`) e aggiorna la Live Activity.
   - `carPlayDPFState` (righe 95-102): applica `CarPlayTelemetryPolicy.displayState` —
     protegge la UI CarPlay da stati "Test Lab" e distingue live vs cache.

3. **DPFMonitor** (Sources/DPFMonitor.swift)
   - Actor che possiede l'unica decodifica raw→unità fisiche.
   - `start(interval: .seconds(2))` (righe 80-88): poll della ECU ogni 2 s.
   - `pollOnce()` (righe 97-260): prima i PID critici (regen progress, clogging %, temp),
     poi i secondari a rotazione (ogni 5 cicli: distanza, conteggi, olio, tensione).
   - Pubblica `snapshot` con `pollSequence`, `freshPIDs`, `failedPIDs`,
     `lastSuccessfulCoreReadAt` (8 s di finestra di freschezza, riga 22).

## 2. Verifica dell'intervallo di 10 secondi

Confermato su tre livelli:

- **Codice**: `Sources/Models.swift` righe 239-244 —
  `enum CarPlayRefreshPolicy { static let interval: Duration = .seconds(10) }`,
  consumato da `CarPlaySceneDelegate.startRefreshing()` (CarPlaySceneDelegate.swift:361).
- **Test**: `Tests/main.swift` righe 192-193 — `expect(CarPlayRefreshPolicy.interval >=
  .seconds(10), "carplay: periodic dashboard refresh respects Apple's 10-second minimum")`.
  Suite eseguita: **268 PASS / 0 FAIL** (comando nel header di Tests/main.swift).
- **Evidenza Apple**: CarPlay App Programming Guide (giugno 2026), estratto verbatim nel
  PDF scaricato: "Do not periodically refresh data items in the CarPlay UI more than once
  every 10 seconds (for example, no real-time engine data)."[1]

Nota: i **dati** (ECU) sono già campionati a 2 s; è la **presentazione CarPlay** che
ricampiona a 10 s. Quindi la latenza percepita peggiore è di circa 10 s + tempo di poll.

## 3. Sorgente dei dati e tipo di polling

- **Sorgente**: letture Mode 22 della centralina (FCA/Alfa) via ELM327 su BLE (Vgate/Konnwei)
  o Wi-Fi TCP. Header fisici 18DA10F1/18DA18F1/18DA01F1/7E0 (DPFMonitor.swift:268).
- **Polling**: due anelli indipendenti e asincroni:
  - DPFMonitor → ECU: ogni 2 s (soggetto al tempo di risposta dell'adapter).
  - CarPlay UI: ogni 10 s, ricampiona l'ultimo snapshot accettato dal MonitorSession.
- **Eventi disponibili oggi**: solo `RegenEvent` (start/finish rigenerazione) prodotto da
  `RegenActivityTracker` dentro DPFMonitor (DPFMonitor.swift:149-154) e osservato in
  CarPlay dal `CarPlayRegenerationAlertTracker` (CarPlaySceneDelegate.swift:393-396) per le
  **notifiche** — ma la UI del dashboard non usa eventi, ricampiona comunque.
- **API CarPlay disponibili per aggiornamento**: `updateGridButtons(_:)`[5] e
  `CPInformationTemplate.items`[2] (max 10 item, riga 35 del ledger); entrambi accettano
  nuovi array in qualsiasi momento — il vincolo è di policy, non tecnico.

## 4. Limiti imposti da CarPlay/iOS

- **Tetto 10 s**: refresh periodico dei data item non più spesso di ogni 10 s; l'esempio
  esplicito è "no real-time engine data"[1] — cioè esattamente il nostro caso d'uso.
- **POI template**: 60 s per i punti di interesse[1] (non rilevante qui, ma conferma la
  logica di throttling per classe di template).
- **CPInformationTemplate**: massimo 10 item[2] (già rispettato via
  `boundedInformationItems`, CarPlaySceneDelegate.swift:708-711).
- **Background BLE**: con `UIBackgroundModes = bluetooth-central` (App/Info.plist) l'app può
  elaborare eventi CoreBluetooth in background, ma "the system may need to terminate your
  app to free up memory"[3] — niente esecuzione illimitata.
- **Timers**: svegliare il sistema a intervalli ha un costo energetico; Apple consiglia di
  ridurne l'uso[4].

## 5. Comportamento in background

- Quando CarPlay è attivo, la scena CarPlay è foreground per l'utente: il loop a 10 s gira
  normalmente.
- Quando l'iPhone è in tasca senza CarPlay, la scena CarPlay non esiste (nessun refresh UI);
  resta attivo solo il poll ECU a 2 s (sostenuto da bluetooth-central) per mantenere dati e
  notifiche. L'app può comunque essere terminata dal sistema in qualsiasi momento[3]; al
  rientro CarPlay mostra lo stato persistito finché non arriva un campione fresco
  (`CarPlayTelemetryPolicy.displayState`, MonitorSession.swift:95-102).

## 6. Impatto previsto su batteria, rete e rate limit

- **Batteria**: il costo dominante è il poll ECU a 2 s (radio BLE attiva, CPU per la
  decodifica), non il refresh UI a 10 s. Il refresh UI a 10 s ricrea 8 tile con artwork
  disegnati via `UIGraphicsImageRenderer` (CarPlaySceneDelegate.swift:78-112) — lavoro
  inutile se i valori non sono cambiati (mancanza di deduplicazione).
- **Rete**: traffico locale BLE/TCP verso l'adapter; nessun rate limit di rete esterno.
- **Rate limit**: l'unico vincolo è quello Apple (10 s); non esistono limiti del provider.

## 7. Proposta: evento-driven, non intervallo più breve

**Non ridurre l'intervallo periodico sotto 10 s.** È il tetto Apple[1]; un poll a 3-5 s
sarebbe tecnicamente banale ma in violazione delle linee guida e a rischio review App Store.

Le opzioni compatibili, in ordine di preferenza:

1. **Refresh change-driven (raccomandato)**: mantenere il tick a 10 s come *deadline*,
   ma rendere il loop *event-driven*: MonitorSession pubblica un `AsyncStream`/callback
   quando un nuovo snapshot accettato cambia i valori mostrati; CarPlay aggiorna la griglia
   **solo quando i dati cambiano** (entro il tetto dei 10 s tra due update). Risultato:
   latenza percepita ≈ latenza ECU (2 s) senza violare Apple, perché non è più un refresh
   *periodico*.
   - Deduplicazione: confrontare i valori formattati/tile rispetto all'ultima emissione;
     nessun update se invariati (risparmia rendering artwork + CPU).
   - Gestione errori: se il trasporto è giù, non forzare update — lo stato "Salvati"
     (cache) resta; il tick periodic mantiene la liveness del titolo.
   - Backoff: nessuna rete esterna; per l'ECU già gestito da DPFMonitor (pidRetryAfter 30 s).
2. **Aggiornamento immediato sugli eventi**: usare i `RegenEvent` esistenti (start/finish)
   per un refresh *immediato* della griglia (cambio colore stato Regen) — non periodico,
   quindi ammissibile; è già il pattern usato per le notifiche.
3. **Configurabilità dell'intervallo**: esporre `CarPlayRefreshPolicy.interval` a un valore
   utente *solo verso l'alto* (es. 10/15/30 s) per chi preferisce meno animazione; mai sotto
   10 s.

### Rischi

- **Interpretazione Apple**: un refresh change-driven molto frequente (es. ogni 2 s in
  rigenerazione attiva, dove i valori cambiano davvero) potrebbe essere letto come
  "real-time engine data". Mitigazione: mantenere un intervallo minimo tra update UI
  (es. ≥2 s, preferibilmente ≥5 s) e verificare con un test che nessun percorso periodico
  scenda sotto i 10 s. Il linguaggio della guida vieta il *periodico* oltre 10 s; l'update
  su evento è una lettura difendibile ma va provata su strada.
- **Regressione su altre piattaforme**: il cambiamento deve toccare solo la scena CarPlay;
  MonitorSession/DPFMonitor restano condivisi. Il test su `CarPlayRefreshPolicy` già
  protegge il tetto.
- **Log sensibili**: log e metriche non devono contenere VIN, coordinate o identificativi;
  solo intervalli, sequence, conteggi skip/fail.

### Criteri di successo

1. `CarPlayRefreshPolicy.interval >= 10 s` resta invariato (test esistente verde).
2. In rigenerazione attiva, un cambio di avanzamento appare sul display in ≤ 2-3 s
   (misurabile con timestamp "Ultimo aggiornamento" già presente nei dettagli).
3. Numero di `updateGridButtons` reali ≤ numero di tick: i tick con valori invariati non
   ri-renderizzano (conteggio loggato, senza dati sensibili).
4. Nessuna modifica al comportamento iPhone/Live Activity (comportamento altre piattaforme
   invariato).
5. Suite standalone verde: 268 PASS / 0 FAIL.

---

## Fonti

1. https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf — CarPlay Developer Guide (June 2026)
2. https://developer.apple.com/documentation/carplay/cpinformationtemplate/items — CPInformationTemplate.items (docc)
3. https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html — Core Bluetooth Background Processing for iOS Apps
4. https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html — Energy Efficiency Guide for iOS Apps — Minimize Timer Use
5. https://developer.apple.com/documentation/carplay/cpgridtemplate/updategridbuttons(_:) — CPGridTemplate.updateGridButtons(_:) (docc)

## Sources

[1] https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf — CarPlay Developer Guide (June 2026)
[2] https://developer.apple.com/documentation/carplay/cpinformationtemplate/items — CPInformationTemplate.items (docc)
[3] https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html — Core Bluetooth Background Processing for iOS Apps
[4] https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html — Energy Efficiency Guide for iOS Apps — Minimize Timer Use
[5] <https://developer.apple.com/documentation/carplay/cpgridtemplate/updategridbuttons(_:)> — CPGridTemplate.updateGridButtons(_:) (docc)
