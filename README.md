# cc-turtles

Turtle programs for [CC: Tweaked](https://tweaked.cc/), built around a shared
navigation library. Written for a single cheap turtle that swaps its tool
upgrade in software.

| Program | What it does |
|---|---|
| `mow.lua` | Mows every grass/fern/dead-bush tile in a rectangle, following rough terrain and routing around walls, chests and holes. |
| `farm.lua` | Learns the layout of a wheat farm inside a bounding box (tilling any dirt it finds), then loops: harvest ripe wheat, replant, dump into a chest, sleep. |
| `turtlelib.lua` | Shared library: dead-reckoned position, mid-task refuelling, obstacle map + BFS routing, terrain/flat stepping, inventory helpers, tool hot-swap. |
| `git.lua` | Minimal git client: `clone`, `pull` and `status` for one branch over HTTP, via the Forgejo/Gitea or GitHub REST API. |

## Hardware

One **basic turtle** (no need for the advanced one) with:

- **Left side:** Advanced Peripherals *Chunk Controller* (chunky turtle), so it keeps
  working when you're away. Optional.
- **Right side:** whichever tool the program needs. Both programs call
  `T.equipTool()` at start, so you can leave the diamond pickaxe and diamond hoe in
  the inventory and the turtle swaps them in itself. CC:Tweaked only accepts
  diamond or netherite tools as upgrades.

Fuel burns only on movement (about one per tile per pass). Lava buckets (1,000
each, bucket returned) are the cheapest fuel if you have a dripstone lava farm;
coal blocks (800) and dried kelp blocks (200) are the renewable alternatives.

## Install

On the turtle, with HTTP enabled on the server:

```
wget https://git.example.com/me/cc-turtles/raw/branch/main/git.lua git
git clone https://git.example.com/me/cc-turtles
cd cc-turtles
```

Later, `git pull` inside the directory fetches only the files that changed.
`git status` shows the checked-out commit and whether the remote has moved on.

If HTTP is disabled, drop the files into
`<world>/computercraft/computer/<id>/` on the server (`id` prints the number).
The programs `require("turtlelib")`, so all files must live in the same
directory and be run from there.

## git

```
git clone <url> [dir] [-b <branch>] [--token <token>]
git pull   [dir]
git status [dir]
```

Not real git: it talks to the host's REST API (branch → commit → recursive
tree → raw blobs), so there is no packfile decoding and it runs fast on the
CC VM. It records the commit and per-file blob SHAs in `.gitlite`; `pull`
downloads only blobs whose SHA changed, deletes tracked files removed
upstream, and never touches untracked files (so `farm.map` survives).
Works with Forgejo/Gitea (any host) and GitHub. `--token` is only needed for
private repos and is saved in `.gitlite` for later pulls.

## mow

```
mow <width> <length> [repeatMinutes] [notorch]
```

Place the turtle on the ground at grass level at one corner of the lawn, facing
along the *length* axis with the lawn to its **right**. An optional chest below the
start position collects seeds.

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
farm learn <width> <length> [repeatMinutes]  re-learn after changing the farm
```

Hover the turtle **two blocks above the farmland** (one above the crop tops) at a
corner of the bounding box, facing along the length axis with the farm to its
right. Put the output chest directly below the start position. Give it a stack of
wheat seeds for the first planting.

- Learning pass classifies every tile: wheat or farmland → crop tile; bare dirt,
  grass block, path → tilled with the hoe and planted; water or anything else →
  left alone. Saved to `farm.map` on the turtle.
- Farming pass visits crop tiles only, harvests wheat at age 7 and replants it
  immediately, plants any bare farmland, and re-tills farmland that reverted to
  dirt. Returns home, keeps 128 seeds, dumps the rest and all wheat, sleeps
  (default 20 min; `0` for a single pass).

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
