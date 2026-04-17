# AlfaDPF-iOS

Port target of the Android app `it.gmg.android.alfadpf`. Phone + CarPlay
companion for live DPF monitoring on Alfa Romeo / FCA diesels via a Wi-Fi
ELM327-style adapter.

## What actually works today vs later

**Works on day one, on any OBD-II car:**

- Connects to a Wi-Fi ELM327 at `192.168.0.10:35000` (the default for most
  cheap dongles — change `OBDConnection.Endpoint.defaultELM` if yours differs).
- Runs the ELM init sequence.
- Polls standard **Mode 01** PIDs and shows live RPM, speed, coolant temp,
  intake temp, and engine load. These are defined by SAE J1979 and every
  OBD-II vehicle supports them — so you can verify the whole stack works
  against your car before touching anything Alfa-specific.

**DPF monitoring — wired to real Alfa PIDs:**

`DPFMonitor` now polls community-verified Mode 22 PIDs confirmed working on
Alfa Romeo Giulia 2.2D and typical FCA diesels (same ECU family used by
Fiat / Alfa / Chrysler). Live signals:

- **2218E4** — DPF clogging %, `(A·256+B) · 0.01526`
- **2218DE** — Exhaust temp °C, `(A·256+B) · 0.02 − 40`
- **22380B** — Regen progress %, `(A·256+B) · 0.01526` (0 = idle)
- **223807** — Distance since last regen km, `A·256+B`
- **2218A4** — Total regen count, `A·256+B`

Sources: [alfaowner.com PID list](https://www.alfaowner.com/threads/list-of-pids.305552/),
[Giulietta DPF PIDs](https://torque-bhp.com/community/main-forum/alfa-romeo-giulietta-dpf-pids/),
[Kapron-AP DPF diagnostics](https://www.kapron-ap.com/dpf/dpf-diagnostics-fiat-en.html).

If a tile stays dashed on your car, your ECU variant uses different PIDs —
the values live in `Sources/Models.swift` and are easy to swap.

**Not yet:**

- **CarPlay scene.** The code compiles against the Driving Task template
  set, but Apple has to approve the `com.apple.developer.carplay-driving-task`
  entitlement via request form before it'll sign. Until then, use the phone
  app (mounted in the car works fine).

## Running it on your car today

1. Open `AlfaDPF.xcodeproj` in Xcode.
2. In the `AlfaDPF` target → Signing & Capabilities, set your Apple team
   (personal team is fine) and change the bundle ID from
   `com.example.AlfaDPF` to something unique to you.
3. Plug in your iPhone, pick it as the destination, hit Run.
4. On the phone, trust the developer cert under Settings → General → VPN &
   Device Management.
5. Power the OBD dongle (turn on the car's ignition, don't need the engine
   running yet). Join its Wi-Fi network on the iPhone.
6. Launch the app, tap **Connect to OBD**. First run asks for Local Network
   + Notifications permission — approve both.
7. Once status goes green, RPM / speed / coolant / intake / load should
   populate within a second or two. The DPF panel will stay dashed until
   real PIDs are wired.

The app keeps the screen awake while connected and asks iOS to keep Wi-Fi
alive, so it'll behave correctly mounted on a dash cradle.

## Module map

| File | Role |
|---|---|
| [AlfaDPFApp.swift](Sources/AlfaDPFApp.swift) | App entry + SwiftUI phone UI |
| [MonitorSession.swift](Sources/MonitorSession.swift) | Phone-side coordinator: connect, ELM init, poll, lifecycle |
| [CarPlaySceneDelegate.swift](Sources/CarPlaySceneDelegate.swift) | CarPlay lifecycle (gated behind Apple entitlement) |
| [OBDConnection.swift](Sources/OBDConnection.swift) | `NWConnection` TCP client w/ reconnect + read timeout |
| [ELM327.swift](Sources/ELM327.swift) | AT init, Mode 22 request framing, response parsing |
| [Mode01.swift](Sources/Mode01.swift) | Standard J1979 PID reader + decoders |
| [DPFMonitor.swift](Sources/DPFMonitor.swift) | Regen state machine + notifications |
| [AlertService.swift](Sources/AlertService.swift) | Local notifications + ducked audio alert |
| [Models.swift](Sources/Models.swift) | `DPFState`, `RegenEvent`, **placeholder PIDs** |

## Known issues / open work

- **PIDs are generic FCA, not model-specific.** Works on Giulia 2.2D and
  most JTDm diesels; older Giulietta / MiTo / 159 may need adjustments.
- **Reconnect backoff** is a flat 2 s with no jitter or cap.
- **No unit tests yet.** `ELM327.parseMode22Response`, `Mode01.parseMode01`,
  and `DPFMonitor.emitEvents` are all pure and very testable — adding an
  XCTest target is the next obvious step.
- **Strict concurrency is off** (`SWIFT_STRICT_CONCURRENCY` unset, Swift 5
  mode). Worth turning to `targeted` once the project is humming. Would
  have caught earlier bugs at compile time.
- **CarPlay entitlement** is not wired into `CODE_SIGN_ENTITLEMENTS` so the
  default build signs with a personal team. Wire `App/AlfaDPF.entitlements`
  in once Apple approves the request.

## Not in this sketch

- DTC database port from `dtc.db` / `dtcsae.db` (straight SQLite copy).
- IAP / StoreKit migration from Play Billing.
- Settings persistence, connection profile editor, history graphs.
