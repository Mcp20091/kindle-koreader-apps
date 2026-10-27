"""Builds the optional apps' install zips: one zip per plugin folder here (flashforge.koplugin.zip),
holding the folder as it goes in koreader/plugins/ on the Kindle: without tests, docs or the notes for
coding agents (AGENTS.md, CLAUDE.md). Run from anywhere: python optional/build-zip.py"""
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
LEAVE_OUT_DIRS = {'tests', 'docs'}
LEAVE_OUT_FILES = {'AGENTS.md', 'CLAUDE.md'}

for name in sorted(os.listdir(HERE)):
    folder = os.path.join(HERE, name)
    if not (name.endswith('.koplugin') and os.path.isdir(folder)):
        continue
    path = os.path.join(HERE, name + '.zip')
    n = 0
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(folder):
            dirs[:] = sorted(d for d in dirs if d not in LEAVE_OUT_DIRS)
            for f in sorted(files):
                if f in LEAVE_OUT_FILES:
                    continue
                full = os.path.join(root, f)
                # (a fixed date: the same files make the same zip)
                info = zipfile.ZipInfo(os.path.relpath(full, HERE).replace('\\', '/'), (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                with open(full, 'rb') as fh:
                    z.writestr(info, fh.read())
                n += 1
    print('%s: %d files' % (os.path.relpath(path), n))
