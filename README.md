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
facing is `+z`. **Width** counts tiles to the turtle's right (`+x`); a negative
width means the area is on its left. **Length** counts tiles ahead; negative means
behind. So a lawn to the left and behind is `mow -70 -40`.

Position is saved to `.turtlepos` after every move. If a job is interrupted
(Ctrl+T, reboot, server restart), `home`, `mow reset` or `farm reset` navigates
back to the start. Starting a job while the saved position isn't home prints a
warning and stops; add `--here` to declare the current spot as the new home.

## Install

On the turtle, with HTTP enabled on the server:

```
wget https://raw.githubusercontent.com/djt-code/cc-turtles/main/git.lua git
git clone https://github.com/djt-code/cc-turtles
cd cc-turtles
```

Later, `git pull` inside the directory fetches only the files that changed.
`git status` shows the checked-out commit and whether the remote has moved on.
The programs `require("turtlelib")`, so run them from inside `cc-turtles`
(or `cd` there first); if HTTP is disabled on the server, drop the files into
`<world>/computercraft/computer/<id>/cc-turtles/` by hand.

## git

```
git clone <url> [dir] [-b <branch>] [--token <token>]
git pull   [dir]
git status [dir]
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
farm reset                                   go home after an interruption
```

Hover the turtle **two blocks above the farmland** (one above the crop tops) at a
corner of the bounding box, facing along the length axis with the farm to its
right. Put the output chest directly below the start position with some wheat
seeds in it: the turtle restocks seeds from the chest at the start of every pass
and whenever it runs out mid-pass (up to one per crop tile, max 256), so you never
need to hand it seeds directly.

- Learning pass classifies every tile: wheat or farmland → crop tile; bare dirt,
  grass block, path → tilled with the hoe and planted; water or anything else →
  left alone. Saved to `farm.map` on the turtle.
- Farming pass visits crop tiles only, harvests wheat at age 7 and replants it
  immediately, plants any bare farmland, and re-tills farmland that reverted to
  dirt. Returns home, dumps wheat and surplus seeds, tops seeds back up, sleeps
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
