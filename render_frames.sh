#!/usr/bin/env bash
# Render every frame that has no PNG yet, several at a time.
#   ./render_frames.sh [sessions]
#
# The queue lives in the database -- `frame WHERE png IS NULL` -- and
# render_next_frame() claims one row from it with FOR UPDATE SKIP LOCKED.  So
# this script holds no work list and does no scheduling: each session asks for
# whatever is left and the database decides who gets what.  Sessions can be
# added or killed mid-run, and a session that dies loses only the frame it was
# holding, which goes straight back in the queue.
#
# The driver has to live out here.  Nothing in core PostgreSQL starts a
# background job, and dblink and pg_background are extensions.
set -uo pipefail
cd "$(dirname "$0")"

N=${1:-4}

q() { docker exec pg_rt psql -U rt -d rt -tAq "$@"; }

pending=$(q -c "SELECT count(*) FROM frame WHERE png IS NULL")
if [ "$pending" -eq 0 ]; then
  echo "nothing to render"
  exit 0
fi
echo "rendering $pending frame(s), $N session(s) at a time ..."

# One psql per frame rather than one per session, which costs a connection per
# frame and buys the property that every frame commits on its own.  A session
# looping inside a single transaction would hold every row lock and every PNG
# until the last frame finished, which is the opposite of a resumable queue.
worker() {
  local id
  while :; do
    if ! id=$(q -c "SELECT render_next_frame()" 2>&1); then
      printf 'session %s failed: %s\n' "$1" "$id" >&2
      return 1
    fi
    [ -n "$id" ] || return 0          # empty result: the queue is drained
    printf '  session %s  frame %s\n' "$1" "$id"
  done
}

t0=$SECONDS
rc=0
for i in $(seq 1 "$N"); do worker "$i" & done
for job in $(jobs -p); do wait "$job" || rc=1; done

left=$(q -c "SELECT count(*) FROM frame WHERE png IS NULL")
printf 'rendered %s frame(s) in %ss (%s still pending)\n' \
  "$((pending - left))" "$((SECONDS - t0))" "$left"
exit $rc
