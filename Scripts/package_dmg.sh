#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 /path/to/Candoa.app /path/to/Candoa.dmg" >&2
  exit 64
fi

APP_PATH="$1"
OUT_DMG="$2"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 66
fi

APP_NAME="$(basename "$APP_PATH")"
VOLUME_NAME="${APP_NAME%.app}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/candoa-dmg.XXXXXX")"
STAGE_DIR="$WORK_DIR/stage"
RW_DMG="$WORK_DIR/$VOLUME_NAME.rw.dmg"

cleanup() {
  set +e
  if [ -n "${DMG_DEVICE:-}" ]; then
    hdiutil detach "$DMG_DEVICE" -quiet
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# hdiutil intermittently fails with EBUSY (exit 16, often with no stderr) on
# CI runners while Spotlight or diskarbitrationd briefly holds the image.
# Every hdiutil step goes through this retry wrapper; output is captured and
# surfaced only when an attempt fails, so logs stay quiet on the happy path.
run_hdiutil() {
  local attempt output status
  for attempt in 1 2 3 4 5; do
    if output="$(hdiutil "$@" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    status=$?
    echo "hdiutil $1 failed (exit $status, attempt $attempt/5): $output" >&2
    sleep $((attempt * 3))
  done
  return "$status"
}

mkdir -p "$STAGE_DIR/.background" "$(dirname "$OUT_DMG")"
ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME"
ln -s /Applications "$STAGE_DIR/Applications"

# Finder resolves the window background per-display when it is a multi-page
# HiDPI TIFF, so render the artwork at 1x and 2x and stitch them together.
# Shapes are rasterized from signed distance fields so edges stay anti-aliased
# at every scale.
python3 - "$STAGE_DIR/.background" <<'PY'
import math
import struct
import sys
import zlib

out_dir = sys.argv[1]
BASE_W, BASE_H = 760, 420

def sdf_round_rect(px, py, x0, y0, x1, y1, radius):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hw, hh = (x1 - x0) / 2 - radius, (y1 - y0) / 2 - radius
    qx, qy = abs(px - cx) - hw, abs(py - cy) - hh
    outside = math.hypot(max(qx, 0), max(qy, 0))
    return outside + min(max(qx, qy), 0) - radius

def sdf_segment(px, py, x0, y0, x1, y1):
    dx, dy = x1 - x0, y1 - y0
    t = max(0.0, min(1.0, ((px - x0) * dx + (py - y0) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - x0 - t * dx, py - y0 - t * dy)

def sdf_triangle(px, py, p0, p1, p2):
    d = min(
        sdf_segment(px, py, p0[0], p0[1], p1[0], p1[1]),
        sdf_segment(px, py, p1[0], p1[1], p2[0], p2[1]),
        sdf_segment(px, py, p2[0], p2[1], p0[0], p0[1]),
    )
    def cross(o, a):
        return (a[0] - o[0]) * (py - o[1]) - (a[1] - o[1]) * (px - o[0])
    c0, c1, c2 = cross(p0, p1), cross(p1, p2), cross(p2, p0)
    inside = (c0 >= 0 and c1 >= 0 and c2 >= 0) or (c0 <= 0 and c1 <= 0 and c2 <= 0)
    return -d if inside else d

def coverage(dist):
    return max(0.0, min(1.0, 0.5 - dist))

def render(scale):
    width, height = BASE_W * scale, BASE_H * scale
    canvas = []
    for y in range(height):
        row = []
        ny = y / height
        for x in range(width):
            nx = x / width
            glow = max(0, 1 - (((nx - 0.42) ** 2) / 0.18 + ((ny - 0.48) ** 2) / 0.36))
            row.append((18 + 42 * glow, 24 + 22 * glow, 29 + 50 * glow))
        canvas.append(row)

    def blend(x, y, color, alpha):
        if alpha <= 0:
            return
        r, g, b = canvas[y][x]
        sr, sg, sb = color
        canvas[y][x] = (
            sr * alpha + r * (1 - alpha),
            sg * alpha + g * (1 - alpha),
            sb * alpha + b * (1 - alpha),
        )

    def paint(bbox, distance, fill_alpha, stroke_alpha=0.0, stroke_half=0.0):
        x0, y0, x1, y1 = bbox
        pad = int(math.ceil(stroke_half)) + 2
        for y in range(max(0, y0 - pad), min(height, y1 + pad)):
            for x in range(max(0, x0 - pad), min(width, x1 + pad)):
                d = distance(x + 0.5, y + 0.5)
                blend(x, y, (255, 255, 255), fill_alpha * coverage(d))
                if stroke_alpha > 0:
                    blend(x, y, (255, 255, 255), stroke_alpha * coverage(abs(d) - stroke_half))

    s = scale
    # Wells behind the app icon and the Applications shortcut: soft fill plus
    # a hairline rim so the drop targets read as recessed panels.
    for x0, y0, x1, y1 in ((50, 84, 312, 322), (448, 84, 710, 322)):
        paint(
            (x0 * s, y0 * s, x1 * s, y1 * s),
            lambda px, py, r=(x0, y0, x1, y1): sdf_round_rect(px, py, r[0] * s, r[1] * s, r[2] * s, r[3] * s, 26 * s),
            fill_alpha=24 / 255,
            stroke_alpha=42 / 255,
            stroke_half=0.5 * s,
        )

    # Drag arrow, drawn as one union SDF (shaft capsule + head triangle) so the
    # shaft/head junction blends without a seam.
    head = ((392 * s, 176 * s), (444 * s, 204 * s), (392 * s, 232 * s))
    def arrow_dist(px, py):
        shaft = sdf_segment(px, py, 318 * s, 204 * s, 398 * s, 204 * s) - 5.5 * s
        return min(shaft, sdf_triangle(px, py, *head))
    paint((310 * s, 170 * s, 450 * s, 238 * s), arrow_dist, fill_alpha=235 / 255)

    return width, height, canvas

def write_png(path, width, height, canvas):
    raw = bytearray()
    for row in canvas:
        raw.append(0)
        for r, g, b in row:
            raw.extend((
                min(255, max(0, int(round(r)))),
                min(255, max(0, int(round(g)))),
                min(255, max(0, int(round(b)))),
            ))
    def png_chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(png_chunk(b"IEND", b""))

for scale, name in ((1, "background.png"), (2, "background@2x.png")):
    write_png(f"{out_dir}/{name}", *render(scale))
PY

tiffutil -cathidpicheck \
  "$STAGE_DIR/.background/background.png" \
  "$STAGE_DIR/.background/background@2x.png" \
  -out "$STAGE_DIR/.background/background.tiff"
rm "$STAGE_DIR/.background/background.png" "$STAGE_DIR/.background/background@2x.png"

# A pre-mounted volume with the same name (e.g. the shipping DMG opened from
# ~/Downloads) makes Finder's `tell disk "$VOLUME_NAME"` target that read-only
# disk, so the layout pass below silently no-ops. Detach it first.
if [ -d "/Volumes/$VOLUME_NAME" ]; then
  echo "Detaching pre-mounted /Volumes/$VOLUME_NAME so Finder layout targets the new image." >&2
  if ! hdiutil detach "/Volumes/$VOLUME_NAME" -quiet; then
    echo "Could not detach existing /Volumes/$VOLUME_NAME; eject it and re-run." >&2
    exit 75
  fi
fi

rm -f "$OUT_DMG" "$RW_DMG"
run_hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG" >/dev/null

MOUNT_INFO="$(run_hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DMG_DEVICE="$(printf '%s\n' "$MOUNT_INFO" | awk -v volume="/Volumes/$VOLUME_NAME" '$0 ~ volume {print $1; exit}')"

if [ -z "$DMG_DEVICE" ]; then
  echo "Could not determine mounted DMG device." >&2
  printf '%s\n' "$MOUNT_INFO" >&2
  exit 70
fi

# Finder scripting is best-effort. The DMG still installs correctly without
# layout metadata, which matters on headless CI runners.
osascript <<OSA || true
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {120, 120, 880, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME" of container window to {180, 210}
    set position of item "Applications" of container window to {580, 210}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

sync
run_hdiutil detach "$DMG_DEVICE" -quiet
DMG_DEVICE=""

run_hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUT_DMG" >/dev/null

run_hdiutil verify "$OUT_DMG" >/dev/null
