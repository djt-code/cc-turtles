# Simulators

Offline tests for the turtle programs. Each `.lua` file here is a
scenario: it sets up one of the mock worlds in `lib/`, runs the real
program from the repo root, and prints the program's output plus a summary
of the world afterwards (lanes, crops, chest contents, moves). The mocks
replace the CC:Tweaked APIs the programs use (`turtle`, `peripheral`,
`fs`, `sleep`, `os.pullEvent`, ...) around a small block world in memory;
nothing is written to disk.

```
pip install lupa
python sim/run.py                  # all of them, then an ok/ERROR summary
python sim/run.py farm_clone       # by name, ".lua" optional
python sim/run.py --check          # syntax-check the programs and these files
```

Or on a ComputerCraft computer or turtle that has the repo (`git clone`),
no Python needed:

```
sim/runsim                         # all of them, then a summary
sim/runsim farm_clone              # by name
sim/runsim --list                  # what there is
```

`runsim` runs each simulator in a sandbox (`lib/sandbox.lua`: its own globals, its own `os`,
its own `loadfile`/`require`), so the mocks never touch the real computer,
and yields about once a second so CC doesn't stop it for running too long
without yielding. Full output goes to `sim/logs/<name>.log`; the screen
scrolls it past as it runs. Ctrl+T stops it.

## Watching one on a monitor

`sim/watchsim <name>` plays a simulator out move by move on an attached
monitor:

- for a farm, a **top-down view** of it (+z up the screen, +x to the
  right), the turtle as a yellow arrow;
- for the mine (`mine_tunnel`), a **plan** instead: a level slice through
  the rock at the turtle's height, so you see the tunnel open up lane by
  lane and the turtle wander off into ore veins;
- a **side view**, a slice through the turtle's current x (z across, y up),
  so you see it dip into lanes, dig and climb. For the mine, both views
  follow the turtle along the tunnel;
- the move count, position, facing and fuel, and the program's own messages
  as it prints them. The computer's screen shows the simulator's report.

Keys on the computer: **space** pause/resume (or tap the monitor),
**right** one move while paused, **up/down** faster/slower (from 1 s down
to one move per tick), **f** skip to the end of the current farm run,
**q** quit. `sim/watchsim` on its own lists the simulators it can show
(the farm ones and `mine_tunnel`; the others have no world to draw).

What to build:

- An **Advanced Computer** (or advanced turtle) with the repo on it
  (`git clone`, which needs HTTP enabled on the server).
- An **Advanced Monitor** wall: plain monitors have no colour, and the
  views rely on it. Monitors join into one screen when placed edge to edge
  in a flat rectangle. Size it for the largest farm you'll watch (the
  viewer runs at text scale 0.5):

  | Simulators | Needs (characters) | Smallest monitor |
  |---|---|---|
  | `farm_reset` (5x22) | 65x27 | 4 wide x 3 tall |
  | `farm_clone`, `farm_clone_lane_fallback`, `farm_fuel` (7x16) | 57x21 | 3 wide x 2 tall |
  | `farm_pass_moves` (9x8) | 45x15 | 3 wide x 2 tall |
  | every other `farm_*` (5x6) | 33x15 | 2 wide x 2 tall |
  | `mine_tunnel` (follows the turtle) | 51x20 | 3 wide x 2 tall |

  **4x3 (78x38) shows all of them, with room for plenty of the
  messages; 3x2 shows all but `farm_reset`.** The mine's views grow with
  the monitor: a bigger one shows more of the tunnel at once. A monitor that's too small gets a message naming the
  size to build.
- Put the monitor against any side of the computer, or connect it with
  wired modems (right-click each modem to connect it). With more than one
  monitor attached, name the one to use: `sim/watchsim farm_clone
  monitor_0`.

What the colours mean: in the mine, `##` rock in its own shade (stone,
deepslate, andesite, diorite, granite, tuff), ores by symbol on the
metal's colour (`Fe` iron, `Au` gold, `Di` diamond, `Em` emerald, `Co`
coal, `La` lapis, `Rs` redstone, `Cu` copper, `**` a modded ore), red on
orange `~~` lava, `..` gravel, `BB` bedrock, yellow `!!` torch, black
open space. On a farm:
blue `~~` water source, light blue `~n` flowing
water, brown `::` farmland, brown dirt, green grass, crops as letter and
age (`w3` wheat at stage 3) on green, lime once ripe, `||` sugar cane,
`..` sand, orange `[]` chest, gray `\/` hopper, gray `##` stone, yellow
the turtle (`^^ >> vv <<` top-down; `>> <<` along z or `+x -x` across, side
on).

A simulator counts as failing if the program raised an error (`ERROR:` in
its output), it crashed, or (with `run.py`) it ran past 5 minutes. Everything
else is for
reading: compare the numbers before and after a change (`git stash`, run,
`git stash pop`, run).

| Simulator | Program | What it covers |
|---|---|---|
| `farm_repair` | farm | learn with existing damage; holes, dry/flowing lane water, dirt in a lane, a block over a lane, untilled dirt; what a farming pass fixes vs. what triggers a full repair; `farm repair` |
| `farm_full_chest` | farm | a turtle full of coal, a nearly full chest, a full chest: nothing spills, the turtle waits for room |
| `farm_mixed_crops` | farm | wheat, carrots, potatoes and beetroot learned per tile; a wrong crop planted on a tile |
| `farm_reset` | farm | `farm reset` after a stop out on a 5x22 farm with cane: past the default routing area, over cane, down in a lane, at travel height, with no map yet, left of home; facing other than saved, at home and mid-farm, and a farming run started at home facing the wrong way |
| `farm_sugar_cane` | farm | a cane strip: harvest above the bottom block, replant a cane lost when its lane dried up |
| `farm_bone_meal` | farm | grow passes with bone meal from the chest |
| `farm_compost_while_waiting` | farm | surplus seeds go into the compost hopper during the wait between runs; a short wait runs out of time |
| `farm_chest_tidy` | farm | the farm chest tidied on every visit: part stacks merged, then sorted with like items together at the end of the chest (slot 1 left free); no moves when already in order; a full chest |
| `farm_clone` | farm | `farm clone` of a 7x16 farm with two lanes; moves, buckets scooped/poured, lane tiles that aren't sources |
| `farm_clone_lane_fallback` | farm | as `farm_clone`, but two lane tiles never fill on their own and must be poured |
| `farm_fuel` | farm | real fuel levels: learn and clone starting nearly empty with little coal in the chest; trips home to refuel and back, waiting at home for the "player" to add coal; never a move on an empty tank; a farming pass 5 min apart that waits longer than that for fuel starts over, a short wait carries on |
| `farm_pass_moves` | farm | moves for one plain farming pass on a 9x8 farm (`ALONGX=1`: lane along x) |
| `mine_tunnel` | mine | tunnels through mixed rock: veins out of the walls, floor and ceiling (part of one beyond reach), ore inside the tunnel, a tag-only modded ore, lava, falling gravel, a floor solid all along (the hole floor ore leaves filled); a crevasse across the tunnel bridged; torches in wall niches with no floor block dark enough for mobs (one wall, both walls for a tunnel 10 wide, one at the end of a short tunnel, a niche opening into a cave given a block to stand the torch on); `--no-lights` leaving the torches in the chest; a Geo Scanner swapped in for the pickaxe beside a chunk controller (the scan lined up with the tunnel though the mock reports along world axes turned from it, ore 5-6 out fetched, a diamond 8 out mined and its vein followed on past the scan, gold 8 out left, a fifth of the turns; a field of small deposits off one wall fetched one after another, not back to the tunnel between each); water that flows back as in the game: a tunnel through an underground lake and under one above its ceiling left dry and sealed off, without going round in circles placing blocks, and with little fuel going for coal as soon as a scan finds it; homes every 16 with supplies carried forward, room left above each valuables chest, and valuables collected on the way back, picked-up items joining their stacks (the mock stores them as the game does); a tunnel with no length that runs out of chests, then `--resume` (twice, the second time with more valuables in a home than it can carry: the most valuable come back); bedrock; running short of fuel (gets back with its margin); `mine reset` from inside a vein; `mine reset` to the last home (and `--to-start`) with a wrong saved heading (corrected from the tunnel's walls; where it can't tell, stopped on finding no home chests); `mine haul` bringing back what one trip couldn't; `mine reset` to the last home from inside the tunnel and `--resume` from there; the last home and its segment flooded: `mine reset --home 1` back a home and `--resume` drying the segment out and going on past home 2 without building it again (fetching fuel from home 2 first, with little in the tank); water standing behind the home not taken for a wrong scan heading, and a scan really turned from the heading skipped; water from a source in the wall spread along the tunnel floor followed upstream and sealed; stopped (as if by Ctrl+T) partway through a segment and resumed from its log, without going over the finished lanes again; then the same with a hole in the ceiling letting water in meanwhile, which the resume follows up to and seals, putting back the torches it washed away; and stopped before the middle column's floor is dug, with lichen leaking into the finished side column, which the resume goes over instead; waterlogged glow lichen in the walls and ceiling with water behind it, and dry lichen, all replaced so no water gets in (with and without a scanner); a segment dug already with lichen leaking water along its floor, gone over from the home before and the lichen found and replaced, and the same with lichen in the ceiling at the far end, its water falling and spreading back along the floor; an aquifer beside the tunnel at every height: no water past the block being dug and no torch washed away (with and without a scanner). Water flows with the game's timing: it reacts 5 ticks after a change next to it, each turtle action takes 8, a turtle pushes flowing water out of the block it moves into, and torches it reaches are washed away; a tunnel to the left and down |
| `turtlelib_stop` | turtlelib | Ctrl+T during a turn: without `T.run` the saved heading is a turn behind; with it the program stops once the turn is saved |
| `turtlelib_restock` | turtlelib | `T.restockFrom` reaching items behind other stacks in a chest |
| `autocompost_with_chest` | autocompost | composts what it can, rejects the rest into the chest in front |
| `autocompost_no_chest` | autocompost | no chest and a backed-up composter: ends idle instead of spinning |
| `diskclone_disks` | diskclone | blank, labelled and non-empty disks, `--force`, a too-small disk, a disk already in the drive, no `LABEL` file |

## The library

The mocks live in `lib/`, apart from the scenarios:

| File | What it holds |
|---|---|
| `lib/mock.lua` | The pieces every world is built from: the turtle's inventory stored as the game stores it (a pickup goes into the first slot from the selected one that is empty or matches; `SPLIT` counts second stacks it starts, `SPILLED` what didn't fit), containers (drop merges first, suck takes the first stack, `pushItems`), moving and turning with fuel (`FUEL`, `LOWEST`, `DRY`), looking, acting each way, upgrades (`EQ`), `fs` over a table of files, print capture, the `==` report line (`M.runner`) and `M.check`. |
| `lib/farmworld.lua` | A farm for farm.lua: `F.build{width, length, lanes, crops}` lays out strips of crops or `"cane"` between water lanes over a dirt floor, with the chest under home; the hoe harvests, cuts cane and tills through the gap; seeds, bone meal, dirt, water buckets and empty buckets place as in the game; water at lane level follows the infinite-source rule (`F.STUCK` keeps a cell from refilling); a hopper behind home takes compost; `sleep` runs the clock (`CLOCK`, `STOP_AT`). `F.stock`, `F.ripen`, `F.show`, `F.chestLine`, `F.cropCount`, `F.badLaneTiles`, `F.caneHeights` for scenarios. |
| `lib/mineworld.lua` | Rock for mine.lua: mixed stone wherever nothing is set, chests, ore (`Mine.features` for the standard veins, lava and gravel), falling gravel, water that flows with the game's timing (`WATERY`), a Geo Scanner (`SCANNER`, `SCAN_TURN`, `WORLD_COORDS`), and the checks: `leftIn`, `checkFloor`, `checkLight`, `checkOres`, `checkLava`, `checkStart`, `checkHomes`, `wetIn`, `torchesIn`. `STOP_AT_DIG` stops a run as Ctrl+T would. |
| `lib/composter.lua` | A turtle on a composter for autocompost.lua: the composter, the hopper under it (`HOPPER_STOPS_AT` backs it up) and an optional chest in front. |
| `lib/sandbox.lua` | What `runsim` and `watchsim` run a simulator in on a CC computer. |

Each world is a module (`local F = require("farmworld")`) that installs the
mocked globals when loaded and returns its state: `F.inv` (the turtle's
slots), `F.chest`, `F.files`, `F.P` (where it is and faces), `F.moves`,
`F.get`/`F.set` for blocks. Knobs and counters the scenarios set and read
(`FUEL`, `EQ`, `WATERY`, `SPILLED`, ...) are globals, listed at the top of
each file. A scenario builds a world, puts things in it, runs the program
(`F.runner(PROJ)` gives the `run(...)` that prints the `==` line) and
prints or checks what came of it; `turtlelib_stop` and `diskclone_disks`
need no world and carry their own small mocks.

All the farm scenarios share one layout: home at `(0,0,0)` facing `+z`,
the chest below home, farmland at `y=-2`, crops at `y=-1`, the dirt floor
at `y=-3`.
