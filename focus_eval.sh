#!/usr/bin/env bash
# Fast catch-dynamics test: elephant-only world, elephant spawns near
# players, short rounds, multiple games per run. Output: capture rate
# per round.
#
# Usage:
#   ./focus_eval.sh <num_hunters> [ticks_per_round] [num_rounds] [seed]
#
# Defaults: 4 hunters, 300 ticks (~12s), 5 rounds, seed 1.
set -euo pipefail
cd "$(dirname "$0")"

HUNTERS="${1:-4}"
TICKS="${2:-300}"
ROUNDS="${3:-5}"
SEED="${4:-1}"

PORT=8090
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="tmp/focus/$TS"
mkdir -p "$OUTDIR"

cat > "$OUTDIR/config.json" <<EOF
{"seed": $SEED, "maxTicks": $TICKS, "maxGames": $ROUNDS, "focus": "elephant"}
EOF

lsof -ti tcp:$PORT 2>/dev/null | xargs -r kill -9 2>/dev/null || true

(./out/staghunt \
  --port:"$PORT" \
  --config-file:"$OUTDIR/config.json" \
  --save-scores:"$OUTDIR/scores.json" \
  --event-log:"$OUTDIR/events.jsonl") \
  > "$OUTDIR/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; pkill -f "out/elephant_hunter --port:$PORT" 2>/dev/null || true' EXIT INT TERM

for _ in $(seq 1 50); do
  curl -fs http://localhost:$PORT/healthz >/dev/null 2>&1 && break
  sleep 0.1
done

for i in $(seq 1 "$HUNTERS"); do
  ./out/elephant_hunter --port:"$PORT" --name:"e$i" --slot:"$i" \
    > "$OUTDIR/bot_$i.log" 2>&1 &
done

wait "$SERVER_PID" || true

# Render compact summary: per-round capture count, total tramples.
python3 - "$OUTDIR/events.jsonl" <<'PY'
import json, sys, collections
captures = collections.Counter()
tramples = collections.Counter()
round_idx = 1
for line in open(sys.argv[1]):
    e = json.loads(line)
    if e['ev'] == 'round_start':
        round_idx = e['round']
    elif e['ev'] == 'catch' and e['kind'] == 'Elephant':
        captures[round_idx] += 1
    elif e['ev'] == 'trample':
        tramples[round_idx] += 1
rounds = sorted(set(list(captures) + list(tramples)) | {1})
print(f"hunters={sys.argv[0]}  rounds={len(rounds)}")
print("round  captures  tramples")
total_c = total_t = 0
for r in rounds:
    c = captures.get(r, 0); t = tramples.get(r, 0)
    print(f"{r:<6} {c:<8} {t}")
    total_c += c; total_t += t
print(f"TOTAL  {total_c:<8} {total_t}  ({total_c}/{len(rounds)} = {total_c/len(rounds):.2f} captures/round)")
PY
echo "outputs in $OUTDIR"
