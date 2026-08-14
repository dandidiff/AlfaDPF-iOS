# QA refresh CarPlay

## Esito

Il refresh periodico resta a **10,0 s**, come richiesto da Apple per le app
Driving Task. Il nuovo percorso guidato dagli eventi rende un contenuto
modificato al primo slot ammesso, **2,0 s** dopo il render precedente. Se il
contenuto non cambia, non viene ridisegnato.

Queste misure sono state osservate con un clock virtuale deterministico nella
suite automatica; non sono misure stradali su un head unit CarPlay reale.

## Prima e dopo

| Caso | Prima | Dopo | Evidenza |
|---|---:|---:|---|
| Scadenza periodica | 10,0 s | 10,0 s | `CarPlayRefreshPolicy.interval` e test di conformità |
| Dato ECU modificato | fino a 10,0 s | 2,0 s minimo/target | test gate a `t=2,0 s` |
| Dato invariato per 60 s | fino a 6 render periodici | 1 render iniziale | 31 richieste di valutazione, 1 render, 30 duplicati scartati |
| Errore rete/liveness | fino a 10,0 s | 2,0 s | transizione `running -> failed` nel test del gate |
| Ripresa dopo sospensione | non change-driven | ultimo stato al primo turno disponibile | buffer `bufferingNewest(1)` e test backlog |

## Copertura aggiunta

Sono stati aggiunti 12 test automatici in `Tests/main.swift` per verificare:

- deduplicazione durante un minuto di eventi ECU invariati;
- conservazione del valore più recente durante burst e rinvii;
- limite minimo di 2 s per gli aggiornamenti guidati da eventi;
- propagazione dello stato di errore/liveness e deduplicazione del tick
  periodico successivo;
- ripresa dopo sospensione senza replay del backlog;
- reset corretto dopo disconnessione/riconnessione della scena;
- buffer newest-one per il consumer sospeso;
- assenza di nuove richieste ECU/rete nel corpo del refresh UI;
- cancellazione dei task periodico, eventi e rinvio durante il teardown.

## Consumo e richieste

Il refresh CarPlay non invia comandi ECU e non apre richieste di rete: valuta
gli snapshot già accettati dal poller esistente. Nel caso sintetico peggiore
con snapshot accettato ogni 2 s, vengono eseguite 30 valutazioni evento al
minuto; il gate limita i render guidati da evento a non più di uno ogni 2 s.
Nel caso invariato verificato, 31 valutazioni producono un solo render.

Le metriche restano aggregate (`requests`, `renders`, `duplicates`,
`deferred`, `failures`, `event_requests`, `effective_interval`) e non includono
PID, VIN, identificatori adattatore o posizione.

## Verifica eseguita

- Suite standalone: **288 PASS / 0 FAIL**.
- Due esecuzioni concorrenti indipendenti: **288/0** e **288/0**.
- Build reale Xcode 27 beta, target `AlfaDPF`, Debug, iOS Simulator 27.0:
  **BUILD SUCCEEDED**.
- App installata e avviata su iPhone Air iOS 27.0: onboarding renderizzato,
  nessun crash o errore visibile.
- Display CarPlay del simulatore rilevato a 720x480 e acceso, ma la UI host
  CarPlay è rimasta nera: non è stato possibile ottenere una sessione
  `CPTemplateApplicationScene` interattiva in questa esecuzione headless.

## Limiti di iOS/CarPlay

- Il limite di 2 s vale solo mentre il processo riceve tempo CPU. iOS può
  sospendere i task; durante la sospensione non esiste una garanzia di latenza.
  Alla ripresa viene conservato solo l'evento più recente, evitando raffiche.
- La scadenza periodica sotto i 10 s non viene usata: il vincolo Apple resta
  rispettato.
- Simulator e clock virtuale non provano la latenza effettiva di Bluetooth,
  ECU, scheduler iOS o head unit. Serve una prova A/B su auto/head unit reale
  con i log aggregati per confermare il valore end-to-end.
