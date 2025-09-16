
# Face → Slug (Privacy-First) — Teaching Build

A Processing + Arduino sketch that:
- Detects a face, crops a square, feathers it, and composites over a “slug” background.
- Enforces **data minimization**: **Consent = OFF** by default. Nothing hits disk until you opt in.
- **Save flow**: single press → **Review** (RAM only) → **Save | Discard**; **double-press (≤1s)** auto-confirms save only if **Consent = ON**.
- **Recording**: one MP4 per session, **consent-gated** and optionally **face-gated**. On stop, you must **Keep** or **Discard**; otherwise the file is deleted.
- **Avatar mode**: geometric portrait alternative when “no headshot” is desired.
- On-screen UI: Consent, Avatar, REC, Show my image, Delete now, plus a tiny data-flow map.

> Built for STEAM classrooms and installations where ethics, consent, and UX are first-class.

## Quick start

1. **Processing (Java mode)** → Install libraries via Contribution Manager:
   - **Video** (Processing Foundation)
   - **OpenCV for Processing** (Greg Borenstein)
   - **Video Export** (by *hamoid*)
2. Put a background image as `data/slug.png` (or rely on the built-in gradient fallback).
3. Open `processing/FaceSlugPrivacyTeaching.pde` in Processing and run.
4. (Optional) Flash the Arduino sketch `arduino/SaveRecDoubleLongPress/SaveRecDoubleLongPress.ino`.
5. Use the on-screen buttons/keys or Arduino buttons.

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
    subgraph "Session Recording"
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
  participant FS as FileSystem

  BTN->>MCU: Press SAVE
  MCU->>Host: "SAVE"
  Host->>Host: Capture preview (RAM); open Review

  BTN->>MCU: Second press (<= 1s)
  MCU->>Host: "SAVE_DBL"
  alt Consent ON
    Host->>FS: Save PNG immediately
  else Consent OFF
    Host->>Host: Remain in Review; prompt for consent
  end

  BTN->>MCU: Long-press SAVE (>=1.5s)
  MCU->>Host: "CONSENT_TOGGLE"
  Host->>Host: Consent flips ON<->OFF
```

## License
MIT. See `LICENSE`.

---

**Credits**: OpenCV for Processing (Greg Borenstein), Video Export (hamoid), Processing Foundation.
