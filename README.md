# cc-turtles

Turtle programs for [CC: Tweaked](https://tweaked.cc/), built around a shared
navigation library. Written for a single cheap turtle that swaps its tool
upgrade in software.

| Program | What it does |
|---|---|
| `mow.lua` | Mows every grass/fern/dead-bush tile in a rectangle, following rough terrain and routing around walls, chests and holes. |
| `farm.lua` | Learns the layout of a crop farm inside a bounding box, including which crop (wheat, carrots, potatoes, beetroot, sugar cane) grows on each tile, then loops: harvest ripe crops, replant, repair damage, dump into a chest, sleep. |
| `mine.lua` | Digs a tunnel of any width and height, as long as asked or as long as its supplies last, following every ore vein it touches. It builds a new home from chests every so often, carries its supplies forward, and brings the valuables back to the start at the end. |
| `turtlelib.lua` | Shared library: dead-reckoned position, mid-task refuelling, obstacle map + BFS routing, terrain/flat stepping, six-direction look/dig/place/move, inventory helpers, tool hot-swap, chest dumping/restocking/tidying. |
| `home.lua` | Sends the turtle back to its start after a Ctrl+T or reboot (same as `mow reset` / `farm reset`; for `mine`, use `mine reset`). |
| `git.lua` | Minimal git client: `clone`, `pull`, `status` and `log` for one branch over HTTP, via the Forgejo/Gitea or GitHub REST API. |
| `cat.lua` | Prints files a screenful at a time (CraftOS has no `cat`): `cat claude.log`. |
| `echo.lua` | Prints its arguments, or writes them to a file with `>` (replace) or `>>` (append), which the CraftOS shell can't do itself. The shell strips double quotes, so use single quotes for Lua strings. |
| `claude.lua` | Lets Claude drive the turtle: you type a goal, the model writes Lua that runs on the turtle (with `turtlelib` in scope), sees what came of it, and carries on until it's done or asks you something. |
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
behind. A lawn to the left and behind is `mow -70 -40`. The exception is `mine`:
a tunnel includes the turtle's own column and row (see [mine](#mine)).

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
`git log` lists recent commits on the branch, marking the one checked out,
a screenful at a time (press a key for the next).
If HTTP is disabled on the server, drop the files into
`<world>/computercraft/computer/<id>/cc-turtles/` by hand.

To run the programs from any directory, put `cc-turtles` on the shell's
search path:

```
cc-turtles/deploy/install
```

It adds a line to the top of `/startup.lua` (or writes
`/startup/00-cc-turtles.lua` if `/startup` is a directory) that puts the
repo's directory on the path at boot, then reboots. `--no-reboot` puts it on
the path in the current shell instead. Running it again changes nothing.
`deploy/` itself isn't on the path, so `install` doesn't become a command.

The shell looks a program name up in each directory on the path in turn,
`.lua` optional. Run from anywhere, a program still finds `turtlelib` and
keeps its files (`.turtlepos`, `mine.job`, `farm.map`, `claude.key` ...)
next to itself in `cc-turtles`, not in the current directory.

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
  few slots as possible. Then it sorts the chest, packed against its last
  slot. Each item's stacks sit together, fullest first. Similar items sit side
  by side, grouped by the last word of the item's name: all the seeds, then all
  the buckets. The empty slots come first, because slot 1 is the working slot:
  hoppers fill it and the turtle takes from it. Stacks already in place
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

## mine

```
mine <width> <height> [length] [--spacing N] [--no-lights] [--here]
mine --resume
mine haul
mine ... --new
mine reset [--home N | --to-start | --here]
```

Digs a tunnel `width` blocks wide (to the right; negative: to the left) and
`height` blocks tall (up; negative: down), `length` blocks long. Without a
length, it keeps going until it can't. The turtle's own column and row are
part of the tunnel: put the turtle where one bottom corner of the tunnel
should start (top corner, for a negative height), facing along it. The tunnel
starts with the block in front of it. `mine 3 3 32` digs a 3x3 tunnel 32
long, up and to the right of the turtle; `mine 3 3` digs one as long as its
supplies last.

Put **two chests** at the start: one directly **above** the turtle for
valuables and supplies, and one directly **below** it for bulk. Stock the top
one with **fuel and chests**, and **torches** if you want the tunnel lit. Bulk is stone, cobblestone, deepslate,
andesite, diorite, granite, tuff, dirt, gravel, sand, netherrack and the
like. Everything else counts as a valuable, including anything it doesn't
recognise. Needs a pickaxe, equipped or in the inventory.

- **Homes:** the tunnel is dug a segment at a time. At the end of each
  segment the turtle builds a new home from two chests:
  - one set into the wall beside its start column, for valuables and supplies;
  - one under the floor (over the ceiling, for a downward tunnel) for bulk.

  Its trips to unload or refuel only ever go back to the nearest home, never
  all the way to the start. The spacing is chosen so a segment's bulk fits
  in one chest, at most 64 blocks (64 for a 3x3 tunnel); `--spacing N`
  overrides it.
- **Supplies move forward:** building a home, the turtle carries the spare
  chests and the fuel from the old home to the new one, in as many trips
  as it takes, leaving a stock of 8 fuel items in every home along the
  way, so a resume from any home finds fuel there. Coal it mines goes into
  the home's chest and fuels it too: coal ore is ore like any other, so
  every coal vein the tunnel touches (and, with a scanner, every one in
  reach) ends up in the chests, and the surplus travels forward with the
  supplies. Bulk stays in the home it was mined near. Valuables stay in
  their home's chest until the end.
- **Stopping:** it stops when:
  - it runs out of chests for the next home;
  - it doesn't have enough fuel to go on and still get back;
  - a home's chest is full or missing;
  - it reaches something it can't dig through (bedrock).

  Then, or once the tunnel is as long as asked, it walks back to the start.
  On the way it collects the valuables from every home: the most valuable
  first when it can't carry them all (diamonds and netherite before gold
  before iron, and so on), swapping out cheaper things for better ones. It
  leaves what it brings in the top chest at the start, and says what it had
  to leave behind and in which home. The tank always keeps enough fuel for
  this walk back.
- **Resume:** supplies left over stay in the last home. After a stop, top up
  the start's top chest with chests and fuel and run `mine --resume`. It
  carries the new supplies out to the last home and carries on from there.
  Run from the last home (where `mine reset` leaves it), it just carries on
  from there. It keeps a log of how far it got with the segment it's
  digging (`mine.seg`: the lane, and the block along it), so it carries on
  from where it stopped. It doesn't dig or look over the lanes it finished
  again. Run from an earlier home (`mine reset --home N`), it goes over the
  segments from that home on, which are dug already, without digging them
  again, and passes the homes already built without building them again.
  Then it carries on past the last one. Use this when part of the tunnel
  has flooded.
- **Fixing water on resume:** water in tunnel it dug before is getting in
  from somewhere. So whatever it goes over again on a resume (the segments
  from an earlier home, and the finished part of the segment it carries on
  with) it walks first along the floor of the middle column (the middle of
  every three, for a wider tunnel). Water in the tunnel ends up on the
  floor and spreads across it, so it reaches the middle. If the middle
  column's floor isn't dug yet (it was stopped partway), it walks a side
  column's floor that is. If that finds any water, it walks all the other
  lanes too. It follows any water it finds
  to where it comes in, a hole in the ceiling or a waterlogged block say,
  and seals that. It also fills any hole or water in the floor it walks
  over, and puts back torches that were washed away. Once it has sealed
  a leak it waits a moment for what's left to drain, so it doesn't chase
  that. (The turtle stirs water up as it moves: it pushes flowing water
  out of the block it moves into, and a block it leaves between two
  sources becomes one.) To start a fresh tunnel somewhere
  else instead, add `--new`.
- **Haul:** `mine haul` shuttles the valuables in the homes back to the start
  whenever you like. Run it from the start or from the last home. It walks
  out to the last home, then back collecting from every home (the most
  valuable first when it can't carry everything), and leaves them in the
  start's top chest. It repeats until the homes are empty, refuelling from
  the top chest at the start; it stops if there isn't enough fuel for another
  trip. Supplies stay where they are, so `mine --resume` still finds them.
- **Room above the valuables chest:** a chest can't be opened with a solid
  block on top. So the turtle digs out the block above each home's
  valuables chest, from the tunnel row above the home. If that lets water
  in, it steps in and seals what feeds it. Homes built before this get it
  when the turtle next starts from them or passes them on a resume. It
  isn't done for a tunnel 1 high, or one going down, where the bulk chest
  is above the home.
- **Lanes:** each segment is dug in lanes along it: every row of the two side
  columns, and every third row plus the top and bottom ones in the columns
  between. The rows in between are dug from above and below. So the turtle
  touches every block of the walls, floor, ceiling and far end, and looks at
  each one.
- **Veins:** an ore it touches is mined along with its whole vein. That means
  anything tagged as an ore (so modded ores too), any `*_ore` block, and
  ancient debris. The turtle follows the vein block by block, looking all round
  each one. It goes at most 4 blocks (`VEIN_REACH`) out from the tunnel, and
  never back past its start.
- **Lava and water:** a turtle can't be hurt by lava, and only by explosions
  that aren't caused by mobs (TNT, beds in the Nether) if it's a normal turtle.
  But lava burns any item that falls into it, and it makes the tunnel deadly
  for you later. So lava or water touching the tunnel or a vein is sealed with
  a bulk block (the turtle keeps a stack, and fetches more if it runs out).
  Falling gravel and sand are dug until they stop coming.
- **Water in the tunnel:** water can't just be dug out. It flows back into
  an open block from any water beside or above it. A block with two sources
  beside it becomes a source itself. A turtle that moves into a source leaves
  the source behind when it moves on. So the turtle fills a source in the
  tunnel with a bulk block and digs it out. If water comes back (from a lake
  above the ceiling, or an aquifer), something next to that block feeds it.
  The turtle steps in and seals the water touching it outside the tunnel.
  It fills the sources touching it inside, steps back, and tries again.
  Those fillings are dug out again later: ahead by the lanes, behind at the
  end of the segment, by when what fed them is sealed. Flowing water that
  nothing beside it feeds, in tunnel it's digging, is from what it's
  digging through: left over and draining, or from sources the lanes will
  reach. But falling water always has water above feeding it, and water in
  tunnel dug before (going over it on a resume, or on a trip) is getting in
  from somewhere. That it follows upstream through the tunnel to where it
  comes in, and seals. It goes up while the water's falling, else toward
  stronger water, looking ahead, above and below before it turns to look
  sideways. Through dug tunnel it wades through flowing water (the turtle
  pushes it out of the block it moves into) and only looks at the walls,
  floor and ceiling, rather than stepping in and out of each wet block.
  It doesn't put a torch where it has just stepped through water until it
  has stopped the water, so the torch isn't washed away.
- **Hidden water:** a waterlogged block holds water but doesn't look like
  it. Glow lichen, pointed dripstone, hanging roots and sculk veins are
  examples. To the turtle it's just a block, but it's a water source that
  never stops. Water plants (seagrass, kelp) are water too. Thin blocks
  that aren't solid (glow lichen, vines, grass, snow layers) don't keep
  water out either. So any of these in the tunnel's walls, floor or
  ceiling is dug out and replaced with a bulk block, waterlogged or not.
  A scan reports them, so with a scanner it turns to them as it does to
  water.
- **Keeping fluid out as it digs:** a turtle in a block keeps fluid out of
  it, and only a block touching the walls, floor or ceiling can let fluid
  in. Every such block is on one of its lanes, and it only opens them from
  inside: it doesn't clear them from the lane beside. So it's always
  standing in a block when it first opens it to the outside. If the dig
  lets water in, it moves in, pushing the water out, and seals where it
  came from before it spreads. That matters most for lava, which is too
  slow to show up right after a dig. With a scanner, it also seals lava and
  water the scan saw:
  - next to the ways it digs out to veins and to ore further out;
  - next to a torch niche, from inside the niche, before the torch goes in.

  Water washes torches away, and lava burns any item it touches. The ways it dug out to veins are sealed too if
  water got into them. In tests through an underground lake and under one,
  it left the tunnel dry with nothing leaking in.
- **Trips home:** before a dig with fewer than 2 empty slots, or a move that
  would leave too little fuel, it goes to its home. There it sorts its
  inventory into the two chests (tidying the valuables chest), refuels, and
  comes back to the same spot, up the vein if it was in one. It only travels
  through blocks it has already dug, so nothing is dug, and nothing can
  spill, on the way. It never drops items on the ground. Whenever a slot
  fills, it first merges part stacks of the same item, which often saves
  the trip (see [Library](#library)). It carries up to 32 fuel items (coal)
  from its home and burns them as it goes, so a low tank seldom means a
  trip; the fuel it carries counts whenever it works out whether it can
  afford a trip. It also carries 64 bulk blocks for sealing, or 192 once
  drying out water has used them up. Resumed from the start of a long
  tunnel, it fills its tank from the start's chest for the walk out to the
  last home and back before setting off. Resumed from an earlier home than
  the last, it first fetches fuel from the last home, where the supplies
  are. Going on to a home that's already built only needs the fuel to get
  there, since the supplies are there.
- **Geo Scanner:** put an Advanced Peripherals Geo Scanner in the start's
  top chest and the turtle takes it along and uses it instead of checking
  every wall block by hand. There's no slot to spare for it: one side holds
  the pickaxe, the other the chunk controller. So every 15 blocks it swaps
  the scanner in for the pickaxe, scans, and swaps back. The chunk
  controller never moves, so its chunk stays loaded. With the scanner:
  - **Lining up:** a scan reports blocks along the world's directions
    (north, east...), which a turtle doesn't know. So the turtle tries all
    four ways round, and keeps the one that puts none of the scanned blocks
    where it knows it has already dug. A scanner that gives offsets from
    the turtle's own facing (Advanced Peripherals 0.8) needs no lining up.
    It's only skipped as "heading looks off" if another heading would fit
    the dug blocks far better. Water and lava don't count, since what it
    dug can fill with them, and a few stray blocks (fallen gravel) don't
    matter.
  - **Walls and veins:** it only turns to look at blocks the scan says are
    ore, lava or water, both in the walls and round each block of a vein.
    In tests it turned about a fifth as often.
  - **Ore further out:** right after each scan, it collects what that scan
    found. It tunnels out to ore up to 6 blocks from the tunnel
    (`SCAN_REACH`) and mines the whole vein, then goes on with the tunnel.
    It goes from one deposit straight to the nearest one left, rather than
    back to the tunnel between them. It goes back only part of the way it
    came, or back to the tunnel, when that's shorter (digging counts double,
    since a step through what's dug is quicker). It steps the way it already
    faces where it can, and backs out of dead ends without turning round. It
    refills any floor it dug through, and seals lava on the way.
  - **Diamonds and coal:** it always mines any diamond or coal a scan shows,
    however far out: diamonds for their worth, coal because it's the
    turtle's fuel. Otherwise it goes no further than the scan reached (8
    blocks along any direction from where the scan was taken). The exception
    is a diamond or coal vein: that's followed to its end, past the scan if
    need be. With or without a scanner, a diamond or coal vein the turtle
    finds is always followed all the way.
  - **Coal first when fuel is low:** when its fuel gets low, it fetches the
    coal a scan found first, and burns it.
  - **Cost:** scans are radius 8, which costs no fuel (Advanced Peripherals'
    defaults: free up to 8, 2 seconds between scans).

  At the end the scanner goes back into the start chest with the valuables.
- **A floor you can walk on:** the turtle doesn't need a floor, but you do.
  Every block under the tunnel's bottom row is filled with a bulk block if
  it's any of these:
  - a hole: a crevasse, a cave, or where ore in the floor was mined out;
  - lava or water;
  - something you shouldn't stand on: grass, snow, cobwebs, pointed dripstone.

  A crevasse across the tunnel gets a bridge one block thick. The turtle tops
  its stack of bulk blocks up from each home's bulk chest, and goes back for
  more if it runs out halfway across. Openings in the walls and ceiling (into
  caves) are left open, apart from lava and water.
- **Lighting:** given torches, the turtle lights the tunnel so mobs can't spawn
  on its floor (since 1.18 they need block light 0), using as few torches as
  that takes:
  - It aims for light 2 or more on every floor block, one level of margin.
  - Each torch goes in a niche it digs into the wall at floor level, beside its
    start column, outside the tunnel, so the turtle never digs it up again.
  - A 3-wide tunnel gets one every 19 blocks; narrower tunnels need fewer.
  - Wider than 8, both walls get them.
  - A torch that would land on a home's wall chest moves one block along.
  - If a niche opens into a cave, with nothing behind or under it to hold a
    torch, the turtle steps into the niche, puts a bulk block under it, and
    stands the torch on that.
  - Torches are supplies: they move forward with the homes, and it keeps up to
    64 on board.
  - Lighting is optional. With no torches it says so once and keeps mining.
    `--no-lights` turns it off altogether; torches are then treated like any
    other valuable.
  - Light doesn't stop slimes, which spawn in slime chunks at any light level.

  Torches *you* place inside the tunnel get dug up wherever the turtle's path
  crosses them. That's everywhere in the stretch it's still digging, and the
  start column's bottom row on its way back. It keeps them and reuses them.
  Behind it, torches higher up the walls are safe.
- **Never dug:** chests, barrels, shulker boxes, spawners and ComputerCraft
  blocks (other turtles, computers).
- **Reset:** position is saved after every move. After a Ctrl+T or a server
  restart, `mine reset` brings the turtle to the **last home it built**, even
  from inside a vein: it digs straight back into the tunnel, then follows it.
  From there `mine --resume` carries on, or `mine haul` brings the valuables
  back. `mine reset --home N` goes to home N instead (0 is the start; homes
  are numbered from the start, every `--spacing` blocks), and
  `mine reset --to-start` all the way back to the start.
  It only counts as arrived if the home's chests are there; if not, its
  saved position or heading must be wrong and it stops and says so.
  - **Ctrl+T is safe:** a turtle command (a move or a turn) waits for the
    game to do it. A plain Ctrl+T in that wait stops the program, but the
    turtle still moves or turns, without the program recording it. So `mine`
    holds a Ctrl+T back until the move or turn is saved (`T.run` in
    turtlelib).
  - **Checking its heading:** before setting off, `mine reset` looks all
    round. It compares what it sees with what it knows of the tunnel there:
    finished segments are dug, walls are solid. If exactly one way round
    fits, it goes by that.
  - **Stopping if lost:** if the way back starts digging through far more
    rock than it should, its position or heading must be wrong, so it stops
    instead of wandering off.
  - **Recovering by hand:** give it a label (`label set miner`, or it loses
    its files when picked up). Empty it, pick it up, and place it back at the
    start, facing down the tunnel. Then run `mine reset --here`.

A second turtle working as a courier is planned: it would shuttle between
the start and the newest home, bringing chests and fuel out and valuables
back, so the miner can go on for as long as the start is kept stocked.

## claude

```
claude [goal words...] [--model id] [--effort low|medium|high] [--steps N] [--confirm]
claude dig a 3 by 3 tunnel 20 blocks ahead and come back
```

Claude (the model, over the Anthropic API) drives the turtle. It gets one
tool that matters, `lua`: the code it writes runs on the turtle with
`turtle`, `peripheral` and `turtlelib` as `T` in scope, and whatever the
code prints or returns goes back to it. Two more tools: `status` (where it
is, fuel, what's in front, above and below, the inventory) and `ask_user`
(it asks you at the keyboard). It works at the goal call by call, says what
it did when it stops, and then waits for the next thing to do; an empty
line quits. Ctrl+T stops it, and because it runs under `T.run` the saved
position stays right, so `home` works afterwards. It picks up `.turtlepos`
from the last job if there is one; otherwise where it starts is `(0,0,0)`
facing `+z`.

Setup:

- Put an API key in `claude.key` next to the program (`edit claude.key`,
  paste, save). Make it a key of its own with a spending limit: anything on
  a computer's disk can be read by whoever can open the turtle or the
  server's save folder. The file is in `.gitignore` and `git pull` never
  touches untracked files.
- The server's CC:Tweaked config must let HTTP reach `api.anthropic.com`,
  the same `http.rules` allow-list that lets `git` reach your host.

Each tool call is one API round trip carrying the whole conversation, so a
long job is many calls; the system prompt and tools are marked for prompt
caching, and the token totals are printed when a goal ends. The defaults
are `claude-opus-5-5` at `medium` effort and at most 60 tool calls per goal
(it's then told to stop and sum up); `--confirm` shows each piece of code
and asks before running it. A refusal by the model's safety classifiers is
retried server-side on a fallback model (the API's `fallbacks: "default"`),
so an odd phrasing doesn't end the job. The code it runs can't reach `fs`,
`http` or `shell`, so a slip can't read the key or rewrite the programs;
it can do anything the turtle can, though, so keep valuables out of reach
the first few times, and `claude.log` keeps every piece of code it ran
and what came back.

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
- To start it at boot: `echo "shell.run('autocompost')" >> /startup.lua`
  (`shell.run('/cc-turtles/autocompost')` if `cc-turtles` isn't on the path).

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

A turtle puts what it picks up into the first slot, counting on from the
selected one, that is empty *or* holds the same item. So an empty slot ahead
of a part stack starts a second stack of that item. `T.tidyInventory()`
merges part stacks of the same item, moves part stacks into empty slots
ahead of them, and selects slot 1, so the next pickup joins its stack. It
costs nothing when there's nothing to do. `T.ensureRoom` and `T.dumpDown`
call it, so mow and farm tidy before every tile and after emptying, and the
miner does whenever a slot fills. Each move between slots takes as long as a
step (moves, turns, digs and transfers all take 8 ticks).
`T.goTo` learns obstacles as it bumps into them and re-plans with BFS; it returns
`false` only when no route exists through the known map.

Beyond columns, the library has six directions: `0..3` as `T.dir` plus
`"up"` and `"down"`. `T.look(d)`, `T.digDir(d)`, `T.placeDir(d)` and
`T.moveDir(d)` face `d` first (up and down need no turn); `T.turnsTo(d)`
says how many turns that takes, `T.eachAround(skip, fn)` goes round the
turtle fewest turns first, `T.stepToward(p)` picks the step toward a
position that turns least. Positions are `{ x, y, z }` tables: `T.here()`,
`T.at(p)`, `T.neighbour(d)`, `T.dirTo(p)`, `T.dist(a, b)`, `T.posKey(p)`.
Chest sides are CC's `"front"`, `"top"` and `"bottom"`: `T.dropSide`,
`T.suckSide`, `T.inspectSide`, `T.containerOn(side)`, `T.sideDir(side)`.
Items are named or picked by a test: `T.selectItem(what)`,
`T.countItem(what)` and `T.findSlot(what)` take a name or a
`function(name, item)`; `T.containerCounts(side)` gives everything a chest
holds; `T.findTool("_pickaxe$")` finds the equipped or carried tool.
`T.hasFuel(n)` is the "unlimited or at least n" check, `T.setDir(d)` fixes
a heading a program has worked out, `T.lookAround()` turns on the spot to
see all four sides, and `T.sortedKeys(t)` gives a table's keys in a set
order (so what a program does doesn't depend on `pairs`).

## Simulators

`sim/` holds offline simulators for testing changes without a Minecraft
server: each sets a scenario up in one of the mock worlds in `sim/lib/` (a
farm, rock to tunnel through, a composter: the CC:Tweaked APIs around a
small block world), runs the real program and prints what happened. They
need Python and [lupa](https://pypi.org/project/lupa/) (`pip install lupa`):

```
python sim/run.py                  # all of them, with a summary
python sim/run.py farm_clone       # one (or several) by name
python sim/run.py --check          # syntax-check every program
```

They also run on a ComputerCraft computer or turtle that has the repo, with
`sim/runsim` (all of them) or `sim/runsim farm_clone`; full output lands in
`sim/logs/`. `sim/watchsim farm_clone` (or `sim/watchsim mine_tunnel`)
plays one out move by move on an attached Advanced Monitor (3x2 blocks or
bigger), with a top-down (for the mine, a plan) and a side view; see
[sim/README.md](sim/README.md) for what to build.

See [sim/README.md](sim/README.md) for what each one covers. They're tests
for the code, not for the game: the mock world only models the vanilla
mechanics the programs rely on, so confirm anything new in game too.
