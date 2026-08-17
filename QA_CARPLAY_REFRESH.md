# QA refresh CarPlay

## Esito

La fonte verificata è il **CarPlay Developer Guide** pubblicato da Apple:

> “Do not periodically refresh data items in the CarPlay UI more than once every
> 10 seconds (for example, no real-time engine data).”

La policy distingue quindi tra aggiornamenti periodici dei dati e transizioni
discrete:

- telemetria e tick periodico: **10,0 s minimo** tra render;
- inizio/fine rigenerazione e liveness: **2,0 s di guardia anti-rimbalzo**;
- interazioni del conducente: immediate;
- contenuto invariato: nessun nuovo render.

Il limite dei 10 secondi è una regola di design/App Review, non un vincolo tecnico
delle API. Gli eventi discreti non sono trasformati in uno stream di telemetria.

## Matrice verificata

| Caso | Policy | Evidenza automatica |
|---|---:|---|
| Scadenza periodica | 10,0 s | `CarPlayRefreshPolicy.interval` |
| Dato ECU modificato | 10,0 s minimo | `CarPlayRefreshTrigger.telemetry` e clock virtuale |
| Dato invariato per 60 s | 1 solo render iniziale | 31 richieste, 30 duplicati scartati |
| Inizio/fine rigenerazione | 2,0 s guardia | trigger `regenerationEdge` |
| Errore/liveness | 2,0 s guardia | trigger `liveness` |
| Interazione utente | immediata | trigger `interaction` |
| Collisione tra rinvii | vince la deadline più vicina | `CarPlayDeferredRefreshPolicy` |
| Ripresa dopo sospensione | conserva solo l’evento più recente | buffer `bufferingNewest(1)` |

Un evento di sicurezza con deadline a due secondi sostituisce un precedente
rinvio telemetrico a dieci secondi; un evento telemetrico successivo non può
posticipare una deadline di sicurezza già più vicina.

## Batteria e firma di rendering

La firma di deduplicazione usa lo stesso `batteryTileValue(for:)` della tile.
Pertanto rileva:

- comparsa, variazione o scadenza del SOC IBS;
- passaggio tra SOC e tensione batteria;
- indisponibilità del dato;
- variazioni della tensione IBS/ECU batteria.

`ATRV` non è mostrato come tensione batteria e rimane soltanto un segnale
indipendente per il rilevamento prudente del motore spento. Valore e timestamp
ATRV avanzano insieme; un valore cache non può essere contato più volte come
nuova evidenza.

## Campanella e test notifiche

- attiva: `bell.fill` nel colore accent;
- disattiva: `bell.slash.fill` neutra;
- il tap mostra una conferma esplicita e chiarisce che gli avvisi iPhone restano
  attivi quando CarPlay è disabilitato;
- il pannello diagnostico dichiara che i test bypassano lo stato della
  campanella.

## Consumo e richieste

Il refresh CarPlay non invia comandi ECU e non apre richieste di rete: valuta gli
snapshot già prodotti da `MonitorSession`. L’acquisizione OBD resta indipendente
dalla cadenza di presentazione CarPlay.

Le metriche restano aggregate (`requests`, `renders`, `duplicates`, `deferred`,
`failures`, `event_requests`, `effective_interval`) e non includono PID, VIN,
identificatori adattatore o posizione.

## Verifica eseguita

- Suite standalone: **406 PASS / 0 FAIL**; ripetuta anche in due processi
  concorrenti, entrambi **406 PASS / 0 FAIL**.
- Build Xcode 27 beta, target `AlfaDPF`, Debug, simulatore iPhone Air iOS 27.0:
  **BUILD SUCCEEDED**, 0 errori.
- App installata e avviata sul simulatore con PID restituito da `simctl`.
- Bundle compilato: versione **1.3.1**, build **19**.
- Localizzazioni app compilate e verificate per IT/EN/FR/ES, comprese le nuove
  conferme della campanella.

## Limiti della verifica

Simulator e clock virtuale non provano la latenza effettiva di Bluetooth, ECU,
scheduler iOS o head unit. Il comportamento della tensione/SOC IBS e la consegna
delle notifiche CarPlay vanno ancora confermati con adattatore e veicolo reali.
