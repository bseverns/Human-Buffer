// Arduino: SAVE button with short/double/long; REC toggle.
// Wire each button between pin and GND (INPUT_PULLUP).

const int BTN_SAVE = 2;  // short: SAVE, double (≤1s): SAVE_DBL, long (≥1.5s): CONSENT_TOGGLE
const int BTN_REC  = 3;  // REC toggle

const unsigned long DOUBLE_MS = 1000;   // double-press window
const unsigned long LONG_MS   = 1500;   // long-press threshold

// SAVE button FSM
bool saveDown = false;
unsigned long saveDownAt = 0;
unsigned long lastShortPressAt = 0;
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

  // --- SAVE button state machine ---
  if (prevSave == HIGH && curSave == LOW) {
    // press
    saveDown = true;
    longFired = false;
    saveDownAt = millis();
  }

  if (saveDown) {
    unsigned long held = millis() - saveDownAt;
    if (!longFired && held >= LONG_MS) {
      // Long-press: CONSENT_TOGGLE, consume gesture (no SAVE messages)
      Serial.println("CONSENT_TOGGLE");
      longFired = true;
      pendingSingle = false; // cancel pending single
    }
    if (prevSave == LOW && curSave == HIGH) {
      // release
      saveDown = false;
      if (!longFired) {
        // Short press path (consider double)
        unsigned long now = millis();
        if (pendingSingle && (now - lastShortPressAt) <= DOUBLE_MS) {
          Serial.println("SAVE_DBL");    // explicit double
          pendingSingle = false;
        } else {
          Serial.println("SAVE");        // first tap
          pendingSingle = true;
          lastShortPressAt = now;
        }
      }
    }
  }

  // timeout a lone first tap if no second tap arrives
  if (pendingSingle && (millis() - lastShortPressAt) > DOUBLE_MS) {
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
