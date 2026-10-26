"""The release zip: every plugin folder as it goes on the Kindle (no tests, no notes for coding
agents), with the Syncthing program and the notice its licence asks for.

    python3 tools/release_zip.py OUT.zip SYNCTHING

SYNCTHING is the Syncthing program for the Kindle (32-bit ARM), as syncthing.koplugin/tools/
fetch-syncthing.sh downloads and checks it. Run from the repo's root (GitHub's release workflow does).
"""
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def main():
    out, prog = sys.argv[1], sys.argv[2]
    head = open(prog, 'rb').read(20)
    # (The Kindle's build: an ELF file for 32-bit ARM.)
    if head[1:4] != b'ELF' or int.from_bytes(head[18:20], 'little') != 40:
        sys.exit('%s is not the ARM build of Syncthing' % prog)
    plugins = sorted(d for d in os.listdir(ROOT) if d.endswith('.koplugin') and os.path.isdir(os.path.join(ROOT, d)))
    n = 0
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in plugins:
            for root, dirs, files in os.walk(os.path.join(ROOT, name)):
                dirs[:] = sorted(d for d in dirs if d != 'tests')
                for f in sorted(files):
                    if f in ('AGENTS.md', 'CLAUDE.md'):
                        continue
                    full = os.path.join(root, f)
                    z.write(full, os.path.relpath(full, ROOT).replace('\\', '/'))
                    n += 1
        info = zipfile.ZipInfo('syncthing.koplugin/syncthing')
        info.external_attr = 0o755 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, open(prog, 'rb').read())
        z.write(os.path.join(HERE, 'SYNCTHING-NOTICE.txt'), 'syncthing.koplugin/SYNCTHING-NOTICE.txt')
        n += 2
    print('%s: %d plugins, %d files' % (out, len(plugins), n))


if __name__ == '__main__':
    main()
