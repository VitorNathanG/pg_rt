#!/usr/bin/env bash
# Render the scene and write a PNG.
#   ./render.sh [width] [height] [samples-per-axis] [max-depth] [exposure] [out]
set -euo pipefail
cd "$(dirname "$0")"

W=${1:-480} H=${2:-320} AA=${3:-2} D=${4:-5} EXP=${5:-1.35} OUT=${6:-out.png}

echo "rendering ${W}x${H}, ${AA}x${AA} samples/pixel, max depth ${D} ..."
docker exec pg_rt psql -U rt -d rt -tAq \
  -c "\timing on" \
  -c "SELECT render($W, $H, $AA, $D, $EXP);" 2>&1 | grep -E '^Time' || true

# bytea comes back as \x-prefixed hex; strip the prefix and decode.
docker exec pg_rt psql -U rt -d rt -tAq \
  -c "SELECT encode(png_encode($W, $H, png_scanlines('img')), 'hex');" \
  | tr -d '\n' | xxd -r -p > "$OUT"

echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
