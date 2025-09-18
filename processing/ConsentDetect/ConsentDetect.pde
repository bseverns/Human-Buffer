/**
 * Consent-Gated Face Detector
 * ---------------------------
 * Minimal teaching sketch showing a privacy-first pipeline:
 * consent before camera, detection-only, TTL storage, and an overlay toggle.
 * <p>
 * Lots of inline comments below so learners can follow the data flow
 * and adapt it for their own experiments.
 *
 * Build: v0.1.0
 */

import processing.video.*;
import gab.opencv.*;
import java.io.File;
import java.util.UUID;
import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import processing.data.JSONObject;

Capture cam;
OpenCV opencv;

// Camera boot happens off-thread so the UI doesn't beachball while
// GStreamer enumerates devices (which can take ages on macOS).
boolean cameraInitializing = false;
String statusMessage = "Press y to start the camera.";

// State machine: we start at CONSENT, then show PREVIEW once the user opts in,
// and finally REVIEW when a frame has been captured and awaits a decision.
String state = "CONSENT"; // CONSENT -> PREVIEW -> REVIEW

// Overlay toggle for "See the math"; default is off to keep things chill.
boolean showOverlay = false;

// Holds the captured frame while we ask the user to save or toss it.
PImage reviewFrame;

// Handles saving and purging images with expiration metadata.
StorageManager storage = new StorageManager();

final String BUILD = "v0.1.0";

void settings() {
  size(640, 480); // fixed window size keeps math simple
}

void setup() {
  surface.setTitle("Consent-Gated Face Detector");
  // Clean out any expired captures from prior runs before we do anything else.
  storage.purgeExpired();
}

void draw() {
  background(0); // blank slate every frame

  // Route to the correct screen based on our current state.
  if (state.equals("CONSENT")) { drawConsent(); return; }
  if (state.equals("PREVIEW")) { drawPreview(); return; }
  if (state.equals("REVIEW"))  { drawReview();  return; }
}

void drawConsent() {
  fill(255);
  textAlign(CENTER, CENTER);
  // Simple prompt: nothing happens until the user hits "y".
  text("Start camera?", width/2, height/2 - 20);
  text("[y]es  |  [n]o", width/2, height/2 + 20);
  if (cameraInitializing) {
    text("Looking for cameras...", width/2, height/2 + 60);
  } else if (statusMessage != null && statusMessage.length() > 0) {
    text(statusMessage, width/2, height/2 + 60);
  }
  drawStatus();
}

void drawPreview() {
  if (cam == null) {
    fill(255);
    textAlign(CENTER, CENTER);
    text("Camera not ready.", width/2, height/2);
    drawStatus();
    return;
  }
  // Pull the next frame if it's ready.
  if (cam.available()) cam.read();
  image(cam, 0, 0); // dump the raw camera feed to the screen

  // Run face detection entirely in RAM—no disk writes here.
  opencv.loadImage(cam);
  Rectangle[] faces = opencv.detect();

  // Optionally draw green rectangles so students can "see the math".
  if (showOverlay) {
    noFill(); stroke(0,255,0);
    for (Rectangle r : faces) rect(r.x, r.y, r.width, r.height);
  }

  drawStatus();
}

void drawReview() {
  // Freeze the captured frame and dim it so the prompt pops.
  image(reviewFrame, 0, 0);
  fill(0,150);
  rect(0,0,width,height);
  fill(255);
  textAlign(CENTER,CENTER);
  text("Save image? y/n", width/2, height/2);
  drawStatus();
}

void keyPressed() {
  // Key handling is state-aware so we don't accidentally trigger actions.
  if (state.equals("CONSENT")) {
    if (key=='y' || key=='Y') startCamera(); // user opts in
    if (key=='n' || key=='N') exit();         // user bails
  } else if (state.equals("PREVIEW")) {
    if (key==' ') captureFrame();              // snapshot for review
    if (key=='o' || key=='O') showOverlay = !showOverlay; // toggle math overlay
  } else if (state.equals("REVIEW")) {
    if (key=='y' || key=='Y') saveReview();   // commit to disk with TTL
    if (key=='n' || key=='N') state = "PREVIEW"; // toss and resume preview
  }
}

void startCamera() {
  if (cameraInitializing || cam != null) {
    return; // either we're already spinning it up or it's live
  }

  cameraInitializing = true;
  statusMessage = "Initializing camera...";
  thread("initCamera");
}

void captureFrame() {
  if (cam == null) return;
  // Grab the current frame so the user can mull it over.
  reviewFrame = cam.get();
  state = "REVIEW";
}

void saveReview() {
  // Save the image to disk along with its expiration metadata.
  storage.saveWithTTL(reviewFrame);
  state = "PREVIEW"; // then hop back to the live feed
}

void drawStatus() {
  // Footer keeps us transparent about what's happening.
  fill(255);
  textSize(12);
  textAlign(LEFT, BOTTOM);
  String msg = BUILD + "  ·  Camera → Detect (RAM) → Save/Discard";
  if (cameraInitializing) {
    msg += "  ·  spinning up camera";
  } else if (statusMessage != null && statusMessage.length() > 0) {
    msg += "  ·  " + statusMessage;
  }
  text(msg, 5, height-5);
}

void initCamera() {
  try {
    String[] cameras = Capture.list();
    if (cameras == null || cameras.length == 0) {
      statusMessage = "No cameras detected.";
      state = "CONSENT";
      return;
    }

    // Camera springs to life only after explicit consent.
    cam = new Capture(this, cameras[0]);
    cam.start();

    // Load the classic Haar cascade—fast, simple, and good for demos.
    opencv = new OpenCV(this, 640, 480);
    opencv.loadCascade(OpenCV.CASCADE_FRONTALFACE);

    state = "PREVIEW"; // start streaming frames
    statusMessage = "Camera live. Space to capture.";
  } catch (Exception e) {
    statusMessage = "Camera failed: " + e.getMessage();
    state = "CONSENT";
    cam = null;
    opencv = null;
  } finally {
    cameraInitializing = false;
  }
}

/**
 * Handles saving images with a time-to-live and purging expired files.
 */
class StorageManager {
  final File dir = new File(sketchPath("captures")); // where images live
  final int retentionDays = 30;                        // TTL in days
  StorageManager() { dir.mkdirs(); }

  /** Deletes expired images based on sidecar metadata. */
  void purgeExpired() {
    // Look for PNGs; if they have a JSON sibling with an old expiresAt, delete.
    File[] imgs = dir.listFiles((d,n)->n.toLowerCase().endsWith(".png"));
    if (imgs == null) return;
    for (File f : imgs) {
      File meta = new File(f.getAbsolutePath()+".json");
      if (!meta.exists()) continue; // missing metadata? keep but note the smell
      JSONObject obj = loadJSONObject(meta);
      long exp = obj.getLong("expiresAt");
      if (exp < System.currentTimeMillis()) {
        f.delete();
        meta.delete();
      }
    }
  }

  /** Saves an image alongside expiration metadata. */
  void saveWithTTL(PImage img) {
    dir.mkdirs();
    String id = UUID.randomUUID().toString();
    String path = new File(dir, id + ".png").getAbsolutePath();
    img.save(path);

    // Sidecar JSON holds the expiration timestamp for purgeExpired().
    JSONObject meta = new JSONObject();
    long ttl = System.currentTimeMillis() + retentionDays*24L*3600L*1000L;
    meta.setLong("expiresAt", ttl);
    saveJSONObject(meta, path + ".json");
  }
}
