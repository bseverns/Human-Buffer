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
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Random;

// ------------------------------
// CONFIG
// ------------------------------
final int   OUTPUT_SIZE        = 800;
final int   CAM_W              = 1280;
final int   CAM_H              = 720;
final float SQUARE_SCALE       = 1.35f;
final int   RECORD_FPS         = 30;
final int   SERIAL_BAUD        = 115200;
final String SERIAL_HINT       = "usb|acm|modem|COM|tty";
final String SLUG_FILENAME     = "slug.png";
final boolean START_MIRROR     = true;
final float SMOOTH_FACTOR      = 0.25f;

final boolean START_FEATHER    = true;
final int     FEATHER_PX       = 60;

final boolean START_GATE_ON_FACE = true;
final boolean START_AUTO_REC      = false;

final boolean PRUNE_OLD_PNG     = false;
final int     KEEP_MAX_PNG      = 800;

// --- SAVE gestures (Arduino) ---
final int DOUBLE_TAP_MS = 1000;   // second SAVE within ≤1s = auto-confirm

// --- Session review timeout (if not confirmed, delete) ---
final int SESSION_REVIEW_TIMEOUT_MS = 15000; // 15s to confirm Keep

// ------------------------------
// STATE
// ------------------------------
Capture cam;
OpenCV  opencv;
Serial  ard;
VideoExport ve;

PImage slug;
PGraphics composite;
PImage featherMask;

// Consent gate: OFF by default
boolean consent = false;

// Toggles
boolean mirrorPreview = START_MIRROR;
boolean debugOverlay  = false;
boolean useFeather    = START_FEATHER;
boolean gateOnFace    = START_GATE_ON_FACE;
boolean autoRecOnFace = START_AUTO_REC;

// Face smoothing
float cx = -1, cy = -1, side = -1;
boolean haveFace = false;
int facePresentStreak = 0;
int faceMissingStreak = 0;

// Review overlay (PNG)
boolean inReview = false;
PImage  reviewFrame = null;
String  reviewNote  = "";

// Last saved PNG (for "Show/Delete")
String lastSavedPath = null;
PImage lastSavedThumb = null;

// Recording state
boolean recording = false;
String  recordingFile = null;
int     framesWrittenThisSession = 0;

// Session file post-stop confirmation
boolean sessionReviewActive = false;
String  sessionReviewPath   = null;
long    sessionReviewDeadlineMs = 0;
Btn     sessKeep = new Btn("sess_keep", "Keep", 0,0,0,0);
Btn     sessDiscard = new Btn("sess_discard", "Discard", 0,0,0,0);

// Avatar mode
boolean avatarMode = false;
long    avatarSeed = 1234567;
Random  avatarRng  = new Random(avatarSeed);

// UI buttons
ArrayList<Btn> buttons = new ArrayList<Btn>();
Btn btnConsent, btnAvatar, btnREC, btnShow, btnDelete;

// Double-tap tracking (serial-origin only)
long lastSaveTapMs = -1;
boolean reviewOpenedFromSerial = false;

// Toast feedback
String toastMsg = null;
long toastUntilMs = 0;

// ------------------------------
// LIFECYCLE
// ------------------------------
void settings() { size(OUTPUT_SIZE, OUTPUT_SIZE); }

void setup() {
  surface.setTitle("Privacy-First Face/Avatar Composite — Teaching Build v2");
  frameRate(RECORD_FPS);

  // Camera
  String camName = pickCamera();
  if (camName == null) { println("No camera found. Exiting."); exit(); }
  cam = new Capture(this, CAM_W, CAM_H, camName);
  cam.start();

  // OpenCV
  opencv = new OpenCV(this, CAM_W, CAM_H);
  opencv.loadCascade(OpenCV.CASCADE_FRONTALFACE);

  // Slug & buffers
  slug = loadImage(SLUG_FILENAME);
  if (slug == null) slug = fallbackSlug();

  composite = createGraphics(OUTPUT_SIZE, OUTPUT_SIZE);
  featherMask = makeRadialFeatherMask(
    OUTPUT_SIZE, OUTPUT_SIZE,
    OUTPUT_SIZE * 0.5f - FEATHER_PX,
    FEATHER_PX
  );

  setupSerial();

  new File(sketchPath("captures")).mkdirs();
  new File(sketchPath("sessions")).mkdirs();

  buildButtons();

  registerMethod("dispose", this);

  println("READY: s(y/n), v, c, A/N, m/d/f/g/t, o, DEL. Arduino: SAVE/SAVE_DBL/REC/CONSENT_TOGGLE.");
}

void captureEvent(Capture c) { c.read(); }

void draw() {
  background(0);

  // --- Detect & smooth ---
  opencv.loadImage(cam);
  Rectangle chosen = null;
  if (!avatarMode) {
    Rectangle[] faces = opencv.detect();
    chosen = pickLargest(faces);
  }
  updateFaceSmoothing(chosen);

  // Auto REC (file open/close), still consent-gated when writing frames
  if (autoRecOnFace) {
    if (!recording && facePresentStreak >= 6) startRecording();
    if (recording  && faceMissingStreak >= 12) stopRecording();
  }

  // --- Composite ---
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
    if (mirrorPreview) crop = mirrorImage(crop);
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
  image(composite, 0, 0);

  // --- UI: map + buttons + status ---
  drawDataFlowMap();
  drawTopButtons();
  if (recording) drawRECIndicator();
  if (debugOverlay) drawDebugPIP();

  // --- Overlays (modal) ---
  if (inReview) drawReviewOverlay();
  if (sessionReviewActive) drawSessionReviewOverlay();
  if (confirmDelete) drawDeleteConfirm();
  if (viewingLast) drawShowLast();

  // --- Recording: write frames only if consent (and optionally face present) ---
  boolean okToWrite = recording && consent && ve != null;
  boolean passGate  = !gateOnFace || haveFace || avatarMode;
  if (okToWrite && passGate) {
    ve.saveFrame();
    framesWrittenThisSession++;
  }

  // Toast
  if (toastMsg != null) {
    if (millis() < toastUntilMs) {
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
    } else {
      toastMsg = null;
    }
  }
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

Btn btnConsent, btnAvatar, btnREC, btnShow, btnDelete;

void buildButtons() {
  int pad=8, bw=140, bh=28, x=pad, y=pad;
  btnConsent = new Btn("consent", "Consent: OFF", x, y, bw, bh); x += bw + pad;
  btnAvatar  = new Btn("avatar",  "Avatar: OFF",  x, y, bw, bh); x += bw + pad;
  btnREC     = new Btn("rec",     "REC: OFF",     x, y, bw, bh); x += bw + pad;
  btnShow    = new Btn("show",    "Show my image", x, y, bw, bh); x += bw + pad;
  btnDelete  = new Btn("delete",  "Delete now",    x, y, bw, bh);
  buttons.clear();
  buttons.add(btnConsent); buttons.add(btnAvatar); buttons.add(btnREC);
  buttons.add(btnShow);    buttons.add(btnDelete);
  updateButtonLabels();
}

void updateButtonLabels() {
  btnConsent.label = "Consent: " + (consent ? "ON" : "OFF");
  btnAvatar.label  = "Avatar: "  + (avatarMode ? "ON" : "OFF");
  btnREC.label     = "REC: "     + (recording ? "ON" : "OFF");
  btnShow.enabled  = (lastSavedPath != null);
  btnDelete.enabled= (lastSavedPath != null);
}

void drawTopButtons() {
  for (Btn b : buttons) {
    boolean active = (b==btnConsent && consent) || (b==btnAvatar && avatarMode) || (b==btnREC && recording);
    b.draw(active);
  }
}

void mousePressed() {
  // If a modal overlay is active, ignore top-bar clicks
  if (inReview || sessionReviewActive || confirmDelete || viewingLast) return;

  for (Btn b : buttons) {
    if (b.hit(mouseX, mouseY)) {
      if (b == btnConsent) { consent = !consent; updateButtonLabels(); toast(consent?"Consent ON":"Consent OFF",1200); return; }
      if (b == btnAvatar)  { avatarMode = !avatarMode; updateButtonLabels(); return; }
      if (b == btnREC)     { toggleRecording(); updateButtonLabels(); return; }
      if (b == btnShow && lastSavedPath != null)   { showLastSavedOverlay(); return; }
      if (b == btnDelete && lastSavedPath != null) { confirmDeleteLast(); return; }
    }
  }
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

void openReview() {
  inReview = true;
  reviewNote = consent ? "Confirm to save image." : "Consent is OFF — turn ON to enable saving.";
}

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

void requestSave() {
  reviewFrame = composite.get(); // RAM only
  openReview();
  reviewOpenedFromSerial = false; // keyboard-origin
}

void commitSave() {
  if (reviewFrame == null || !consent) { reviewNote = "Consent required to save."; return; }
  String fn = "captures/face-" + timestamp(true) + ".png";
  reviewFrame.save(fn);
  println("Saved PNG: " + fn);
  lastSavedPath = fn;
  cacheLastSavedThumb();
  if (PRUNE_OLD_PNG) pruneCaptures();
  inReview = false; reviewFrame = null;
  updateButtonLabels();
  toast("Saved", 1200);
}

void cancelReview() {
  inReview = false;
  reviewFrame = null;
  reviewOpenedFromSerial = false;
}

// ------------------------------
// Session Review overlay (MP4 Keep/Discard with timeout)
// ------------------------------
void drawSessionReviewOverlay() {
  // Auto-delete if timed out
  if (millis() > sessionReviewDeadlineMs) {
    deleteSessionFile(sessionReviewPath, "Session not confirmed → deleted");
    sessionReviewActive = false;
    sessionReviewPath = null;
    return;
  }

  // Dim + panel
  pushStyle(); noStroke(); fill(0,180); rect(0,0,width,height); popStyle();
  int pw= width - 120, ph = 220, px = 60, py = (height - ph)/2;
  pushStyle(); fill(20); stroke(200); rect(px,py,pw,ph,14); popStyle();

  // Text
  fill(255); textAlign(LEFT, TOP); textSize(14);
  int remaining = int((sessionReviewDeadlineMs - millis())/1000.0);
  text("Keep this session video?\\n" +
       "File: " + sessionReviewPath + "\\n" +
       "Auto-delete in: " + remaining + "s", px+20, py+20);

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
    } else if (sessDiscard.hit(mouseX, mouseY)) {
      deleteSessionFile(sessionReviewPath, "Session discarded");
      sessionReviewActive = false;
      sessionReviewPath = null;
    }
  }
}

void deleteSessionFile(String path, String msg) {
  if (path == null) return;
  File f = new File(sketchPath(path));
  boolean ok = f.delete();
  println((ok? "Deleted: " : "Delete failed: ") + path);
  toast(msg + (ok? "" : " (delete failed)"), 1600);
}

// ------------------------------
// Show / Delete last PNG
// ------------------------------
void showLastSavedOverlay() { if (lastSavedPath != null) viewingLast = true; }

void confirmDeleteLast() {
  if (lastSavedPath == null) return;
  confirmDelete = true;
}

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

void drawShowLast() {
  pushStyle(); noStroke(); fill(0,180); rect(0,0,width,height); popStyle();
  int pw = width - 120, ph = height - 120, px = 60, py = 60;
  pushStyle(); fill(20); stroke(200); rect(px,py,pw,ph,14); popStyle();

  PImage img = loadImage(lastSavedPath);
  if (img != null) image(img, px+20, py+20, pw-40, ph-80);

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

void cacheLastSavedThumb() {
  if (lastSavedPath == null) { lastSavedThumb=null; return; }
  PImage img = loadImage(lastSavedPath);
  if (img != null) { lastSavedThumb = img.copy(); lastSavedThumb.resize(160, 160); }
}

void deleteLastSaved() {
  if (lastSavedPath == null) return;
  File f = new File(sketchPath(lastSavedPath));
  boolean ok = f.delete();
  println(ok ? "Deleted: " + lastSavedPath : "Delete failed: " + lastSavedPath);
  lastSavedPath = null; lastSavedThumb = null; updateButtonLabels();
  toast(ok ? "Deleted" : "Delete failed", 1200);
}

// ------------------------------
// Serial
// ------------------------------
void setupSerial() {
  String[] ports = Serial.list();
  if (ports == null || ports.length == 0) { println("No serial ports found."); return; }
  println("Serial ports:");
  for (int i=0;i<ports.length;i++) println("  ["+i+"] "+ports[i]);

  int pick=-1;
  for (int i=0;i<ports.length;i++) if (ports[i].toLowerCase().matches(".*(" + SERIAL_HINT + ").*")) { pick=i; break; }
  if (pick==-1) pick=0;
  println("Connecting to: " + ports[pick]);
  try { ard = new Serial(this, ports[pick], SERIAL_BAUD); ard.bufferUntil('\\n'); }
  catch(Exception e){ println("Serial error: "+e.getMessage()); ard=null; }
}

void serialEvent(Serial s) {
  String line = s.readStringUntil('\\n');
  if (line == null) return;
  line = trim(line);
  if (line.length()==0) return;
  String u = line.toUpperCase();

  if (u.equals("CONSENT_TOGGLE")) {
    consent = !consent;
    updateButtonLabels();
    toast(consent? "Consent ON (via Arduino)" : "Consent OFF (via Arduino)", 1400);
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
          PImage snap = composite.get();
          String fn = "captures/face-" + timestamp(true) + ".png";
          snap.save(fn);
          println("Saved PNG: " + fn);
          lastSavedPath = fn;
          cacheLastSavedThumb();
          updateButtonLabels();
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

void requestSaveFromSerialTap() {
  reviewFrame = composite.get();
  openReview();
  reviewOpenedFromSerial = true;
  lastSaveTapMs = millis();
}

void toast(String msg, int ms) {
  toastMsg = msg;
  toastUntilMs = millis() + ms;
}

// ------------------------------
// Recording
// ------------------------------
void toggleRecording(){ if (recording) stopRecording(); else startRecording(); }

void startRecording() {
  if (recording) return;
  recordingFile = "sessions/session-" + timestamp(false) + ".mp4";
  framesWrittenThisSession = 0;
  try {
    ve = new VideoExport(this, recordingFile);
    ve.setFrameRate(RECORD_FPS);
    ve.startMovie();
    recording = true;
    println("Recording STARTED → " + recordingFile + " (writes require Consent)");
  } catch(Exception e){
    println("Could not start recording: " + e.getMessage());
    ve=null; recording=false; recordingFile=null;
  }
}

void stopRecording() {
  if (!recording) return;
  try {
    if (ve!=null) ve.endMovie();
    println("Recording STOPPED → " + recordingFile + " (frames: " + framesWrittenThisSession + ")");
  } catch(Exception e){
    println("Error closing movie: " + e.getMessage());
  } finally {
    recording = false;
    // Post-stop policy: if 0 frames written, auto-delete. Else, require Keep confirmation.
    if (recordingFile != null) {
      if (framesWrittenThisSession <= 0) {
        deleteSessionFile(recordingFile, "Empty session → deleted");
        recordingFile = null;
      } else {
        sessionReviewActive = true;
        sessionReviewPath = recordingFile;
        sessionReviewDeadlineMs = millis() + SESSION_REVIEW_TIMEOUT_MS;
        toast("Review session: Keep or Discard", 1500);
        recordingFile = null;
      }
    }
    ve=null;
  }
}

// ------------------------------
// Keyboard
// ------------------------------
void keyPressed() {
  if (key == 's' || key=='S') requestSave();
  if (key == 'y' || key=='Y') { if (inReview && consent) commitSave(); }
  if (key == 'n' || key=='N') { if (inReview) cancelReview(); }

  if (key == 'v' || key=='V') { toggleRecording(); updateButtonLabels(); }
  if (key == 'c' || key=='C') { consent = !consent; updateButtonLabels(); toast(consent?"Consent ON":"Consent OFF",1200); }
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

void drawRECIndicator() {
  boolean writing = (recording && consent && (!gateOnFace || haveFace || avatarMode) && ve!=null);
  pushStyle();
  fill(255,0,0); noStroke(); ellipse(18, 18, 14, 14);
  if (writing) { noFill(); stroke(255,0,0); strokeWeight(2); ellipse(18,18,20,20); }
  fill(255); textSize(12); textAlign(LEFT, CENTER);
  text("REC" + (gateOnFace ? " (gated)" : ""), 28, 18);
  // Consent badge
  fill(consent ? color(40,180,70) : color(120));
  noStroke(); rect(70,10, 58,16,4); fill(255); textSize(10); textAlign(CENTER,CENTER);
  text(consent ? "CONSENT ON" : "CONSENT OFF", 70+29, 10+8);
  popStyle();
}

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
Rectangle pickLargest(Rectangle[] faces) {
  if (faces == null || faces.length == 0) return null;
  Rectangle best = null; float area=-1;
  for (Rectangle r : faces) { float a=r.width*r.height; if (a>area) {area=a; best=r;} }
  return best;
}

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
    haveFace = false; faceMissingStreak++; facePresentStreak=0;
  }
}

// ------------------------------
// Avatar (procedural geometric portrait)
// ------------------------------
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

String pickCamera() {
  String[] cams = Capture.list(); if (cams == null || cams.length == 0) return null;
  for (String c : cams) if (c.toLowerCase().contains("1280x720"))  return c;
  for (String c : cams) if (c.toLowerCase().contains("1920x1080")) return c;
  return cams[0];
}

String timestamp(boolean includeMillis) {
  String t = nf(year(),4)+nf(month(),2)+nf(day(),2)+"-"+nf(hour(),2)+nf(minute(),2)+nf(second(),2);
  if (includeMillis) t += "-" + nf(millis()%1000,3);
  return t;
}

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
void dispose() {
  stopRecording();
  if (cam!=null) cam.stop();
  if (ard!=null) ard.stop();
}

// ------------------------------
// SAVE (serial first-tap helper)
// ------------------------------
void requestSaveFromSerialTap() {
  reviewFrame = composite.get();
  openReview();
  reviewOpenedFromSerial = true;
  lastSaveTapMs = millis();
}
