/**
 * ConsentDetect — consent-first face detection teaching sketch.
 * -------------------------------------------------------------
 * Cameras stay parked until someone explicitly says "yes".
 * Captures live in RAM until confirmed, and on-disk PNGs auto-expire.
 * The overlay shows bounding-box math instead of identity guesses.
 *
 * Controls:
 *   c / click CONSENT badge : toggle consent gate (camera on/off)
 *   space                   : capture preview (RAM only)
 *   y / n                   : save or discard during review
 *   o                       : toggle "See the math" detection overlay
 */

import processing.video.*;
import gab.opencv.*;

import java.awt.Rectangle;
import java.io.File;

// -------------------------------------------------------------
// Configuration knobs
// -------------------------------------------------------------
final int    CAM_W                 = 1280;
final int    CAM_H                 = 720;
final int    FRAME_RATE            = 30;
final int    CAPTURE_TTL_MS        = 5 * 60 * 1000; // 5 minutes
final int    PRUNE_INTERVAL_MS     = 30 * 1000;     // sweep for expired captures
final int    CAMERA_TIMEOUT_MS     = 3000;          // fallback to default profile
final String CAM_PREFERRED_HINT    = "usb video device";
final String CAPTURE_PREFIX        = "captures/consent-";

// -------------------------------------------------------------
// Camera + detection state
// -------------------------------------------------------------
Capture  cam;
OpenCV   opencv;
int      opencvW            = -1;
int      opencvH            = -1;
String   cameraName         = null;
boolean  camReady           = false;
boolean  camUsingAutoConfig = false;
boolean  camFallbackAttempt = false;
long     camStartAttemptMs  = 0;
int      camFramesSeen      = 0;
String   camStatusMsg       = "Consent OFF — camera parked.";
Rectangle[] detections      = new Rectangle[0];

// -------------------------------------------------------------
// Consent + review state
// -------------------------------------------------------------
boolean consent       = false;
boolean showMath      = false;
boolean inReview      = false;
PImage  reviewFrame   = null;

// -------------------------------------------------------------
// UI helpers
// -------------------------------------------------------------
Rectangle consentBtn = new Rectangle(16, 16, 190, 44);
String    reviewNote = "";
String    toastMsg    = null;
long      toastUntil  = 0;
int       activeCaptures = 0;
long      lastPruneMs     = 0;
PFont     uiFont;

// -------------------------------------------------------------
// Lifecycle
// -------------------------------------------------------------
void settings() {
  size(CAM_W, CAM_H);
}

void setup() {
  surface.setTitle("ConsentDetect — consent-first face detection");
  frameRate(FRAME_RATE);
  uiFont = createFont("SansSerif", 16, true);
  textFont(uiFont);
  textAlign(LEFT, TOP);

  cameraName = pickCamera();
  if (cameraName == null) {
    println("No camera found. Exiting.");
    exit();
  }
  println("Using camera: " + cameraName);

  new File(sketchPath("captures")).mkdirs();
  pruneExpiredCaptures();
  lastPruneMs = millis();

  println("Controls: [c] consent, [space] capture, [y/n] review, [o] math overlay");
}

void draw() {
  background(18);

  updateCameraStartupState();
  maybePruneExpiredCaptures();

  if (!consent) {
    drawParkedScreen();
    drawUI();
    drawToast();
    return;
  }

  if (cam == null) {
    drawCameraStatus();
    drawUI();
    drawToast();
    return;
  }

  if (!camReady) {
    drawCameraStatus();
    drawUI();
    drawToast();
    return;
  }

  image(cam, 0, 0, width, height);

  updateDetections();
  if (showMath) {
    drawDetectionOverlay();
  }

  drawUI();

  if (inReview) {
    drawReviewOverlay();
  }

  drawToast();
}

// -------------------------------------------------------------
// Camera plumbing
// -------------------------------------------------------------
void captureEvent(Capture c) {
  c.read();
  camFramesSeen++;

  ensureOpenCVFor(c.width, c.height);

  if (!camReady) {
    camReady = true;
    camStatusMsg = null;
    println("Camera streaming @ " + c.width + "x" + c.height + (camUsingAutoConfig ? " (auto config)" : ""));
  }
}

void ensureOpenCVFor(int w, int h) {
  if (opencv != null && opencvW == w && opencvH == h) return;
  opencv = new OpenCV(this, w, h);
  opencv.loadCascade(OpenCV.CASCADE_FRONTALFACE);
  println("OpenCV ready for " + w + "x" + h);
  opencvW = w;
  opencvH = h;
}

void startCameraPreferred() {
  startCamera(false);
}

void startCameraAuto() {
  startCamera(true);
}

void startCamera(boolean autoConfig) {
  shutdownCamera(null);

  camReady = false;
  camFramesSeen = 0;
  camUsingAutoConfig = autoConfig;
  camFallbackAttempt = autoConfig;
  camStartAttemptMs = millis();

  try {
    if (autoConfig) {
      println("Starting camera with default profile: " + cameraName);
      cam = new Capture(this, cameraName);
      camStatusMsg = "Starting camera (auto profile)…";
    } else {
      println("Starting camera @ " + CAM_W + "x" + CAM_H + ": " + cameraName);
      cam = new Capture(this, CAM_W, CAM_H, cameraName);
      camStatusMsg = "Starting camera @ " + CAM_W + "x" + CAM_H + "…";
    }
    cam.start();
  } catch(Exception e) {
    println("Camera init exception: " + e.getMessage());
    cam = null;
    camStatusMsg = "Camera init failed: " + e.getMessage();
    if (!autoConfig && !camFallbackAttempt) {
      camFallbackAttempt = true;
      println("Retrying camera with default profile.");
      startCameraAuto();
    }
  }
}

void shutdownCamera(String reason) {
  if (cam != null) {
    try {
      cam.stop();
    } catch(Exception e) {
      println("Camera stop error: " + e.getMessage());
    }
  }
  cam = null;
  camReady = false;
  camUsingAutoConfig = false;
  camFallbackAttempt = false;
  camFramesSeen = 0;
  camStartAttemptMs = 0;
  detections = new Rectangle[0];
  opencv = null;
  opencvW = -1;
  opencvH = -1;
  if (reason != null) camStatusMsg = reason;
}

boolean cameraReadyForCapture() {
  return consent && cam != null && camReady;
}

void updateCameraStartupState() {
  if (!consent) return;
  if (cam == null) return;
  if (camReady) return;

  int elapsed = (int)(millis() - camStartAttemptMs);
  if (elapsed < 0) elapsed = 0;

  if (!camUsingAutoConfig && !camFallbackAttempt && elapsed > CAMERA_TIMEOUT_MS && camFramesSeen == 0) {
    println("Camera timed out @ " + CAM_W + "x" + CAM_H + " — retrying default profile.");
    camStatusMsg = "Camera timed out @ " + CAM_W + "x" + CAM_H + " → retrying default profile…";
    camFallbackAttempt = true;
    startCameraAuto();
    return;
  }

  if (camUsingAutoConfig && camFramesSeen == 0 && elapsed > CAMERA_TIMEOUT_MS) {
    camStatusMsg = "Camera never produced frames. Close other apps or check permissions.";
  }
}

void drawCameraStatus() {
  pushStyle();
  fill(14);
  rect(0, 0, width, height);
  fill(255);
  textAlign(CENTER, CENTER);
  textSize(20);
  String msg = camStatusMsg != null ? camStatusMsg : "Waiting for camera…";
  text(msg, width/2f, height/2f - 20);
  textSize(12);
  text("Consent is ON → camera warming up." , width/2f, height/2f + 20);
  popStyle();
}

void drawParkedScreen() {
  pushStyle();
  fill(14);
  rect(0, 0, width, height);
  fill(255);
  textAlign(CENTER, CENTER);
  textSize(22);
  text("Consent OFF → camera parked.", width/2f, height/2f - 16);
  textSize(13);
  text("Toggle consent (key 'c' or click badge) to wake the camera.", width/2f, height/2f + 18);
  popStyle();
}

// -------------------------------------------------------------
// Detection overlay
// -------------------------------------------------------------
void updateDetections() {
  if (opencv == null || cam == null) return;
  opencv.loadImage(cam);
  detections = opencv.detect();
}

void drawDetectionOverlay() {
  if (detections == null) return;
  pushStyle();
  noFill();
  stroke(255, 200, 0);
  strokeWeight(2);
  textSize(12);
  for (Rectangle r : detections) {
    if (r == null) continue;
    rect(r.x, r.y, r.width, r.height);
    String label = r.width + "×" + r.height + " @" + r.x + "," + r.y;
    float tx = constrain(r.x, 8, width - 160);
    float ty = constrain(r.y - 16, 8, height - 24);
    fill(0, 180);
    noStroke();
    rect(tx - 4, ty - 2, textWidth(label) + 8, 18, 4);
    fill(255);
    text(label, tx, ty + 11);
    noFill();
    stroke(255, 200, 0);
  }
  popStyle();
}

// -------------------------------------------------------------
// Consent + review handling
// -------------------------------------------------------------
void toggleConsent() {
  setConsent(!consent);
}

void setConsent(boolean newState) {
  if (consent == newState) {
    if (consent) toast("Consent already ON", 1000);
    else toast("Consent already OFF", 1000);
    return;
  }

  consent = newState;
  if (consent) {
    toast("Consent ON — camera waking", 1400);
    camStatusMsg = "Starting camera…";
    startCameraPreferred();
  } else {
    toast("Consent OFF — camera parked", 1400);
    cancelReview();
    shutdownCamera("Consent OFF — camera parked.");
  }
}

void requestCapture() {
  if (!cameraReadyForCapture()) {
    String msg = consent ? "Camera is still waking up." : "Consent OFF — nothing captured.";
    toast(msg, 1400);
    return;
  }

  reviewFrame = cam.get();
  inReview = true;
  reviewNote = "Reviewing in RAM. Press [y] to keep or [n] to discard.";
  toast("Capture staged in RAM", 1200);
}

void saveReviewFrame() {
  if (!inReview || reviewFrame == null) {
    toast("Nothing to save", 1000);
    return;
  }
  String filename = CAPTURE_PREFIX + timestamp(false) + ".png";
  String fullPath = sketchPath(filename);
  reviewFrame.save(fullPath);
  println("Saved capture: " + filename);
  toast("Saved. TTL ≈ " + (CAPTURE_TTL_MS/60000) + " min.", 1600);
  inReview = false;
  reviewFrame = null;
  reviewNote = "";
  pruneExpiredCaptures();
}

void cancelReview() {
  inReview = false;
  reviewFrame = null;
  reviewNote = "";
}

// -------------------------------------------------------------
// UI & interaction
// -------------------------------------------------------------
void drawUI() {
  drawConsentBadge();
  drawHUDText();
}

void drawConsentBadge() {
  pushStyle();
  fill(consent ? color(0, 160, 120) : color(160, 40, 40));
  stroke(255);
  strokeWeight(2);
  rect(consentBtn.x, consentBtn.y, consentBtn.width, consentBtn.height, 10);
  fill(255);
  textAlign(LEFT, CENTER);
  textSize(16);
  String label = "Consent: " + (consent ? "ON" : "OFF");
  text(label, consentBtn.x + 16, consentBtn.y + consentBtn.height/2f);
  popStyle();
}

void drawHUDText() {
  pushStyle();
  fill(255);
  textAlign(LEFT, TOP);
  textSize(14);
  int faces = detections != null ? detections.length : 0;
  String overlayState = showMath ? "ON" : "OFF";
  text("Faces detected: " + faces + "\nMath overlay: " + overlayState + " [o]\nSaved (≤" + (CAPTURE_TTL_MS/60000) + " min): " + activeCaptures,
       16, consentBtn.y + consentBtn.height + 12);

  textAlign(RIGHT, BOTTOM);
  text("[space] capture → review\n[y] save  [n] discard\n[c] toggle consent\n[o] see the math",
       width - 16, height - 16);
  popStyle();
}

void drawReviewOverlay() {
  pushStyle();
  fill(0, 200);
  rect(0, 0, width, height);

  int pad = 60;
  int panelW = width - pad*2;
  int panelH = height - pad*2;
  fill(20, 220);
  stroke(255);
  rect(pad, pad, panelW, panelH, 14);

  if (reviewFrame != null) {
    int innerPad = 20;
    image(reviewFrame, pad + innerPad, pad + innerPad, panelW - innerPad*2, panelH - innerPad*2 - 80);
  }

  fill(255);
  textAlign(CENTER, CENTER);
  textSize(16);
  text(reviewNote, width/2f, height - pad - 40);
  popStyle();
}

void mousePressed() {
  if (consentBtn.contains(mouseX, mouseY)) {
    toggleConsent();
    return;
  }
}

void keyPressed() {
  if (key == 'c' || key == 'C') { toggleConsent(); return; }
  if (key == 'o' || key == 'O') { showMath = !showMath; toast("Math overlay " + (showMath ? "ON" : "OFF"), 1200); return; }
  if (key == ' ') { requestCapture(); return; }
  if (key == 'y' || key == 'Y') { saveReviewFrame(); return; }
  if (key == 'n' || key == 'N') { cancelReview(); toast("Discarded", 900); return; }
}

// -------------------------------------------------------------
// Capture retention helpers
// -------------------------------------------------------------
void maybePruneExpiredCaptures() {
  if (millis() - lastPruneMs < PRUNE_INTERVAL_MS) return;
  pruneExpiredCaptures();
  lastPruneMs = millis();
}

void pruneExpiredCaptures() {
  File dir = new File(sketchPath("captures"));
  if (!dir.exists()) {
    activeCaptures = 0;
    return;
  }
  File[] files = dir.listFiles((d, f) -> f.toLowerCase().endsWith(".png"));
  if (files == null) {
    activeCaptures = 0;
    return;
  }
  long now = System.currentTimeMillis();
  int kept = 0;
  for (File f : files) {
    if (f == null) continue;
    long age = now - f.lastModified();
    if (age > CAPTURE_TTL_MS) {
      boolean ok = f.delete();
      if (ok) println("TTL expired, deleted: " + f.getName());
    } else {
      kept++;
    }
  }
  activeCaptures = kept;
}

// -------------------------------------------------------------
// Toast helpers
// -------------------------------------------------------------
void toast(String msg, int durationMs) {
  toastMsg = msg;
  toastUntil = millis() + durationMs;
  println("[toast] " + msg);
}

void drawToast() {
  if (toastMsg == null) return;
  if (millis() > toastUntil) {
    toastMsg = null;
    return;
  }
  pushStyle();
  String msg = toastMsg;
  textSize(16);
  float tw = textWidth(msg);
  float bx = (width - tw) * 0.5f - 16;
  float by = height - 60;
  fill(0, 180);
  rect(bx, by - 8, tw + 32, 36, 10);
  fill(255);
  textAlign(CENTER, CENTER);
  text(msg, width/2f, by + 10);
  popStyle();
}

// -------------------------------------------------------------
// Utilities
// -------------------------------------------------------------
String pickCamera() {
  String[] cams = Capture.list();
  if (cams == null || cams.length == 0) return null;

  String hint = CAM_PREFERRED_HINT.toLowerCase();
  for (String c : cams) {
    if (c.toLowerCase().contains(hint)) return c;
  }
  for (String c : cams) if (c.toLowerCase().contains("1280x720")) return c;
  for (String c : cams) if (c.toLowerCase().contains("1920x1080")) return c;
  return cams[0];
}

String timestamp(boolean includeMillis) {
  String t = nf(year(),4) + nf(month(),2) + nf(day(),2) + "-" + nf(hour(),2) + nf(minute(),2) + nf(second(),2);
  if (includeMillis) {
    t += "-" + nf(millis() % 1000, 3);
  }
  return t;
}

void exit() {
  shutdownCamera(null);
  super.exit();
}
