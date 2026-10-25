"""Checks that Apps, Home Assistant, To Do and the web server put nothing in
KOReader's input path (what a pen stroke in Notes or Crosswords goes
through): no replaced function of Input, the gesture detector, UIManager's
event handling or InputContainer. (The emulator check, a Notes notebook
fed 400 pen-like events with a call hook on these plugins' files, found no
call into them; the same events over the launcher, 451.)

    python tests/check_input_path.py   (from apps.koplugin; the other plugins next to it)

It lists every KOReader function these plugins replace, so a new one is seen.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPOS = os.path.dirname(os.path.dirname(HERE))
PLUGINS = ["apps.koplugin", "homeassistant.koplugin", "todo.koplugin", "webpage.koplugin"]

# Replacing one of these would put work in the input path.
FORBIDDEN = re.compile(
    r"^\s*(Input|GestureDetector|InputContainer|Device\.input|UIManager\.(handleInput|sendEvent|_checkTasks|_repaint|onGesture|setDirty))"
    r"\.?[\w.]*\s*=\s*", re.M)
# Any assignment to a KOReader module's function (to list them).
ASSIGN = re.compile(r"^\s*([A-Z]\w*(?:\.\w+)+)\s*=\s*function", re.M)

problems = []
hooks = []
for plugin in PLUGINS:
    root = os.path.join(REPOS, plugin)
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "tests", "docs", "web")]
        for name in files:
            if not name.endswith(".lua"):
                continue
            path = os.path.join(folder, name)
            text = open(path, encoding="utf-8").read()
            rel = os.path.relpath(path, REPOS)
            for m in FORBIDDEN.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                problems.append("%s:%d replaces %s" % (rel, line, m.group(0).strip()))
            for m in ASSIGN.finditer(text):
                target = m.group(1)
                # The plugins' own modules (View, Bar, KO…) don't count.
                if target.split(".")[0] in ("UIManager", "Dispatcher", "Screensaver", "Device", "M", "G", "RF", "map", "Notify"):
                    line = text.count("\n", 0, m.start()) + 1
                    hooks.append("%s:%d %s" % (rel, line, target))

print("KOReader functions these plugins replace:")
for h in hooks:
    print("  " + h)
if problems:
    print("In the input path:")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("Nothing in the input path.")
