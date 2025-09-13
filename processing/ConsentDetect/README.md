# ConsentDetect
**What this tests:** consent gate + face detection with TTL saves
**Learning goals:**
- cameras stay dark until you say yes
- detection boxes show math, not identity
- review the capture and decide if it lives or dies
**Run:** Processing 4 (Java mode). Open this folder and hit **Run**.
**Dependencies:** Video library, OpenCV for Processing
**Controls:** `space` capture → review; `y`/`n` save or toss; `o` toggle "See the math"
**Known limits:** single USB cam, front-facing cascade only, PNG output
**Ethics:** detection only; no recognition; stays offline; images auto-expire
