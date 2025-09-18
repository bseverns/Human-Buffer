# Privacy

This repo ships sketches that keep it local. Pair this with the [Ethics notes](ETHICS.md) and the [Aftercare ritual](docs/workshop-playbook.md#aftercare).

- detection-only: no face IDs, no embeddings — revisit the distinction during the [surveillance unpacked](docs/workshop-playbook.md#2-surveillance-unpacked-15-min) segment.
- camera stays off until you say **Yes**; facilitators model the consent toggle per the [workshop playlist](README.md#workshop-playlist).
- preview lives in RAM; nothing hits disk unless you smash save. The flow is spelled out in the [data diagram](README.md#data-flow-high-level).
- saved pics carry an `expiresAt`; old files nuke themselves on launch. Document manual purges in the [Assumption Ledger](docs/assumption-ledger.md).
- no network calls, no analytics, no surprises. Keep it air-gapped and note any deviations in `notes/`.

Want a file gone now? trash the `captures/` folder together and cheer.
