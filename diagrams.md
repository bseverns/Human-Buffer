
# Diagrams

## A. Save gesture state machine

```mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Review : SAVE (first press)
  Review --> Saved : SAVE_DBL (<= 1s) / Consent ON
  Review --> Review : SAVE_DBL / Consent OFF
  Review --> Saved : Save button (Consent ON)
  Review --> Idle  : Discard
  Saved --> Idle
```

## B. Recording lifecycle (consent + face-gate)

```mermaid
flowchart TD
  A[REC toggle ON] --> B{Consent ON?}
  B -- "no" --> A
  B -- "yes" --> C{Gate on face?}
  C -- "no" --> D[Write frames every draw()]
  C -- "yes" --> E{Face present?}
  E -- "yes" --> D
  E -- "no" --> A
  D --> F[REC toggle OFF]
  F --> G{Frames written > 0?}
  G -- "no" --> H[Delete empty MP4]
  G -- "yes" --> I[Session Review Keep/Discard]
  I -- "Keep" --> J[Keep MP4]
  I -- "Discard/Timeout" --> H
```

## C. Data pipeline

```mermaid
flowchart LR
  Cam([Camera]) --> CV[OpenCV Detect]
  CV --> Comp[Composite over Slug]
  Comp --> UI[UI Overlays (buttons/map/toasts)]
  UI -->|Consent-gated| Disk[(Disk PNG/MP4)]
```

## D. Serial interactions

```mermaid
sequenceDiagram
  participant Arduino
  participant Processing
  participant FS as FileSystem

  Arduino->>Processing: SAVE
  Processing->>Processing: Open Review overlay (RAM only)

  Arduino->>Processing: SAVE_DBL
  alt Consent ON
    Processing->>FS: Write PNG
  else Consent OFF
    Processing->>Processing: Stay in Review
  end

  Arduino->>Processing: CONSENT_TOGGLE
  Processing->>Processing: Flip consent state
```
