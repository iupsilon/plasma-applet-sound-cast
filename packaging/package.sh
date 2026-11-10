#!/bin/sh
# Build the .deb, .rpm and Arch packages into dist/.
#
# Needs make, gettext (msgfmt) and nfpm (https://nfpm.goreleaser.com).
set -eu
cd "$(dirname "$0")/.."

version=$(sed -n 's/.*"Version": "\(.*\)".*/\1/p' package/metadata.json)

rm -rf dist
make install DESTDIR="$PWD/dist/root" PREFIX=/usr

for packager in deb rpm archlinux; do
    VERSION=$version nfpm package --config packaging/nfpm.yaml --packager "$packager" --target dist/
done

(cd dist && sha256sum plasma6-applets-sound-cast[-_]* > SHA256SUMS)
ls -l dist
