// ------------------------------
// Avatar (procedural geometric portrait)
// ------------------------------

float avatarCenterX = -1;
float avatarCenterY = -1;
float avatarScale = 1.0f;
float avatarMood = 0.55f;
float avatarEnergy = 0.35f;

void drawAvatar(PGraphics g, Random rng) {
  float targetX = g.width * 0.5f;
  float targetY = g.height * 0.5f;
  float targetScale = 1.0f;
  float targetMood = avatarMood;
  float targetEnergy = 0.35f;

  if (cam != null && cam.width > 0 && cam.height > 0) {
    float normX = 0.5f;
    float normY = 0.5f;
    if (haveFace) {
      normX = constrain(cx / (float)cam.width, 0, 1);
      normY = constrain(cy / (float)cam.height, 0, 1);
      if (mirrorPreview) normX = 1.0f - normX;

      float xRange = g.width * 0.22f;
      float yRange = g.height * 0.18f;
      targetX = g.width * 0.5f + (normX - 0.5f) * xRange;
      targetY = g.height * 0.5f + (normY - 0.5f) * yRange;

      float sizeNorm = constrain(side / max(1.0f, (float)cam.width), 0.15f, 1.35f);
      float scaleAmt = (sizeNorm - 0.15f) / (1.35f - 0.15f);
      targetScale = lerp(0.75f, 1.35f, constrain(scaleAmt, 0, 1));

      targetMood = sampleFaceBrightness();

      float motion = dist(normX, normY, 0.5f, 0.5f);
      float streakEnergy = constrain(facePresentStreak / 18.0f, 0.0f, 1.0f);
      float motionEnergy = constrain(map(motion, 0, 0.6f, 0.25f, 1.0f), 0.25f, 1.0f);
      targetEnergy = max(motionEnergy, streakEnergy);
    }
  }

  if (avatarCenterX < 0) avatarCenterX = targetX;
  else avatarCenterX = lerp(avatarCenterX, targetX, 0.12f);
  if (avatarCenterY < 0) avatarCenterY = targetY;
  else avatarCenterY = lerp(avatarCenterY, targetY, 0.12f);
  avatarScale = lerp(avatarScale, targetScale, 0.08f);
  avatarMood = lerp(avatarMood, targetMood, 0.1f);
  avatarEnergy = lerp(avatarEnergy, targetEnergy, 0.12f);

  float baseRadius = min(g.width, g.height) * 0.35f * avatarScale;
  float haloRadius = baseRadius * (1.6f + 0.25f * avatarEnergy);

  g.pushStyle();
  g.colorMode(HSB, 360, 100, 100, 100);
  g.noStroke();
  g.fill(210, 12, 12 + 60 * avatarEnergy, 35);
  g.ellipse(avatarCenterX, avatarCenterY, haloRadius * 2, haloRadius * 2);

  rng.setSeed(avatarSeed);
  float time = millis() * 0.0015f;
  int layers = 7;
  for (int i = 0; i < layers; i++) {
    float layerPct = (layers <= 1) ? 0 : i / (float)(layers - 1);
    float radius = baseRadius * (1.0f - 0.12f * layerPct);
    radius *= 0.85f + 0.3f * rng.nextFloat();
    radius *= 1.0f + (noise(time + i * 0.21f) - 0.5f) * 0.9f * avatarEnergy;

    int sides = 3 + rng.nextInt(6);
    float rot = rng.nextFloat() * TWO_PI;
    float spin = time * (0.2f + avatarEnergy * 0.9f) * (rng.nextFloat() < 0.5f ? -1 : 1);
    int copies = 1 + rng.nextInt(3);
    for (int k = 0; k < copies; k++) {
      float extraRot = k * 0.18f + spin;
      float hueBase = lerp(170, 330, constrain(avatarMood, 0, 1));
      float hue = (hueBase + layerPct * 28 + k * 8 + 360) % 360;
      float sat = constrain(35 + avatarEnergy * 45 + layerPct * 15, 0, 100);
      float bri = constrain(45 + (1.0f - layerPct) * 40 + avatarMood * 25, 0, 100);

      g.noFill();
      g.strokeWeight(2 + rng.nextInt(3));
      g.stroke(hue, sat, bri, 95);
      polygon(g, avatarCenterX, avatarCenterY, radius, sides, rot + extraRot);
    }
  }

  float faceX = haveFace && cam != null && cam.width > 0
    ? constrain((mirrorPreview ? (cam.width - cx) : cx) / (float)cam.width, 0, 1)
    : 0.5f;
  float faceY = haveFace && cam != null && cam.height > 0
    ? constrain(cy / (float)cam.height, 0, 1)
    : 0.5f;
  float eyeOffsetX = (faceX - 0.5f) * baseRadius * 0.22f;
  float eyeOffsetY = (faceY - 0.5f) * baseRadius * 0.22f;

  float irisSize = baseRadius * 0.18f * (1.0f + 0.35f * avatarEnergy);
  float pupilSize = irisSize * 0.55f;
  g.noStroke();
  g.fill(0, 0, 96, 100);
  g.ellipse(avatarCenterX + eyeOffsetX, avatarCenterY + eyeOffsetY, irisSize * 2, irisSize * 2);
  g.fill(0, 0, 15, 100);
  g.ellipse(avatarCenterX + eyeOffsetX, avatarCenterY + eyeOffsetY, pupilSize * 2, pupilSize * 2);

  if (useFeather) {
    g.colorMode(RGB, 255);
    PImage snap = g.get();
    snap.mask(featherMask);
    g.image(snap, 0, 0);
  }
  g.popStyle();
}

float sampleFaceBrightness() {
  if (!haveFace || cam == null || cam.width <= 0 || cam.height <= 0) {
    return avatarMood;
  }

  cam.loadPixels();
  if (cam.pixels == null || cam.pixels.length == 0) {
    return avatarMood;
  }

  int size = max(4, round(side * 0.3f));
  size = constrain(size, 4, min(cam.width, cam.height));
  int half = size / 2;
  int cxPix = constrain(round(cx), half, cam.width - 1 - half);
  int cyPix = constrain(round(cy), half, cam.height - 1 - half);
  int x0 = cxPix - half;
  int y0 = cyPix - half;

  float sum = 0;
  int count = 0;
  for (int y = y0; y < y0 + size; y++) {
    int row = y * cam.width;
    for (int x = x0; x < x0 + size; x++) {
      color c = cam.pixels[row + x];
      sum += brightness(c);
      count++;
    }
  }

  if (count == 0) return avatarMood;
  return constrain(sum / (count * 255.0f), 0, 1);
}

void polygon(PGraphics g, float cx, float cy, float r, int sides, float rot) {
  g.beginShape();
  for (int i = 0; i < sides; i++) {
    float a = rot + TWO_PI * i / sides;
    g.vertex(cx + cos(a) * r, cy + sin(a) * r);
  }
  g.endShape(CLOSE);
}

