"""The personal-data check for this repo: nothing personal goes into a commit, a commit message, a branch
name, a pull request or a push. The git hooks in .githooks/ run it (git config core.hooksPath .githooks),
and so does GitHub (.github/workflows/privacy.yml).

    python tools/privacy_check.py --staged          what's staged (the pre-commit hook)
    python tools/privacy_check.py --message FILE    a commit message (the commit-msg hook)
    python tools/privacy_check.py --push            what a push sends (the pre-push hook; refs on stdin)
    python tools/privacy_check.py --range A..B      the commits in A..B (any rev-list arguments): changes, messages, authors
    python tools/privacy_check.py --all             every tracked file as it is now
    python tools/privacy_check.py --text FILE|-     any text (a pull request's title and description)

It looks for the kinds of things that are always personal (emails, home folders, real addresses, keys,
PC names), allowing the made-up examples the apps use. On top of that it reads the user's own values from
local files that never go into git: private-words.local.txt in the main checkout (one word per line, or
`re:` and a regular expression; `#` starts a note), the To Do app ID and the Notes defaults in the install
folder next to it, and this PC's name and user name. On GitHub those aren't there and only the kinds are
checked. Any hit prints where it is and exits 1.
"""
import getpass
import os
import re
import socket
import subprocess
import sys

REPO = 'Mcp20091/kindle-koreader-apps'
OWNER = REPO.split('/')[0]

PATTERNS = {
    'email': r'[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[a-z]{2,}\b',
    'home path': r'(?i)C:[\\/]+Users[\\/]+(?!<)|(?<![/\w])/home/(?!<)[a-z]\w+|/mnt/c/',
    'ip': r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
    'key': r'sk-ant-[A-Za-z0-9_-]{8,}|sk-[A-Za-z0-9]{32,}|eyJ[\w-]{30,}\.[\w-]{20,}|AKIA[0-9A-Z]{16}'
           r'|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_\w{30,}|xox[abprs]-[\w-]{10,}|AIza[\w-]{35}',
    'private key': r'-----BEGIN [A-Z ]*PRIVATE KEY-----',
    'windows pc name': r'\bDESKTOP-[A-Z0-9]{5,}\b',
}
# Example values the apps and the guide use on purpose.
OK_IPS = {'192.168.1.5', '192.168.1.10', '192.168.1.20', '192.168.1.42', '192.168.1.50', '127.0.0.1', '0.0.0.0',
          '192.0.2.1', '255.255.255.255', '1.2.3.4', '10.0.0.1', '10.0.0.2', '192.168.1.2',
          '1.3.101.112', '2.5.29.17', '225.0.0.9'}  # OIDs (Ed25519 in the SSH key code, subject alternative names in
          # the web server's certificates) and FlashForge printers' discovery address (their protocol's own)
OK_EMAILS = re.compile(r'(?i)^(pi@|git@github\.com$|user@|you@|me@|someone@|name@|root@|admin@|noreply@|.*@example\.(com|org|net)$'
                       r'|.*@localhost|support@github\.com$|\d+\+[\w-]+(\[bot\])?@users\.noreply\.github\.com$)')
# Files where a kind is expected (key handling code and its tests).
OK_FILES = {
    'private key': re.compile(r'sshclient\.koplugin/(sshkeys\.lua|tests/|sshko\.lua|web/ssh\.js)|webpage\.koplugin/web/ssh\.js'
                              r'|webpage\.koplugin/webssh\.lua|webpage\.koplugin/webtls\.lua'
                              r'|webpage\.koplugin/web/system\.js|tools/privacy_check\.py'),
}
TEXT = ('.lua', '.js', '.html', '.css', '.md', '.txt', '.json', '.py', '.sh', '.xml', '.svg', '.webmanifest',
        '.yml', '.yaml', '.toml', '.cfg', '.ini', '')
PICTURES = ('.png', '.jpg', '.jpeg', '.gif', '.webp')
# Files that stay on this PC: never staged.
LOCAL_ONLY = re.compile(r'(^|/)[^/]*\.local\.[^/]*$|(^|/)client_id\.txt$|(^|/)notes_defaults\.lua$|(^|/)\.env$')


def git(*args, check=True):
    r = subprocess.run(['git', '-c', 'core.quotepath=false'] + list(args), capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    if check and r.returncode != 0:
        sys.exit('privacy check: git %s failed: %s' % (' '.join(args), r.stderr.strip()))
    return r.stdout


def main_checkout():
    """The main checkout (worktrees share its .git), where the local files are."""
    try:
        common = git('rev-parse', '--path-format=absolute', '--git-common-dir', check=False).strip()
    except OSError:
        return None
    return os.path.dirname(common) if common else None


def own_values():
    """(words, patterns): the user's own values, read from this PC's files (never written here)."""
    words, pats = set(), []
    main = main_checkout()
    if main:
        install = os.path.join(os.path.dirname(main), 'kindle-install')
        cid = os.path.join(install, 'todo.koplugin', 'client_id.txt')
        if os.path.exists(cid):
            words.add(open(cid, encoding='utf-8').read().strip())
        nd = os.path.join(install, 'notes.koplugin', 'notes_defaults.lua')
        if os.path.exists(nd):
            for v in re.findall(r'=\s*"([^"]{4,})"', open(nd, encoding='utf-8').read()):
                words.add(v)
                words.update(re.findall(r'\d+\.\d+\.\d+\.\d+', v))
        path = os.path.join(main, 'private-words.local.txt')
        if os.path.exists(path):
            for w in open(path, encoding='utf-8'):
                w = w.rstrip('\n')
                if w.startswith('re:'):
                    pats.append(re.compile(w[3:].strip()))
                    continue
                w = w.split('#')[0].strip()
                if w:
                    words.add(w)
    for get in (socket.gethostname, getpass.getuser):
        try:
            words.add(get())
        except Exception:
            pass
    return {w.lower() for w in words if len(w) >= 4}, pats


OWN = None


def scan_line(line, rel=''):
    """The hits in one line: [(kind, text)]."""
    global OWN
    if OWN is None:
        OWN = own_values()
    # The repo's own address names the account it lives under; only that is allowed.
    line = line.replace('github.com/' + REPO, 'github.com/<repo>').replace(REPO, '<owner>/<repo>')
    # The account itself is public (the address above has it): as the author, in its noreply address and as
    # the owner of a branch (GitHub's "Merge pull request #1 from <owner>/<branch>").
    line = re.sub(r'\d+\+%s@users\.noreply\.github\.com' % OWNER, '<noreply>', line)
    line = re.sub(r'^%s$|\b%s/' % (OWNER, OWNER), '<owner>/', line)
    hits = []
    low = line.lower()
    if any(w in low for w in OWN[0]) or any(p.search(line) for p in OWN[1]):
        hits.append(('own value', "(one of the user's own values)"))
    name = os.path.basename(rel)
    for kind, pat in PATTERNS.items():
        if rel == 'tools/privacy_check.py':
            break  # (this file: its patterns are the kinds it looks for)
        for m in re.finditer(pat, line):
            s = m.group(0)
            if kind == 'ip' and (s in OK_IPS or not all(0 <= int(x) <= 255 for x in s.split('.'))
                                 or re.search(r'[\d.]' + re.escape(s) + r'|' + re.escape(s) + r'\.\d', line)
                                 or name.endswith('.svg')):
                continue
            if kind == 'email' and (OK_EMAILS.match(s) or name.endswith('.svg')):
                continue
            if kind in OK_FILES and OK_FILES[kind].search(rel):
                continue
            hits.append((kind, line.strip()[:120]))
    return hits


def is_text(rel):
    return os.path.splitext(rel)[1].lower() in TEXT


def picture_metadata(data):
    """What a picture carries besides its pixels (camera details, places, editing notes), or ''."""
    if data[:2] == b'\xff\xd8' and (b'Exif\x00' in data[:65536] or b'http://ns.adobe.com/xap' in data[:65536]):
        return 'EXIF or XMP data (can hold where and when it was taken)'
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        found = {c.decode() for c in (b'eXIf', b'tEXt', b'iTXt', b'zTXt') if c in data}
        if found:
            return 'PNG text or EXIF chunks (%s)' % ', '.join(sorted(found))
    return ''


def check_diff(diff, hits, where=''):
    """The added lines of a `git diff -U0` (and new files' names)."""
    rel = ''
    for line in diff.split('\n'):
        if line.startswith('+++ '):
            rel = line[6:] if line.startswith('+++ b/') else ''
            for kind, text in scan_line(rel, rel):
                hits.append((where + rel, 0, kind, 'in the file name'))
            n = 0
        elif line.startswith('@@'):
            m = re.search(r'\+(\d+)', line)
            n = int(m.group(1)) - 1 if m else 0
        elif line.startswith('+') and rel and is_text(rel):
            n += 1
            for kind, text in scan_line(line[1:], rel):
                hits.append((where + rel, n, kind, text))


def check_names(names, hits, where, staged):
    """Local-only files, and pictures (metadata; each one listed to look at by eye)."""
    pics = []
    for rel in names:
        if LOCAL_ONLY.search(rel):
            hits.append((where + rel, 0, 'local file', 'stays on this PC (never committed)'))
        if rel.lower().endswith(PICTURES):
            pics.append(rel)
            spec = (':' + rel) if staged else rel
            r = subprocess.run(['git', 'show', spec], capture_output=True)
            meta = picture_metadata(r.stdout) if r.returncode == 0 else ''
            if meta:
                hits.append((where + rel, 0, 'picture', meta + ': strip it (save it again without metadata)'))
    return pics


def check_staged():
    hits = []
    check_diff(git('diff', '--cached', '-U0', '--no-color', '--diff-filter=ACMR', '--no-ext-diff'), hits)
    names = [n for n in git('diff', '--cached', '--name-only', '--diff-filter=ACMR').split('\n') if n]
    return hits, check_names(names, hits, '', True)


def check_commits(revs, hits):
    """Each commit rev-list gives for revs: who made it, its message, its changes."""
    pics = []
    for sha in git('rev-list', '--reverse', *revs).split():
        short = sha[:9] + ' '
        head = git('show', '-s', '--format=%an%n%ae%n%cn%n%ce', sha).split('\n')
        for i, who in enumerate(head[:4]):
            for kind, text in scan_line(who):
                hits.append((short + 'author/committer', 0, kind, text))
            if i % 2 == 1 and who and not OK_EMAILS.match(who):
                hits.append((short + 'author/committer', 0, 'email', who + ' (use the GitHub noreply address)'))
        for i, line in enumerate(git('show', '-s', '--format=%B', sha).split('\n'), 1):
            for kind, text in scan_line(line):
                hits.append((short + 'message', i, kind, text))
        check_diff(git('show', '-U0', '--no-color', '--format=', '--diff-filter=ACMR', '--no-ext-diff', sha), hits, short)
        names = git('show', '--name-only', '--format=', '--diff-filter=ACMR', sha).split('\n')
        for rel in names:
            if rel and LOCAL_ONLY.search(rel):
                hits.append((short + rel, 0, 'local file', 'stays on this PC (never committed)'))
        pics += [n for n in names if n.lower().endswith(PICTURES)]
    return pics


def check_push():
    """The pre-push hook: stdin has `local_ref local_sha remote_ref remote_sha` per ref."""
    hits, pics = [], []
    zero = '0' * 40
    for line in sys.stdin.read().split('\n'):
        parts = line.split()
        if len(parts) != 4 or parts[1] == zero:
            continue  # (a deletion sends nothing)
        local_ref, local_sha, remote_ref, remote_sha = parts
        for kind, text in scan_line(remote_ref):
            hits.append((remote_ref, 0, kind, 'in the branch or tag name'))
        if git('cat-file', '-t', local_sha).strip() == 'tag':
            for i, l in enumerate(git('cat-file', 'tag', local_sha).split('\n'), 1):
                for kind, text in scan_line(l):
                    hits.append((remote_ref + ' (tag message)', i, kind, text))
        # Only the commits GitHub doesn't have yet.
        if remote_sha == zero or git('cat-file', '-t', remote_sha, check=False).strip() != 'commit':
            revs = [local_sha, '--not', '--remotes']
        else:
            revs = ['%s..%s' % (remote_sha, local_sha)]
        pics += check_commits(revs, hits)
    return hits, pics


def check_all():
    hits = []
    for rel in git('ls-files', '-z').split('\0'):
        if not rel or not is_text(rel) or rel.endswith('.pem'):
            continue
        try:
            text = open(rel, encoding='utf-8').read()
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(text.split('\n'), 1):
            for kind, t in scan_line(line, rel):
                hits.append((rel, i, kind, t))
    names = [n for n in git('ls-files', '-z').split('\0') if n]
    for rel in names:
        if LOCAL_ONLY.search(rel):
            hits.append((rel, 0, 'local file', 'stays on this PC (never committed)'))
        if rel.lower().endswith(PICTURES):
            meta = picture_metadata(open(rel, 'rb').read())
            if meta:
                hits.append((rel, 0, 'picture', meta))
    return hits, []


def check_text(text, where):
    hits = []
    for i, line in enumerate(text.split('\n'), 1):
        if line.startswith('#') and where == 'message':
            continue  # git's own notes in the editor, not part of the message
        for kind, t in scan_line(line):
            hits.append((where, i, kind, t))
    return hits


def main():
    args = sys.argv[1:]
    mode = args[0] if args else '--staged'
    if mode == '--staged':
        hits, pics = check_staged()
    elif mode == '--message':
        hits, pics = check_text(open(args[1], encoding='utf-8', errors='replace').read(), 'message'), []
    elif mode == '--push':
        hits, pics = check_push()
    elif mode == '--range':
        hits = []
        pics = check_commits(args[1:], hits)
    elif mode == '--all':
        hits, pics = check_all()
    elif mode == '--text':
        src = sys.stdin if args[1] == '-' else open(args[1], encoding='utf-8')
        hits, pics = check_text(src.read(), 'text'), []
    else:
        sys.exit(__doc__)
    if pics:
        print('privacy check: pictures to look at by eye (made-up data only): ' + ', '.join(sorted(set(pics))))
    if hits:
        print('\nPERSONAL-DATA CHECK FAILED: %d hit(s)' % len(hits))
        for where, i, kind, line in hits:
            print('  %s%s [%s] %s' % (where, ':%d' % i if i else '', kind, line))
        print('\nUse made-up values (AGENTS.md, "No personal data anywhere"). For a made-up example the check'
              '\ndoesn\'t know, add it to the allowed examples in tools/privacy_check.py.')
        sys.exit(1)
    print('privacy check: clean')


if __name__ == '__main__':
    main()
