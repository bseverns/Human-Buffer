// ------------------------------
// Face tracking helpers (pulled into their own tab for sanity)
// ------------------------------

Rectangle pickLargest(Rectangle[] faces) {
  if (faces == null || faces.length == 0) return null;
  Rectangle best = null;
  float area = -1;
  for (Rectangle r : faces) {
    if (r == null) continue;
    float a = r.width * r.height;
    if (a > area) {
      area = a;
      best = r;
    }
  }
  return best;
}

void updateFaceSmoothing(Rectangle chosen) {
  if (cam == null) {
    haveFace = false;
    facePresentStreak = 0;
    faceMissingStreak = 0;
    return;
  }

  if (chosen != null) {
    haveFace = true;
    facePresentStreak++;
    faceMissingStreak = 0;

    float fx = chosen.x + chosen.width * 0.5f;
    float fy = chosen.y + chosen.height * 0.5f;
    float s  = max(chosen.width, chosen.height) * SQUARE_SCALE;

    float half = s * 0.5f;
    fx = constrain(fx, half, cam.width - half);
    fy = constrain(fy, half, cam.height - half);

    if (cx < 0) {
      cx = fx;
      cy = fy;
      side = s;
    } else {
      cx = lerp(cx, fx, SMOOTH_FACTOR);
      cy = lerp(cy, fy, SMOOTH_FACTOR);
      side = lerp(side, s, SMOOTH_FACTOR);
    }
  } else {
    faceMissingStreak++;
    boolean recentlySeen = facePresentStreak > 0;
    if (recentlySeen && faceMissingStreak <= FACE_MISSING_GRACE_FRAMES) {
      haveFace = true;
    } else {
      haveFace = false;
      facePresentStreak = 0;
    }
  }
}

