"""Run the simulators in this folder against the programs one level up.

    pip install lupa
    python sim/run.py                    every simulator, then a summary
    python sim/run.py farm_clone ...     just these (".lua" optional)
    python sim/run.py --check            syntax-check the programs only

On a ComputerCraft computer, use sim/runsim.lua instead (sim/watchsim.lua
plays one out on a monitor).

Each simulator is a Lua script that sets a scenario up in one of the mock
worlds in lib/ (farmworld, mineworld, composter: the CC:Tweaked APIs the
program needs, around a small block world), runs the real program and
prints what happened.  It gets the repo root as its argument (`local PROJ
= ...`).  Each one runs in its own process so a hang only costs that one
simulator.
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TIMEOUT = 300   # seconds per simulator


def lua():
    try:
        from lupa import LuaRuntime
    except ImportError:
        sys.exit("needs lupa: pip install lupa")
    return LuaRuntime()


def run_one(path):
    src = open(path, encoding="utf-8").read()
    runner = lua().eval("function(src, name, root) return assert(load(src, '@' .. name))(root) end")
    runner(src, os.path.basename(path), ROOT.replace("\\", "/"))


def check():
    load = lua().eval("function(s, n) local f, e = load(s, '@' .. n); return e end")
    bad = 0
    for path in sorted(glob.glob(os.path.join(ROOT, "*.lua")) + glob.glob(os.path.join(HERE, "*.lua"))
                       + glob.glob(os.path.join(HERE, "lib", "*.lua"))):
        err = load(open(path, encoding="utf-8").read(), os.path.relpath(path, ROOT))
        print(("FAIL " + err) if err else ("ok   " + os.path.relpath(path, ROOT)))
        bad += err is not None
    return 1 if bad else 0


def main(args):
    if args[:1] == ["--one"]:
        run_one(args[1])
        return 0
    if args[:1] == ["--check"]:
        return check()
    if args:
        paths = [os.path.join(HERE, a if a.endswith(".lua") else a + ".lua") for a in args]
    else:
        paths = sorted(p for p in glob.glob(os.path.join(HERE, "*.lua"))
                       if os.path.basename(p) not in ("runsim.lua", "watchsim.lua"))
    results = []
    for path in paths:
        name = os.path.basename(path)[:-4]
        print("#" * 8, name)
        sys.stdout.flush()
        try:
            p = subprocess.run([sys.executable, __file__, "--one", path], timeout=TIMEOUT,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            out = p.stdout
            status = "ERROR" if p.returncode != 0 or "   ERROR:" in out else "ok"
        except subprocess.TimeoutExpired as e:
            out = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
            status = "TIMEOUT"
        print(out, end="" if out.endswith("\n") else "\n")
        results.append((name, status))
    if len(results) > 1:
        print("#" * 8, "summary")
        for name, status in results:
            print("%-8s %s" % (status, name))
    return 0 if all(s == "ok" for _, s in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
