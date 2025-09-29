# Changelog

## v2.2 (unreleased)
- Stabilized camera detection, recording, and save flows so the workshop survives low frame rates and post-capture edge cases.
- Made the avatar mode reactive, shuffled the face helper tabs for clarity, and dropped fresh UV slug assets for remixing.
- Expanded the lineage timeline + repo map docs to spotlight the ethical throughline of the build.
- Documented the Educator Mode toggle with Minnesota standards alignment so teachers can translate the punk brief for admins.

## v2.1.2
- Added Arduino **long-press** → `CONSENT_TOGGLE`.
- Added **Session Review** for MP4 keep/discard (auto-delete if not confirmed).
- Double-press SAVE (≤1s) auto-confirms **only** when Consent is ON.
- Kept avatar mode, consent gate, feathered mask, and UI buttons.

## v2.1.1 (unreleased)
- macOS friendly camera picker + permission hints so the sketch behaves on Apple hardware.

## v2.1
- Added ConsentDetect teaching sketch (consent gate, TTL, overlay toggle)
- Added privacy/ethics docs and auto-purge on startup
