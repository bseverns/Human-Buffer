
# Face → Slug (Privacy-First) — Teaching Build

A Processing + Arduino sketch that doubles as a workshop kit on community consent and computer vision. This README is the facilitator’s map: it folds technical steps together with prompts from the [Ethics one-pager](ETHICS.md), the [Privacy policy sketch](PRIVACY.md), and the [Assumption Ledger](docs/assumption-ledger.md).

## Why this demo exists

- **Surface the politics of surveillance.** The build lets folks poke at face detection without ever touching recognition, tying back to the [Ethics notes](ETHICS.md) and the [lineage timeline](docs/lineage.md).
- **Practice consent-as-default.** Every capture is opt-in, mirrored by the retention rules in the [Privacy brief](PRIVACY.md).
- **Celebrate community self-expression.** The avatar mode is a love letter to people who’d rather not hand over a headshot.
- **Teach with transparency.** The repo stays detection-only; the [Assumption Ledger](docs/assumption-ledger.md) and [CHANGELOG](CHANGELOG.md) flag the edges.

> Built for STEAM classrooms, community tech clinics, and punk art spaces where ethics, consent, and UX are first-class citizens.

## Workshop playlist

1. **Consent check-in** — Read the [Ethics zine](ETHICS.md) out loud; ask the group who decides when cameras roll.
2. **Tooling quickie** — Walk through the [Installation guide](INSTALLATION.md) and this README.
3. **Hands-on build** — Run the Processing sketch (below) and wire up the Arduino button panel if you have one.
4. **Data walk** — Trace the `Camera → RAM → Review → (optional) Disk` flow using the Mermaid diagram further down; bring in the [Privacy brief](PRIVACY.md).
5. **Reflection circle** — Compare your observations with the [Assumption Ledger](docs/assumption-ledger.md) and drop new findings into `notes/`.
6. **Next steps** — Use the [Workshop Playbook](docs/workshop-playbook.md) to adapt for your crew.

## Quick start

1. **Processing (Java mode)** → Install libraries via Contribution Manager:
   - **Video** (Processing Foundation)
   - **OpenCV for Processing** (Greg Borenstein)
   - **Video Export** (by *hamoid*)
2. Drop a background image at `processing/data/slug.png` (or lean on the built-in gradient fallback).
3. Open `processing/FaceSlugPrivacyTeaching.pde` in Processing and press ▶️.
4. (Optional) Flash the Arduino sketch `arduino/SaveRecDoubleLongPress/SaveRecDoubleLongPress.ino` and connect a tactile double-press button.
5. Use the on-screen buttons/keys or Arduino signals to explore the save/consent flow.

## Controls

- **Buttons (top bar):** Consent, Avatar, REC, Show my image, Delete now
- **Keys:** `s` (save→review), `y/n` (confirm/discard), `v` (REC), `c` (consent),
  `m` (mirror), `d` (debug), `f` (feather), `g` (gate writes on face), `t` (auto REC on face),
  `A` (avatar), `N` (new avatar), `o` (show last), `Delete` (delete last)
- **Arduino serial:** `SAVE` (first tap), `SAVE_DBL` (second tap ≤1s), `REC` (toggle),
  `CONSENT_TOGGLE` (long-press ≥1.5s)

## Folder structure

```
face-slug-privacy-teaching/
├─ processing/
│  ├─ FaceSlugPrivacyTeaching.pde
│  └─ data/
│     └─ (put slug.png here)
├─ arduino/
│  └─ SaveRecDoubleLongPress/
│     └─ SaveRecDoubleLongPress.ino
├─ notes/
│  └─ HARDWARE_NOTES_PLACEHOLDER.md
├─ diagrams.md
├─ INSTALLATION.md
├─ CHANGELOG.md
├─ LICENSE
└─ .gitignore
```

## Data-flow (high level)

```mermaid
flowchart LR
    C(Camera) --> D[Detect (RAM)]
    D --> R{Review}
    R -- Save --> PNG[Write PNG]
    R -- Discard --> X1[(No file)]
    subgraph Session Recording
      SR(REC ON) -->|Consent & optional face-gate| FW[Write frames]
      SR -->|Stop| RS{Session Review}
      RS -- Keep --> MP4[Keep MP4]
      RS -- Discard/Timeout --> X2[(Delete MP4)]
    end
```

## Serial protocol (gesture semantics)

```mermaid
sequenceDiagram
  participant BTN as Arduino Button
  participant MCU as Arduino
  participant Host as Processing Sketch

  BTN->>MCU: Press SAVE
  MCU->>Host: "SAVE"
  Host->>Host: Capture preview (RAM); open Review

  BTN->>MCU: Second press (≤ 1s)
  MCU->>Host: "SAVE_DBL"
  alt Consent ON
    Host->>FS: Save PNG immediately
  else Consent OFF
    Host->>Host: Remain in Review; prompt for consent
  end

  BTN->>MCU: Long-press SAVE (≥1.5s)
  MCU->>Host: "CONSENT_TOGGLE"
  Host->>Host: Consent flips ON↔OFF
```

## License
MIT. See `LICENSE`.

---

## More references & signal boosts

- [INSTALLATION.md](INSTALLATION.md) — step-by-step setup.
- [ETHICS.md](ETHICS.md) — values manifesto.
- [PRIVACY.md](PRIVACY.md) — storage promises.
- [docs/lineage.md](docs/lineage.md) — evolution notes.
- [docs/workshop-playbook.md](docs/workshop-playbook.md) — facilitation prompts and remix ideas.
- [CITATION.cff](CITATION.cff) — academic citation metadata.

**Credits**: OpenCV for Processing (Greg Borenstein), Video Export (hamoid), Processing Foundation.
