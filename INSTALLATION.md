
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
- Any board with native USB-serial (e.g., Uno).
- No extra libraries required.

## 2) Hardware (fill in)

### Camera
- **Model / driver**: Common USB Webcam
- **Resolution/format**: 1280x760
- **Lighting considerations**: Dependent on camera model selected. Have a desk lamp available to help OpenCV.

### Computer / OS
- **OS**: Verified on Windows 10/11 and macOS 13+. On macOS you’ll need to grant Processing access under **System Settings → Privacy & Security → Camera** and then relaunch the sketch.

### Arduino + Buttons
- **Board**: Uno
- **Wiring**: Buttons from pin → **GND** (use `INPUT_PULLUP`).
- **Pins**: SAVE = D2, REC = D3 (change in code if needed).

## 3) Deployment

### Directory hygiene
Add to `.gitignore` (already included):
```
captures/
sessions/
*.mp4
```
