# Simulators

Offline tests for the turtle programs. Each `.lua` file here is a
self-contained script: it mocks the CC:Tweaked APIs it needs (`turtle`,
`peripheral`, `fs`, `sleep`, `os.pullEvent`, ...) around a small block
world, runs the real program from the repo root, and prints the program's
output plus a summary of the world afterwards (lanes, crops, chest
contents, moves). The world is in memory; nothing is written to disk.

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

`runsim` runs each simulator in a sandbox (its own globals, its own `os`,
its own `loadfile`/`require`), so the mocks never touch the real computer,
and yields about once a second so CC doesn't stop it for running too long
without yielding. Full output goes to `sim/logs/<name>.log`; the screen
scrolls it past as it runs. Ctrl+T stops it.

A simulator counts as failing if the program raised an error (`ERROR:` in
its output), it crashed, or it ran past 5 minutes. Everything else is for
reading: compare the numbers before and after a change (`git stash`, run,
`git stash pop`, run).

| Simulator | Program | What it covers |
|---|---|---|
| `farm_repair` | farm | learn with existing damage; holes, dry/flowing lane water, dirt in a lane, a block over a lane, untilled dirt; what a farming pass fixes vs. what triggers a full repair; `farm repair` |
| `farm_full_chest` | farm | a turtle full of coal, a nearly full chest, a full chest: nothing spills, the turtle waits for room |
| `farm_mixed_crops` | farm | wheat, carrots, potatoes and beetroot learned per tile; a wrong crop planted on a tile |
| `farm_sugar_cane` | farm | a cane strip: harvest above the bottom block, replant a cane lost when its lane dried up |
| `farm_bone_meal` | farm | grow passes with bone meal from the chest |
| `farm_compost_while_waiting` | farm | surplus seeds go into the compost hopper during the wait between runs; a short wait runs out of time |
| `farm_chest_merge_stacks` | farm | part stacks in the farm chest are merged on every visit |
| `farm_clone` | farm | `farm clone` of a 7x16 farm with two lanes; moves, buckets scooped/poured, lane tiles that aren't sources |
| `farm_clone_lane_fallback` | farm | as `farm_clone`, but two lane tiles never fill on their own and must be poured |
| `farm_fuel` | farm | real fuel levels: learn and clone starting nearly empty with little coal in the chest; trips home to refuel and back, waiting at home for the "player" to add coal; never a move on an empty tank |
| `farm_pass_moves` | farm | moves for one plain farming pass on a 9x8 farm (`ALONGX=1`: lane along x) |
| `turtlelib_restock` | turtlelib | `T.restockFrom` reaching items behind other stacks in a chest |
| `autocompost_with_chest` | autocompost | composts what it can, rejects the rest into the chest in front |
| `autocompost_no_chest` | autocompost | no chest and a backed-up composter: ends idle instead of spinning |
| `diskclone_disks` | diskclone | blank, labelled and non-empty disks, `--force`, a too-small disk, a disk already in the drive, no `LABEL` file |

The farm simulators share the same world layout: home at `(0,0,0)` facing
`+z`, the chest below home, farmland at `y=-2`, crops at `y=-1`. Each file
carries its own copy of the mock, so one can model a mechanic (such as
infinite water in `farm_clone`) without changing the others.
