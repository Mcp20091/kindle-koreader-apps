#!/bin/sh
# Downloads the Syncthing program for the Kindle (32-bit ARM, static) from
# Syncthing's GitHub releases, checks it, and puts it in a plugin folder:
#   tools/fetch-syncthing.sh [plugin folder] [arch]
# The folder defaults to this checkout; arch is arm (Kindle, Kobo) or amd64
# (the KOReader emulator on a PC).
set -e

VERSION=v2.1.2
# SHA-256 of the release archives (from the release's sha256sum.txt.asc).
SHA_arm=600f7d37f174825df55df619ef3e90a11f13ea4f4a5ca2a506461772ba9865e9
SHA_amd64=0cea24660ac7d8df19f01da979827b5c9463a8a60042e296829293cf80213ee4

dest=${1:-$(cd "$(dirname "$0")/.." && pwd)}
arch=${2:-arm}
case "$arch" in
    arm) want=$SHA_arm ;;
    amd64) want=$SHA_amd64 ;;
    *) echo "arch must be arm or amd64" >&2; exit 2 ;;
esac

name=syncthing-linux-$arch-$VERSION
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$name.tar.gz" "https://github.com/syncthing/syncthing/releases/download/$VERSION/$name.tar.gz"
got=$(sha256sum "$tmp/$name.tar.gz" | cut -d' ' -f1)
if [ "$got" != "$want" ]; then
    echo "Checksum mismatch for $name.tar.gz: $got" >&2
    exit 1
fi
tar -xzf "$tmp/$name.tar.gz" -C "$tmp" "$name/syncthing"
mv "$tmp/$name/syncthing" "$dest/syncthing"
chmod 755 "$dest/syncthing"
echo "$dest/syncthing: Syncthing $VERSION ($arch)"
