#!/usr/bin/env bash
# Stag Hunt balance sweep — runs a configurable grid of scenarios with
# repeatable seeds and prints a per-scenario, per-round summary with
# captures-by-kind, per-bot scores, and end-of-round energies.
#
# Intended for: confirming a balance change does what you expected
# without breaking something else, OR for the first-pass investigation
# of "where is balance off?"
#
# Usage:
#   stag_hunt/balance_sweep.sh                                # default grid
#   stag_hunt/balance_sweep.sh --rounds=3 --ticks=1800        # short games
#   stag_hunt/balance_sweep.sh --seeds=1,42,7 --rounds=3      # 3 seeds
#   stag_hunt/balance_sweep.sh --rosters=moose4,elephant4     # subset
#   stag_hunt/balance_sweep.sh --port=8093 --no-build         # alt port
#
# Adding a new roster: extend the case in `roster_for` below.

set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8092
SEEDS="5744151,1,42"
TICKS=1800
ROUNDS=3
ROSTERS="moose4,mixed6,elephant4,rabbit4,stag2"
BUILD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port=*)    PORT="${1#*=}";;
    --seeds=*)   SEEDS="${1#*=}";;
    --ticks=*)   TICKS="${1#*=}";;
    --rounds=*)  ROUNDS="${1#*=}";;
    --rosters=*) ROSTERS="${1#*=}";;
    --no-build)  BUILD=0;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0;;
    *)           echo "unknown flag: $1" >&2; exit 2;;
  esac
  shift
done

roster_for() {
  case "$1" in
    moose4)     echo "moose_hunter moose_hunter moose_hunter moose_hunter";;
    moose3)     echo "moose_hunter moose_hunter moose_hunter";;
    elephant4)  echo "elephant_hunter elephant_hunter elephant_hunter elephant_hunter";;
    rabbit4)    echo "rabbiteer rabbiteer rabbiteer rabbiteer";;
    stag2)      echo "stag_hunter stag_hunter";;
    stag4)      echo "stag_hunter stag_hunter stag_hunter stag_hunter";;
    mixed6)     echo "stag_hunter stag_hunter nearest_hunter nearest_hunter rabbiteer rabbiteer";;
    coord4)     echo "coordinator coordinator coordinator coordinator";;
    sidekick3)  echo "sidekick stag_hunter stag_hunter";;
    *)          echo "" >&2; return 1;;
  esac
}

if [[ $BUILD -eq 1 ]]; then
  echo "[sweep] building server + bots..."
  nim c -d:release --hints:off -o:out/stag_hunt stag_hunt/stag_hunt.nim > /tmp/sweep_build.log 2>&1
  # Build any bot referenced by any roster we'll run.
  declare -A SEEN_BOT
  IFS=',' read -A ROSTER_ARR <<< "$ROSTERS" 2>/dev/null || \
    ROSTER_ARR=("${(@s:,:)ROSTERS}")  # zsh
  for r in "${ROSTER_ARR[@]}"; do
    bots=$(roster_for "$r" 2>/dev/null) || { echo "unknown roster: $r" >&2; exit 1; }
    for b in $bots; do
      if [[ -z "${SEEN_BOT[$b]:-}" ]]; then
        SEEN_BOT[$b]=1
        nim c -d:release --hints:off -o:"out/$b" "stag_hunt/players/$b/$b.nim" >> /tmp/sweep_build.log 2>&1
      fi
    done
  done
fi

TS=$(date +%Y%m%d-%H%M%S)
SWEEPDIR="tmp/sweep/$TS"
mkdir -p "$SWEEPDIR"
echo "[sweep] outputs under $SWEEPDIR"

# Comma-split helper that works in both bash 4+ and zsh.
split_csv() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    eval "$1=(\"\${(@s:,:)$2}\")"
  else
    IFS=',' read -ra "$1" <<< "${!2}"
  fi
}

split_csv SEED_ARR SEEDS
split_csv ROSTER_ARR ROSTERS

run_one() {
  local roster_name="$1"; local seed="$2"
  local outdir="$SWEEPDIR/${roster_name}_seed${seed}"
  mkdir -p "$outdir"
  local bots; bots=$(roster_for "$roster_name")
  cat > "$outdir/cfg.json" <<EOF
{"seed": $seed, "maxTicks": $TICKS, "maxGames": $ROUNDS}
EOF
  lsof -ti tcp:$PORT 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  (cd stag_hunt && ../out/stag_hunt --port:$PORT \
      --config-file:"../$outdir/cfg.json" \
      --event-log:"../$outdir/events.jsonl" \
      --save-scores:"../$outdir/scores.json" \
      > "../$outdir/server.log" 2>&1) &
  local SERVER_PID=$!
  for _ in $(seq 1 50); do curl -fs http://localhost:$PORT/healthz >/dev/null 2>&1 && break; sleep 0.1; done
  local i=0
  for b in $bots; do
    ./out/$b --port:$PORT --name:${b}_$i --slot:$i > "$outdir/bot_${i}.log" 2>&1 &
    i=$((i+1))
  done
  wait $SERVER_PID || true
  pkill -f "out/.* --port:$PORT" 2>/dev/null || true
  sleep 0.5
}

for roster in "${ROSTER_ARR[@]}"; do
  for seed in "${SEED_ARR[@]}"; do
    echo "[sweep] roster=$roster seed=$seed"
    run_one "$roster" "$seed"
  done
done

echo
echo "=== balance sweep summary ==="
python3 - "$SWEEPDIR" <<'PY'
import json, os, sys, collections, glob
root = sys.argv[1]
for d in sorted(glob.glob(os.path.join(root, "*"))):
  if not os.path.isdir(d): continue
  evpath = os.path.join(d, "events.jsonl")
  if not os.path.exists(evpath): continue
  cap = collections.Counter()
  gut = 0; trample = 0
  last_snap = {}
  cur_round = 1
  for line in open(evpath):
    e = json.loads(line)
    if e['ev'] == 'round_start': cur_round = e['round']
    elif e['ev'] == 'snapshot':  last_snap[cur_round] = e
    elif e['ev'] == 'catch':     cap[e['kind']] += 1
    elif e['ev'] == 'moose_gut': gut += 1
    elif e['ev'] == 'trample':   trample += 1
  print(f"\n--- {os.path.basename(d)} ---")
  print(f"  captures: {dict(cap)}  gut={gut} trample={trample}")
  for r in sorted(last_snap):
    snap = last_snap[r]
    es = [p['energy'] for p in snap['players']]
    ss = [p['score'] for p in snap['players']]
    print(f"  r{r}: scores={ss} energies={es}")
PY
echo
echo "[sweep] full logs in $SWEEPDIR"
