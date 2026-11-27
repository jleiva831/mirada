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
    echo "This AppImage requires an amd64 build environment." >&2
    exit 1
fi

mkdir -p -- "$out"
out=$(cd -- "$out" && pwd)
work=$(mktemp -d "$out/.mirada-appimage.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
appdir=$work/Mirada.AppDir

"$repo_root/packaging/build-runtime.sh" "$appdir/usr"
python=$appdir/usr/python/bin/python3
version=$("$python" -IB -c 'from mirada import __version__; print(__version__)')
site_packages=$("$python" -IB -c 'import sysconfig; print(sysconfig.get_path("purelib"))')

install -m755 -- "$repo_root/packaging/appimage/AppRun" "$appdir/AppRun"
install -m644 -- "$repo_root/packaging/appimage/sitecustomize.py" "$site_packages/sitecustomize.py"
install -m644 -- "$repo_root/data/mirada.desktop" "$appdir/mirada.desktop"
install -Dm644 -- "$repo_root/data/io.github.jleiva831.mirada.metainfo.xml" \
    "$appdir/usr/share/metainfo/io.github.jleiva831.mirada.metainfo.xml"
install -m644 -- "$repo_root/src/mirada/mirada.svg" "$appdir/mirada.svg"
ln -s mirada.svg "$appdir/.DirIcon"

doc=$appdir/usr/share/doc/mirada
install -Dm644 -- "$repo_root/LICENSE" "$doc/copyright"
mv -T -- "$appdir/usr/licenses" "$doc/licenses"
mv -T -- "$appdir/usr/THIRD-PARTY-NOTICES.txt" "$doc/THIRD-PARTY-NOTICES.txt"
notices=$doc/THIRD-PARTY-NOTICES.txt

config=$repo_root/packaging/appimage
mkdir -- "$work/apt" "$work/native"
mapfile -t packages < <(cut -d ' ' -f 1 "$config/libraries.txt" "$config/fallback-libraries.txt")
(cd -- "$work/apt" && apt-get download "${packages[@]}")
cat >> "$notices" <<'NOTICES'

Native libraries bundled from Ubuntu packages
  License and copyright terms: licenses/ubuntu/
  Enable Ubuntu source repositories before running the source commands below.
NOTICES
source_field='^([^[:space:]]+) \(([^)]+)\)$'
for archive in "$work/apt/"*.deb; do
    package=$(dpkg-deb -f "$archive" Package)
    package_version=$(dpkg-deb -f "$archive" Version)
    source_package=$(dpkg-deb -f "$archive" Source)
    source_version=$package_version
    if [[ $source_package =~ $source_field ]]; then
        source_package=${BASH_REMATCH[1]}
        source_version=${BASH_REMATCH[2]}
    fi
    printf '%s\n' "- $package $package_version" \
        "  apt-get source '${source_package:-$package}=$source_version'" \
        "  https://packages.ubuntu.com/jammy/$package" >> "$notices"
    dpkg-deb --extract "$archive" "$work/native"
done

copy_libraries() {
    local manifest=$1 package library source destination
    local -a entry
    while read -r -a entry; do
        package=${entry[0]}
        for library in "${entry[@]:1}"; do
            source=$work/native/usr/lib/x86_64-linux-gnu/$library
            if [[ ! -f "$source" ]]; then
                source=$work/native/lib/x86_64-linux-gnu/$library
            fi
            destination=$appdir/usr/lib
            if [[ $manifest == "$config/fallback-libraries.txt" ]]; then
                destination=$destination/fallback/$library
            fi
            install -Dm644 -- "$source" "$destination/$library"
        done
        install -Dm644 -- "$work/native/usr/share/doc/$package/copyright" \
            "$doc/licenses/ubuntu/$package/copyright"
    done < "$manifest"
}

copy_libraries "$config/libraries.txt"
copy_libraries "$config/fallback-libraries.txt"

tool_url=https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
tool_sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
runtime_tag=20251108
runtime_url=https://github.com/AppImage/type2-runtime/releases/download/$runtime_tag/runtime-x86_64
runtime_sha256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

download_verified() {
    local url=$1 expected=$2 destination=$3
    "$python" -ISB - "$url" "$destination" <<'PY'
from shutil import copyfileobj
from sys import argv
from urllib.request import urlopen

with urlopen(argv[1], timeout=60) as response, open(argv[2], "wb") as target:
    copyfileobj(response, target)
PY
    printf '%s  %s\n' "$expected" "$destination" | sha256sum --check --status
}

tool=$work/appimagetool
runtime=$work/runtime-x86_64
download_verified "$tool_url" "$tool_sha256" "$tool"
download_verified "$runtime_url" "$runtime_sha256" "$runtime"
runtime_licenses=$doc/licenses/AppImage-runtime
mkdir -p -- "$runtime_licenses"
download_verified "https://raw.githubusercontent.com/AppImage/type2-runtime/$runtime_tag/LICENSE" \
    aa154fc9070614bbe7921f89db11efd1dba7a1f3a41685958110e2230f9c0ca1 "$runtime_licenses/LICENSE"
download_verified https://raw.githubusercontent.com/libfuse/libfuse/fuse-3.15.0/LGPL2.txt \
    dc626520dcd53a22f727af3ee42c770e56c97a64fe3adb063799d8ab032fe551 "$runtime_licenses/libfuse-LGPL-2.1.txt"
download_verified https://raw.githubusercontent.com/vasi/squashfuse/0.5.2/LICENSE \
    9e909cc8a8ba27b1a649c964cf9eda37de911f3138c2b64e6d2f01703904ac13 "$runtime_licenses/squashfuse-LICENSE"
# Versions match the pinned x86_64 runtime and its published debug symbols.
download_verified https://raw.githubusercontent.com/microsoft/mimalloc/v2.1.7/LICENSE \
    19c99805e7a44a34b297a75d1edea9985e300066dfc024d5c99d4236d4573b5d "$runtime_licenses/mimalloc-LICENSE"
download_verified https://raw.githubusercontent.com/ifduyue/musl/v1.2.5/COPYRIGHT \
    f9bc4423732350eb0b3f7ed7e91d530298476f8fec0c6c427a1c04ade22655af "$runtime_licenses/musl-COPYRIGHT"
download_verified https://raw.githubusercontent.com/facebook/zstd/v1.5.6/LICENSE \
    7055266497633c9025b777c78eb7235af13922117480ed5c674677adc381c9d8 "$runtime_licenses/zstd-LICENSE"
download_verified https://raw.githubusercontent.com/Cyan4973/xxHash/v0.8.2/LICENSE \
    6ffedbc0f7878612d2b23589f1ff2ab15633e1df7963a5d9fc750ec5500c7e7a "$runtime_licenses/xxHash-LICENSE"
download_verified https://raw.githubusercontent.com/madler/zlib/v1.3.1/LICENSE \
    845efc77857d485d91fb3e0b884aaa929368c717ae8186b66fe1ed2495753243 "$runtime_licenses/zlib-LICENSE"
cat >> "$notices" <<NOTICES

AppImage Type-2 Runtime $runtime_tag (MIT; includes statically linked dependencies)
  License texts and dependency notices: licenses/AppImage-runtime/
  Corresponding source, build recipes and dependency patches:
  https://github.com/AppImage/type2-runtime/tree/$runtime_tag
  libfuse 3.15.0 (LGPL-2.1-or-later):
  https://github.com/libfuse/libfuse/releases/download/fuse-3.15.0/fuse-3.15.0.tar.xz
  https://github.com/AppImage/type2-runtime/blob/$runtime_tag/patches/libfuse/mount.c.diff
  squashfuse 0.5.2: https://github.com/vasi/squashfuse/tree/0.5.2
  mimalloc 2.1.7 (MIT): https://github.com/microsoft/mimalloc/tree/v2.1.7
    License: licenses/AppImage-runtime/mimalloc-LICENSE
  musl 1.2.5 (MIT and component notices): https://musl.libc.org/releases/musl-1.2.5.tar.gz
    License: licenses/AppImage-runtime/musl-COPYRIGHT
  zstd 1.5.6 (BSD-3-Clause): https://github.com/facebook/zstd/tree/v1.5.6
    License: licenses/AppImage-runtime/zstd-LICENSE
  xxHash, copy included in zstd 1.5.6 (Copyright Yann Collet - Meta Platforms, Inc; BSD-3-Clause, see zstd-LICENSE above):
    https://github.com/facebook/zstd/blob/v1.5.6/lib/common/xxhash.h
    Upstream xxHash 0.8.2 license (BSD-2-Clause), for reference: licenses/AppImage-runtime/xxHash-LICENSE
  zlib 1.3.1 (Zlib): https://github.com/madler/zlib/tree/v1.3.1
    License: licenses/AppImage-runtime/zlib-LICENSE

  Run the AppImage with --appimage-extract to get squashfs-root/. The Mirada
  payload runs via squashfs-root/AppRun independently of the Type-2 Runtime.
  To relink the runtime with a modified libfuse, rebuild the runtime using the
  sources and recipe above, then repackage the extracted directory:
    ARCH=x86_64 appimagetool --no-appstream --runtime-file ./runtime-x86_64 squashfs-root Mirada-repacked.AppImage
NOTICES
cp -- "$notices" "$work/THIRD-PARTY-NOTICES.txt"
chmod +x -- "$tool"
artifact=Mirada-${version}-x86_64.AppImage
# Update information for AppImageUpdate; appimagetool also writes $artifact.zsync,
# which must be published next to the AppImage in every GitHub release.
update_info='gh-releases-zsync|jleiva831|mirada|latest|Mirada-*x86_64.AppImage.zsync'
ARCH=x86_64 "$tool" --appimage-extract-and-run --no-appstream --runtime-file "$runtime" \
    --updateinformation "$update_info" \
    --mksquashfs-opt=-processors --mksquashfs-opt=2 "$appdir" "$work/$artifact"
test -s "$work/$artifact.zsync"
mv -Tf -- "$work/$artifact" "$out/$artifact"
mv -Tf -- "$work/$artifact.zsync" "$out/$artifact.zsync"
mv -Tf -- "$work/THIRD-PARTY-NOTICES.txt" "$out/THIRD-PARTY-NOTICES-AppImage.txt"
echo "$out/$artifact"
