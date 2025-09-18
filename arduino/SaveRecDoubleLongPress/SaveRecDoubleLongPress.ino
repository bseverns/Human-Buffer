// Arduino: SAVE button with short/double/long; REC toggle.
// -----------------------------------------------------------------------------
// This sketch is the hardware wing of the Face → Slug teaching rig. We speak a
// micro-serial language that mirrors the Processing sketch:
//   - quick tap  → "SAVE" (stage capture in RAM)
//   - double tap → "SAVE_DBL" (auto-save if consent is already ON)
//   - long hold  → "CONSENT_TOGGLE" (flip consent state without capturing)
//   - REC button → "REC" (Processing will start/stop the MP4 session)
// Buttons are wired between the pin and GND while using INPUT_PULLUP so idle = HIGH.

const int BTN_SAVE = 2;  // short: SAVE, double (≤1s): SAVE_DBL, long (≥1.5s): CONSENT_TOGGLE
const int BTN_REC  = 3;  // REC toggle

// Gesture timing windows (in milliseconds)
const unsigned long DOUBLE_MS = 1000;   // allow 1 second for the second tap
const unsigned long LONG_MS   = 1500;   // long-press threshold for consent toggle

// SAVE button finite-state machine bookkeeping
bool saveDown = false;            // is the SAVE button currently pressed?
unsigned long saveDownAt = 0;     // when the press started

// Short presses queue up in case they grow into a double-tap.
unsigned long pendingStartedAt = 0; // when we started waiting for the second tap
bool pendingSingle = false;          // true while we’re waiting to resolve single vs double

// Guard so long-press doesn’t emit SAVE events on release.
bool longFired = false;

void setup() {
  pinMode(BTN_SAVE, INPUT_PULLUP);
  pinMode(BTN_REC,  INPUT_PULLUP);
  Serial.begin(115200); // matches the Processing sketch’s SERIAL_BAUD
}

void loop() {
  static bool prevSave = HIGH, prevRec = HIGH; // previous sample for edge detection
  bool curSave = digitalRead(BTN_SAVE);
  bool curRec  = digitalRead(BTN_REC);
  unsigned long now = millis();

  // --- SAVE button state machine ---
  if (prevSave == HIGH && curSave == LOW) {
    // button just went down
    saveDown = true;
    longFired = false;
    saveDownAt = now;
  }

  if (saveDown) {
    unsigned long held = now - saveDownAt;
    if (!longFired && held >= LONG_MS) {
      // Long-press: CONSENT_TOGGLE, consume gesture (no SAVE messages)
      Serial.println("CONSENT_TOGGLE");
      longFired = true;
      pendingSingle = false; // cancel pending single so release stays quiet
    }
  }

  if (prevSave == LOW && curSave == HIGH) {
    // button just went up
    saveDown = false;
    if (!longFired) {
      if (pendingSingle && (now - pendingStartedAt) <= DOUBLE_MS) {
        // second tap arrived in time → emit explicit double
        Serial.println("SAVE_DBL");
        pendingSingle = false;
      } else {
        // first tap: tentatively mark as single and wait for a partner
        pendingSingle = true;
        pendingStartedAt = now;
      }
    }
  }

  // If a pending single press ages out, emit the SAVE now.
  // This keeps doubles from spamming a SAVE + SAVE_DBL pair.
  if (pendingSingle && (now - pendingStartedAt) > DOUBLE_MS) {
    Serial.println("SAVE");
    pendingSingle = false;
  }

  // --- REC toggle ---
  if (prevRec == HIGH && curRec == LOW) {
    Serial.println("REC");
  }

  // crude debounce so bouncy buttons don’t double-trigger
  delay(8);

  prevSave = curSave;
  prevRec  = curRec;
}
