"""Apps that App lock can't lock: every app KOReader can open (a Dispatcher action with an event
"Show..."), in the main install and in optional/, must ask App lock where it opens:

    local lock = require("pluginshare").lock
    if lock and lock.ask("<its tile's key>", function() self:show(...) end) then return end

at the top of its show (and of any function that opens it straight to a place). An app opens from places
the launcher never sees (KOReader's Tools menu, a gesture), so the launcher can't lock it by itself. Its
PS.appInfo entry lists it in Settings > Launcher > App lock (apps.koplugin/appslock.lua).

    python tests/check_app_lock.py   (from apps.koplugin; the other plugins next to it)

One line per app, "ok" or what's missing; exit 1 if any. Not apps here: the launcher, and the Library
(books and folders)."""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
NOT_APPS = {'apps', 'library'}


def plugins():
    out = []
    for base in (ROOT, os.path.join(ROOT, 'optional')):
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if name.endswith('.koplugin') and os.path.isdir(path):
                out.append(path)
    return out


def code(folder):
    text = ''
    for name in sorted(os.listdir(folder)):
        if name.endswith('.lua'):
            with open(os.path.join(folder, name), encoding='utf-8', errors='replace') as f:
                text += f.read() + '\n'
    return text


def main():
    bad = False
    for folder in plugins():
        name = os.path.basename(folder)[:-len('.koplugin')]
        if name in NOT_APPS:
            continue
        lua = code(folder)
        if not re.search(r'event\s*=\s*"Show', lua):
            continue
        ok = 'lock.ask(' in lua
        print(name + ': ' + ('ok' if ok else 'no PS.lock.ask where it opens'))
        bad = bad or not ok
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
