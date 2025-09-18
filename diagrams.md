
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
flowchart LR
  start([REC toggle ON])
  consent{Consent ON?}
  gate{Gate on face?}
  present{Face present?}
  writer["Write frames every draw()"]
  stop([REC toggle OFF])
  written{Frames written > 0?}
  review{"Session Review"\nKeep or Discard}
  keep[[Keep MP4]]
  delete[[Delete empty MP4]]

  start --> consent
  consent -- No --> start
  consent -- Yes --> gate
  gate -- No --> writer
  gate -- Yes --> present
  present -- Yes --> writer
  present -- No --> start
  writer --> stop
  stop --> written
  written -- No --> delete
  written -- Yes --> review
  review -- Keep --> keep
  review -- Discard/Timeout --> delete
```

## C. Data pipeline

```mermaid
flowchart LR
  camera[[Camera]] --> detect["OpenCV Detect"]
  detect --> composite["Composite over slug"]
  composite --> ui["UI overlays"\nbuttons / map / toasts]
  ui -->|Consent gated| disk[(Disk PNG/MP4)]
```

## D. Serial interactions

```mermaid
sequenceDiagram
  participant Arduino
  participant Processing
  participant FS as FileSystem

  Arduino->>Processing: SAVE
  Processing->>Processing: Open review overlay (RAM only)

  Arduino->>Processing: SAVE_DBL
  alt Consent ON
    Processing->>FS: Write PNG
  else Consent OFF
    Processing->>Processing: Stay in Review
  end

  Arduino->>Processing: CONSENT_TOGGLE
  Processing->>Processing: Flip consent state
```
