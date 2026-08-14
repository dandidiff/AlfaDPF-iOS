# Implementazione: cache protocollo OBD (fast path di riconnessione)

Task: t_8a1de45c — Riduci il tempo di connessione OBD senza regressioni
Branch: `feature/obd-protocol-cache-t_8a1de45c`
Commit: `4184f505f95261332d4b5d7487d2fa65286a2506`
Baseline di riferimento: analisi t_9a200f30 (attachment `connection_baselines.json`)

## Cosa è stato implementato

La ricerca automatica del protocollo dopo `ATSP0` era il collo di bottiglia
del warm reconnect (5,564 s su 7,569 s — 73,5% sul log reale dell'adattatore
lento). Il protocollo negoziato non veniva persistito, quindi ogni
riconnessione rifaceva la ricerca completa.

### Fast path del protocollo cached, con fallback sicuro

- `OBDProtocolCache` (Models.swift): persiste il protocollo numerico (1–9)
  normalizzato da `ATDPN` per `cacheIdentifier()` (per-adapter, UserDefaults).
  La cache è scritta solo dopo un probe accettato; un semplice `OK` di `ATSPx`
  non viene mai promosso a prova diagnostica.
- `ELM327.initializeSession(cachedProtocol:probeHeader:)` (ELM327.swift):
  - mantenuti `ATZ`, `ATE0`, `ATL0`, `ATS0`, `ATH1`, `ATAT1` invariati;
  - al posto di `ATSP0`, prova `ATSP<cachedProtocol>`;
  - probe DPF obbligatorio `22380B`; il fast path resta solo con risposta
    ECU-proven: positiva `62…` o negativa `7F22…` (`isECUProvenDiagnosticProbe`);
  - su timeout, `?`, `ERROR`, `UNABLE TO CONNECT` o `NO DATA`: fallback **una
    sola volta** ad `ATSP0` + probe con la semantica di accettazione originale
    (`NO DATA` ammesso come prova del command path);
  - `ATDPN` finale: `parseProtocol` normalizza `A7`→7, `7`→7, `A6`→6, con
    echo/spazi; rifiuta `0`/`A0` (automatico) e descrizioni.
- Il probe del fast path usa `lastGoodHeader` del profilo ECU ricordato
  (`DPFECUProfileStore`), così il probe può essere confermato anche su veicoli
  dove il PID DPF vive su un ECU non default (es. `18DA01F1`).
- `MonitorSession.boot`: carica la cache, la passa al bootstrap, persiste il
  protocollo rinegoziato dopo il successo, e logga i tempi di fase.

### Logging dei tempi

- `init: protocol path cached(7)|fallback|auto after %.2f s` (ELM327).
- `connection: adapter initialized in %.2f s (protocol N)` (MonitorSession),
  in aggiunta ai log già esistenti `transport ready` e `session running`.

### Non fatto (deliberatamente)

- Nessun timeout ridotto: i timeout globali restano invariati (ATZ 5 s, probe
  12 s, AT 2 s) per non danneggiare cloni lenti o wake-up ECU.
- Nessuna parallelizzazione di comandi AT/PID (line engine seriale per natura).
- `ATZ` mantenuto: una riconnessione può trovare stato/header residui.
- Nessun `ATSPx` forzato senza probe di conferma.

## Misurazione comparabile (benchmark deterministico)

Il benchmark in `Tests/main.swift` modella l'adattatore lento reale con i costi
di fase misurati nel log storico (ATZ 0,962 s, boot 5×0,036 s, ricerca
automatica 5,564 s, ATDPN 0,031 s) e misura il tempo a parete di entrambi i
percorsi sullo stesso modello:

```
TIMING: ATSP0 init 7.27 s vs cached ATSP7 init 2.09 s — saving 5.18 s (71%)
```

- Il percorso cached elimina la ricerca automatica (~5,6 s) sostituendola con
  `ATSP7` + probe su protocollo forzato (~0,3 s).
- La proiezione (71%) è coerente con il potenziale stimato nell'analisi
  (~5,4 s / 71,9%).
- È una simulazione deterministica: la verifica definitiva su hardware
  richiede il benchmark controllato del criterio di accettazione (10 cold +
  10 warm connect, mediana e p95, stesso iPhone/auto/adattatore).

## Test

- Suite standalone: **308 PASS / 0 FAIL** (baseline 268 + 40 nuovi).
- Copertura nuova: parsing `ATDPN`, cache per-adapter e valori non validi,
  fast path ECU-proven senza `ATSP0`, `7F22` negativo, probe su header
  ricordato, fallback su `NO DATA` (un solo probe extra dopo `ATSP0`), fallback
  su `ATSPx` rifiutato, baseline senza cache invariata, errori terminali
  (probe rifiutata o silenziosa su fast path E fallback), benchmark tempi.
- Build iOS (simulatore, Xcode 27.0 beta): **BUILD SUCCEEDED** (AlfaDPF +
  DPFWidget).

## File modificati

- `Sources/ELM327.swift` — fast path + fallback, `parseProtocol`,
  `isECUProvenDiagnosticProbe`, `logOptionalSP0`, log del path.
- `Sources/Models.swift` — `OBDProtocolCache`.
- `Sources/MonitorSession.swift` — wiring cache + probe header + log tempi.
- `Tests/main.swift` — 40 nuovi test + benchmark.

## Rischi residui (invariati rispetto all'analisi)

- Adapter spostato su un'altra auto: il probe non conferma → fallback `ATSP0`
  nello stesso tentativo.
- Clone che accetta `ATSPx` senza applicarlo: il probe (non l'`OK`) decide.
- `NO DATA` ambiguo sul fast path: trattato come fallback (più conservativo
  del bootstrap corrente, che lo accetta sempre).
