#!/bin/sh
# Downloads the Syncthing program for the Kindle (32-bit ARM, static) from
# Syncthing's GitHub releases, checks it, and puts it in a plugin folder:
#   tools/fetch-syncthing.sh [plugin folder] [arch]
# The folder defaults to this checkout; arch is arm (Kindle, Kobo) or amd64
# (the KOReader emulator on a PC).
set -e

VERSION=v2.1.7
# SHA-256 of the release archives (from the release's sha256sum.txt.asc).
SHA_arm=d8b59029e25992bc0d280fccc5626e5dca743b285fca1a36db1148fcf871b639
SHA_amd64=2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142

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
