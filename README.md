# Stag Hunt

Cooperative BitWorld hunting game where players surround prey together:
rabbits go down alone, but stags, moose, and elephants require coordinated
multi-player encirclement.

## Running

```bash
nimble build
./staghunt --address:0.0.0.0 --port:8080
```

Open `http://localhost:8080/client/global` to spectate.

## Bots

Eight reference Nim bots ship in `players/`:

- `rabbiteer` — chases rabbits only (solo kills, guaranteed energy income)
- `nearest_hunter` — greedy A* to the closest prey
- `stag_hunter` — coordinates 2-hunter stag captures
- `moose_hunter` — coordinates 3-hunter moose encirclements
- `elephant_hunter` — coordinates 4-hunter elephant captures
- `big_game_hunter` — picks the biggest prey it can take given current coalition size
- `sidekick` — follows allies and assists multi-player kills
- `modeler` — adaptive bot that learns per-ally cooperation probabilities

Build one bot:

```bash
nim c --path:src players/rabbiteer/rabbiteer.nim
./players/rabbiteer/rabbiteer --address:localhost --port:8080
```

Run a full local eval (server + N bots):

```bash
./eval.sh rabbiteer,rabbiteer,stag_hunter,stag_hunter
```

See `learnings.md` for iteration notes and `stats.md` for per-change capture-rate snapshots.
