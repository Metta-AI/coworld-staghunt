# Stag Hunt iteration log

Working notes for the upgrade pass against `~/dev/stag_hunt_goal.md`.

Branch: `stag-hunt-upgrade` (bitworld). Do not push.

## Tooling

### `stag_hunt/eval.sh`

Local-only eval harness. Spawns server + a chosen roster of bot binaries,
captures structured events and per-bot stdout, prints a summary.

```sh
stag_hunt/eval.sh rabbiteer,rabbiteer,stag_hunter,stag_hunter \
  --ticks=1440 --rounds=1
```

- Roster: comma-separated. Same binary repeated is fine; tags get suffixed
  (`stag_hunter`, `stag_hunter_1`, …) so per-bot log files don't collide.
  Override the tag with `name:tag` syntax if needed.
- 1440 ticks ≈ 60s at 24fps. Default is 1200.
- Outputs under `tmp/eval/<timestamp>/`: `server.log`, `events.jsonl`,
  `scores.json`, `bots/<tag>.log`, `summary.txt`.
- Use `--keep-server` to leave the viewer reachable at
  `http://localhost:8090/global` after the rounds end.

### Server `--event-log:PATH`

Emits JSONL. One line per event. Events implemented so far:

- `server_start` — host, port, seed, max_ticks, max_games.
- `player_connect` — name, slot. Fires whenever a websocket joins.
- `round_start` — round (1-indexed), seed, max_ticks, roster (slot, name,
  color, x, y). Only emitted from round 2 onward — for round 1, the
  `player_connect` events serve as the implicit roster.
- `catch` — kind, x, y, by[{slot, name, color, score, energy}],
  reward_energy, reward_score.
- `round_end` — round, players[{slot, name, color, score, energy,
  catches[{kind, n}]}].
- `tournament_end` — games.

Also writes the existing `--save-scores` JSON (cumulative roster, per-round
score array, co-catch matrix) at tournament end.

### What I'm explicitly *not* building yet

- Per-tick position dump. The event log is enough to reason about outcomes;
  fine-grained debugging is via opening the global viewer in a browser.
- A standalone replay player. The browser viewer plus the event log covers
  it. If a need for offline scrubbing shows up later (e.g. comparing
  candidate policies on identical seeds without re-running), revisit.
- A Python eval orchestrator a la `optimizers/`. Too much infra for the
  current loop; shell script is enough to iterate at "edit bot, rerun"
  speed.

## Baselines (current `master`, before any bot changes)

`rabbiteer,rabbiteer,stag_hunter,stag_hunter`, 1440 ticks (60s), default
seed:

```
slot  color  name           score  Rabbit  Boar  Stag  Moose  Elephant
0     2      rabbiteer      8      8       0     0     0      0
1     0      rabbiteer_1    4      4       0     0     0      0
2     1      stag_hunter    0      0       0     0     0      0
3     3      stag_hunter_1  0      0       0     0     0      0
```

Reading: stag_hunters catch **zero** stags in 60s despite there being two of
them. They almost certainly need each other to converge on the same stag; the
explore-quadrant-on-a-timer pattern in their current code doesn't enable
that.

## Observations (deferred — not acted on yet)

- The default config has `TargetStags = 6`. So there are plenty of stags to
  catch — supply is not the bottleneck. The bottleneck is two stag_hunters
  rarely picking the same one.
- Sidekick was mentioned as "favor bigger game in a tie." Worth biasing
  *every* multi-hunter player toward the same target when allies are in
  view (otherwise self-play won't pair up).
- `findStag` (and presumably the other "find" functions in each bot) takes
  the **first** stag in `visiblePrey`. That's effectively random because the
  prey array order depends on which slot in `MaxPreySlots` is occupied. A
  stable tiebreak (e.g. lowest objectId, or position with allies nearest)
  would make two stag_hunters converge.
- BFS pathfinding looks solid. Stuck-detection thresholds (15 to switch to
  unstick, 30 to reroll explore target) feel reasonable given the 5-tick
  movement cooldown.

## Subgoal 1 — stag_hunter

Before: 2 stag_hunters caught 0 stags in 60s. Root causes:
- `findStag` returns the *first* stag in the array, not the closest or the
  one allies are converging on. Two stag_hunters routinely picked
  different stags.
- `pickClearCardinalNeighbor` picks a side at random. Two stag_hunters that
  *did* converge on the same stag often took adjacent (not opposing) sides.
  Stag needs opposing sides (N+S or E+W) to capture.

After (lift from `nearest_hunter`-style helpers, specialized to stags):
- `chooseStag` ranks visible stags by a cost = `myDist + crowdingPenalty -
  cooperationBonus`. crowdingPenalty kicks in only when 2+ allies are
  *closer to that stag than me*, so a natural pair forms but a 3rd hunter
  looks elsewhere. cooperationBonus when an ally is already adjacent.
  Stags with 2+ allies already adjacent get skipped entirely.
- `bestStagSide` picks the side opposite a side already claimed by an ally
  or self. If nothing is claimed yet, picks a side from the stag's tile
  parity so two hunters tend to pre-align onto the same axis.
- When already adjacent: hold if partnered on the opposite side, slide to
  the opposite side after an 18-tick wait if alone.
- Explore: if no stag visible AND nearest ally > 3 tiles away, navigate
  toward that ally (don't wander off solo — a lone stag_hunter is useless).

Results (default seed, 60s):
- 2-player self-play: 2 stags + 2 boars + 1 rabbit. Both players ~17 pts.
  Before: 0 stags ever.
- 4-player self-play: 3 stags + 2 rabbits, but very uneven (slot 0 got 3
  stags, slot 3 got 0). The losers run out of energy and get stuck — see
  open issue below.
- Mixed (2 rabbiteer + 2 stag_hunter): rabbiteers unchanged (~16 rabbits
  total), stag_hunters get 1 stag + 1 boar between them. Doesn't interfere.
- Solo (1 stag_hunter + 1 rabbiteer): stag_hunter gets 1 incidental rabbit.
  Doesn't claim it "succeeded" — there's no way for one stag_hunter to
  catch a stag — but stays out of trouble.

Open issues:
- 4-player self-play is unfair. One hunter routinely catches nothing, runs
  out of energy (server gates movement on `energy >= MoveEnergyCost = 2`),
  and is permanently locked in place. Two fixes worth trying:
  - Energy-conservation mode: if my energy < 30 and no stag visible
    within 4 tiles, hold position to let passive recharge build up
    (1.33/sec to a cap of 100).
  - Better pair assignment: stable matching where two specific hunters
    commit to one stag and others actively look elsewhere. Tricky because
    visibility differs per hunter.

## Iteration patterns that worked

1. **JSONL event log + per-bot stdout + summary text is enough for fast
   iteration.** I did not need a graphical step-through to fix
   stag_hunter; the catch events told the whole story.
2. **State the strategy in one sentence, then compute the metric that
   says yes/no.** For stag_hunter: "two of me should catch stags in
   self-play." Metric: count of `catch` events with `kind=Stag` in a 60s
   game. Before: 0. After: 2-3.
3. **Test before AND after every change with a 4-line eval.** Cycle time
   of "edit → rebuild → eval → read summary" is under 90s including the
   game itself. Resist the urge to bundle multiple changes.
4. **Look at the event log when the summary surprises you.** The "slot 3
   caught nothing" pattern only became obvious from raw catches; the
   summary just showed 0s.
5. **Mixed-roster sanity check after self-play improvement.** Each time I
   "fixed" stag_hunter I re-ran with rabbiteers in the mix to make sure
   I hadn't broken anything weird (e.g. interfering with rabbiteer
   pathfinding, claiming far stags that no one could catch). Cheap.

## "Player description" → "sane behavior" — heuristics

Going into subgoals 2 and 3, the templates that worked for stag_hunter:

- **Cooperation requires symmetry-breaking.** If two bots have identical
  code and identical inputs, they will pick the same side / same target.
  Either build in an asymmetry signal (objectId tiebreak, tile parity) or
  use sequential commitment (when an ally is already adjacent, treat the
  problem as solved-but-by-them).
- **Cost function over hard rules.** Picking a target by "first match" or
  even "nearest" loses to picking by a small cost function (distance,
  crowding, cooperation bonus). It lets you encode multiple preferences
  cleanly.
- **Each capture has a "commit" stage and a "wait" stage.** The bot
  should know when it's positioned and partnered (hold), positioned but
  alone (wait briefly, then re-think), or still en route (navigate).
- **A lone specialist is useless.** Specialists must explicitly maintain
  proximity to potential partners during downtime; default exploration
  scatters them.

## Subgoal 1 — sidekick

Strategy as stated: follow an ally, flank the prey they're adjacent to.

Changes:
- `preyAdjacentTo` now returns the *largest* prey adjacent to the ally
  (was: first in iteration order). Direct expression of the "favor bigger
  game in a tie" hint from the goal.
- Added `preyAllyApproaching` + a pre-position step: when the followed
  ally is within 2 tiles of a multi-player prey, sidekick claims the
  *nearest unoccupied* cardinal side of that prey itself rather than
  waiting for the ally to reach the prey and then reacting. The
  ally-side prediction I tried first was worse than no pre-position —
  it conflicted with stag_hunter's deterministic parity-side choice
  and they raced for the same tile.

Result: sidekick still catches things when paired with low-aggression
allies. With `nearest_hunter + 2 sidekick`, 60s gets 4 rabbits + 1 stag
+ 1 boar.

Open issue: `stag_hunter + sidekick` still catches **zero stags** in
60s. The pair stays mostly together but stag_hunter is *too aggressive*
— it triggers the stag's flee response (75% per think cycle within
range 3) before sidekick is on a complementary side, and the stag runs
in a chain ahead of them with stag_hunter behind it and sidekick
behind stag_hunter, never trapping. The fix is on the *prey* side
(make stags flee perpendicular to the closest hunter, not directly
away) or in the bot pairing (stag_hunter should hang back when it has
no ally near a stag, letting the ally lead). Out of scope for "make
existing players follow stated strategy" — sidekick *is* following
its strategy; the strategy just doesn't compose with stag_hunter's.

## Subgoal 2 — moose_hunter, elephant_hunter

Built as copies of stag_hunter with three differences each:
- target filter (`Moose` / `Elephant` instead of `Stag`)
- required hunters (3 / 4 instead of 2) — drives the cooperation-bonus
  scaling and the alliesAdjacent skip threshold in `chooseTarget`
- side selection: any unoccupied side instead of opposing-pair logic,
  with rank-based primary side assignment

The first cut had **rank-based side assignment** wrong: when several
hunters approach from the same direction (the common case for fleeing
prey since they all chase), an approach-direction-based side pick
makes them all want the same side. Fixed by sorting visible hunters
by `objectId` and using `myRank mod 4` as primary side. Three hunters
with the same view of each other pick three distinct sides.

The second bug: `chooseMoose` could pick a *different* moose than the
one I was already adjacent to, abandoning a partial encirclement.
Fixed by short-circuiting: if I'm cardinally adjacent to any visible
moose, hold there.

Results (60s, 3 moose_hunter self-play across seeds):
- default seed: 1 moose caught
- seed=1: 0
- seed=42: 0

Results (60s, 4 elephant_hunter): 0 elephants across all seeds tried.

Mixed (2 moose + 2 elephant): 0 of either big game, as expected (test d).
Failure case (1 moose_hunter + 2 rabbiteers): moose_hunter scored 0,
rabbiteers got their rabbits. Test a's negative half passes.

Open: success criteria a (moose) and b (elephant) are only flaky-passing.
The bots demonstrably *try* to encircle, but the game's fleeing dynamics
+ slow per-hunter cadence + thin energy budget make complete
encirclement rare. Three fixes worth considering, in order of cost:

1. **Game tuning** (subgoal 4): reduce `PreyFleeProb*` for Moose and
   Elephant — they're cumbersome animals; 75% flee at range 1 is more
   appropriate for rabbits than for an elephant.
2. **Smarter prediction**: predict where the prey will flee (away from
   the nearest visible hunter) and pre-position one hunter on the flee
   path. Same complexity tier as the modeler bot.
3. **Better assignment**: a stable matching pass where 3-of-N hunters
   commit to one specific moose. Effective but visibility-sensitive.

## Concurrency bug fixed during subgoal 2

The event log writer wasn't thread-safe. `player_connect` is emitted
from the HTTP handler thread; everything else from the main sim loop.
Two threads writing simultaneously would interleave bytes mid-line. A
single-line JSONL became two-record-no-newline corruption that broke
the summary script. Fixed with a `Lock` around the file write.
Symptom in the wild: `JSONDecodeError: Extra data: line 1 column 58`
when reading events.jsonl shortly after game start.

## Subgoal 3 — modeler

A bot that scores each visible prey by `reward × P(cooperation) ×
1/dist`, where P(cooperation) is the product of per-color trust
estimates over the `requiredHunters - 1` best-trusted visible allies.

State:
- `colorMem[color].seenCatch: set[PreyKind]` — observed catches we
  attributed to that color (via kill-glow rising-edge + vanished prey
  nearby).
- `colorMem[color].attempts[kind]` / `failures[kind]` — episodes where
  the modeler was adjacent to that kind with an ally nearby.
  `failures` increments when the episode ends and the prey escaped
  (still visible, not captured).
- `preyMem[idx]` and `lastKillGlowPresent[i]` — last-frame state for
  edge detection.

Trust ramps from 0.5 default → 1.0 after one observed catch → 0.05
after 5 failures. Conservative; the goal explicitly says "points don't
matter at this phase!" so we're optimizing for *behavior fidelity*.

Capture detection: the server emits a `KillGlow` object (id base
7000 + player array index, sprite id 5) on every kill participant.
The kind is read by cross-referencing a prey from the previous frame
that vanished within 1 tile of the glow.

Color extraction: server's per-player sprite id is
`PlayerSpriteBase + colorSlot * 4 + facing.ord`, so
`colorSlot = (spriteId - PlayerSpriteBase) div 4`. Stable across slots
*within a round*; resets on new connections to other slots.

Results (60s, default seed):
- (a) modeler + 3 rabbiteers: modeler caught 13 rabbits + 2 stags (top
  score, 23). Adapted to "rabbits are what's catchable here".
- (b) modeler + 3 stag_hunters: 7 rabbits + 1 stag for modeler. Tried
  stag once, mostly hunted rabbits when stag_hunters didn't show.
- (c) modeler + 3 moose_hunters: ~15 rabbits, modeler dominated. The
  moose_hunters' own coordination is flaky (see subgoal 2 notes), so
  the modeler appropriately fell back.
- (d) modeler + 3 elephant_hunters: modeler 9 rabbits + 1 boar, top
  score. Same reason.
- (e) modeler + coordinator + sidekick: 19 rabbits, modeler 5, all
  reasonable. No big game cooperation between this mix in 60s.
- (f) 4 modelers self-play: 17 rabbits + 4 boars + 1 stag. Boar is a
  2-player capture — multiple boars caught means modelers
  *cooperated*, not just opportunistically hunted rabbits.

Observations:
- Within-round learning is constrained by game length. 60s isn't long
  enough for a stable per-color model to build up; the bot mostly runs
  on its optimistic priors and adapts at the *behavior* level rather
  than at the *trust* level. Pass between rounds in tournament mode
  would let learning compound.
- Trust update is asymmetric: one success → full trust; five failures
  → distrust. This biases toward exploration, which matters because
  many "failures" are actually game-mechanics (fleeing prey) not
  partner incompetence.
- The detection mechanism is approximate (within 1 tile of glow). In
  practice this misattributes occasionally — e.g. for Moose where the
  glow can appear on a player adjacent to *a different* recently-
  vanished prey. The error gets washed out by many observations but
  shows up as noise in short games.

## Subgoal 4 — balance

Two game-side tunings, both per-kind:

1. **Flee probability scales down with size.** Base flee chances at
   range 1/2/3 are 75/50/25 for Rabbit. Multiplied by 0.80 for Boar,
   0.70 for Stag, 0.45 for Moose, 0.25 for Elephant. An elephant at
   range 1 now flees at 18% instead of 75%.
2. **Think interval scales up with size.** Base 10 ticks. +4 for
   Boar, +6 for Stag, +10 for Moose, +14 for Elephant. So big game
   not only reacts less often but also wanders less.

Result is a real shift on the moose end:
- 3 moose_hunter, multiple seeds: 2–3 moose caught per 60s game
  (was 0–1). Subgoal 2 criterion a now passes consistently.
- 4 elephant_hunter: 0–1 elephant per game depending on seed. Still
  rare. The 4-of-4-sides requirement combined with edge-of-map
  spawning and limited visibility means perfect encirclement is hard
  even with sympathetic prey AI.
- 4 stag_hunter: variable. 0 to 3 stags per game across seeds. The
  per-game noise is dominated by spawn location more than mechanics.
- 4 rabbiteer: 25–30 rabbits per game. Per-player rate similar to
  before (rabbit dynamics unchanged).
- 2 stag_hunter: 1–3 stags per game across seeds; similar to
  pre-balance.

Per-player score estimates (60s of self-play):
- Rabbiteer: 7–8 pts/player (one rabbit per ~3 seconds)
- Stag_hunter: 3–4 pts/player (variable; one catch is 2.5 pts/player)
- Moose_hunter: 7–10 pts/player (2 moose @ 3.3 pts/player each)
- Elephant_hunter: 0–2 pts/player

Reading: coordinated moose hunters are now *competitive* with
rabbiteers. Elephant hunters are still under-rewarded relative to
their difficulty. That's the next tuning if I revisit:

- Either bump elephant rewards substantially (current 18 → 30?) so
  the rare catch is worth the effort,
- Or further reduce elephant flee (maybe to 10% / 8% / 5%) so 4-side
  encirclement is plausibly achievable, paying back the reward.

I prefer the latter — score inflation cascades into trust thresholds
in the modeler.

## Energy awareness — added after interactive session

Interactive long-running game surfaced a regression hidden by 60s
eval rounds: bots had **no way to read their own energy**. They'd
keep walking into elephants, get trampled (-30 each hit), and burn
movement energy (2 per step) until pinned at 0-1. Once there, the
server denied every move (`if p.energy < MoveEnergyCost: return`)
so the bot looked frozen with `stuckCount` climbing into
`unstickStep` territory — explaining the "back and forth with no
direction" behavior the user saw.

Fix:
1. Server adds packet message type **0x08** in every per-player
   frame carrying the player's current energy as a u16 right after
   the existing 0x07 identity message.
2. `elephant_hunter` reads it into `bot.energy` and applies a
   hysteretic gate: drop below 32 → retreat to chebyshev ≥ 5 from
   any visible elephant and hold for passive recharge; climb back
   to 64 → rejoin hunt. Exception: if already at chebyshev ≤ 2
   with 2+ allies near, commit — don't bail mid-capture.
3. All other bots (`moose_hunter`, `stag_hunter`, `modeler`,
   `rabbiteer`, `sidekick`, `coordinator`, `nearest_hunter`) skip
   past the 2-byte payload so the protocol stays compatible.
4. The browser `global_client` viewer also consumes-and-ignores
   the field so the user's `/player` viewer keeps working.

End-of-round energy after fix: 22-180 (was 0-1). Captures per round
unchanged at ~1.0 average across seeds — bots no longer starve.

## Open work — not done in this pass

- Energy-conservation mode for stag_hunter (4-player self-play
  still wastes one slot to starvation).
- Stable matching between hunters and big game (one stag = two
  specific hunters, deterministically; one moose = three).
- Extract a common bot framework — five files share ~500 lines of
  identical sprite/camera/nav boilerplate.
- Per-color memory persisted across rounds (so a modeler in tournament
  mode can keep learning between games).
