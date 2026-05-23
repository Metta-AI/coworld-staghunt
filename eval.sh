#!/usr/bin/env bash
# Local eval harness for stag_hunt.
#
# Usage:
#   stag_hunt/eval.sh <roster> [options]
#
# <roster> is a comma-separated list of bot names, e.g.
#   rabbiteer,rabbiteer,stag_hunter,stag_hunter
#
# Each name must correspond to an executable in ./out/ (built via
# `nim c -d:release -o:out/<name> stag_hunt/players/<name>/<name>.nim`).
# Names may be suffixed with a colon and tag for disambiguation when the
# same binary appears more than once, e.g. `stag_hunter:a,stag_hunter:b`.
#
# Options:
#   --port=N          Server port (default 8090)
#   --seed=N          Game seed (default 0x57A617)
#   --ticks=N         Max ticks per round (default 1200 = 50s @ 24fps)
#   --rounds=N        Number of rounds (default 1)
#   --out=DIR         Output directory (default tmp/eval/<timestamp>)
#   --keep-server     Leave server running after rounds end (for viewing)
#   --no-build        Skip the rebuild step (assumes binaries are up-to-date)
#
# Outputs (in <out>):
#   server.log        Server stdout/stderr
#   events.jsonl      Structured event log
#   scores.json       Per-round scores + catch matrix
#   bots/<name>.log   Each bot's stdout/stderr
#   summary.txt       Human-readable per-player breakdown
#
set -euo pipefail

cd "$(dirname "$0")/.."

ROSTER=""
PORT=8090
SEED=0x57A617
TICKS=1200
ROUNDS=1
OUTDIR=""
KEEP_SERVER=0
BUILD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port=*)    PORT="${1#*=}";;
    --seed=*)    SEED="${1#*=}";;
    --ticks=*)   TICKS="${1#*=}";;
    --rounds=*)  ROUNDS="${1#*=}";;
    --out=*)     OUTDIR="${1#*=}";;
    --keep-server) KEEP_SERVER=1;;
    --no-build)  BUILD=0;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0;;
    --*)         echo "unknown flag: $1" >&2; exit 2;;
    *)
      if [[ -z "$ROSTER" ]]; then ROSTER="$1"
      else echo "extra positional arg: $1" >&2; exit 2
      fi
      ;;
  esac
  shift
done

if [[ -z "$ROSTER" ]]; then
  echo "usage: $0 <roster> [options]" >&2
  exit 2
fi

# Convert seed (allow 0x... or decimal). The server parses JSON ints only,
# so normalize to decimal here.
SEED_DEC=$(printf '%d' "$SEED")

if [[ -z "$OUTDIR" ]]; then
  TS=$(date +%Y%m%d-%H%M%S)
  OUTDIR="tmp/eval/$TS"
fi
mkdir -p "$OUTDIR/bots"

# Parse roster into bot binary names and tags.
IFS=',' read -ra ENTRIES <<< "$ROSTER"
BINS=()
TAGS=()
for entry in "${ENTRIES[@]}"; do
  if [[ "$entry" == *:* ]]; then
    BINS+=("${entry%%:*}")
    TAGS+=("${entry#*:}")
  else
    BINS+=("$entry")
    TAGS+=("$entry")
  fi
done

# Disambiguate duplicate tags by appending index.
declare -A SEEN
for i in "${!TAGS[@]}"; do
  base="${TAGS[$i]}"
  count="${SEEN[$base]:-0}"
  if [[ $count -gt 0 ]]; then
    TAGS[$i]="${base}_${count}"
  fi
  SEEN[$base]=$((count + 1))
done

if [[ $BUILD -eq 1 ]]; then
  echo "[eval] building server + bots..."
  nim c -d:release -o:out/stag_hunt stag_hunt/stag_hunt.nim > "$OUTDIR/build.log" 2>&1
  for bin in "${BINS[@]}"; do
    if [[ ! -x "out/$bin" ]]; then
      if [[ -f "stag_hunt/players/$bin/$bin.nim" ]]; then
        nim c -d:release -o:"out/$bin" "stag_hunt/players/$bin/$bin.nim" >> "$OUTDIR/build.log" 2>&1
      else
        echo "[eval] missing binary out/$bin and no source at stag_hunt/players/$bin/$bin.nim" >&2
        exit 1
      fi
    fi
  done
fi

# Write a config file the server can read.
CONFIG="$OUTDIR/config.json"
cat > "$CONFIG" <<EOF
{"seed": $SEED_DEC, "maxTicks": $TICKS, "maxGames": $ROUNDS}
EOF

# Start the server.
echo "[eval] starting server on port $PORT (seed=$SEED_DEC, ticks=$TICKS, rounds=$ROUNDS)"
(cd stag_hunt && \
  ../out/stag_hunt \
    --port:"$PORT" \
    --config-file:"../$CONFIG" \
    --save-scores:"../$OUTDIR/scores.json" \
    --event-log:"../$OUTDIR/events.jsonl") \
  > "$OUTDIR/server.log" 2>&1 &
SERVER_PID=$!

# Cleanup on exit.
PIDS=("$SERVER_PID")
cleanup() {
  echo "[eval] cleanup..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# Wait for server to be listening.
for _ in $(seq 1 50); do
  if curl -fs "http://localhost:$PORT/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

# Launch each bot.
for i in "${!BINS[@]}"; do
  bin="${BINS[$i]}"
  tag="${TAGS[$i]}"
  slot=$i
  echo "[eval] launching slot=$slot bin=$bin tag=$tag"
  "./out/$bin" --port:"$PORT" --name:"$tag" --slot:"$slot" \
    > "$OUTDIR/bots/$tag.log" 2>&1 &
  PIDS+=("$!")
done

# Wait for the server to finish (it exits after maxGames rounds).
if [[ $KEEP_SERVER -eq 1 ]]; then
  echo "[eval] --keep-server: waiting forever; ctrl-c to stop"
  wait "$SERVER_PID"
else
  wait "$SERVER_PID" || true
fi

# Render a summary.
SUMMARY="$OUTDIR/summary.txt"
{
  echo "stag_hunt eval — $(date)"
  echo "roster: $ROSTER"
  echo "seed=$SEED_DEC ticks=$TICKS rounds=$ROUNDS"
  echo
  if [[ -f "$OUTDIR/scores.json" ]]; then
    python3 - "$OUTDIR/events.jsonl" "$OUTDIR/scores.json" <<'PY'
import json, sys
events_path, scores_path = sys.argv[1], sys.argv[2]
# Per-slot accumulators from the event log — this is keyed by the slot
# the bot actually got, not the order it joined.
totals = {}  # slot -> {name, score, by_kind}
prey_kinds = ["Rabbit", "Boar", "Stag", "Moose", "Elephant"]
for line in open(events_path):
    e = json.loads(line)
    if e["ev"] == "catch":
        for p in e["by"]:
            slot = p["slot"]
            t = totals.setdefault(slot, {"name": p["name"], "color": p["color"],
                                         "score": 0, "by_kind": {k: 0 for k in prey_kinds}})
            t["score"] += e["reward_score"]
            t["by_kind"][e["kind"]] += 1
            # Keep latest name (in case of reconnect with same slot).
            t["name"] = p["name"]
            t["color"] = p["color"]
# Also pick up zero-score players from round_end so they show in the table.
for line in open(events_path):
    e = json.loads(line)
    if e["ev"] == "round_end":
        for p in e["players"]:
            slot = p["slot"]
            if slot not in totals:
                totals[slot] = {"name": p["name"], "color": p["color"],
                                "score": 0, "by_kind": {k: 0 for k in prey_kinds}}
rows = [["slot", "color", "name", "score"] + prey_kinds + ["total_kills"]]
for slot in sorted(totals):
    t = totals[slot]
    bk = [t["by_kind"][k] for k in prey_kinds]
    rows.append([str(slot), str(t["color"]), t["name"], str(t["score"])]
                + [str(x) for x in bk] + [str(sum(bk))])
widths = [max(len(r[c]) for r in rows) for c in range(len(rows[0]))]
for r in rows:
    print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)))
PY
  else
    echo "(scores.json missing — server may have failed to write results)"
  fi
  echo
  echo "events: $(wc -l < "$OUTDIR/events.jsonl" 2>/dev/null || echo 0) lines"
  if [[ -f "$OUTDIR/events.jsonl" ]]; then
    echo "catch breakdown:"
    grep '"ev":"catch"' "$OUTDIR/events.jsonl" \
      | python3 -c '
import json, sys
from collections import Counter
c = Counter()
for line in sys.stdin:
    e = json.loads(line)
    c[e["kind"]] += 1
for k, n in sorted(c.items()):
    print(f"  {k}: {n}")
' || true
  fi
} | tee "$SUMMARY"

echo
echo "[eval] outputs in $OUTDIR"
