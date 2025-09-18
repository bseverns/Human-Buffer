// Arduino: SAVE button with short/double/long; REC toggle.
// Wire each button between pin and GND (INPUT_PULLUP).

const int BTN_SAVE = 2;  // short: SAVE, double (≤1s): SAVE_DBL, long (≥1.5s): CONSENT_TOGGLE
const int BTN_REC  = 3;  // REC toggle

const unsigned long DOUBLE_MS = 1000;   // double-press window (single fires after this expires)
const unsigned long LONG_MS   = 1500;   // long-press threshold

// SAVE button FSM
bool saveDown = false;
unsigned long saveDownAt = 0;

// Short press gets queued until the double-tap window expires.
unsigned long pendingStartedAt = 0;
bool pendingSingle = false;

bool longFired = false;

void setup() {
  pinMode(BTN_SAVE, INPUT_PULLUP);
  pinMode(BTN_REC,  INPUT_PULLUP);
  Serial.begin(115200);
}

void loop() {
  static bool prevSave = HIGH, prevRec = HIGH;
  bool curSave = digitalRead(BTN_SAVE);
  bool curRec  = digitalRead(BTN_REC);
  unsigned long now = millis();

  // --- SAVE button state machine ---
  if (prevSave == HIGH && curSave == LOW) {
    // press
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
      pendingSingle = false; // cancel pending single
    }
  }

  if (prevSave == LOW && curSave == HIGH) {
    // release
    saveDown = false;
    if (!longFired) {
      if (pendingSingle && (now - pendingStartedAt) <= DOUBLE_MS) {
        Serial.println("SAVE_DBL");    // explicit double
        pendingSingle = false;
      } else {
        pendingSingle = true;          // wait to see if a second tap arrives
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

  // crude debounce
  delay(8);

  prevSave = curSave;
  prevRec  = curRec;
}
