#!/bin/bash
# Moves the pinned Syncthing program to a newer release: the version and checksums in
# fetch-syncthing.sh, the notices, the README, the plugin's What changed, and the program itself
# (downloaded and checked by fetch-syncthing.sh):
#   tools/update-syncthing.sh [vX.Y.Z]
# Without a version it takes Syncthing's latest release (never a pre-release). The checksums come from
# the release's sha256sum.txt.asc, whose signature must be from Syncthing's release key (the
# fingerprints below; the key itself is fetched from syncthing.net). Prints "up to date" or
# "updated: vOLD -> vNEW". Needs curl, gpg, python3 and git. GitHub's Syncthing update workflow
# (.github/workflows/syncthing-update.yml) runs it every week.
set -euo pipefail

# Syncthing's release keys ("Syncthing Release Management"): the one that signs
# releases since 2024, and the older one that signed earlier releases.
KEYS="FBA2E162F2F44657B38F0309E5665F9BD5970C47 37C84554E7E0A261E4F76E1ED26E6ED000654A3E"

die() { echo "update-syncthing: $*" >&2; exit 1; }
plugin=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$plugin/.." && pwd)
fetch=$plugin/tools/fetch-syncthing.sh

old=$(sed -n 's/^VERSION=//p' "$fetch")
new=${1:-}
if [ -z "$new" ]; then
    new=$(curl -fsSL https://api.github.com/repos/syncthing/syncthing/releases/latest \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
fi
echo "$new" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "not a release version: $new"
if [ "$new" = "$old" ]; then echo "up to date: $old"; exit 0; fi
newest=$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -1)
[ "$newest" = "$new" ] || die "$new is older than the pinned $old"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME=$tmp/gnupg
mkdir -m 700 "$GNUPGHOME"
curl -fsSL -o "$tmp/key.gpg" https://syncthing.net/release-key.gpg
gpg -q --batch --import "$tmp/key.gpg" 2>/dev/null
curl -fsSL -o "$tmp/sums.asc" "https://github.com/syncthing/syncthing/releases/download/$new/sha256sum.txt.asc"
# A good signature from one of our keys (VALIDSIG's last field: the primary fingerprint), and no bad one.
# (gpg's exit code isn't used: the file is signed by both keys, and syncthing.net now has only the new
# one, so the older signature can't be checked.)
status=$(gpg --batch --status-fd 1 --verify "$tmp/sums.asc" 2>/dev/null || true)
echo "$status" | grep -q '^\[GNUPG:\] BADSIG' && die "a bad signature on the checksums for $new"
signed=""
for k in $(echo "$status" | awk '$2 == "VALIDSIG" { print $NF }'); do
    case " $KEYS " in *" $k "*) signed=$k ;; esac
done
[ -n "$signed" ] || die "the checksums for $new aren't signed by Syncthing's release key"
gpg -q --batch --decrypt "$tmp/sums.asc" 2>/dev/null > "$tmp/sums.txt" || true
sha() { awk -v f="syncthing-linux-$1-$new.tar.gz" '$2 == f { print $1 }' "$tmp/sums.txt"; }
arm=$(sha arm); amd64=$(sha amd64)
[ ${#arm} = 64 ] && [ ${#amd64} = 64 ] || die "no checksums for the arm and amd64 archives of $new"

# The pinned version and checksums, then the program itself (fetch-syncthing.sh checks it).
sed -i -e "s/^VERSION=.*/VERSION=$new/" -e "s/^SHA_arm=.*/SHA_arm=$arm/" -e "s/^SHA_amd64=.*/SHA_amd64=$amd64/" "$fetch"
sh "$fetch" "$plugin" arm

# The version named in the notices and the README.
o=${old#v}; n=${new#v}
for f in "$plugin/SYNCTHING-NOTICE.txt" "$root/tools/SYNCTHING-NOTICE.txt"; do
    sed -i -e "s/version ${o//./\\.} /version $n /" -e "s#/v${o//./\\.}\b#/v$n#g" "$f"
done
sed -i "s/Syncthing v${o//./\\.} /Syncthing $new /" "$plugin/README.md"

# What changed: the date and time first, then this, newest first, at most five.
python3 - "$plugin/version.txt" "$old" "$new" <<'EOF'
import sys, time
path, old, new = sys.argv[1:]
lines = open(path, encoding='utf-8').read().split('\n')
entry = '%s  Syncthing: the Kindle\'s program is Syncthing %s (was %s), as released and checked' % (
    time.strftime('%b %d').replace(' 0', ' '), new, old)
rest = [l for l in lines[1:] if l.strip()]
open(path, 'w', encoding='utf-8', newline='\n').write('\n'.join([time.strftime('%Y-%m-%d %H:%M'), entry] + rest[:4]) + '\n')
EOF

echo "updated: $old -> $new"
