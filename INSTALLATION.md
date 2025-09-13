
# Installation & Implementation Notes

> This document leaves **intentional space** for your hardware-specific notes (camera, Arduino model, wiring, power). Fill in per your classroom or exhibit context.

## 1) Software

### Processing
- Version: 3.x or 4.x (Java mode)
- Libraries (Contribution Manager):
  - Video
  - OpenCV for Processing
  - Video Export (hamoid)

### Arduino
- Any board with native USB-serial (e.g., Uno, Nano, Leonardo, Micro, MKR, etc.).
- No extra libraries required.

## 2) Hardware (fill in)

### Camera
- **Model / driver**: _TODO_
- **Resolution/format**: _TODO_
- **Mounting & FOV**: _TODO_
- **Lighting considerations**: _TODO_

### Computer / OS
- **OS**: _TODO_
- **GPU**: _TODO_
- **USB ports & hubs**: _TODO_

### Arduino + Buttons
- **Board**: _TODO_
- **Wiring**: Buttons from pin → **GND** (use `INPUT_PULLUP`).
- **Pins**: SAVE = D2, REC = D3 (change in code if needed).
- **Enclosures / panel mount**: _TODO_

### Power / Safety
- **Power budget**: _TODO_
- **Cable management**: _TODO_
- **Emergency stop / supervisor**: _TODO_

## 3) Deployment

### Directory hygiene
Add to `.gitignore` (already included):
```
captures/
sessions/
*.mp4
```

### Kiosk mode (optional)
- _TODO: describe full-screen, auto-launch, watchdog, etc._

### Accessibility
- _TODO: physical affordances, readable color contrast, alternative input, teaching aids._
