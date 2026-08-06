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

python3 - "$STAGE_DIR/.background/background.png" <<'PY'
import math
import struct
import sys
import zlib

path = sys.argv[1]
width, height = 760, 420
pixels = bytearray()

def blend(dst, src):
    r, g, b = dst
    sr, sg, sb, a = src
    alpha = a / 255.0
    return (
        int(sr * alpha + r * (1 - alpha)),
        int(sg * alpha + g * (1 - alpha)),
        int(sb * alpha + b * (1 - alpha)),
    )

canvas = []
for y in range(height):
    row = []
    for x in range(width):
        nx = x / width
        ny = y / height
        glow = max(0, 1 - (((nx - 0.42) ** 2) / 0.18 + ((ny - 0.48) ** 2) / 0.36))
        row.append((18 + int(42 * glow), 24 + int(22 * glow), 29 + int(50 * glow)))
    canvas.append(row)

def rect(x0, y0, x1, y1, color):
    for y in range(max(0, y0), min(height, y1)):
        for x in range(max(0, x0), min(width, x1)):
            canvas[y][x] = blend(canvas[y][x], color)

def rounded_rect(x0, y0, x1, y1, radius, color):
    for y in range(max(0, y0), min(height, y1)):
        for x in range(max(0, x0), min(width, x1)):
            cx = min(max(x, x0 + radius), x1 - radius)
            cy = min(max(y, y0 + radius), y1 - radius)
            if (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2:
                canvas[y][x] = blend(canvas[y][x], color)

def line(x0, y0, x1, y1, thickness, color):
    dx = x1 - x0
    dy = y1 - y0
    length_sq = dx * dx + dy * dy
    for y in range(max(0, min(y0, y1) - thickness), min(height, max(y0, y1) + thickness + 1)):
        for x in range(max(0, min(x0, x1) - thickness), min(width, max(x0, x1) + thickness + 1)):
            t = 0 if length_sq == 0 else max(0, min(1, ((x - x0) * dx + (y - y0) * dy) / length_sq))
            px = x0 + t * dx
            py = y0 + t * dy
            if math.hypot(x - px, y - py) <= thickness:
                canvas[y][x] = blend(canvas[y][x], color)

def triangle(points, color):
    (x1, y1), (x2, y2), (x3, y3) = points
    min_x = max(0, min(x1, x2, x3))
    max_x = min(width - 1, max(x1, x2, x3))
    min_y = max(0, min(y1, y2, y3))
    max_y = min(height - 1, max(y1, y2, y3))
    denom = ((y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3))
    for y in range(min_y, max_y + 1):
        for x in range(min_x, max_x + 1):
            a = ((y2 - y3) * (x - x3) + (x3 - x2) * (y - y3)) / denom
            b = ((y3 - y1) * (x - x3) + (x1 - x3) * (y - y3)) / denom
            c = 1 - a - b
            if a >= 0 and b >= 0 and c >= 0:
                canvas[y][x] = blend(canvas[y][x], color)

rounded_rect(50, 84, 312, 322, 26, (255, 255, 255, 24))
rounded_rect(448, 84, 710, 322, 26, (255, 255, 255, 24))
line(350, 204, 430, 204, 5, (255, 255, 255, 235))
triangle([(430, 174), (486, 204), (430, 234)], (255, 255, 255, 235))

raw = bytearray()
for row in canvas:
    raw.append(0)
    for r, g, b in row:
        raw.extend((r, g, b))

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
PY

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
    set background picture of viewOptions to file ".background:background.png"
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
