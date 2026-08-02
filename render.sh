#!/usr/bin/env bash
# Render the scene and write a PNG, or a GIF if the output is named one.
#   ./render.sh [width] [height] [samples-per-axis] [max-depth] [exposure] [out]
set -euo pipefail
cd "$(dirname "$0")"

W=${1:-480} H=${2:-320} AA=${3:-2} D=${4:-5} EXP=${5:-1.35} OUT=${6:-out.png}

# The extension picks the encoder rather than a flag, because it is the only
# thing about the output the caller has already had to decide.
case "$OUT" in
  *.gif) ENCODE="gif_of('img')" ;;
  *)     ENCODE="png_encode($W, $H, png_scanlines('img'))" ;;
esac

echo "rendering ${W}x${H}, ${AA}x${AA} samples/pixel, max depth ${D} -> $OUT ..."

# Both statements go to one psql, and that is a requirement rather than a
# tidiness: `img` lives in a schema named for the backend that filled it, so a
# second connection would look for it in its own empty workspace and find
# nothing.  Renders are isolated from each other by exactly the same mechanism.
out=$(docker exec pg_rt psql -U rt -d rt -tAq \
  -c "\timing on" \
  -c "SELECT render($W, $H, $AA, $D, $EXP);" \
  -c "SELECT encode($ENCODE, 'hex');" 2>&1)

grep -E '^Time' <<<"$out" || true
# bytea comes back as \x-prefixed hex; strip the prefix and decode.
grep -E '^[0-9a-f]+$' <<<"$out" | tr -d '\n' | xxd -r -p > "$OUT"

echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
