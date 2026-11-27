#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$repo_root/dist"
if [[ $# -eq 2 && $1 == --out && -n $2 ]]; then
    out=$2
elif [[ $# -ne 0 ]]; then
    echo "Usage: ${0##*/} [--out DIR]" >&2
    exit 2
fi

if [[ $(dpkg --print-architecture) != amd64 ]]; then
    echo "This package requires an amd64 build environment." >&2
    exit 1
fi

maintainer_name=$(git -C "$repo_root" config --get user.name)
maintainer_email=$(git -C "$repo_root" config --get user.email)
mkdir -p -- "$out"
out=$(cd -- "$out" && pwd)
work=$(mktemp -d "$out/.mirada-deb.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
stage=$work/package
install -d -m 755 -- "$stage/DEBIAN"

"$repo_root/packaging/build-runtime.sh" "$stage/opt/mirada"
version=$("$stage/opt/mirada/python/bin/python3" -IB -c 'from mirada import __version__; print(__version__)')

install -Dm755 -- "$repo_root/packaging/deb/mirada" "$stage/usr/bin/mirada"
install -Dm755 -- "$repo_root/packaging/deb/postinst" "$stage/DEBIAN/postinst"
install -Dm755 -- "$repo_root/packaging/deb/postrm" "$stage/DEBIAN/postrm"
install -Dm644 -- "$repo_root/data/mirada.desktop" "$stage/usr/share/applications/mirada.desktop"
install -Dm644 -- "$repo_root/src/mirada/mirada.svg" "$stage/usr/share/icons/hicolor/scalable/apps/mirada.svg"
install -Dm644 -- "$repo_root/data/io.github.jleiva831.mirada.metainfo.xml" \
    "$stage/usr/share/metainfo/io.github.jleiva831.mirada.metainfo.xml"
doc=$stage/usr/share/doc/mirada
install -Dm644 -- "$repo_root/LICENSE" "$doc/copyright"
printf '\nSee THIRD-PARTY-NOTICES.txt and licenses/ for bundled components.\n' >> "$doc/copyright"
mv -T -- "$stage/opt/mirada/licenses" "$doc/licenses"
mv -T -- "$stage/opt/mirada/THIRD-PARTY-NOTICES.txt" "$doc/THIRD-PARTY-NOTICES.txt"
cp -- "$doc/THIRD-PARTY-NOTICES.txt" "$work/THIRD-PARTY-NOTICES.txt"
install -m644 -- "$repo_root/README.md" "$doc/README.md"
gzip -n -9 -c -- "$repo_root/CHANGELOG.md" > "$doc/changelog.gz"

installed_size=$(du -sk -- "$stage")
cat > "$stage/DEBIAN/control" <<CONTROL
Package: mirada
Version: $version
Section: video
Priority: optional
Architecture: amd64
Maintainer: $maintainer_name <$maintainer_email>
Installed-Size: ${installed_size%%[[:space:]]*}
Depends: libxcb-cursor0, libxcb-icccm4, libxcb-keysyms1, libxcb-shape0, libegl1, libgl1, libxkbcommon0, libxkbcommon-x11-0, libfontconfig1, libdbus-1-3, libglib2.0-0, libwayland-client0, libwayland-cursor0
Recommends: libportaudio2
Homepage: https://github.com/jleiva831/mirada
Description: Desktop teleprompter with voice tracking
 Mirada displays a script under your webcam and can advance it as you speak.
CONTROL

artifact=mirada_${version}_amd64.deb
dpkg-deb -z3 --build --root-owner-group "$stage" "$work/$artifact"
mv -Tf -- "$work/$artifact" "$out/$artifact"
mv -Tf -- "$work/THIRD-PARTY-NOTICES.txt" "$out/THIRD-PARTY-NOTICES-deb.txt"
echo "$out/$artifact"
