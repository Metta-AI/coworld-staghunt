---
name: testing-game-balance-change
description: Use when you (or the user) have a specific proposed change to a game tunable — "lower this prob 40 → 30", "give rabbit less energy", "make moose flee more at distance 2" — and you need to confirm it has the intended effect without breaking something else.
---

# testing-game-balance-change

## When to invoke

The trigger is a **named change to a named tunable**. Examples:
- "drop MooseGutProb from 40 to 30"
- "RabbitEnergyReward 25 → 15"
- "raise the elephant cadence min from 12 to 24"
- "make stag flee 80% instead of 70% at the same scale"

If you don't have a specific change in mind, use **investigating-game-balance** first to find one.

## Core principle

**A balance change is a localized experiment, not a refactor.** You want to know: (a) did this change move the metric I targeted? (b) what else moved that I didn't intend? You answer both by running the SAME scenarios with the SAME seeds before and after, and reading the delta.

Single-seed runs lie. Run at least 3 seeds, ideally 5 — game RNG variance often exceeds the change size you're testing.

## The change-test workflow

1. **Snapshot the baseline.** Build the current binary, run 3-5 seeds × 60-75s rounds × the scenarios your change should affect. Save the captures-by-kind, scores-per-bot, and end-energies. Don't skip this step thinking "I remember the numbers."
2. **Make ONLY the named change.** No drive-by refactors. No unrelated tuning. If you find yourself wanting to change a second thing, finish the first test first.
3. **Rebuild and re-run.** SAME scenarios, SAME seeds, SAME round length. Anything different invalidates the comparison.
4. **Compare deltas in a table.** Per scenario, per seed: did the targeted metric move in the expected direction by a meaningful amount?
5. **Check for collateral damage.** Did any other metric move? Score distribution, capture distribution, end-energy distribution. Unexpected movement is usually the more important finding.

## What "meaningful" means

The change has to beat the noise floor. In stag_hunt with 60s rounds:
- ±2 captures per round is noise (single seed)
- ±5 captures total across 3 seeds is also possibly noise
- Consistent direction across 3+ seeds, even with small magnitude, is signal

If your change is in the noise, either (a) the change is too small to test, or (b) the noise floor is too high — use longer rounds or more seeds.

## Output shape (copyable)

```
CHANGE: MooseGutProb 40 → 30
SCENARIOS: 4×moose_hunter self-play, 1800 ticks, 3 rounds each, seeds 1/42/7

                           BEFORE (40)    AFTER (30)     DELTA
seed 1, total captures:    8 (5M+3R)      10 (5M+4R+1S)  +2 (+1R+1S)
seed 1, gut events:        17             12             -5
seed 1, scores [a,b,c,d]:  [50, 8, 60, 55] [50, 30, 50, 55] +20 (b recovered)
seed 1, end-energies:      [22-50]        [33-58]        slightly healthier

seed 42, total captures:   2              5              +3
seed 42, gut events:       14             9              -5
...

VERDICT: Gut frequency dropped ~30% (expected), moose captures up slightly,
hunter scores more even. No regression in other captures. APPLY.
```

The verdict line is the deliverable. Without it the test was just data collection.

## Possible verdicts and what to do

| Verdict | What to do |
|---|---|
| Targeted metric moved as intended, nothing else moved | Apply the change. Done. |
| Targeted metric moved, something else moved too (bad) | Investigate the second-order effect before applying. Often the new bug is the more important finding. |
| Targeted metric moved, something else moved too (good) | Apply, but document the secondary effect — your model of why the change works was incomplete. |
| Targeted metric didn't move | The change is in the noise, OR your model of how it would propagate is wrong. Re-investigate. |
| Targeted metric moved the WRONG direction | You misread the code. Re-read the relevant procs before changing anything else. |

## Common mistakes

- **Skipping the baseline.** "I'll just compare against my mental model." Your mental model is the thing being debugged.
- **Changing two things at once.** Now you can't attribute either delta. Revert one, test the other.
- **One-seed verdicts.** "Captures went 6 → 5, the change made things worse." Run 5 seeds; you'll see the original 6 was high for the seed.
- **Stopping at "did the targeted metric move."** The collateral check is the more valuable half of the experiment.
- **Forgetting the build step between baseline and test.** Running the old binary against new config = comparing nothing.

## A real example

User asked: "MooseGutProb 40 → 30, that's too high right now." We ran:
- baseline (40): 17 gut events / round, 4-5 moose captures, hunters scoring [30,0,30,30]
- after (30): 12 gut events / round, 5 moose captures, hunters scoring [50,30,50,55]

Targeted metric (gut events) dropped as expected. Hunter score distribution flattened — slot-2 hunter who previously got crushed (score 0) now contributing (score 30). Captures held steady. **Both halves of the verdict agreed: apply.**

If we'd only looked at captures we'd have said "no effect, change is in the noise" and missed the real story (the change rescued the hunter that was getting repeatedly gutted).

## See also

- `investigating-game-balance` — for the "I don't know what to change yet" upstream case
- For stag_hunt specifically: `./balance_sweep.sh` accepts seed args for repeatable runs.
