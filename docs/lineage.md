# Lineage

## Timeline of the weird little slug machine
- **2023** · First face→slug mashups land as scrappy Processing experiments. We kept everything in `notes/` and learned the hard way that "temporary" folders live forever.
- **2024** · Consent-gated composites go live with tactile buttons. The Arduino gestures now live in `arduino/SaveRecDoubleLongPress/` so classrooms can reflash the board without spelunking old laptops.
- **Early 2025** · The repo splits out a dedicated detection-only Processing sketch for workshops. That code graduates into `processing/FaceSlugPrivacyTeaching.pde` with avatar fallbacks for the camera-shy crew.
- **Late 2025** · Documentation grows a spine: the [README](../README.md) becomes a facilitator’s playlist, `docs/workshop-playbook.md` bundles aftercare rituals, and `docs/assumption-ledger.md` tracks every bias we’ve caught.
- **2026** · Repository gets a full privacy-and-ethics pass (hello `ETHICS.md`, `PRIVACY.md`, and the expanded `CHANGELOG.md`). We add diagrams, consent prompts, and a macOS camera picker so the sketch behaves in school labs.
- **On deck** · Drone/vision workshops and remote sensing riffs are scoped in `docs/sketchbook/` — we’re keeping them detection-only until the consent story is airtight.

## Repo map (2026 refresh)
This is the bird’s-eye view for facilitators and students who want to remix the build without getting lost in the guts.

- `/README.md` — The live workshop script. It explains why the build exists, how to set it up, and where the ethical guardrails sit.
- `/INSTALLATION.md` — Plain-language setup steps for Processing, libraries, and Arduino tooling.
- `/CHANGELOG.md` — Every feature bump and safety tweak since the project left napkin stage.
- `/ETHICS.md` & `/PRIVACY.md` — Policy one-pagers you can read aloud before any camera rolls.
- `/diagrams.md` — Data-flow visuals you can drop into slides or whiteboards when explaining the consent loop.
- `/CITATION.cff` — How to cite the project when you publish that righteous zine or research note.
- `/docs/` — Deeper facilitation resources:
  - `assumption-ledger.md` captures the biases we’ve spotted.
  - `lineage.md` (this file) chronicles how the tech and pedagogy evolve.
  - `workshop-playbook.md` gives step-by-step facilitation guidance plus aftercare rituals.
  - `sketchbook/` houses future experiments and rough workshop concepts.
- `/arduino/SaveRecDoubleLongPress/` — The tactile consent hardware sketch with long-press toggles and double-tap logic.
- `/processing/FaceSlugPrivacyTeaching.pde` — The main Processing sketch, complete with avatar mode, consent gate, and serial hooks.
- `/notes/` — Field logs, hardware gotchas, and open questions from past builds. Drop your battle stories here.

This lineup is intentionally loud: every folder telegraphs intent so learners can trace how ethics, code, and hardware co-conspire. Remix it, annotate it, but keep the consent-first vibes intact.
