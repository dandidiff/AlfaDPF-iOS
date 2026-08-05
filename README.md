# Alpha DPF Monitor iOS

Monitor DPF per Alfa Romeo / FCA diesel via adattatore ELM327 Bluetooth LE.
La versione corrente è volutamente concentrata sui dati del filtro e sulla
rilevazione affidabile della rigenerazione. La dashboard mostra anche la
tensione di alimentazione reale restituita dall’adattatore tramite `ATRV`.

Versione in sviluppo: **1.2 (build 10)**.

Il nome pubblico della versione App Store è **Alpha DPF Monitor** — non “Alfa
DPF”: “Alpha” è il marchio pubblico, scelto per restare distintivo senza usare
ALFA come brand dell’app. La compatibilità con i veicoli Alfa Romeo/FCA è
descritta nei testi, senza mai presentare l’app come affiliata. Le occorrenze
di `AlfaDPF`/`alfadpf` nel repository sono identificatori interni (scheme,
target, bundle ID, URL scheme) e non compaiono come marchio pubblico.
Informativa privacy e supporto sono pubblicati su
[dpf-monitor-support.etamburi.chatgpt.site](https://dpf-monitor-support.etamburi.chatgpt.site);
i metadati di pubblicazione sono raccolti nella cartella `AppStore`.

L’app è gratuita e ogni funzione resta disponibile senza pagamento. Un
contributo volontario ai costi annuali può essere lasciato su
[Ko-fi](https://ko-fi.com/eddytamburi); il link è disponibile anche nelle
Impostazioni e non sblocca contenuti o servizi. Per la pubblicazione va usata
la modalità Ko-fi Free con **Contributor disattivato** (0% Ko-fi sulle mance
singole); non vanno collegati membership, ricompense digitali o contenuti per
sostenitori.

## Cosa buildare

Aprire **`AlfaDPF.xcodeproj`**, selezionare lo scheme **AlfaDPF**, scegliere
l'iPhone e premere Run. Il target `DPFWidget` è una dipendenza dello scheme:
Xcode lo compila e lo incorpora automaticamente, non va avviato separatamente.

Con un Personal Team gratuito l'app e la Live Activity si possono installare
sul proprio iPhone. La firma di una vera app-template CarPlay richiede invece
un entitlement approvato da Apple; per questo il vecchio target CarPlay è stato
rimosso dalla build finale.

## Compatibilità adattatori

La connessione iOS usa esclusivamente Bluetooth Low Energy tramite CoreBluetooth.
Il profilo Konnwei KW903 BLE `FFE0`/`FFE1` è riconosciuto esplicitamente, insieme
al profilo Vgate/Vlink `FFF0`/`FFF1`/`FFF2`. I modelli Konnwei Bluetooth Classic
come KW902 non sono accessibili a una normale app iOS; il marchio Konnwei, da
solo, non implica compatibilità. Un servizio generico `FFE0` senza un nome OBD,
Konnwei o KW903 viene ignorato per evitare di collegarsi a periferiche HM-10 non
OBD.

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

## Localizzazione (1.2)

- Notifiche localizzate IT/EN: `AlertService` usa `String(localized:)` con
  carico (`%.0f%%`) e durata (`%d min.`) formattati; le traduzioni stanno in
  `App/Localizable.xcstrings`.
- Il messaggio di autorizzazione Bluetooth è localizzato in
  `App/InfoPlist.xcstrings`.
- Il widget mostra il marchio pubblico `ALPHA DPF` anche su Lock Screen.
- Le stringhe della Live Activity hanno localizzazioni `it` ed `en` esplicite:
  il bundle dell'estensione deve contenere entrambi gli `.lproj`.

## Test senza automobile

Nell'app aprire **Impostazioni → Laboratorio DPF**, quindi:

1. accettare le notifiche alla prima richiesta;
2. toccare **Esegui ciclo completo (8 secondi)**;
3. controllare il passaggio pulito → carico elevato → inizio rigenerazione →
   rigenerazione al 52% → fine;
4. verificare banner e suono sia all'inizio sia alla fine;
5. controllare contemporaneamente Live Activity e Dynamic Island.

Per la prova reale lasciare attiva la sessione Bluetooth, bloccare il telefono
e verificare anche CarPlay. Gli avvisi usano una categoria abilitata per
CarPlay; in **Impostazioni → Notifiche → Alpha DPF Monitor** devono essere consentiti
Schermata di blocco e Suoni. Con un Personal Team le notifiche urgenti non sono
firmabili, quindi anche la modalità Full immersion Guida deve consentire gli
avvisi di Alpha DPF Monitor.

Ogni scenario può anche essere selezionato singolarmente. Per provare soltanto
il canale di notifica usare **Prova solo banner e suono**. Il simulatore usa lo
stesso `RegenActivityTracker`, lo stesso `AlertService` e la stessa Live
Activity della connessione reale: non è un mock soltanto grafico.

Per QA automatica di una build Debug sono disponibili due variabili di lancio:

```text
ALFADPF_AUTORUN_TEST=1
ALFADPF_SCENARIO=regenInProgress
```

## Perché i dati motore non vengono letti

La sessione principale non invia PID generici Mode 01. Due prove ripetibili sul
veicolo reale hanno mostrato che, subito dopo `0105` o `010C`, i PID DPF Mode 22
validi su `18DA10F1` passano a `NO DATA`; tornano disponibili soltanto dopo la
sospensione del Mode 01. Poiché il prodotto serve al monitoraggio DPF, la
connessione finale conserva esclusivamente il polling DPF già validato. Il
parser Mode 01 resta nel repository e nei test, ma non interviene nella sessione
in auto.

L'app non identifica automaticamente marca o modello: un header ECU descrive
il destinatario diagnostico, non distingue in modo affidabile Stelvio, Giulia,
500X o altri veicoli FCA.

## PID DPF

- `2218E4` — saturazione %, `(A·256+B) · (1000/65535)`
- `2218DE` — temperatura scarico °C, `(A·256+B) · 0.02 − 40`
- `223915` — temperatura post-DPF °C, preferita con fallback automatico a
  `2218DE`
- `22380B` — avanzamento rigenerazione %, `(A·256+B) · (100/65535)`
- `223807` — distanza dall'ultima rigenerazione km, valore a 3 byte `· 0.1`
- `2218A4` — numero totale rigenerazioni
- `2218EC` non viene usato come stato della rigenerazione normale: le prove su
  strada confermano che è lo stato della rigenerazione forzata e rimane `0`
  anche durante una rigenerazione attiva
- `22194D` — stato pressione olio; sui diesel non viene inventato un valore in
  bar quando la diagnosi espone soltanto lo stato

`DPFMonitor` prova gli indirizzi ECU FCA conosciuti, memorizza separatamente
l'header funzionante per ogni PID e mantiene il rilevamento attivo attraverso
brevi campioni mancanti. Se `22380B` resta a zero o non risponde, una seconda
strategia riconosce la rigenerazione solo dopo aver osservato insieme scarico
caldo e calo sostenuto dell'intasamento; il raffreddamento confermato chiude il
ciclo. Il PID di stato è opzionale: valori sconosciuti o `NO DATA` non
disattivano mai il rilevatore già esistente.

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
