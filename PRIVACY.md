# Privacy

This repo ships sketches that keep it local:

- detection-only: no face IDs, no embeddings
- camera stays off until you say **Yes**
- preview lives in RAM; nothing hits disk unless you smash save
- saved pics carry an `expiresAt`; old files nuke themselves on launch
- no network calls, no analytics, no surprises

Want a file gone now? trash the `captures/` folder.
