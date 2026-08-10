# Alpha DPF Monitor 1.3 — scheda di pubblicazione

## Identità

- Nome pubblico: `Alpha DPF Monitor` (la grafia pubblica è sempre **Alpha**;
  “Alfa” resta solo negli identificatori interni del progetto)
- Bundle ID: `com.tamburi.AlfaDPF`
- Versione: `1.3`
- Build: `18` (`CURRENT_PROJECT_VERSION` aggiornato nel progetto; il target
  `DPFWidget` usa la stessa versione/build)
- SKU suggerito: `dpf-monitor-ios-001`
- Lingue app: Italiano, Inglese, Francese e Spagnolo
- Metadati App Store disponibili: Italiano e Inglese (Regno Unito)
- Categoria primaria: Utility
- Categoria secondaria: nessuna
- Copyright: `2026 Eddy Tamburi`
- Prezzo: **Gratis** — nessun prezzo di listino, acquisto in-app o abbonamento.

## Novità della 1.3

- Connessione ELM327 sia Bluetooth LE sia Wi‑Fi TCP, con tolleranza migliorata
  per i clone v1.5 e diagnostica degli header CAN.
- Selezione lingua in-app con catalogo Italiano, Inglese, Francese e Spagnolo.
- Dashboard e CarPlay allineati sulle stesse soglie DPF, accesso prioritario
  alla connessione e conferma di sicurezza durante una rigenerazione.
- Stima prudente del tempo residuo quando il PID di avanzamento offre campioni
  sufficienti; lo storico aggiunge statistiche e selezione interattiva.
- Gestione tri-state degli edge di rigenerazione: un PID temporaneamente
  sconosciuto non chiude più falsamente il ciclo nello storico.

## URL

- Supporto: https://dpf-monitor-support.etamburi.chatgpt.site/support
- Privacy: https://dpf-monitor-support.etamburi.chatgpt.site/privacy
- Marketing URL: https://dpf-monitor-support.etamburi.chatgpt.site

## Dichiarazioni

- Crittografia soggetta a export compliance: no (`ITSAppUsesNonExemptEncryption = false`)
- Account/login: nessuno
- Acquisti in-app e abbonamenti: nessuno
- Pubblicità o analytics: nessuno
- App Privacy: “Data Not Collected”
- Content Rights: l’app non distribuisce contenuti di terzi; i marchi sono
  citati solo per descrivere la compatibilità e accompagnati dal disclaimer.
- Age Rating: rispondere “No/None” a contenuti, social, UGC, gioco, gambling,
  acquisti e accesso web senza restrizioni; non selezionare Kids né override.

## Checklist pre-invio

### QA su iPhone

- [ ] Con Bluetooth disattivato, la connessione termina con un messaggio utile
      e lo schermo torna a poter andare in standby.
- [ ] Senza adattatore nelle vicinanze, dopo circa 30 secondi compare il timeout
      e il pulsante permette di riprovare.
- [ ] Con Vgate iCar Pro BLE reale, connessione, inizializzazione e telemetria
      ripartono correttamente dopo una disconnessione.
- [ ] Toccando Live Activity o Dynamic Island con sessione ferma/in errore,
      l’app si apre e avvia la riconnessione.
- [ ] Dopo un’interruzione della telemetria l’ultimo dato resta visibile come
      storico e il blocco automatico dello schermo viene ripristinato.

### App Store Connect

- [ ] Compilare i campi `AppStore/it-IT/` e `AppStore/en-GB/` su App Store
      Connect (nome, sottotitolo, testo promozionale, descrizione, novità della
      versione, parole chiave ≤ 100 byte, URL supporto/privacy).
- [ ] Caricare gli screenshot reali: set `it-IT/` (5 presenti) + Live
      Activity/Dynamic Island e BLE da catturare; set `en-GB/` da catturare.
- [ ] Verificare `App/Localizable.xcstrings` e `App/InfoPlist.xcstrings`
      (notifiche, errori, autorizzazione Bluetooth e branding IT/EN/FR/ES).
- [ ] Build 18 con versione 1.3: archiviare con `AppStore/ExportOptions.plist`,
      caricare con `AppStore/UploadOptions.plist`.
- [ ] Recensione: usare `AppStore/review-notes-en.txt` aggiornato.

## Da confermare come titolare dell’account

- Stato “trader” DSA per la distribuzione nell’Unione europea.
- Accettazione di eventuali accordi aggiornati e verifica dei dati fiscali/bancari
  se richiesti da App Store Connect.
- Paesi e regioni di distribuzione definitivi.

Queste tre scelte sono attestazioni legali o commerciali e non vanno dedotte
automaticamente. Nessuna modifica va applicata ad App Store Connect senza
l’approvazione del titolare dell’account.
