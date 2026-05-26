---
name: investigating-game-balance
description: Use when a game "feels off" but you don't know where — bots dominate that shouldn't, prey never gets caught, scores don't match the design, players die invisibly, or one strategy beats every other. Open-ended diagnostic, not a targeted fix.
---

# investigating-game-balance

## When to invoke

Symptoms that should trigger this:
- "rabbit-spam beats everyone, that's not the design"
- "no one ever catches the elephant"
- "bots score 30 in round 1 and 0 in every round after"
- "this strategy was supposed to be viable and it's not"
- a user reports a vibe — "feels too easy" / "feels broken" — without naming the cause

If the user has already named a specific tunable to change ("lower the moose gut prob"), skip this skill and use **testing-game-balance-change** instead.

## Core principle

**Balance bugs hide behind aggregate numbers.** A "total captures" count can stay flat while the actual failure mode shifts. You diagnose by spreading the data across three axes simultaneously: bot type, prey kind, and time within the round. The pattern jumps out when you see all three at once.

## The investigation workflow

1. **List the scenarios you need.** Each major bot policy in self-play, plus 1-2 mixed rosters. Include the policy the user is complaining about. Don't include human players — automate-only.
2. **Pick a round length that lets failure modes appear.** Short rounds (~60s) hide energy/economy bugs; long rounds (~5min) hide spawn-rate bugs. Run BOTH if you have the time.
3. **Use multiple seeds.** Single-seed runs in stochastic games have huge variance — three captures vs zero might be noise, not a real delta. 3 seeds minimum for any conclusion.
4. **Capture three layers per round:**
   - **Catches by kind** (which prey actually got hunted)
   - **Score by bot** (which policy is winning)
   - **End-of-round resource state per bot** (energy / health / hand size / whatever the bot needs to function)
5. **Look for inconsistencies between layers**, not at any one layer in isolation. The diagnostic patterns below come from cross-referencing.

## Diagnostic patterns to look for

| Pattern across the data | Likely cause |
|---|---|
| Captures = 0 AND end-energies are 0-1 | Bots are starving, not failing to find prey |
| Captures = 0 AND end-energies are healthy | Bots can't see / can't reach / can't coordinate |
| One bot has score 0 every round | That bot's strategy isn't viable in this roster, OR it's broken |
| Score drops sharply round-over-round | State leaking between rounds (reset bug) |
| One prey kind is never caught | Spawn rate, flee mechanic, or coalition requirement is too tight |
| One prey kind is caught 10× more than expected | That prey is a free lunch — too high reward for the effort |
| Self-play succeeds but mixed-play fails | Cooperation depends on shared assumptions broken by other policies |
| Energies stay high but no captures | Bots resting too defensively — threshold too high |

## What to write down

For each scenario, record a single line. Aim for legibility, not completeness:

```
roster=4×moose_hunter ticks=1800 rounds=3 seed=1
  captures: Moose 5, Rabbit 4, Stag 1
  scores  : [30, 0, 30, 30] / [0, 0, 0, 0] / [21, 25, 21, 7]
  end-energies: [44,30,25,50] / [41,40,32,29] / [37,36,32,40]
  → moose hunting works, round 2 was a wipe (no captures, energy still OK = bots couldn't find a moose)
```

The "→" line is the whole point. If you can't write one, you didn't look hard enough at the cross-references.

## When to stop investigating and act

Stop when you can complete this sentence:
> "The problem is X, and the smallest change I can make to test a fix is Y."

Then switch to **testing-game-balance-change** to validate Y.

If you can't finish that sentence, run more scenarios. **Don't guess and tweak.** A guess masquerading as a fix wastes the next investigation round.

## Common mistakes

- **Looking only at total captures.** Total can stay flat while the failure mode changes from "bots starve" to "bots can't reach prey."
- **Trusting a single seed.** "It went from 6 to 5 captures, the change made things worse" — no, that's seed-1 noise. Need 3+ seeds.
- **Running only short rounds.** Energy / fuel / resource bugs are invisible at 60s.
- **Forgetting mixed rosters.** Self-play tests the policy in isolation; mixed reveals "this strategy fails when allies don't cooperate."
- **Fixing the first thing you see.** Often the visible symptom is downstream of the real bug. Investigate broadly before touching code.

## A real example

In stag_hunt, a 60s self-play eval of `elephant_hunter` showed 1 capture/round and looked healthy. An 8-hour interactive session showed the same bots had 162 tramples vs 1 capture — they were starving inside long rounds, getting hit and unable to recover. Three layers told the story:
- captures: 1 (looked OK)
- score: max 29 (looked OK)
- end-energy: 0-1 across all 7 bots (smoking gun)

Without the end-energy snapshot, the score line "29" would have read as "fine" rather than "29 from one good moment, then died." Same lesson everywhere: **capture the resource state, not just the result.**

## See also

- `testing-game-balance-change` — once you know what to change
- `debugging-stuck-game-agents` — when "captures = 0, energies = 0-1" appears
- For stag_hunt specifically: `./balance_sweep.sh` runs a fixed grid of scenarios with the right output shape.
