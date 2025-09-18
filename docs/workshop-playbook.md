# Workshop Playbook — Face → Slug (Privacy-First)

This is the facilitation script for running the demo as a community workshop. Pair it with the [README](../README.md), [ETHICS](../ETHICS.md), and [PRIVACY](../PRIVACY.md) briefs. Remix loudly.

## Pre-game checklist

- **Space vibes:** let folks know cameras will be pointed at themselves, not strangers; print the [Ethics zine](../ETHICS.md) and tape it up.
- **Hardware:** laptop with Processing, webcam (built-in is fine), Arduino with tactile buttons (optional but joyful).
- **Files:** confirm `processing/FaceSlugPrivacyTeaching.pde` runs; stash a `slug.png` backdrop that reflects local community pride.
- **Safety:** review the [Assumption Ledger](assumption-ledger.md) so you can speak candidly about limitations.

## Session arcs

### 1. Welcome + consent culture (10 min)

- Invite everyone to opt-in before the camera turns on. If someone opts out, honor it by activating **Avatar mode**.
- Read a few bullet points from [PRIVACY.md](../PRIVACY.md) and ask: *Who owns the footage in this room?*

### 2. Surveillance unpacked (15 min)

- Show the live feed and pause at the detection boxes. Explain the difference between detection and recognition using the line in [ETHICS.md](../ETHICS.md).
- Prompt: *Where have you seen similar tech? Was it consensual?*
- Capture a still with consent OFF to demonstrate that nothing saves without the explicit toggle.

### 3. Build + remix (25 min)

- Pair folks up. One drives the Processing sketch; the other navigates the README’s [Quick start](../README.md#quick-start) and [Controls](../README.md#controls).
- Encourage scribbling new button ideas on sticky notes and saving them in `notes/`.
- Optional: flash the Arduino sketch from `arduino/SaveRecDoubleLongPress/` and let participants map the serial messages to actions.

### 4. Data stewardship circle (10 min)

- Stop recording; show how the MP4 either persists or self-destructs depending on the final choice.
- Reference the [data-flow diagram](../README.md#data-flow-high-level) and trace where files live.
- Prompt: *What would collective consent look like for a neighborhood CCTV?*

### 5. Debrief + commitments (10 min)

- Add new assumptions or findings to the [Assumption Ledger](assumption-ledger.md).
- Update the [Lineage timeline](lineage.md) with today’s remix.
- Close with an invitation to cite the project via [CITATION.cff](../CITATION.cff) when folks publish their reflections.

## Aftercare

- Delete the `captures/` directory together; narrate the act as part of your privacy ritual.
- Log facilitation notes in `notes/` and open a PR pointing to specific sections of the README or docs you tweaked.
- Dream up the next iteration: maybe a zine, maybe a counter-surveillance fashion workshop.

> Keep it punk, keep it consensual, and always explain what the code is doing.
