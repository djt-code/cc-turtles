# cc-turtles

Turtle programs for [CC: Tweaked](https://tweaked.cc/), built around a shared
navigation library. Written for a single cheap turtle that swaps its tool
upgrade in software.

| Program | What it does |
|---|---|
| `mow.lua` | Mows every grass/fern/dead-bush tile in a rectangle, following rough terrain and routing around walls, chests and holes. |
| `farm.lua` | Learns the layout of a wheat farm inside a bounding box (tilling any dirt it finds), then loops: harvest ripe wheat, replant, dump into a chest, sleep. |
| `turtlelib.lua` | Shared library: dead-reckoned position, mid-task refuelling, obstacle map + BFS routing, terrain/flat stepping, inventory helpers, tool hot-swap. |
| `home.lua` | Sends the turtle back to its start after a Ctrl+T or reboot (same as `mow reset` / `farm reset`). |
| `git.lua` | Minimal git client: `clone`, `pull` and `status` for one branch over HTTP, via the Forgejo/Gitea or GitHub REST API. |

## Hardware

One **basic turtle** (no need for the advanced one). Two layouts work:

- **Hoe + pickaxe**, one on each side. Each program makes its own tool the
  *only* tool equipped while it runs (`T.usePrimaryTool`): the other tool is
  parked in the inventory and re-equipped on exit, including after Ctrl+T. This
  matters because `turtle.dig()` tries the left tool first, so a left-hand pickaxe
  would otherwise break the dirt the hoe was meant to till. Keep one inventory slot
  free for the swap. No chunk loading, so it only runs while the area is loaded.
- **Chunky + one tool**: Advanced Peripherals *Chunk Controller* on one side so it
  keeps working when you're away, the tool on the other; the second tool can live
  in the inventory and gets swapped in the same way. CC:Tweaked only accepts
  diamond or netherite tools as upgrades.

Fuel burns only on movement (about one per tile per pass). Lava buckets (1,000
each, bucket returned) are the cheapest fuel if you have a dripstone lava farm;
coal blocks (800) and dried kelp blocks (200) are the renewable alternatives.

## Coordinates, home and reset

Everything is relative to where the turtle starts: that spot is home `(0,0,0)`,
facing is `+z`. **Width** and **length** are counted *out from the turtle*: stand
at the turtle, count `width` blocks to its right and `length` blocks ahead, and
that is the box. The turtle's own row and column are not part of it, so it parks
diagonally outside one corner (over its chest) and never mows or farms the tile
it sits on. Negative width means the area is on its left; negative length means
behind. A lawn to the left and behind is `mow -70 -40`.

Position is saved to `.turtlepos` after every move. If a job is interrupted
(Ctrl+T, reboot, server restart), `home`, `mow reset` or `farm reset` navigates
back to the start. Starting a job while the saved position isn't home prints a
warning and stops; add `--here` to declare the current spot as the new home.
If you carried the turtle back yourself, `farm reset --here` / `mow reset --here`
just marks where it is as home without moving it or starting a job (the saved
farm layout is kept).

## Install

On the turtle, with HTTP enabled on the server:

```
wget https://raw.githubusercontent.com/djt-code/cc-turtles/main/git.lua git
git clone https://github.com/djt-code/cc-turtles
cd cc-turtles
```

Later, `git pull` inside the directory fetches only the files that changed.
`git status` shows the checked-out commit and whether the remote has moved on;
`git log` lists recent commits on the branch, marking the one checked out.
The programs `require("turtlelib")`, so run them from inside `cc-turtles`
(or `cd` there first); if HTTP is disabled on the server, drop the files into
`<world>/computercraft/computer/<id>/cc-turtles/` by hand.

## git

```
git clone <url> [dir] [-b <branch>] [--token <token>]
git pull   [dir]
git status [dir]
git log    [dir] [-n <count>]
```

Not real git: it talks to the host's REST API (branch -> commit -> recursive
tree -> raw blobs), so there is no packfile decoding and it runs fast on the
CC VM. It records the commit and per-file blob SHAs in `.gitlite`; `pull`
downloads only blobs whose SHA changed, deletes tracked files removed
upstream, and never touches untracked files (so `farm.map` survives).
Works with GitHub and Forgejo/Gitea (any host). `--token` is only needed for
private repos and is saved in `.gitlite` for later pulls.

## mow

```
mow <width> <length> [repeatMinutes] [notorch] [--here]
mow reset
```

Place the turtle on the ground at grass level diagonally outside one corner of the
lawn, facing along the *length* axis. An optional chest below the start position
collects seeds.

- Only cuts blocks in the `T.diggable` list (short/tall grass, ferns, dead bushes).
  Everything else is terrain or an obstacle.
- Climbs steps up to 3 blocks, follows dips, and treats drops deeper than 3 as a
  crevasse to be routed around rather than entered.
- Tiles it can't reach are retried at the end of the pass from whatever side it
  can get to; anything still unreachable is printed as coordinates.
- Grass doesn't regrow naturally, so a single pass is usually enough; the repeat
  argument is there if a mod on your server spreads it.
- **Lighting:** with torches in its inventory it places them as it mows, on a
  diamond lattice so every tile is within taxicab distance 12 of a torch (mobs need
  block light 0 to spawn since 1.18; a torch is light 14, so 13 is the limit and 12
  leaves a margin). That's about one torch per 313 tiles — 18 for a 70×40 lawn. The
  startup line tells you how many sites there are. Pass `notorch` to disable, or
  set `TORCH_RADIUS = 6` for a pre-1.18 server. Torches already present are left
  alone on repeat passes.

## farm

```
farm <width> <length> [repeatMinutes]        first run: learn layout, then farm
farm [repeatMinutes]                         later runs: use saved layout
farm learn <width> <length> [repeatMinutes]  save a new layout after changing the farm
farm repair                                  inspect every tile once, fix damage, stop
farm clone [repeatMinutes]                   build the last learned farm HERE
farm reset                                   go home after an interruption
```

Hover the turtle **two blocks above the farmland** (one above the crop tops),
diagonally outside one corner of the farm, facing along the length axis. Put the output chest directly below the start position with some wheat
seeds in it: the turtle restocks seeds from the chest at the start of every pass
and whenever it runs out mid-pass (up to one per crop tile, max 256), so you never
need to hand it seeds directly.

- **Learning** only records the layout; it doesn't touch the farm. Wheat or
  farmland → crop tile; water → lane; anything else → left alone. A missing
  ground block or bare dirt could be either, so it takes the kind of the strip it
  lies in (a column or row that is otherwise all land, or all water); bare dirt
  outside any strip is farmed. Saved to `farm.map`, which from then on is the farm
  as it *should* be. Re-learn only when you change the farm on purpose.
- **Farming pass** works the layout one line at a time along the lanes, entering
  each line from the end nearest the last, so it never flies back across the
  farm. It harvests wheat at age 7 and replants it immediately, plants any bare
  farmland, and re-tills farmland that reverted to dirt, all from cruise height
  (CC:Tweaked lets a hoe till through one block of air below the turtle). Over a
  lane it drops to crop level to check the water and stays down along the lane.
  Then it goes home, dumps wheat and surplus seeds, tops seeds back up, and sleeps
  (default 20 min; `0` for a single pass).
- **Repair mode.** Ground missing under a crop tile, a lane tile that isn't a
  water *source* (dry, flowing, or filled in), or a block in the way counts as
  damage. After a pass that found any, the turtle goes home, restocks and repairs
  before sleeping. `farm repair` does the same on demand: one inspection sweep
  (no harvesting), then the fixes.
  - Land gets dirt, tilling and wheat right away.
  - A filled-in lane tile (dirt or anything else in it or on top of it) is dug
    out with a **diamond pickaxe**, which the turtle swaps in for the hoe; keep one
    in its inventory.
  - A lane tile then gets a dirt floor beneath if that's missing, dirt walls on
    every side the map doesn't call lane, and a bucket of water, which also turns
    flowing water back into a source.
  - Water comes from one bucket, refilled at a lane tile with two or more
    source neighbours so it regenerates (or from water buckets in the chest).
  - Anything it can't fix is listed and found again on the next pass.
- **Inventory.** At the start of a run and after every pass the turtle prints
  what it carries, then puts everything it doesn't need right now into the chest:
  it keeps seeds for one pass, fuel and its tools, plus dirt and buckets only
  while a repair is using them. Keep **seeds, dirt and a bucket or two in the
  chest**.

### Cloning a farm

`farm clone` rebuilds the last learned layout wherever the turtle is now, then
farms it. Park the turtle the same way you would for a new farm (two blocks
above ground level, diagonally outside the corner, chest below) with a pickaxe
and a hoe on board, and **dirt, seeds and two water buckets in the chest**. It
runs two phases: with the pickaxe it clears the crop level, digs the lane
trenches and removes stone where land is wanted; with the hoe it fills, tills
and plants the land, then floors and walls each lane and waters it. Lanes are
walled on every side the map doesn't call lane, including the ends, so nothing
runs out of the box. Each lane is bootstrapped by pouring the two buckets at
tiles 1 and 3 — Minecraft turns tile 2 into a source — and the rest is scooped
from that regenerating tile, so two buckets build any number of lanes. The site
should be roughly level with the turtle's starting height; it won't terraform
more than one block.

## Library

`turtlelib.lua` is self-contained. A minimal program:

```lua
local T = require("turtlelib")
T.cfg.width, T.cfg.length = 10, 10
T.step = T.stepTerrain          -- or T.stepFlat for a fixed height
T.diggable = { ["minecraft:short_grass"] = true }

for _, t in ipairs(T.serpentine()) do
    if T.goTo(t.x, t.z) then T.settle() end
end
T.goTo(0, 0)
```

Everything is relative to the start: `(0,0,0)` facing `+z`, `+x` to the right.
`T.goTo` learns obstacles as it bumps into them and re-plans with BFS; it returns
`false` only when no route exists through the known map.
