# AlfaDPF iOS

Monitor DPF per Alfa Romeo / FCA diesel via adattatore ELM327 Bluetooth LE o
Wi-Fi. La versione corrente è volutamente concentrata sui dati del filtro e
sulla rilevazione affidabile della rigenerazione.

Il nome pubblico della versione App Store è **DPF Monitor**. Informativa privacy
e supporto sono pubblicati su
[dpf-monitor-support.etamburi.chatgpt.site](https://dpf-monitor-support.etamburi.chatgpt.site);
i metadati di pubblicazione sono raccolti nella cartella `AppStore`.

## Cosa buildare

Aprire **`AlfaDPF.xcodeproj`**, selezionare lo scheme **AlfaDPF**, scegliere
l'iPhone e premere Run. Il target `DPFWidget` è una dipendenza dello scheme:
Xcode lo compila e lo incorpora automaticamente, non va avviato separatamente.

Con un Personal Team gratuito l'app e la Live Activity si possono installare
sul proprio iPhone. La firma di una vera app-template CarPlay richiede invece
un entitlement approvato da Apple; per questo il vecchio target CarPlay è stato
rimosso dalla build finale.

## Schermata auto e Live Activity

Quando arrivano i primi dati DPF, l'app avvia una Live Activity con:

- carico DPF;
- stato e avanzamento rigenerazione; durante una rigenerazione la scheda
  diventa arancione e mostra esplicitamente **RIGENERAZIONE ATTIVA** anche se
  il PID di avanzamento non è disponibile;
- temperatura di scarico;
- presentazione compatta per Dynamic Island e CarPlay.

Le Live Activity possono apparire automaticamente su CarPlay senza
l'entitlement di una app CarPlay completa. Riferimenti Apple:
[CarPlay](https://developer.apple.com/carplay/),
[ActivityKit](https://developer.apple.com/documentation/activitykit),
[Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

## Test senza automobile

Nell'app toccare l'icona con le due provette, quindi:

1. accettare le notifiche alla prima richiesta;
2. toccare **Esegui ciclo completo (8 secondi)**;
3. controllare il passaggio pulito → carico elevato → inizio rigenerazione →
   rigenerazione al 52% → fine;
4. verificare banner e suono sia all'inizio sia alla fine;
5. controllare contemporaneamente Live Activity e Dynamic Island.

Per la prova reale lasciare attiva la sessione Bluetooth, bloccare il telefono
e verificare anche CarPlay. Gli avvisi usano una categoria abilitata per
CarPlay; in **Impostazioni → Notifiche → AlfaDPF** devono essere consentiti
Schermata di blocco e Suoni. Con un Personal Team le notifiche urgenti non sono
firmabili, quindi anche la modalità Full immersion Guida deve consentire gli
avvisi di AlfaDPF.

Ogni scenario può anche essere selezionato singolarmente. Per provare soltanto
il canale di notifica usare **Prova solo banner e suono**. Il simulatore usa lo
stesso `RegenActivityTracker`, lo stesso `AlertService` e la stessa Live
Activity della connessione reale: non è un mock soltanto grafico.

Per QA automatica di una build Debug sono disponibili due variabili di lancio:

```text
ALFADPF_AUTORUN_TEST=1
ALFADPF_SCENARIO=regenInProgress
```

## Perché i dati motore non vengono più letti

La sessione principale non invia più i PID generici Mode 01. Sul setup reale,
alternare Mode 01 e i PID Alfa Mode 22 poteva cambiare header/contesto ECU e
far sparire a turno i dati motore o quelli DPF. Poiché il prodotto serve alla
rigenerazione, la connessione finale preserva esclusivamente il polling DPF già
validato. Il parser Mode 01 resta nel repository e nei test, ma non interviene
nella sessione in auto.

## PID DPF

- `2218E4` — saturazione %, `(A·256+B) · 0.01526`
- `2218DE` — temperatura scarico °C, `(A·256+B) · 0.02 − 40`
- `22380B` — avanzamento rigenerazione %, `(A·256+B) · (100/65535)`
- `223807` — distanza dall'ultima rigenerazione km, valore a 3 byte `· 0.1`
- `2218A4` — numero totale rigenerazioni

`DPFMonitor` prova gli indirizzi ECU FCA conosciuti, memorizza separatamente
l'header funzionante per ogni PID e mantiene il rilevamento attivo attraverso
brevi campioni mancanti. Se `22380B` resta a zero o non risponde, una seconda
strategia riconosce la rigenerazione solo dopo aver osservato insieme scarico
caldo e calo sostenuto dell'intasamento; il raffreddamento confermato chiude il
ciclo.

## Test automatici

Il runner standalone copre parser CAN 11/29 bit, formule, tracker di
rigenerazione, scenari simulati, BLE, timeout, riconnessione e atomicità dei
comandi ELM:

```sh
swiftc Sources/Models.swift Sources/OBDLog.swift Sources/OBDTransport.swift \
  Sources/OBDConnection.swift Sources/BLEConnection.swift Sources/ELM327.swift \
  Sources/Mode01.swift Tests/main.swift -o /tmp/alfadpf_tests
/tmp/alfadpf_tests
```

## File principali

| File | Ruolo |
|---|---|
| `Sources/AlfaDPFApp.swift` | UI DPF, diagnostica e laboratorio test |
| `Sources/MonitorSession.swift` | connessione, polling DPF, simulazioni |
| `Sources/DPFMonitor.swift` | PID Mode 22 e transizioni rigenerazione |
| `Sources/AlertService.swift` | notifiche locali con suono |
| `Sources/DPFLiveActivityController.swift` | avvio e aggiornamento Live Activity |
| `DPFWidget/DPFWidgetBundle.swift` | Lock Screen, Dynamic Island e CarPlay |
| `Sources/Models.swift` | stato DPF, tracker, scenari e formule PID |
