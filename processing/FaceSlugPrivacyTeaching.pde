/**
 * Privacy-First Face/Avatar Composite — Teaching Build (v2)
 * ---------------------------------------------------------
 * - Consent = OFF by default (data minimization). Nothing hits disk until user opts in.
 * - SAVE (single press) → Review overlay (RAM-only) → [Save | Discard].
 * - SAVE (double press ≤1s) → Auto-confirm write ONLY if Consent = ON.
 * - SAVE (long press ≥1.5s) from Arduino → CONSENT_TOGGLE (no image write).
 * - Recording = 1 MP4 per session; writes are consent-gated & optionally face-gated.
 * - On stop: open Session Review [Keep | Discard]. If not confirmed, DELETE the file.
 *   (If 0 frames written, auto-delete immediately.)
 * - Avatar mode: geometric portrait instead of headshot (privacy-friendly).
 * - On-screen UI: Consent, Avatar, REC, Show last image, Delete last image.
 * - Data-flow map: "Camera → Detect (RAM) → Review [Save | Discard]"
 *
 * Hardware IO: Arduino Uno @115200 baud. Momentary switch tied from digital pin 13 → GND
 *   using the internal pull-up. Short tap = SAVE, double tap = SAVE_DBL, long hold toggles consent.
 *
 * Serial commands (newline-terminated):
 *   "SAVE"         : capture preview → open Review (no write)
 *   "SAVE_DBL"     : double press → auto-save if Consent ON; else remain in Review
 *   "REC"          : toggle recording
 *   "REC START"    : start new session file
 *   "REC STOP"     : stop & open Session Review (Keep/Discard)
 *   "CONSENT_TOGGLE": toggle consent ON/OFF (from Arduino long-press)
 *
 * Keys:
 *   s : request save (Review)      y/n : confirm/discard in Review
 *   v : toggle recording           c   : toggle Consent
 *   m : mirror preview             d   : debug overlay
 *   f : feather on/off             g   : face-gate writes on/off
 *   t : auto start/stop on face    A   : avatar toggle, N: new avatar
 *   o : show last saved image      DEL/BKSP : delete last saved (confirm)
 */

import processing.video.*;
import processing.serial.*;
import gab.opencv.*;
import com.hamoid.*;

import java.awt.Rectangle;
import java.io.File;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Random;
import java.util.HashSet;

// ------------------------------
// CONFIG
// ------------------------------
// OUTPUT_SIZE: final rendered square avatar. The UI scales around this, so we keep it stable.
final int   OUTPUT_SIZE        = 800;
// CAM_W / CAM_H: preferred capture profile. We downscale later but detection loves higher res.
final int   CAM_W              = 1280;
final int   CAM_H              = 720;
// SQUARE_SCALE: face bounding box inflation; gives breathing room beyond raw detection.
final float SQUARE_SCALE       = 1.35f;
final int   FACE_MISSING_GRACE_FRAMES = 6;
// RECORD_FPS: matches both Processing draw() and VideoExport to prevent frame duplication.
final int   RECORD_FPS         = 30;
// SERIAL_BAUD + SERIAL_HINT: handshake speed + port name sniff for Arduino-based controls.
final int   SERIAL_BAUD        = 115200;
final String SERIAL_HINT       = "usb|acm|modem|COM|tty";
// SLUG_FILENAME: slug art the camera feed composites onto. Missing file falls back to gradient.
final String SLUG_FILENAME     = "slug.png";
// START_* toggles: how we boot into the workshop — mirror on for human-friendly UI, etc.
final boolean START_MIRROR     = true;
// SMOOTH_FACTOR: exponential smoothing of face positions so the slug doesn’t jitter.
final float SMOOTH_FACTOR      = 0.25f;
// DISPLAY_SCALE: scales down the composite slightly to leave room for UI chrome.
final float DISPLAY_SCALE      = 0.90f;
// CAMERA_RETRY_DELAY_MS: throttle for camera auto-retry when consent is granted mid-session.
final int   CAMERA_RETRY_DELAY_MS = 2000;

// Camera auto-recovery: how long to wait between retries and how many we’ll attempt.
final int   CAM_RETRY_DELAY_MS = 1800;
final int   CAM_AUTO_RETRY_MAX = 3;

// Feathering: soft edge mask around the face crop; helps blend into the slug background.
final boolean START_FEATHER    = true;
final int     FEATHER_PX       = 60;

// Consent modifiers: whether to gate recording on a face and whether auto recording boots hot.
final boolean START_GATE_ON_FACE = true;
final boolean START_AUTO_REC      = false;

final String OS_NAME = System.getProperty("os.name").toLowerCase();
final boolean ON_WINDOWS = OS_NAME.contains("win");
final boolean ON_MAC = OS_NAME.contains("mac");
final boolean ON_LINUX = !ON_WINDOWS && !ON_MAC;

// Housekeeping: optionally delete old PNG captures so a workshop laptop can breathe.
final boolean PRUNE_OLD_PNG     = false;
final int     KEEP_MAX_PNG      = 800;

// --- SAVE gestures (Arduino) ---
// DOUBLE_TAP_MS: how long we wait for a second tap before promoting the first tap to SAVE.
final int DOUBLE_TAP_MS = 1000;   // second SAVE within ≤1s = auto-confirm

// --- Session review timeout (if not confirmed, delete) ---
// SESSION_REVIEW_TIMEOUT_MS: fail-safe so unattended recordings self-delete.
final int SESSION_REVIEW_TIMEOUT_MS = 15000; // 15s to confirm Keep

// ------------------------------
// STATE
// ------------------------------
// Live camera interface and detection helper.
Capture cam;
OpenCV  opencv;
int     opencvW = -1;
int     opencvH = -1;
// Serial channel to the Arduino button board, and the video exporter for MP4 sessions.
Serial  ard;
VideoExport ve;

// Visual buffers — the slug background, our off-screen composite, and the feathering mask.
PImage slug;
PGraphics composite;
PImage featherMask;

// Camera startup bookkeeping: track which device, whether it’s awake, and retry status.
String cameraName = null;
String cameraPrimaryName = null;
boolean camReady = false;
boolean camUsingAutoConfig = false;
boolean camFallbackAttempted = false;
long    camStartAttemptMs = 0;
int     camFramesSeen = 0;
String  camStatusMsg = null;
int     camAutoRetryCount = 0;
long    camRetryAtMs = 0;
boolean macPipelineFallbackArmed = false;
boolean macPipelineFallbackActive = false;
int     macPipelineFallbackStage = 0;
final int MAC_PIPELINE_FALLBACK_MAX_STAGE = 2;

// Consent gate: OFF by default. We only spin up hardware and file IO once this flips true.
boolean consent = false;

// Live toggles controlled by UI or workshop facilitators.
boolean mirrorPreview = START_MIRROR; // human-friendly orientation
boolean debugOverlay  = false;        // draw detection debug line work
boolean useFeather    = START_FEATHER; // soften edges on the face crop
boolean gateOnFace    = START_GATE_ON_FACE; // require a face to write frames
boolean autoRecOnFace = START_AUTO_REC;     // robot cameraman mode

// Face smoothing: exponential averages for the latest face box so the overlay eases into place.
float cx = -1, cy = -1, side = -1;
boolean haveFace = false;
int facePresentStreak = 0;
int faceMissingStreak = 0;

// Review overlay (PNG) holds a RAM copy of the snapshot while the human decides its fate.
boolean inReview = false;
PImage  reviewFrame = null;
String  reviewNote  = "";

// Last saved PNG (for "Show/Delete") — we lazy-load the full image to avoid disk thrash.
String lastSavedPath = null;
PImage lastSavedThumb = null;
PImage lastSavedFull  = null;

// Recording state: MP4 session metadata and counters for consent/timeouts.
boolean recording = false;
String  recordingFile = null;
String  recordingBaseName = null;
FrameStackRecorder frameStackRecorder = null;
String  recordingFallbackNote = null;
String  sessionReviewFallbackNote = null;
int     framesWrittenThisSession = 0;

// Session file post-stop confirmation: modal that asks "keep or toss" after recording stops.
boolean sessionReviewActive = false;
String  sessionReviewPath   = null;
boolean sessionReviewIsFrameStack = false;
long    sessionReviewDeadlineMs = 0;
Btn     sessKeep = new Btn("sess_keep", "Keep", 0,0,0,0);
Btn     sessDiscard = new Btn("sess_discard", "Discard", 0,0,0,0);

// Avatar mode is seeded so runs are deterministic unless the facilitator reshuffles.
boolean avatarMode = false;
long    avatarSeed = 1234567;
Random  avatarRng  = new Random(avatarSeed);

// UI buttons live in one list so we can iterate for drawing/hit-testing.
ArrayList<Btn> buttons = new ArrayList<Btn>();

// Double-tap tracking (serial-origin only) pairs with Arduino’s SAVE → SAVE_DBL semantics.
long lastSaveTapMs = -1;
boolean reviewOpenedFromSerial = false;

// Toast feedback system — punk zine energy for ephemeral notes.
String toastMsg = null;
long toastUntilMs = 0;

// ------------------------------
// LIFECYCLE
// ------------------------------
/**
 * settings() fires before setup(); we fix the canvas to a square so the slug art
 * and the feathered face overlay stay pixel-perfect. Processing’s size() call
 * lives here because the newer renderers demand it.
 */
void settings() { size(OUTPUT_SIZE, OUTPUT_SIZE); }

void setup() {
  // Window title is part workshop signage, part vibe check.
  surface.setTitle("Privacy-First Face/Avatar Composite — Teaching Build v2");
  frameRate(RECORD_FPS);

  // Camera
  // -------
  // We delay spinning up the camera until consent arrives. Here we just pick which
  // device we *would* use and show a parked status message.
  cameraName = pickCamera();
  cameraPrimaryName = inferPrimaryCameraName(cameraName);
  if (cameraName == null) { println("No camera found. Exiting."); exit(); }
  camStatusMsg = "Consent is OFF — camera parked.";

  // Slug & buffers
  // ---------------
  // Pull in the slug illustration (or synthesize a gradient fallback) and prep
  // the off-screen composite surface plus the feather mask we reuse each frame.
  slug = loadImage(SLUG_FILENAME);
  if (slug == null) slug = fallbackSlug();

  composite = createGraphics(OUTPUT_SIZE, OUTPUT_SIZE);
  featherMask = makeRadialFeatherMask(
    OUTPUT_SIZE, OUTPUT_SIZE,
    OUTPUT_SIZE * 0.5f - FEATHER_PX,
    FEATHER_PX
  );

  setupSerial(); // handshake with the Arduino button board (if one is plugged in)

  // Make sure the capture + session folders exist before we try to write anything.
  new File(sketchPath("captures")).mkdirs();
  new File(sketchPath("sessions")).mkdirs();

  buildButtons();

  registerMethod("dispose", this);

  println("READY: s(y/n), v, c, A/N, m/d/f/g/t, o, DEL. Arduino Uno (pin13 pull-up): SAVE/SAVE_DBL/REC/CONSENT_TOGGLE.");
}

void captureEvent(Capture c) {
  c.read();
  camFramesSeen++;

  ensureOpenCVFor(c.width, c.height);

  if (!camReady) {
    // First frame arrived. We treat this as the camera being officially live and
    // clear any retry timers the consent system may have queued up.
    camReady = true;
    camStatusMsg = null;
    println("Camera streaming @ " + c.width + "x" + c.height + (camUsingAutoConfig ? " (auto config)" : ""));
    camAutoRetryCount = 0;
    camRetryAtMs = 0;
    updateButtonLabels();
  }
}

void draw() {
  background(0);

  updateCameraStartupState();

  if (!cameraReadyForProcessing()) {
    drawCameraStatusScreen();
    drawUIBackplates();
    drawDataFlowMap();
    drawTopButtons();
    drawToast();
    return;
  }

  // --- Detect & smooth ---
  // Face detection stays framed as “math, not identity.” We only run the detector
  // when avatarMode is off, otherwise we build a generative portrait.
  opencv.loadImage(cam);
  Rectangle chosen = null;
  if (!avatarMode) {
    Rectangle[] faces = opencv.detect();
    chosen = pickLargest(faces);
  }
  updateFaceSmoothing(chosen);

  // Auto REC (file open/close), still consent-gated when writing frames
  // If the facilitator toggled auto-record-on-face, this robot cameraman watches for
  // a face streak and opens/closes MP4 files for them.
  if (autoRecOnFace) {
    if (!recording && facePresentStreak >= 6) startRecording();
    if (recording  && faceMissingStreak >= 12) stopRecording();
  }

  // --- Composite ---
  // Render the slug base, optional face crop, or the procedural avatar.
  composite.beginDraw();
  composite.imageMode(CORNER);
  composite.image(slug, 0, 0, composite.width, composite.height);

  if (!avatarMode && haveFace) {
    int sq = max(4, round(side));
    int x0 = round(cx - side * 0.5f);
    int y0 = round(cy - side * 0.5f);
    x0 = constrain(x0, 0, cam.width  - sq);
    y0 = constrain(y0, 0, cam.height - sq);

    PImage crop = cam.get(x0, y0, sq, sq);
    if (mirrorPreview) crop = mirrorImage(crop); // reflect horizontally to match mirrors/selfies
    crop.resize(OUTPUT_SIZE, OUTPUT_SIZE);

    if (useFeather) {
      PImage masked = crop.copy();
      masked.mask(featherMask);
      composite.image(masked, 0, 0);
    } else {
      composite.image(crop, 0, 0);
    }

    if (debugOverlay) {
      composite.noFill(); composite.stroke(255); composite.strokeWeight(3);
      composite.rect(2, 2, composite.width-4, composite.height-4);
    }
  }

  if (avatarMode && !inReview) {
    drawAvatar(composite, avatarRng);
  }

  composite.endDraw();

  float scaledW = composite.width * DISPLAY_SCALE;
  float scaledH = composite.height * DISPLAY_SCALE;
  float offsetX = (width  - scaledW) * 0.5f;
  float offsetY = (height - scaledH) * 0.5f;
  image(composite, offsetX, offsetY, scaledW, scaledH);

  // --- UI: map + buttons + status ---
  // Blend the teaching aids (data-flow map, consent buttons, debug status) on top.
  drawUIBackplates();
  drawDataFlowMap();
  drawTopButtons();
  if (recording) drawRECIndicator();
  if (debugOverlay) drawDebugPIP();

  // --- Overlays (modal) ---
  // Modals trump the live preview. Each overlay explains what’s happening, by design.
  if (inReview) drawReviewOverlay();
  if (sessionReviewActive) drawSessionReviewOverlay();
  if (confirmDelete) drawDeleteConfirm();
  if (viewingLast) drawShowLast();

  // --- Recording: write frames only if consent (and optionally face present) ---
  // Consent is a hard gate. The optional face gate means “no empty room B-roll.”
  boolean okToWrite = recording && consent && recorderReady();
  boolean passGate  = !gateOnFace || haveFace || avatarMode;
  if (okToWrite && passGate) {
    if (ve != null) {
      ve.saveFrame();
    } else if (frameStackRecorder != null) {
      frameStackRecorder.saveFrame(null);
    }
    framesWrittenThisSession++;
  }

  drawToast();
}

/**
 * cameraReadyForProcessing() centralizes our "is the camera safe to use?" logic.
 * We require a Capture object, at least one frame read (camReady), and OpenCV to be
 * configured. UI buttons rely on this so we don't invite folks to capture while the
 * pipeline is half-built.
 */
boolean cameraReadyForProcessing() {
  return cam != null && camReady && opencv != null;
}

/**
 * updateCameraStartupState() runs each frame to wrangle camera boot edges:
 * - respect consent (no spinning if OFF)
 * - retry with auto config when a custom resolution fails
 * - schedule exponential-ish retries to avoid hammering USB drivers.
 */
void updateCameraStartupState() {
  if (!consent) return;

  if (camRetryAtMs > 0 && millis() >= camRetryAtMs) {
    camRetryAtMs = 0;
    println("Retrying camera (auto config) — attempt " + camAutoRetryCount + " / " + CAM_AUTO_RETRY_MAX);
    startCameraAuto();
    return;
  }
  if (cam == null) return;
  if (camReady) return;

  int elapsed = (int)(millis() - camStartAttemptMs);
  if (elapsed < 0) elapsed = 0;

  if (!camUsingAutoConfig && !camFallbackAttempted && elapsed > 3000 && camFramesSeen == 0) {
    println("Camera start timed out @ " + CAM_W + "x" + CAM_H + " — retrying with camera defaults.");
    camStatusMsg = "Camera timed out @ " + CAM_W + "x" + CAM_H + " → retrying default profile...";
    startCameraAuto();
    return;
  }

  if (camUsingAutoConfig && camFramesSeen == 0 && elapsed > 3000) {
    if (camRetryAtMs == 0) {
      boolean scheduled = scheduleAutoRetry("Camera never produced frames.");
      if (!scheduled) {
        camStatusMsg = "Camera never produced frames. Close other apps or check driver permissions.";
      }
    }
  }
}

/**
 * drawCameraStatusScreen() paints the "camera is sleeping/warming" panel. It's what
 * participants see before consent or while the driver is negotiating settings.
 */
void drawCameraStatusScreen() {
  pushStyle();
  noStroke();
  fill(20);
  rect(0, 0, width, height);
  fill(255);
  textAlign(CENTER, CENTER);
  textSize(18);
  String msg;
  if (!consent) {
    msg = "Consent is OFF → camera parked.";
  } else {
    msg = camStatusMsg != null ? camStatusMsg : "Waiting for camera…";
  }
  text(msg, width/2f, height/2f - 16);

  if (!consent) {
    textSize(12);
    text("Toggle Consent (button or 'c') to wake the camera.", width/2f, height/2f + 24);
  } else if (camUsingAutoConfig && camFramesSeen == 0) {
    textSize(12);
    String extra = cameraWarmupHelpMessage();
    if (extra != null && extra.length() > 0) {
      text(extra, width/2f, height/2f + 32);
    }
  }
  popStyle();
}

/**
 * ensureOpenCVFor() lazily instantiates the OpenCV helper at the incoming capture size.
 * Changing camera modes invalidates the instance, so we tear it down and rebuild.
 */
void ensureOpenCVFor(int w, int h) {
  if (opencv != null && opencvW == w && opencvH == h) return;
  opencv = new OpenCV(this, w, h);
  opencv.loadCascade(OpenCV.CASCADE_FRONTALFACE);
  opencvW = w;
  opencvH = h;
  println("OpenCV configured for " + w + "x" + h);
}

void startCameraPreferred() {
  if (cameraName != null && cameraName.toLowerCase().startsWith("pipeline:")) {
    startCamera(cameraName, 0, 0, true);
  } else {
    startCamera(cameraName, CAM_W, CAM_H, false);
  }
}

void startCameraAuto() {
  startCamera(cameraName, 0, 0, true);
}

/**
 * startCamera() is the single ingress for camera sessions. It stops any current stream,
 * resets state, and spins up either a requested resolution (workshop default) or the
 * vendor’s auto profile when the preferred mode flakes out.
 */
void startCamera(String name, int reqW, int reqH, boolean autoConfig) {
  if (name == null) return;

  if (cam != null) {
    try { cam.stop(); }
    catch(Exception e) { println("Camera stop error: " + e.getMessage()); }
  }
  cam = null;

  updateButtonLabels();

  camReady = false;
  camFramesSeen = 0;
  camStartAttemptMs = millis();
  boolean usingPipeline = name.toLowerCase().startsWith("pipeline:");
  String lowerName = name.toLowerCase();
  boolean usingMacFallback = usingPipeline && lowerName.startsWith("pipeline:avfvideosrc");
  boolean usingMacAutoFallback = usingPipeline && lowerName.startsWith("pipeline:autovideosrc");
  camUsingAutoConfig = autoConfig || usingPipeline;
  camFallbackAttempted = camUsingAutoConfig ? true : false;
  if (!autoConfig || usingPipeline) {
    camAutoRetryCount = 0;
  }
  camRetryAtMs = 0;
  if (usingMacFallback || usingMacAutoFallback) {
    macPipelineFallbackActive = true;
  } else if (!usingPipeline) {
    macPipelineFallbackActive = false;
    macPipelineFallbackArmed = false;
    macPipelineFallbackStage = 0;
  }

  opencv = null;
  opencvW = -1;
  opencvH = -1;

  try {
    if (usingPipeline) {
      println("Starting camera via pipeline: " + name + (reqW > 0 && reqH > 0 ? " (ignoring " + reqW + "x" + reqH + ")" : ""));
      cam = new Capture(this, name);
      camStatusMsg = "Starting camera via pipeline…";
    } else if (autoConfig) {
      println("Starting camera with default profile: " + name);
      cam = new Capture(this, name);
      camStatusMsg = "Starting camera (auto config)…";
    } else {
      println("Starting camera @ " + reqW + "x" + reqH + ": " + name);
      cam = new Capture(this, reqW, reqH, name);
      camStatusMsg = "Starting camera @ " + reqW + "x" + reqH + "…";
    }
    cam.start();
  } catch(Exception e) {
    println("Camera init exception: " + e.getMessage());
    camStatusMsg = "Camera init failed: " + e.getMessage();
    cam = null;
    if (!usingPipeline && !autoConfig && !camFallbackAttempted) {
      println("Retrying camera with default profile.");
      startCameraAuto();
    } else if (autoConfig) {
      scheduleAutoRetry("Camera init failed: " + e.getMessage());
    }
  }
}

/**
 * scheduleAutoRetry() backs off camera restarts so a flaky USB hub doesn’t get DoS’d.
 * Returns false when we’ve exhausted retries and should tell the facilitator to step in.
 */
boolean scheduleAutoRetry(String reason) {
  if (camAutoRetryCount >= CAM_AUTO_RETRY_MAX) {
    if (ON_MAC) {
      int nextStage = macPipelineFallbackStage + 1;
      if (nextStage <= MAC_PIPELINE_FALLBACK_MAX_STAGE) {
        String pipeline = buildMacPipelineFallback(nextStage);
        if (pipeline != null) {
          macPipelineFallbackArmed = true;
          macPipelineFallbackStage = nextStage;
          cameraName = pipeline;
          camAutoRetryCount = 0;
          camRetryAtMs = millis() + CAM_RETRY_DELAY_MS;
          String stageLabel = describeMacFallbackStage(nextStage);
          camStatusMsg = reason + " Retrying with macOS fallback (" + stageLabel + ")…";
          println("macOS camera fallback engaged (" + stageLabel + ") → " + pipeline);
          return true;
        }
      }
    }
    String tail;
    if (ON_MAC) {
      tail = "Check macOS camera privacy permissions or wake your Continuity Camera device, then restart the sketch.";
    } else if (ON_WINDOWS) {
      tail = "Confirm no other app owns the webcam or try a different USB port, then restart.";
    } else {
      tail = "Check USB power/permissions and restart.";
    }
    camStatusMsg = reason + " (" + tail + ")";
    return false;
  }

  int attempt = camAutoRetryCount + 1;
  camAutoRetryCount = attempt;
  camRetryAtMs = millis() + CAM_RETRY_DELAY_MS;
  camStatusMsg = reason + " Retrying (" + attempt + " / " + CAM_AUTO_RETRY_MAX + ")…";
  println("Scheduling camera retry (attempt " + attempt + " / " + CAM_AUTO_RETRY_MAX + ") in " + CAM_RETRY_DELAY_MS + "ms.");
  return true;
}

String describeMacFallbackStage(int stage) {
  if (stage == 1) return "stage 1 → autovideosrc";
  if (stage == 2) return "stage 2 → explicit avfvideosrc";
  return "stage " + stage;
}

String buildMacPipelineFallback(int stage) {
  if (!ON_MAC) return null;

  if (stage == 1) {
    return
      "pipeline:autovideosrc" +
      " ! queue max-size-buffers=2 leaky=downstream" +
      " ! videoconvert ! video/x-raw,format=RGB";
  }

  if (stage == 2) {
    int index = 0;
    String[] raw = Capture.list();
    if (raw != null && cameraPrimaryName != null) {
      String targetLower = cameraPrimaryName.toLowerCase();
      int looseMatch = -1;
      for (int i = 0; i < raw.length; i++) {
        String entry = raw[i];
        if (entry == null) continue;
        String trimmed = entry.trim();
        if (trimmed.length() == 0) continue;
        if (trimmed.equals(cameraPrimaryName)) { index = i; looseMatch = i; break; }
        String lower = trimmed.toLowerCase();
        if (lower.equals(targetLower)) { looseMatch = i; }
        else if (looseMatch < 0 && lower.contains(targetLower)) { looseMatch = i; }
      }
      if (looseMatch >= 0) index = looseMatch;
    }

    int w = CAM_W > 0 ? CAM_W : 1280;
    int h = CAM_H > 0 ? CAM_H : 720;
    int fps = RECORD_FPS > 0 ? RECORD_FPS : 30;

    String macCaps =
      "video/x-raw,width=" + w +
      ",height=" + h +
      ",framerate=" + fps + "/1";

    return
      "pipeline:avfvideosrc device-index=" + index +
      " ! " + macCaps +
      " ! queue max-size-buffers=2 leaky=downstream" +
      " ! videoconvert ! video/x-raw,format=RGB";
  }
  return null;
}

// ------------------------------
// Buttons & basic UI
// ------------------------------
class Btn {
  String id, label; int x,y,w,h; boolean enabled = true;
  Btn(String id, String label, int x, int y, int w, int h) {
    this.id=id; this.label=label; this.x=x; this.y=y; this.w=w; this.h=h;
  }
  void draw(boolean active) {
    pushStyle();
    stroke(active ? color(255) : color(120));
    if (!enabled) fill(60);
    else fill(active ? color(30,120,40) : color(40,40,40));
    rect(x, y, w, h, 8);
    fill(255); textAlign(CENTER, CENTER); textSize(12);
    text(label, x+w/2, y+h/2);
    popStyle();
  }
  boolean hit(int mx, int my) { return enabled && mx>=x && mx<=x+w && my>=y && my<=y+h; }
}

Btn btnConsent, btnCapture, btnAvatar, btnREC, btnShow, btnDelete;

/**
 * buildButtons() lays out the consent + action buttons at the top of the frame.
 * The copy is intentionally explicit so facilitators can narrate what each control does.
 */
void buildButtons() {
  int pad=8, bw=120, bh=28, x=pad, y=pad;
  btnConsent = new Btn("consent", "Consent: OFF", x, y, bw, bh); x += bw + pad;
  btnCapture = new Btn("capture", "Capture", x, y, bw, bh); x += bw + pad;
  btnAvatar  = new Btn("avatar",  "Avatar: OFF",  x, y, bw, bh); x += bw + pad;
  btnREC     = new Btn("rec",     "REC: OFF",     x, y, bw, bh); x += bw + pad;
  btnShow    = new Btn("show",    "Show my image", x, y, bw, bh); x += bw + pad;
  btnDelete  = new Btn("delete",  "Delete now",    x, y, bw, bh);
  buttons.clear();
  buttons.add(btnConsent); buttons.add(btnCapture); buttons.add(btnAvatar); buttons.add(btnREC);
  buttons.add(btnShow);    buttons.add(btnDelete);
  updateButtonLabels();
}

/**
 * updateButtonLabels() syncs button text/enabled states with the latest consent +
 * hardware conditions. It’s the subtle teacher that keeps reminding folks when
 * actions are blocked (e.g., capture without consent).
 */
void updateButtonLabels() {
  btnConsent.label = "Consent: " + (consent ? "ON" : "OFF");
  if (!consent) {
    btnCapture.label = "Capture (needs consent)";
  } else if (!cameraReadyForProcessing()) {
    btnCapture.label = "Capture (warmup)";
  } else {
    btnCapture.label = "Capture now";
  }
  btnCapture.enabled = consent && cameraReadyForProcessing();
  btnAvatar.label  = "Avatar: "  + (avatarMode ? "ON" : "OFF");
  btnREC.label     = "REC: "     + (recording ? "ON" : "OFF");
  btnShow.enabled  = (lastSavedPath != null);
  btnDelete.enabled= (lastSavedPath != null);
}

/**
 * drawTopButtons() renders the top bar and highlights whichever controls are active.
 */
void drawTopButtons() {
  for (Btn b : buttons) {
    boolean active = (b==btnConsent && consent) || (b==btnAvatar && avatarMode) || (b==btnREC && recording);
    b.draw(active);
  }
}

/**
 * mousePressed() routes clicks either to the modal overlays (if any) or to the top bar.
 * We bail early if a modal is open so workshop participants stay in the current flow.
 */
void mousePressed() {
  // If a modal overlay is active, ignore top-bar clicks
  if (inReview || sessionReviewActive || confirmDelete || viewingLast) return;

  for (Btn b : buttons) {
    if (b.hit(mouseX, mouseY)) {
      if (b == btnConsent) { toggleConsent("Consent ON", "Consent OFF"); return; }
      if (b == btnCapture) { requestSave(); return; }
      if (b == btnAvatar)  { avatarMode = !avatarMode; updateButtonLabels(); return; }
      if (b == btnREC)     { toggleRecording(); updateButtonLabels(); return; }
      if (b == btnShow && lastSavedPath != null)   { showLastSavedOverlay(); return; }
      if (b == btnDelete && lastSavedPath != null) { confirmDeleteLast(); return; }
    }
  }
}

/**
 * toggleConsent() is a sugar helper so button + keyboard handlers can flip consent
 * while reusing the toast copy.
 */
void toggleConsent(String toastOn, String toastOff) {
  setConsent(!consent, toastOn, toastOff);
}

/**
 * setConsent() flips the consent gate and handles the side effects: spinning up the
 * camera, shutting down recording, updating UI, and dropping toasts.
 */
void setConsent(boolean newState, String toastOn, String toastOff) {
  if (consent == newState) {
    if (consent && toastOn != null) toast(toastOn, 1200);
    if (!consent && toastOff != null) toast(toastOff, 1200);
    return;
  }

  consent = newState;

  if (consent) {
    if (toastOn != null) toast(toastOn, 1200);
    startCameraIfNeeded();
  } else {
    if (toastOff != null) toast(toastOff, 1200);
    stopRecording();
    shutdownCamera("Consent is OFF — camera parked.");
  }

  updateButtonLabels();
}

/**
 * startCameraIfNeeded() respects the intent to keep the camera parked until
 * there’s consent and a known device.
 */
void startCameraIfNeeded() {
  if (cam != null || cameraName == null) return;
  startCameraPreferred();
}

/**
 * shutdownCamera() is the full teardown path. We reset state so the next consent
 * toggle starts from a clean slate (no stale detection boxes or recording flags).
 */
void shutdownCamera(String reason) {
  if (cam != null) {
    try { cam.stop(); }
    catch(Exception e) { println("Camera stop error: " + e.getMessage()); }
  }
  cam = null;
  camReady = false;
  camFramesSeen = 0;
  camStartAttemptMs = 0;
  camUsingAutoConfig = false;
  camFallbackAttempted = false;
  camAutoRetryCount = 0;
  camRetryAtMs = 0;
  if (reason != null) camStatusMsg = reason;

  opencv = null;
  opencvW = -1;
  opencvH = -1;

  haveFace = false;
  facePresentStreak = 0;
  faceMissingStreak = 0;
}

// ------------------------------
// PNG Review overlay
// ------------------------------
Btn rvSave = new Btn("rv_save", "Save", 0,0,0,0);
Btn rvDisc = new Btn("rv_disc", "Discard", 0,0,0,0);
boolean confirmDelete = false;
Btn delYes = new Btn("del_yes","Delete",0,0,0,0);
Btn delNo  = new Btn("del_no", "Cancel",0,0,0,0);
boolean viewingLast = false;

/**
 * openReview() flips the PNG review modal on. We store the consent status so the
 * overlay can explain why Save is disabled if consent is still OFF.
 */
void openReview() {
  inReview = true;
  reviewNote = consent ? "Confirm to save image." : "Consent is OFF — turn ON to enable saving.";
}

/**
 * drawReviewOverlay() renders the RAM-only preview and action buttons. This is the
 * heart of the consent conversation — nothing hits disk until Save is clicked.
 */
void drawReviewOverlay() {
  // Dim
  pushStyle(); noStroke(); fill(0, 180); rect(0,0,width,height); popStyle();

  // Panel
  int pw = width - 120, ph = height - 120, px = 60, py = 60;
  pushStyle(); fill(20); stroke(200); rect(px,py,pw,ph,14); popStyle();

  if (reviewFrame != null) image(reviewFrame, px+20, py+20, pw-40, ph-120);

  fill(255); textAlign(LEFT, CENTER); textSize(14);
  text(reviewNote, px+20, py+ph-80);

  int bw=120, bh=32, gap=20;
  rvSave.x = px+pw-bw*2-gap-20; rvSave.y = py+ph-60; rvSave.w=bw; rvSave.h=bh;
  rvDisc.x = px+pw-bw-20;       rvDisc.y = py+ph-60; rvDisc.w=bw; rvDisc.h=bh;
  rvSave.enabled = consent;

  rvSave.draw(false); rvDisc.draw(false);

  if (mousePressed) {
    if (rvSave.enabled && rvSave.hit(mouseX, mouseY)) { commitSave(); }
    else if (rvDisc.hit(mouseX, mouseY)) { cancelReview(); }
  }
}

/**
 * requestSave() is triggered by UI/keyboard. It pulls a frame into RAM (if the camera
 * is ready) and opens the review modal. Serial double-taps reset their timer here too.
 */
void requestSave() {
  if (prepareReviewFrame(false)) {
    lastSaveTapMs = -1;
  }
}

/**
 * commitSave() writes the reviewed PNG to disk and updates cached thumbnails. Consent
 * is double-checked here because the overlay can stay open while someone toggles it off.
 */
void commitSave() {
  if (reviewFrame == null || !consent) { reviewNote = "Consent required to save."; return; }
  String relPath = nextCaptureRelPath();
  if (!saveCaptureImage(reviewFrame, relPath)) {
    reviewNote = "Save failed — check storage.";
    toast("Save failed", 1600);
    return;
  }

  println("Saved PNG: " + relPath);
  lastSavedPath = relPath;
  lastSavedFull = null; // lazy reload on demand (ensures path changes bust cache)
  cacheLastSavedThumb();
  if (PRUNE_OLD_PNG) pruneCaptures();
  inReview = false; reviewFrame = null;
  updateButtonLabels();
  toast("Saved", 1200);
}

/**
 * cancelReview() dismisses the modal without writing anything. We also clear the
 * serial double-tap state so an Arduino tap sequence doesn’t leak across attempts.
 */
void cancelReview() {
  inReview = false;
  reviewFrame = null;
  reviewOpenedFromSerial = false;
}

// ------------------------------
// Session Review overlay (MP4 Keep/Discard with timeout)
// ------------------------------
/**
 * drawSessionReviewOverlay() is the post-recording modal. Facilitators get a countdown
 * to confirm the MP4, otherwise we auto-delete as part of the privacy promise.
 */
void drawSessionReviewOverlay() {
  // Auto-delete if timed out
  if (millis() > sessionReviewDeadlineMs) {
    deleteSessionFile(sessionReviewPath, "Session not confirmed → deleted");
    sessionReviewActive = false;
    sessionReviewPath = null;
    sessionReviewIsFrameStack = false;
    sessionReviewFallbackNote = null;
    return;
  }

  // Dim + panel
  pushStyle(); noStroke(); fill(0,180); rect(0,0,width,height); popStyle();
  int pw= width - 120, ph = 220, px = 60, py = (height - ph)/2;
  pushStyle(); fill(20); stroke(200); rect(px,py,pw,ph,14); popStyle();

  // Text
  fill(255); textAlign(LEFT, TOP); textSize(14);
  int remaining = int((sessionReviewDeadlineMs - millis())/1000.0);
  String header = sessionReviewIsFrameStack ? "Keep this session capture?" : "Keep this session video?";
  String detail = sessionReviewIsFrameStack ? "Frames: " + sessionReviewPath : "File: " + sessionReviewPath;
  String auto = "Auto-delete in: " + remaining + "s";
  StringBuilder overlay = new StringBuilder();
  overlay.append(header).append("\n").append(detail).append("\n").append(auto);
  if (sessionReviewIsFrameStack) {
    overlay.append("\nConvert via README inside that folder.");
  }
  if (sessionReviewFallbackNote != null && sessionReviewFallbackNote.length() > 0) {
    overlay.append("\nReason: ").append(sessionReviewFallbackNote);
  }
  text(overlay.toString(), px+20, py+20);

  // Buttons
  int bw=140, bh=32, gap=20;
  sessKeep.x = px+pw-bw*2-gap-20; sessKeep.y = py+ph-60; sessKeep.w=bw; sessKeep.h=bh;
  sessDiscard.x = px+pw-bw-20;    sessDiscard.y = py+ph-60; sessDiscard.w=bw; sessDiscard.h=bh;
  sessKeep.draw(false); sessDiscard.draw(false);

  if (mousePressed) {
    if (sessKeep.hit(mouseX, mouseY)) {
      toast("Session kept", 1200);
      sessionReviewActive = false;
      sessionReviewPath = null;
      sessionReviewIsFrameStack = false;
      sessionReviewFallbackNote = null;
    } else if (sessDiscard.hit(mouseX, mouseY)) {
      deleteSessionFile(sessionReviewPath, "Session discarded");
      sessionReviewActive = false;
      sessionReviewPath = null;
      sessionReviewIsFrameStack = false;
      sessionReviewFallbackNote = null;
    }
  }
}

void deleteSessionFile(String path, String msg) {
  if (path == null) return;
  File f = new File(sketchPath(path));
  boolean ok = deleteRecursive(f);
  println((ok? "Deleted: " : "Delete failed: ") + path);
  toast(msg + (ok? "" : " (delete failed)"), 1600);
}

boolean deleteRecursive(File target) {
  if (target == null) return true;
  if (!target.exists()) return true;
  if (target.isDirectory()) {
    File[] kids = target.listFiles();
    if (kids != null) {
      for (File k : kids) {
        if (!deleteRecursive(k)) return false;
      }
    }
  }
  return target.delete();
}

void showLastSavedOverlay() {
  if (lastSavedPath != null) {
    viewingLast = true;
  }
}

/**
 * confirmDeleteLast() opens the "are you sure" dialog for deleting the last PNG.
 */
void confirmDeleteLast() {
  if (lastSavedPath == null) return;
  confirmDelete = true;
}

/**
 * drawDeleteConfirm() is the modal that lets someone back out or nuke their image forever.
 */
void drawDeleteConfirm() {
  pushStyle(); noStroke(); fill(0,180); rect(0,0,width,height); popStyle();
  int pw=420, ph=160, px=(width-pw)/2, py=(height-ph)/2;
  pushStyle(); fill(20); stroke(200); rect(px,py,pw,ph,12); popStyle();
  fill(255); textAlign(CENTER, CENTER); textSize(14);
  text("Delete last saved image?\\nThis cannot be undone.", px+pw/2, py+50);

  int bw=120, bh=32, gap=20;
  delYes.x = px+pw/2 - gap - bw; delYes.y = py+ph-50; delYes.w=bw; delYes.h=bh;
  delNo.x  = px+pw/2 + gap;      delNo.y  = py+ph-50; delNo.w=bw;  delNo.h=bh;
  delYes.draw(false); delNo.draw(false);

  if (mousePressed) {
    if (delYes.hit(mouseX, mouseY)) { deleteLastSaved(); confirmDelete=false; }
    if (delNo.hit(mouseX, mouseY))  { confirmDelete=false; }
  }
}

/**
 * drawShowLast() renders the “show me my image” modal, complete with a manual close box.
 */
void drawShowLast() {
  pushStyle(); noStroke(); fill(0,180); rect(0,0,width,height); popStyle();
  int pw = width - 120, ph = height - 120, px = 60, py = 60;
  pushStyle(); fill(20); stroke(200); rect(px,py,pw,ph,14); popStyle();

  PImage img = ensureLastSavedFull();
  if (img != null) {
    image(img, px+20, py+20, pw-40, ph-80);
  } else {
    fill(255, 120, 120);
    textAlign(CENTER, CENTER);
    textSize(16);
    text("Couldn't load last saved image.\nCheck that the capture still exists.", px+pw/2, py+ph/2);
    textAlign(LEFT, CENTER);
  }

  fill(255); textAlign(LEFT, CENTER); textSize(12);
  text("Viewing: " + lastSavedPath, px+20, py+ph-40);

  // Close "X"
  pushStyle(); noFill(); stroke(255); rect(px+pw-40, py+20, 20, 20, 4);
  line(px+pw-36, py+24, px+pw-24, py+36);
  line(px+pw-36, py+36, px+pw-24, py+24); popStyle();

  if (mousePressed) {
    if (mouseX >= px+pw-40 && mouseX <= px+pw-20 && mouseY >= py+20 && mouseY <= py+40) viewingLast = false;
  }
}

/**
 * cacheLastSavedThumb() keeps a small copy around for the top-bar button preview.
 */
void cacheLastSavedThumb() {
  if (lastSavedPath == null) { lastSavedThumb=null; return; }
  PImage img = loadImageSafe(lastSavedPath);
  if (img != null) { lastSavedThumb = img.copy(); lastSavedThumb.resize(160, 160); }
}

/**
 * deleteLastSaved() nukes the on-disk PNG and clears UI caches. This is a manual
 * consent revocation moment, so we surface a toast confirming the result.
 */
void deleteLastSaved() {
  if (lastSavedPath == null) return;
  File f = new File(sketchPath(lastSavedPath));
  boolean ok = f.delete();
  println(ok ? "Deleted: " + lastSavedPath : "Delete failed: " + lastSavedPath);
  lastSavedPath = null; lastSavedThumb = null; lastSavedFull = null; updateButtonLabels();
  toast(ok ? "Deleted" : "Delete failed", 1200);
}

/**
 * ensureLastSavedFull() lazily loads the full-resolution capture. We only hit disk when
 * the modal is opened to keep the main loop snappy.
 */
PImage ensureLastSavedFull() {
  if (lastSavedPath == null) { lastSavedFull = null; return null; }
  if (lastSavedFull != null) return lastSavedFull;
  lastSavedFull = loadImageSafe(lastSavedPath);
  return lastSavedFull;
}

/**
 * loadImageSafe() wraps Processing’s loadImage() to add logging and null-guarded paths.
 */
PImage loadImageSafe(String relPath) {
  if (relPath == null) return null;
  String fullPath = sketchPath(relPath);
  if (fullPath == null) return null;
  PImage img = loadImage(fullPath);
  if (img == null) {
    println("loadImage failed for: " + fullPath);
  }
  return img;
}

// ------------------------------
// Serial (Arduino Uno w/ pin 13 pull-up switch)
// ------------------------------
/**
 * setupSerial() enumerates serial ports, picks the likely Arduino, and attaches a
 * newline-buffered listener. If nothing is connected we log the fallback path.
 */
void setupSerial() {
  String[] rawPorts = Serial.list();
  String[] ports = dedupeStringsCaseInsensitive(rawPorts);
  if (ports == null || ports.length == 0) {
    println("No serial ports found — keyboard/mouse controls stay live. Plug in the workshop Arduino and restart when ready.");
    return;
  }
  if (rawPorts != null && ports.length != rawPorts.length) {
    println("Serial list deduped (" + rawPorts.length + " → " + ports.length + ") to hide driver clones.");
  }
  println("Serial ports:");
  for (int i=0;i<ports.length;i++) println("  ["+i+"] "+ports[i]);

  int pick=-1;
  for (int i=0;i<ports.length;i++) if (ports[i].toLowerCase().matches(".*(" + SERIAL_HINT + ").*")) { pick=i; break; }
  if (pick==-1) pick=0;
  println("Connecting to: " + ports[pick]);
  try { ard = new Serial(this, ports[pick], SERIAL_BAUD); ard.bufferUntil('\n'); }
  catch(Exception e){ println("Serial error: "+e.getMessage()); ard=null; }
}

/**
 * serialEvent() consumes Arduino button gestures and maps them to the consent workflow.
 * SAVE vs SAVE_DBL mirrors the Processing UI flow so facilitators can swap between
 * hardware and keyboard without confusion.
 */
void serialEvent(Serial s) {
  String line = s.readStringUntil('\n');
  if (line == null) return;
  line = trim(line);
  if (line.length()==0) return;
  String u = line.toUpperCase();

  if (u.equals("CONSENT_TOGGLE")) {
    toggleConsent("Consent ON (via Arduino)", "Consent OFF (via Arduino)");
    return;
  }

  if (u.equals("SAVE") || u.equals("S") || u.equals("1") || u.equals("SAVE_DBL")) {
    int now = millis();
    boolean dblExplicit = u.equals("SAVE_DBL");

    if (dblExplicit || (reviewOpenedFromSerial && (now - lastSaveTapMs) <= DOUBLE_TAP_MS)) {
      if (consent) {
        if (inReview && reviewFrame != null) {
          commitSave(); // confirm the first-tap preview
        } else {
          if (!cameraReadyForProcessing()) {
            toast("Camera is still waking up.", 1500);
            reviewOpenedFromSerial = false;
            lastSaveTapMs = -1;
            return;
          }
          PImage snap = composite.get();
          String relPath = nextCaptureRelPath();
          if (saveCaptureImage(snap, relPath)) {
            println("Saved PNG: " + relPath);
            lastSavedPath = relPath;
            cacheLastSavedThumb();
            updateButtonLabels();
          } else {
            toast("Save failed", 1600);
          }
        }
        toast("Saved (double-press)", 1500);
      } else {
        if (!inReview) { requestSaveFromSerialTap(); }
        reviewNote = "Consent is OFF — cannot auto-save. Review only.";
        toast("Consent OFF → not saved", 1500);
      }
      reviewOpenedFromSerial = false;
      lastSaveTapMs = -1;
      return;
    }

    // First press: capture & open Review (RAM only)
    requestSaveFromSerialTap();
    return;
  }

  if (u.equals("REC START")) { startRecording(); updateButtonLabels(); return; }
  if (u.equals("REC STOP"))  { stopRecording();  updateButtonLabels(); return; }
  if (u.equals("REC") || u.equals("R")) { toggleRecording(); updateButtonLabels(); return; }

  println("Unrecognized serial command: ["+line+"]");
}

/**
 * requestSaveFromSerialTap() is the Arduino twin of requestSave(). We track timestamps
 * so the next tap can promote the action to a double-press auto-save (when allowed).
 */
void requestSaveFromSerialTap() {
  if (prepareReviewFrame(true)) {
    lastSaveTapMs = millis();
  } else {
    lastSaveTapMs = -1;
  }
}

/**
 * prepareReviewFrame() copies the current composite into reviewFrame and opens the modal.
 * When called from serial we record that fact so double-press logic can respond.
 */
boolean prepareReviewFrame(boolean fromSerial) {
  if (!cameraReadyForProcessing()) {
    String msg = consent ? "Camera is still waking up." : "Consent OFF → camera parked.";
    toast(msg, 1500);
    reviewOpenedFromSerial = false;
    return false;
  }

  reviewFrame = composite.get();
  openReview();
  reviewOpenedFromSerial = fromSerial;
  return true;
}

String nextCaptureRelPath() {
  return "captures/face-" + timestamp(true) + ".png";
}

boolean saveCaptureImage(PImage img, String relPath) {
  if (img == null || relPath == null) return false;

  String absPath = sketchPath(relPath);
  if (absPath == null) {
    println("Save failed — sketchPath returned null for " + relPath);
    return false;
  }

  File outFile = new File(absPath);
  File parent = outFile.getParentFile();
  if (parent != null && !parent.exists()) {
    boolean ok = parent.mkdirs();
    if (!ok && !parent.exists()) {
      println("Save failed — couldn't create directory: " + parent.getAbsolutePath());
      return false;
    }
  }

  try {
    img.save(absPath);
    return true;
  } catch(Exception e) {
    println("Save failed — " + e.getMessage());
    return false;
  }
}

/**
 * drawToast() paints the floating message bar in the lower center of the frame.
 * Toasts fade automatically once their deadline hits.
 */
void drawToast() {
  if (toastMsg == null) return;
  if (millis() >= toastUntilMs) { toastMsg = null; return; }

  pushStyle();
  String msg = toastMsg;
  textSize(12);
  int tw = (int)textWidth(msg) + 24;
  int th = 26;
  int x = (width - tw)/2;
  int y = height - th - 18;
  noStroke(); fill(0, 180); rect(x, y, tw, th, 8);
  fill(255); textAlign(CENTER, CENTER); text(msg, x + tw/2, y + th/2);
  popStyle();
}

/**
 * toast() queues a message for drawToast(). We store the future expiry so it self-clears.
 */
void toast(String msg, int ms) {
  toastMsg = msg;
  toastUntilMs = millis() + ms;
}

// ------------------------------
// Recording
// ------------------------------
boolean recorderReady() {
  return ve != null || frameStackRecorder != null;
}

/**
 * toggleRecording() flips between start/stop recording. A helper so UI + serial share code.
 */
void toggleRecording(){ if (recording) stopRecording(); else startRecording(); }

/**
 * startRecording() opens a new MP4 session file. Consent still gates writes later, so we
 * start the file immediately but rely on the frame gate to keep it empty if folks decline.
 */
void startRecording() {
  if (recording) return;
  recordingBaseName = "sessions/session-" + timestamp(false);
  recordingFile = recordingBaseName + ".mp4";
  framesWrittenThisSession = 0;
  recordingFallbackNote = null;
  frameStackRecorder = null;
  sessionReviewFallbackNote = null;

  try {
    ve = new VideoExport(this, recordingFile);
    ve.setFrameRate(RECORD_FPS);
    ve.startMovie();
    recording = true;
    println("Recording STARTED → " + recordingFile + " (writes require Consent)");
    return;
  } catch(Throwable e){
    String reason = e.getClass().getSimpleName();
    if (e.getMessage() != null && e.getMessage().length() > 0) reason += ": " + e.getMessage();
    println("VideoExport unavailable → " + reason);
    recordingFallbackNote = reason;
    ve = null;
  }

  // Fallback: keep workshop momentum by buffering PNG frames on disk.
  recordingFile = recordingBaseName + "-frames";
  try {
    frameStackRecorder = new FrameStackRecorder(this, recordingBaseName, RECORD_FPS, recordingFallbackNote);
    recordingFile = frameStackRecorder.reviewPath();
    recording = true;
    println("Recording FALLBACK → " + recordingFile + " (PNG frame stack; convert via README)");
    toast("Recording fallback: saving PNG frames", 2200);
  } catch(Exception e) {
    frameStackRecorder = null;
    recordingFile = null;
    recordingBaseName = null;
    recordingFallbackNote = null;
    println("Could not start recording fallback: " + e.getMessage());
    toast("Recording failed — see console", 2000);
  }
}

/**
 * stopRecording() finalizes the MP4, enforces the zero-frame auto-delete, and opens the
 * session review modal so folks can confirm or trash the clip.
 */
void stopRecording() {
  if (!recording) return;
  String stopPath = recordingFile;
  try {
    if (ve!=null) ve.endMovie();
  } catch(Exception e){
    println("Error closing movie: " + e.getMessage());
  }
  try {
    if (frameStackRecorder != null) {
      frameStackRecorder.finish(framesWrittenThisSession > 0);
    }
  } catch(Exception e) {
    println("Error finalizing frame stack: " + e.getMessage());
  } finally {
    println("Recording STOPPED → " + stopPath + " (frames: " + framesWrittenThisSession + ")");
    recording = false;
    sessionReviewIsFrameStack = false;
    // Post-stop policy: if 0 frames written, auto-delete. Else, require Keep confirmation.
    if (recordingFile != null) {
      if (framesWrittenThisSession <= 0) {
        deleteSessionFile(recordingFile, "Empty session → deleted");
        sessionReviewFallbackNote = null;
        recordingFile = null;
      } else {
        sessionReviewActive = true;
        sessionReviewPath = recordingFile;
        sessionReviewIsFrameStack = (frameStackRecorder != null);
        sessionReviewFallbackNote = sessionReviewIsFrameStack ? recordingFallbackNote : null;
        sessionReviewDeadlineMs = millis() + SESSION_REVIEW_TIMEOUT_MS;
        toast(sessionReviewIsFrameStack ? "Review capture: Keep or Discard" : "Review session: Keep or Discard", 1500);
        recordingFile = null;
      }
    }
    ve=null;
    frameStackRecorder = null;
    recordingBaseName = null;
    recordingFallbackNote = null;
  }
}

// ------------------------------
// Keyboard
// ------------------------------
/**
 * keyPressed() mirrors the button/serial controls so laptops without the Arduino rig
 * still get the full experience. We intentionally map each action to a loud, mnemonic key.
 */
void keyPressed() {
  if (key == 's' || key=='S') requestSave();
  if (key == 'y' || key=='Y') { if (inReview && consent) commitSave(); }
  if (key == 'n' || key=='N') { if (inReview) cancelReview(); }

  if (key == 'v' || key=='V') { toggleRecording(); updateButtonLabels(); }
  if (key == 'c' || key=='C') { toggleConsent("Consent ON", "Consent OFF"); }
  if (key == 'm' || key=='M') mirrorPreview = !mirrorPreview;
  if (key == 'd' || key=='D') debugOverlay = !debugOverlay;
  if (key == 'f' || key=='F') useFeather = !useFeather;
  if (key == 'g' || key=='G') gateOnFace = !gateOnFace;
  if (key == 't' || key=='T') autoRecOnFace = !autoRecOnFace;

  if (key == 'A') { avatarMode = !avatarMode; updateButtonLabels(); }
  if (key == 'N') { avatarSeed = System.nanoTime(); avatarRng = new Random(avatarSeed); }

  if (key == 'o' || key=='O') { showLastSavedOverlay(); }
  if (keyCode == DELETE || keyCode == BACKSPACE) { confirmDeleteLast(); }
}

// ------------------------------
// Teaching UI bits
// ------------------------------
/**
 * drawUIBackplates() lays down translucent panels so the teaching text stays legible
 * regardless of how wild the slug art or lighting gets.
 */
void drawUIBackplates() {
  // Keep the teaching overlay legible even when the slug art is loud.
  pushStyle();
  noStroke();
  fill(0, 180);
  int topBarH = 28 + 16; // button height + breathing room
  rect(0, 0, width, topBarH);

  int mapPad = 12;
  int mapBoxH = 56;
  rect(0, topBarH, 280, mapBoxH + mapPad);
  popStyle();
}

/**
 * drawDataFlowMap() prints the core consent flow in the corner. It’s the quick reference
 * folks can point to during discussion.
 */
void drawDataFlowMap() {
  int x = 8, y = 8 + 28 + 8;
  pushStyle();
  textAlign(LEFT, TOP); textSize(12); fill(220);
  String flow = "Camera → Detect (RAM) → Review [Save | Discard]";
  text(flow, x, y+8);
  noStroke();
  fill(100,200,255); ellipse(x-4, y+12, 6, 6);
  fill(150,255,150); ellipse(x-4, y+26, 6, 6);
  fill(255,220,120); ellipse(x-4, y+40, 6, 6);
  popStyle();
}

/**
 * drawRECIndicator() shows both the REC light and whether frames are actually being written.
 * The concentric ring only appears if the consent + face gates are satisfied.
 */
void drawRECIndicator() {
  boolean writing = (recording && consent && (!gateOnFace || haveFace || avatarMode) && recorderReady());
  pushStyle();
  fill(255,0,0); noStroke(); ellipse(18, 18, 14, 14);
  if (writing) { noFill(); stroke(255,0,0); strokeWeight(2); ellipse(18,18,20,20); }
  fill(255); textSize(12); textAlign(LEFT, CENTER);
  String recLabel = "REC" + (gateOnFace ? " (gated)" : "");
  if (recording && frameStackRecorder != null) {
    recLabel += " — PNG fallback";
  }
  text(recLabel, 28, 18);
  // Consent badge
  fill(consent ? color(40,180,70) : color(120));
  noStroke(); rect(70,10, 58,16,4); fill(255); textSize(10); textAlign(CENTER,CENTER);
  text(consent ? "CONSENT ON" : "CONSENT OFF", 70+29, 10+8);
  popStyle();
}

/**
 * drawDebugPIP() renders a mini picture-in-picture with the raw camera feed. Useful for
 * facilitators troubleshooting framing, mirroring, or detection slop.
 */
void drawDebugPIP() {
  PImage camPrev = cam;
  if (mirrorPreview) camPrev = mirrorImage(camPrev);
  int w = 240; int h = int(w * (float)camPrev.height / camPrev.width);
  image(camPrev, width - w - 12, height - h - 12, w, h);
  if (haveFace) {
    pushStyle(); noFill(); stroke(255,200); strokeWeight(2);
    float sx = (float)w / cam.width, sy = (float)h / cam.height;
    float px = width - w - 12 + (mirrorPreview ? (cam.width - cx) * sx : cx * sx);
    float py = height - h - 12 + cy * sy;
    ellipse(px, py, 16, 16); popStyle();
  }
}

// ------------------------------
// Face smoothing helpers
// ------------------------------
/**
 * pickLargest() selects the biggest detected face — a crude but effective heuristic for
 * single-subject workshops.
 */
Rectangle pickLargest(Rectangle[] faces) {
  if (faces == null || faces.length == 0) return null;
  Rectangle best = null; float area=-1;
  for (Rectangle r : faces) { float a=r.width*r.height; if (a>area) {area=a; best=r;} }
  return best;
}

/**
 * updateFaceSmoothing() eases face positions toward the latest detection. It also tracks
 * streaks so auto-record knows when someone has left the frame.
 */
void updateFaceSmoothing(Rectangle chosen) {
  if (avatarMode) { haveFace=false; faceMissingStreak++; facePresentStreak=0; return; }
  if (chosen != null) {
    haveFace = true; facePresentStreak++; faceMissingStreak=0;
    float fx = chosen.x + chosen.width*0.5f;
    float fy = chosen.y + chosen.height*0.5f;
    float s  = max(chosen.width, chosen.height) * SQUARE_SCALE;
    float half = s*0.5f;
    fx = constrain(fx, half, cam.width - half);
    fy = constrain(fy, half, cam.height - half);
    if (cx < 0) { cx = fx; cy = fy; side = s; }
    else {
      cx = lerp(cx, fx, SMOOTH_FACTOR);
      cy = lerp(cy, fy, SMOOTH_FACTOR);
      side = lerp(side, s, SMOOTH_FACTOR);
    }
  } else {
    faceMissingStreak++;
    boolean recentlySeen = (facePresentStreak > 0);
    if (recentlySeen && faceMissingStreak <= FACE_MISSING_GRACE_FRAMES) {
      haveFace = true;
    } else {
      haveFace = false;
      facePresentStreak = 0;
    }
  }
}

// ------------------------------
// Avatar (procedural geometric portrait)
// ------------------------------
/**
 * drawAvatar() is the privacy-friendly alt identity: a stack of jittered polygons whose
 * randomness is seeded so participants can remix but also reset deterministically.
 */
void drawAvatar(PGraphics g, Random rng) {
  g.pushStyle();
  g.noStroke(); g.fill(0, 60); g.ellipse(g.width/2f, g.height/2f, g.width*0.9f, g.height*0.9f);

  int layers = 7;
  float base = min(g.width, g.height)*0.35f;
  rng.setSeed(avatarSeed);
  for (int i=0;i<layers;i++) {
    float r   = base * (1.0f - i/(float)layers) * (0.85f + 0.3f*rng.nextFloat());
    int sides = 3 + rng.nextInt(6);
    float rot = rng.nextFloat()*TWO_PI;
    int   cnt = 1 + rng.nextInt(3);
    for (int k=0;k<cnt;k++) {
      float rr = r * (0.9f + 0.18f*rng.nextFloat());
      g.noFill();
      g.strokeWeight(2 + rng.nextInt(3));
      g.stroke(180 + rng.nextInt(70));
      polygon(g, g.width/2f, g.height/2f, rr, sides, rot + k*0.15f);
    }
  }
  g.noStroke(); g.fill(230); g.ellipse(g.width/2f, g.height/2f, 28, 28);
  g.fill(60);  g.ellipse(g.width/2f, g.height/2f, 12, 12);

  if (useFeather) {
    PImage snap = g.get(); snap.mask(featherMask); g.image(snap, 0, 0);
  }
  g.popStyle();
}

/**
 * polygon() is a helper that draws regular polygons with optional rotation.
 */
void polygon(PGraphics g, float cx, float cy, float r, int sides, float rot) {
  g.beginShape();
  for (int i=0;i<sides;i++) {
    float a = rot + TWO_PI * i / sides;
    g.vertex(cx + cos(a)*r, cy + sin(a)*r);
  }
  g.endShape(CLOSE);
}

// ------------------------------
// Helpers
// ------------------------------
/**
 * mirrorImage() flips a frame horizontally — the "selfie view" everyone expects.
 */
PImage mirrorImage(PImage src) {
  PImage out = createImage(src.width, src.height, src.format);
  src.loadPixels(); out.loadPixels();
  for (int y=0; y<src.height; y++) {
    int row = y*src.width;
    for (int x=0; x<src.width; x++) out.pixels[row+x] = src.pixels[row + (src.width-1-x)];
  }
  out.updatePixels();
  return out;
}

class FrameStackRecorder {
  final PApplet app;
  final String dirRel;
  final int fps;
  final String fallbackReason;
  int frameIndex = 0;

  FrameStackRecorder(PApplet parent, String baseName, int fps, String reason) {
    this.app = parent;
    this.dirRel = baseName + "-frames";
    this.fps = fps;
    this.fallbackReason = reason;
    ensureDir();
  }

  void ensureDir() {
    File dir = new File(app.sketchPath(dirRel));
    if (!dir.exists() && !dir.mkdirs()) {
      throw new RuntimeException("Could not create frame stack directory: " + dir.getAbsolutePath());
    }
  }

  void saveFrame(PImage frame) {
    if (frame == null) frame = app.get();
    String filename = String.format("%s/frame-%05d.png", dirRel, frameIndex++);
    frame.save(app.sketchPath(filename));
  }

  void finish(boolean hasFrames) {
    if (!hasFrames) {
      discard();
      return;
    }
    writeReadme();
  }

  void writeReadme() {
    File dir = new File(app.sketchPath(dirRel));
    if (!dir.exists()) return;
    String readmePath = app.sketchPath(dirRel + "/README.txt");
    PrintWriter out = app.createWriter(readmePath);
    out.println("Frame stack fallback engaged because MP4 export failed.");
    if (fallbackReason != null && fallbackReason.length() > 0) {
      out.println("Reason: " + fallbackReason);
    }
    out.println();
    out.println("This folder holds sequential PNG frames. Convert them to a video with ffmpeg:");
    out.println("  ffmpeg -framerate " + fps + " -i frame-%05d.png -c:v libx264 -pix_fmt yuv420p session.mp4");
    out.println();
    out.println("Run the command above from inside " + dirRel + ".");
    out.flush();
    out.close();
  }

  void discard() {
    deleteRecursive(new File(app.sketchPath(dirRel)));
  }

  String reviewPath() { return dirRel; }
}

/**
 * fallbackSlug() synthesizes a gentle gradient when the slug art is missing. Keeps the
 * workshop rolling even if assets weren’t copied over.
 */
PImage fallbackSlug() {
  println("WARNING: Could not load " + SLUG_FILENAME + " — using generated gradient.");
  PImage img = createImage(64, 64, RGB);
  img.loadPixels();
  for (int y=0; y<img.height; y++) for (int x=0; x<img.width; x++) {
    float u = map(y, 0, img.height-1, 0, 1);
    img.pixels[y*img.width+x] = lerpColor(color(30,30,30), color(80,80,120), u);
  }
  img.updatePixels();
  return img;
}

/**
 * makeRadialFeatherMask() builds a reusable alpha mask so the face crop eases into the slug.
 */
PImage makeRadialFeatherMask(int w, int h, float innerRadius, float featherPx) {
  PImage m = createImage(w, h, ALPHA); m.loadPixels();
  float cx = w*0.5f, cy = h*0.5f, outer = innerRadius + featherPx;
  float inner2 = innerRadius*innerRadius, outer2 = outer*outer;
  for (int y=0; y<h; y++) {
    float dy = y - cy;
    for (int x=0; x<w; x++) {
      float dx = x - cx, r2 = dx*dx + dy*dy;
      float a;
      if (r2 <= inner2) a = 255;
      else if (r2 >= outer2) a = 0;
      else { float r = sqrt(r2); float t=(r - innerRadius)/featherPx; a = 255*(1.0f - t); }
      m.pixels[y*w+x] = (int)a;
    }
  }
  m.updatePixels(); return m;
}

/**
 * inferPrimaryCameraName() keeps a human-friendly device label around even when we fall
 * back to pipeline-based capture strings. macOS fallback stages lean on it to select
 * the correct device index.
 */
String inferPrimaryCameraName(String chosen) {
  if (chosen != null && !chosen.toLowerCase().startsWith("pipeline:")) return chosen;

  String[] raw = Capture.list();
  String[] cams = dedupeStringsCaseInsensitive(raw);
  if (cams == null || cams.length == 0) return null;

  for (String c : cams) {
    if (c == null) continue;
    String trimmed = c.trim();
    if (trimmed.length() == 0) continue;
    if (!trimmed.toLowerCase().startsWith("pipeline:")) return trimmed;
  }
  return null;
}

/**
 * pickCamera() dedupes OS camera listings and returns the best match. USB Video Device is
 * the usual suspect on Windows, but we fall back to the first camera otherwise.
 */
String pickCamera() {
  String[] raw = Capture.list();
  String[] cams = dedupeStringsCaseInsensitive(raw);
  if (cams == null || cams.length == 0) {
    if (ON_LINUX) {
      println("Camera list empty — defaulting to pipeline:autovideosrc (GStreamer auto source).");
      return "pipeline:autovideosrc";
    }
    return null;
  }
  if (raw != null && cams.length != raw.length) {
    println("Camera list deduped (" + raw.length + " → " + cams.length + ") to avoid ghost entries.");
  }

  if (ON_MAC) {
    String[] macPrefs = {
      "facetime hd",
      "continuity camera",
      "iphone",
      "obs virtual"
    };
    for (String pref : macPrefs) {
      for (String c : cams) {
        if (c.toLowerCase().contains(pref)) {
          return c;
        }
      }
    }
  } else if (ON_WINDOWS) {
    String[] winPrefs = {
      "usb video device",
      "integrated webcam",
      "hd webcam"
    };
    for (String pref : winPrefs) {
      for (String c : cams) {
        if (c.toLowerCase().contains(pref)) {
          return c;
        }
      }
    }
  }

  for (String c : cams) if (c.toLowerCase().contains("pipeline:")) return c;
  for (String c : cams) if (c.toLowerCase().contains("1280x720"))  return c;
  for (String c : cams) if (c.toLowerCase().contains("1920x1080")) return c;

  if (ON_LINUX) {
    println("No explicit Linux camera match — defaulting to pipeline:autovideosrc.");
    return "pipeline:autovideosrc";
  }

  return cams[0];
}

String cameraWarmupHelpMessage() {
  if (ON_WINDOWS) {
    return "Windows' ksvideosrc (0x00000020) warning usually means another app owns the camera\nor the driver rejected the requested resolution. Unplug/replug or close other capture apps.";
  }
  if (ON_MAC) {
    return "macOS might still be waiting for you to grant camera access. Hit System Settings → Privacy & Security → Camera and enable Processing. If you're leaning on Continuity Camera, wake the phone.";
  }
  return "If the camera never wakes, close other capture apps and double-check USB power or permissions.";
}

/**
 * dedupeStringsCaseInsensitive() collapses duplicate device names so Windows’ ghost
 * entries don’t spam the UI. Preserves original casing for nicer logs.
 */
String[] dedupeStringsCaseInsensitive(String[] input) {
  if (input == null) return null;
  ArrayList<String> clean = new ArrayList<String>();
  HashSet<String> seen = new HashSet<String>();
  for (String raw : input) {
    if (raw == null) continue;
    String trimmed = raw.trim();
    String key = trimmed.toLowerCase();
    if (!seen.contains(key)) {
      seen.add(key);
      clean.add(trimmed);
    }
  }
  return clean.toArray(new String[clean.size()]);
}

/**
 * timestamp() returns sortable filenames. We optionally tack on milliseconds so PNG
 * double-presses don’t collide.
 */
String timestamp(boolean includeMillis) {
  String t = nf(year(),4)+nf(month(),2)+nf(day(),2)+"-"+nf(hour(),2)+nf(minute(),2)+nf(second(),2);
  if (includeMillis) t += "-" + nf(millis()%1000,3);
  return t;
}

/**
 * pruneCaptures() keeps disk usage chill by trimming oldest PNGs once KEEP_MAX_PNG is hit.
 */
void pruneCaptures() {
  File dir = new File(sketchPath("captures"));
  File[] files = dir.listFiles((d,f)->f.toLowerCase().endsWith(".png"));
  if (files == null || files.length <= KEEP_MAX_PNG) return;
  Arrays.sort(files, (a,b)->Long.compare(a.lastModified(), b.lastModified()));
  int toDelete = files.length - KEEP_MAX_PNG;
  for (int i=0;i<toDelete;i++) files[i].delete();
}

// ------------------------------
// Cleanup
// ------------------------------
/**
 * dispose() is Processing’s shutdown hook. We stop recording, park the camera, and
 * close serial so the OS doesn’t think another app is hogging the gear.
 */
void dispose() {
  stopRecording();
  shutdownCamera(null);
  if (ard!=null) ard.stop();
}
