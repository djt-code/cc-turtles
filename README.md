# cc-turtles

Turtle programs for [CC: Tweaked](https://tweaked.cc/), built around a shared
navigation library. Written for a single cheap turtle that swaps its tool
upgrade in software.

| Program | What it does |
|---|---|
| `mow.lua` | Mows every grass/fern/dead-bush tile in a rectangle, following rough terrain and routing around walls, chests and holes. |
| `farm.lua` | Learns the layout of a crop farm inside a bounding box, including which crop (wheat, carrots, potatoes, beetroot, sugar cane) grows on each tile, then loops: harvest ripe crops, replant, repair damage, dump into a chest, sleep. |
| `turtlelib.lua` | Shared library: dead-reckoned position, mid-task refuelling, obstacle map + BFS routing, terrain/flat stepping, inventory helpers, tool hot-swap, chest dumping/restocking/tidying. |
| `home.lua` | Sends the turtle back to its start after a Ctrl+T or reboot (same as `mow reset` / `farm reset`). |
| `git.lua` | Minimal git client: `clone`, `pull` and `status` for one branch over HTTP, via the Forgejo/Gitea or GitHub REST API. |
| `autocompost.lua` | A stationary turtle on top of a composter: composts everything compostable in its inventory, forever. |
| `diskclone.lua` | Runs on a plain computer: copies a directory onto every floppy a dispenser feeds into its disk drive, labels each one and ejects it. |

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
back to the start, from anywhere: a farm or lawn of any size or direction, or
past its edge. `farm reset` routes over the saved farm, flying above sugar cane
when the farm has some (or when it stopped while still learning, before a map
was saved).

A server stop in the instant between a turn and its save, or a turtle put
back by hand facing the wrong way, leaves it facing other than it thinks.
So before `farm reset` sets off, and before any farm run from a saved map,
the turtle looks at a few farm tiles near it, changing nothing, and checks
which way round they fit the map. If they fit another heading, it corrects
its own and carries on. If they fit none, it stops and asks you to place it
by hand. With the heading right, this costs about a dozen moves per start.

Starting a job while the saved position isn't home prints a
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
- When it's down to two empty slots it goes home, empties the seeds it collected
  into the chest and carries on, so cut grass doesn't drop seeds on the ground. A
  full chest makes it wait at home until there's room. Without a chest it warns
  once and keeps mowing.
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
diagonally outside one corner of the farm, facing along the length axis. Put the
output chest directly below the start position with what each crop is planted
with in it (wheat seeds, carrots, potatoes, beetroot seeds, sugar cane): the turtle restocks
them from the chest at the start of every pass and whenever it runs out mid-pass
(up to one per tile of that crop, max 256), so you never need to hand them to it
directly.

The chest (or barrel) can be anywhere from 1 to 3 blocks below the start
position, with only air between it and the turtle. The turtle doesn't remember
where the chest is. Each visit home, it moves down until it finds the chest, so
you can raise or lower the chest on an existing farm without telling the turtle,
even while it's running. Don't move the start position itself. The saved farm
map is measured from it, and it must stay two blocks above the farmland. If no
chest is found within 3 blocks, the turtle prints "No chest found below home;
keeping items." and carries on.

Farms can grow **wheat, carrots, potatoes, beetroot and sugar cane**, in any mix:
strips of different crops, or crops mixed within a strip.

**Sugar cane** grows on dirt, grass, sand, moss, mud and similar ground (same level
as the farmland), and only next to a water source, so plant it along the lanes. It
stands up to three blocks tall, reaching past the turtle's cruise height, so on a
farm with cane the turtle gets around two blocks higher than usual (and the
learning pass always scans from there). It works cane from one block above cruise
height, cutting a third block on the way in and the second from above, so every
cut block goes straight into its inventory and nothing falls to the ground. The
bottom block is never cut, because that's what regrows. A missing bottom block is
replanted with cane from the chest; if it won't take, there's no ground or no water
beside it, which counts as damage and sends the turtle into a full repair pass that
fixes the lane first and then replants.

- **Learning** only records the layout; it doesn't touch the farm. A crop or
  farmland → crop tile, and the crop growing there becomes that tile's crop;
  sugar cane, or bare sand/mud/moss → cane tile;
  water → lane; anything else → left alone. Bare farmland, and gaps settled as
  land, get the crop most of their strip grows (else the farm's most common crop,
  else wheat). A missing
  ground block or bare dirt could be either, so it takes the kind of the strip it
  lies in (a column or row that is otherwise all land, or all water); bare dirt
  outside any strip is farmed. Saved to `farm.map`, which from then on is the farm
  as it *should* be. Re-learn only when you change the farm on purpose.
- **Farming pass** serpentines over the crop tiles only, one line at a time
  along the lanes, entering each line from the end nearest the last; lanes are
  skipped. It harvests each crop when ripe (age 7; beetroot at 3) and replants
  the tile's planned crop immediately, plants any bare farmland, and re-tills
  farmland that reverted to dirt, all from cruise height (CC:Tweaked lets a hoe
  till through one block of air below the turtle). A different crop found growing
  on a tile is left to ripen, then harvested and replaced with the planned one.
  Then it goes home, dumps the harvest and surplus planting items, tops them back
  up, and sleeps
  (default 20 min; `0` for a single pass).
- **Full repair pass.** Ground missing under a crop tile, or a block in the way,
  makes the turtle go home after the farming pass and run a full repair pass
  before sleeping (untilled dirt doesn't: the farming pass fixes that itself). The
  full pass inspects every crop tile and drops to crop level over every lane tile
  to check its water, then fixes everything it found. Lane damage counts there: a
  lane tile that isn't a water *source* (dry, flowing, or filled in). It also runs
  once after `clone`, and `farm repair` runs it on demand and stops. After `learn`
  there's no extra pass: learning has just looked at every tile, so the turtle
  only rebuilds the gaps it found (missing ground, lane water that isn't a source),
  and goes straight to farming when there are none.
  - Land gets dirt, tilling and its planned crop right away.
  - A filled-in lane tile (dirt or anything else in it or on top of it) is dug
    out with a **diamond pickaxe**, which the turtle swaps in for the hoe; keep one
    in its inventory.
  - A lane tile then gets a dirt floor beneath if that's missing, dirt walls on
    every side the map doesn't call lane, and a bucket of water, which also turns
    flowing water back into a source. A wall that lands on a crop tile is tilled
    and planted on the spot.
  - Water comes from empty buckets refilled at a lane tile with two or more
    source neighbours (it regenerates), always the one nearest the tile being
    filled. When it runs dry the turtle fills every bucket it carries that the
    rest of the lane can use in one stop (up to 4, if the chest has that many
    buckets), and it stays down at lane level while pouring along a lane, so a
    long lane is filled in a few short trips. If a lane is broken up so that no
    refilling tile exists, the turtle moves one of the lane's own sources into a
    gap that creates one, and refills the borrowed tile afterwards. Water buckets
    in the chest are only needed to start a lane from nothing.
  - Only every other lane tile is poured: a tile between two sources becomes a
    source by itself, so an empty lane takes about half the buckets, and a gap
    between two intact sources takes none. The skipped tiles are checked once
    the lane is done (or on the way past while refilling), and any that didn't
    take get a bucket after all.
  - Anything it can't fix is listed and found again on the next pass.
- **Inventory.** At the start of a run and after every pass the turtle prints
  what it carries, then puts everything it doesn't need right now into the chest:
  it keeps planting items for one pass, fuel and its tools, plus dirt and buckets only
  while a repair is using them. Keep **seeds, dirt and a bucket or two in the
  chest**.
- **Fuel.** Keep **fuel in the chest** too. Every visit home tops the tank up
  from it to about one pass's worth. Before any move that would leave too
  little fuel to get home (plus a margin of 30 for detours), the turtle stops
  what it's doing, flies home, empties out, refuels from the chest, flies back
  to the exact spot and carries on, mid-learn, mid-clone or mid-pass. If the
  chest has no fuel either, it waits **at home** and says so, checking again
  whenever you put fuel in the chest or the turtle (or every 10 seconds). If a
  trip home in the middle of a farming pass took longer than the time between
  passes, the crops it already did have had time to ripen again, so it starts
  the pass over from the beginning instead of going back. A run
  starts with whatever fuel it can get, as long as it has enough to make
  headway.
- **Compost hopper (optional).** Put a hopper **directly behind the turtle's start
  position**, at the turtle's height, feeding a composter. The turtle looks for it
  at the start of every run. Composting happens while the turtle waits for its
  next pass: every 10 seconds, if the hopper has an empty slot and the chest holds
  more than twice as many wheat or beetroot seeds as the farm has tiles of that
  crop, it takes the surplus out in whole stacks (only as many as the hopper has
  empty slots for, and never taking the chest below that limit) and drops them
  into the hopper. It stops when there's no surplus left or when the next pass is
  due, whichever comes first. A single pass (`farm 0`) doesn't compost. Carrots,
  potatoes and sugar cane are never composted, since the seed is the harvest. Route
  the bone meal back however you like, e.g. a hopper under the composter into the
  farm chest.
- **Grow passes (bone meal).** After each farming pass, if the chest holds enough
  bone meal to grow the whole farm from seed (near the worst case: 4 per crop
  tile, 6 per beetroot tile, since one bone meal adds 2-5 growth stages but
  beetroot only advances one stage three times in four), the turtle does a grow
  pass: it bone meals every crop until it's ripe, harvests it and replants it.
  It repeats while there's still enough, carrying up to three stacks and fetching
  more mid-pass, and returns what's left to the chest. Sugar cane is skipped (bone
  meal doesn't grow it). If a pass uses no bone meal at all, it stops trying until
  the next cycle.
- **Tidy chest.** At every visit, before taking or moving anything and again
  before leaving, the turtle merges part stacks of the same item in the chest
  (hoppers and its own partial takes leave them scattered), so each item fills as
  few slots as possible. Then it sorts the chest from its first slot onward.
  Each item's stacks sit together, fullest first. Similar items sit side by
  side, grouped by the last word of the item's name: all the seeds, then all
  the buckets. The empty slots end up at the end. Stacks already in place
  aren't moved, so a chest that's already in order costs nothing. A full chest
  gets sorted too: the turtle holds one stack while it shuffles the rest.
- **Full inventory, full chest.** Before working each tile the turtle checks it
  has room for that tile's drops (three empty slots). If not, it goes home to
  empty what it doesn't need, then carries on where it was, so harvest never
  spills onto the ground. Restocking also leaves those slots free. If the chest
  is full, the turtle stops at home and waits, checking every 30 seconds, until
  there is room.

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
from that regenerating tile, so two buckets build any number of lanes; only
every other tile needs pouring. The site
should be roughly level with the turtle's starting height; it won't terraform
more than one block.

## autocompost

```
autocompost
```

Put the turtle directly **on top of a composter**, with a **hopper under the
composter** to take the bone meal out. Fill the turtle with anything; it never
moves. It drops compostable items in one at a time (a composter only takes one
per drop), waits while the composter is full and turning to bone meal, and when
it has nothing left to compost it sleeps until you give it more.

- What's compostable is learned, not listed, so modded items work too: an item
  the composter refuses while it isn't full isn't compostable. Those go into a
  chest **in front of the turtle** if there is one, otherwise they stay in the
  turtle.
- If the composter stays full for 10 seconds it asks whether the hopper below is
  full or missing, and keeps waiting.
- To start it at boot: `echo shell.run("autocompost") > startup.lua`.

## diskclone

```
diskclone <dir> [count] [--force]
```

Runs on an ordinary computer (not a turtle) with a **disk drive on its bottom**
and a **dispenser wired to its back**. Each cycle it sends a short redstone pulse
out the back, the dispenser drops one floppy into the hopper that feeds the
drive, and the program copies `<dir>` onto the disk, labels it and ejects it into
the collecting hopper. It keeps going until no disk arrives (the dispenser is
empty) or `count` disks have been written.

- `<dir>` must have a file named `LABEL` in its root. Its first line becomes each
  disk's label; `LABEL` itself is not copied.
- A disk that already has a label or any files on it is ejected without being
  written. With `--force` it is wiped and written like a blank one.
- Anything that isn't a floppy is ejected untouched.
- Each copy is checked against the source (same files, same sizes) before the disk
  is labelled. If the directory doesn't fit on a floppy, it stops at the first
  disk without touching it.

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

## Simulators

`sim/` holds offline simulators for testing changes without a Minecraft
server: each mocks the CC:Tweaked APIs around a small block world, runs the
real program and prints what happened. They need Python and
[lupa](https://pypi.org/project/lupa/) (`pip install lupa`):

```
python sim/run.py                  # all of them, with a summary
python sim/run.py farm_clone       # one (or several) by name
python sim/run.py --check          # syntax-check every program
```

They also run on a ComputerCraft computer or turtle that has the repo, with
`sim/runsim` (all of them) or `sim/runsim farm_clone`; full output lands in
`sim/logs/`. `sim/watchsim farm_clone` plays one out move by move on an
attached Advanced Monitor (3x2 blocks or bigger), with a top-down and a
side view; see [sim/README.md](sim/README.md) for what to build.

See [sim/README.md](sim/README.md) for what each one covers. They're tests
for the code, not for the game: the mock world only models the vanilla
mechanics the programs rely on, so confirm anything new in game too.
