---
name: stag-hunt-balance
description: Use when iterating on stag_hunt — tuning prey rewards, flee probabilities, capture coalition sizes, energy economy, or testing a server-side mechanic change. Specific to the stag_hunt game in this repo; for the general process see investigating-game-balance and testing-game-balance-change.
---

# stag-hunt-balance

## When to invoke

Stag_hunt-specific tuning. Triggers:
- Changing any constant in `src/staghunt.nim` between roughly lines 20-75 (the gameplay tunables block)
- Reports like "rabbit-spam dominates", "no one catches the elephant", "moose gut feels brutal", "stags don't get caught"
- After landing a new server mechanic (e.g. trample, gut, stride) — verify it didn't wreck the balance of unrelated prey

For the underlying process (investigation vs change-test), use the two general skills referenced below. This skill is just the stag_hunt-specific entrypoint.

## The script

Use `./balance_sweep.sh`. Default grid runs 5 rosters × 3 seeds × 3 rounds × 1800 ticks ≈ 11 minutes. For faster iteration:

```sh
# investigation: full grid, 3 seeds
./balance_sweep.sh

# change-test: single roster + 3 seeds, fast
./balance_sweep.sh --rosters=moose4 --seeds=1,42,7

# probing a specific scenario
./balance_sweep.sh --rosters=elephant4 --rounds=5 --ticks=600
```

Output: per-scenario summary with captures-by-kind, end-of-round per-bot scores AND energies. The energy column is the half that catches starvation bugs — don't read it as decoration.

For elephant-focused catch-dynamics testing where you want elephants spawning near players (instead of randomly across the 32×32 map), use `./focus_eval.sh` instead — same output shape, but config has `"focus": "elephant"` set.

## The tunable block

In `src/staghunt.nim` around lines 20-75 these are the main knobs:

| Constant | Default | What changing it does |
|---|---|---|
| `RabbitEnergyReward` | 15 | How much fuel rabbits give. Was 25; suspect 17-20 right. |
| `RabbitScoreReward` | 1 | Score per rabbit. |
| `BoarEnergyReward` | 90 | Boar is designed as fuel, not score. |
| `StagEnergyReward` / `Score` | 60 / 5 | 2-coop catch. |
| `MooseEnergyReward` / `Score` | 140 / 10 | 3-coop catch. |
| `ElephantEnergyReward` / `Score` | 220 / 18 | 4-coop catch. |
| `MooseGutProbCardinal` | 30 | % chance moose shoves a player at N/S/E/W of it. |
| `MooseGutProbDiagonal` | 5 | Same but for diagonal (NE/NW/SE/SW). "Almost safe." |
| `MooseGutEnergyLoss` | 10 | Damage from a moose gut. |
| `ElephantTrampleEnergyLoss` | 30 | Damage from an elephant trample. |
| `ElephantThinkMin` / `Max` | 12 / 24 | Tick cooldown range for elephant moves. Lower = faster elephant. |
| `ElephantStrideProb` | 30 | % chance an elephant chains another 1-3 steps after a clean move. |
| `MoveEnergyCost` | 2 | Per player step. |
| `PassiveRechargeMax` | 100 | Resting only refills to here. Starting energy is 120. |
| `PassiveRechargeInterval` | 18 | Ticks per +1 energy at rest. |

Per-kind flee probabilities are in `thinkPrey` (around line 990-1020). Stag/moose/elephant scale the base prob (75/50/25% at chebyshev 1/2/3+) by a kind-specific multiplier; moose also has a distance-specific override.

## What "investigation" looks like here

Run the full sweep, look at the summary, write the one-line cross-reference. Real example from a recent session:

```
--- moose4_seed1 ---
  captures: {'Moose': 5, 'Rabbit': 4, 'Stag': 1}  gut=45 trample=2
  r1: scores=[30, 0, 30, 30] energies=[44, 30, 25, 50]
  r2: scores=[0, 0, 0, 0]    energies=[41, 40, 32, 29]
  r3: scores=[21, 25, 21, 7] energies=[37, 36, 32, 40]
→ slot-1 hunter got crushed in r1 (likely repeated gut events), recovered in r3.
  Moose captures are landing. r2 had no captures — bots couldn't find a moose.
```

The `→` line is the deliverable. See `investigating-game-balance` for the broader pattern.

## What "change-test" looks like here

Baseline-and-replicate. Real example: dropping `MooseGutProb` 40 → 30:

```sh
# baseline
./balance_sweep.sh --rosters=moose4 --seeds=1,42,7 > /tmp/baseline.txt
# edit constant in stag_hunt.nim
./balance_sweep.sh --rosters=moose4 --seeds=1,42,7 > /tmp/after.txt
diff /tmp/baseline.txt /tmp/after.txt
```

Look for: did `gut=N` drop ~proportionally? Did moose captures hold? Did any score distribution change unexpectedly? See `testing-game-balance-change` for the full verdict template.

## Common stag_hunt-specific gotchas

- **Always rebuild after changing constants.** `--no-build` skips it; only use that flag when you're SURE the binary is fresh.
- **Energy state persists within a round but resets between rounds.** A bot that ended round 1 at energy 0 starts round 2 at 120. So multi-round eval shows recovery, single-round eval may not.
- **Slot collision.** When launching N bots, slots 0..N-1 are taken. A user joining `/player` without `?slot=...` gets `sim.players.len`, which collides. Either launch bots on slots 0..(N-1) and leave N free, OR explicit `?slot=N` in the URL.
- **Browser-viewer compatibility.** If you add a new sprite-packet message type to the server, `client/player_client.html` and `client/global_client.html` BOTH have their own inline JS parser that needs updating — they're separate from `client/*.nim`. Forgetting these will silently disconnect every browser viewer.
- **Stag captures are noisy.** Single seed 0-3 stags/game is normal variance. Use 3+ seeds before any conclusion.
- **focus_eval vs balance_sweep.** Focus mode strips everything to 1 elephant near players for catch-dynamics testing. Use it for "does the synchronized dash work at all" not for "how does this scoring change feel."

## See also

- `investigating-game-balance` — the general "balance feels off" workflow
- `testing-game-balance-change` — the general A/B change-test workflow
- `debugging-stuck-game-agents` — when the symptom is "bots stopped" not "scoring is wrong"
- `learnings.md` — chronological notes from the upgrade pass
- `stag_hunt_goal_status.html` — current state dashboard
