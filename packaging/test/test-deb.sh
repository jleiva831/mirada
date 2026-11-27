#!/usr/bin/env bash
# Tests the Mirada .deb in fresh Docker containers.
# Usage: packaging/test/test-deb.sh <path-to.deb> [image...]
# PACKAGING_STRICT=1 (CI): every image must pass; a skipped image or a failed pull counts as FAIL.
set -uo pipefail

DEFAULT_IMAGES=(debian:12 ubuntu:22.04 ubuntu:24.04 debian:13)
STRICT="${PACKAGING_STRICT:-0}"

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "Usage: $0 <path-to.deb> [image...]" >&2
  exit 2
fi
DEB="$(realpath "$1")"
shift
if [ $# -gt 0 ]; then IMAGES=("$@"); else IMAGES=("${DEFAULT_IMAGES[@]}"); fi

# Expected version from the file name mirada_<version>[-revision]_amd64.deb (empty if it does not match).
EXPECTED_VERSION=""
name="$(basename "$DEB")"
if [[ "$name" =~ ^mirada_([0-9][^_-]*)(-[^_]+)?_amd64\.deb$ ]]; then EXPECTED_VERSION="${BASH_REMATCH[1]}"; fi

# Script that runs inside the container. The .deb is mounted at /pkg/mirada.deb.
read -r -d '' INNER <<'INNER_EOF' || true
set -u
export DEBIAN_FRONTEND=noninteractive
fail() { echo "FAILED-STEP: $*"; exit 1; }
step() { echo "--- $*"; }

# Minimal image: only the .deb is installed, no extra packages beforehand.
# Docker images exclude /usr/share/doc via dpkg; real systems do not.
rm -f /etc/dpkg/dpkg.cfg.d/excludes
echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries

step "apt-get update + install ./mirada.deb"
apt-get update -qq >/dev/null 2>&1 || fail "apt-get update"
cp /pkg/mirada.deb /tmp/mirada.deb
apt-get install -y -qq /tmp/mirada.deb >/tmp/install.log 2>&1 || { tail -30 /tmp/install.log; fail "apt-get install"; }

step "mirada --version"
VERSION_OUT="$(mirada --version 2>&1)" || fail "mirada --version exited non-zero: $VERSION_OUT"
echo "$VERSION_OUT"
case "$VERSION_OUT" in "mirada "[0-9]*) ;; *) fail "unexpected version output: $VERSION_OUT" ;; esac
if [ -n "${EXPECTED_VERSION:-}" ] && [ "$VERSION_OUT" != "mirada $EXPECTED_VERSION" ]; then
  fail "version output '$VERSION_OUT' does not match package version '$EXPECTED_VERSION'"
fi

step "Installed files"
[ -x /usr/bin/mirada ] || fail "/usr/bin/mirada missing"
[ -d /opt/mirada ] || fail "/opt/mirada missing"
[ -f /usr/share/applications/mirada.desktop ] || fail "mirada.desktop missing"
[ -f /usr/share/metainfo/io.github.jleiva831.mirada.metainfo.xml ] || fail "AppStream metainfo missing"
ICON="$(find /usr/share/icons /usr/share/pixmaps -name 'mirada.*' 2>/dev/null | head -n1)"
[ -n "$ICON" ] || fail "icon missing under /usr/share/icons or /usr/share/pixmaps"
echo "icon: $ICON"

step "License documentation"
DOC=/usr/share/doc/mirada
[ -s "$DOC/THIRD-PARTY-NOTICES.txt" ] || fail "$DOC/THIRD-PARTY-NOTICES.txt missing or empty"
[ -d "$DOC/licenses" ] || fail "$DOC/licenses missing"
[ -n "$(find "$DOC/licenses" -type f -size +0c 2>/dev/null | head -n1)" ] || fail "$DOC/licenses has no non-empty file"
echo "ok: THIRD-PARTY-NOTICES.txt and $(find "$DOC/licenses" -type f -size +0c | wc -l) license files present"

step "desktop-file-validate"
apt-get install -y -qq desktop-file-utils >/dev/null 2>&1 || fail "installing desktop-file-utils"
desktop-file-validate /usr/share/applications/mirada.desktop || fail "desktop-file-validate"

step "Launcher isolation (cwd and PYTHONPATH must not be able to shadow the app)"
mkdir -p /tmp/evil
echo 'raise SystemExit("EVIL")' > /tmp/evil/mirada.py
ISO_OUT="$(cd /tmp/evil && PYTHONPATH=/tmp/evil mirada --version 2>&1)"
echo "$ISO_OUT"
[ "$ISO_OUT" = "$VERSION_OUT" ] || fail "launcher is not isolated: got '$ISO_OUT', expected '$VERSION_OUT'"

# Window start: exit 124 (timeout) means the app ran until killed. Anything else,
# a traceback or a Qt platform plugin error is a failure.
check_run() { # <label> <command...>
  local label="$1"; shift
  timeout 8 "$@" >/tmp/run.log 2>&1
  local rc=$?
  cat /tmp/run.log
  [ "$rc" -eq 124 ] || fail "$label: exit $rc (expected 124 = ran until timeout)"
  if grep -qiE 'Traceback|could not load the Qt platform plugin|Aborted|core dumped|Segmentation' /tmp/run.log; then
    fail "$label: traceback or platform plugin error in log"
  fi
  echo "OK: $label"
}

step "Window start, offscreen"
mkdir -p /tmp/h1
QT_QPA_PLATFORM=offscreen HOME=/tmp/h1 check_run "offscreen --start" mirada --start

step "Window start, xcb under xvfb (exercises libxcb-cursor)"
apt-get install -y -qq xvfb >/dev/null 2>&1 || fail "installing xvfb"
mkdir -p /tmp/h2
QT_QPA_PLATFORM=xcb HOME=/tmp/h2 check_run "xcb --start (xvfb)" \
  xvfb-run -a -s "-screen 0 1280x800x24" mirada --start

step "apt-get purge mirada"
apt-get purge -y -qq mirada >/tmp/purge.log 2>&1 || { tail -20 /tmp/purge.log; fail "apt-get purge"; }
[ ! -e /opt/mirada ] || fail "/opt/mirada still present after purge"
[ ! -e /usr/bin/mirada ] || fail "/usr/bin/mirada still present after purge"
[ ! -e /usr/share/applications/mirada.desktop ] || fail ".desktop still present after purge"
[ ! -e /usr/share/metainfo/io.github.jleiva831.mirada.metainfo.xml ] || fail "metainfo still present after purge"
[ ! -e /usr/share/doc/mirada ] || fail "$DOC still present after purge"
LEFT="$(find /usr/share/icons /usr/share/pixmaps -name 'mirada.*' 2>/dev/null)"
[ -z "$LEFT" ] || fail "icon still present after purge: $LEFT"
if dpkg -s mirada >/dev/null 2>&1; then fail "dpkg still knows mirada after purge"; fi
echo "ALL-OK"
INNER_EOF

overall=0
declare -A RESULT
for img in "${IMAGES[@]}"; do
  echo "=================== $img ==================="
  if ! docker pull -q "$img" >/dev/null 2>&1; then
    if [ "$STRICT" = 1 ]; then
      echo "FAIL: docker pull $img failed (strict mode)"
      RESULT[$img]="FAIL"; overall=1; continue
    fi
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "SKIP: image $img not available"
      RESULT[$img]="SKIP"; continue
    fi
  fi
  log="$(mktemp)"
  docker run --rm -e "EXPECTED_VERSION=$EXPECTED_VERSION" -v "$DEB:/pkg/mirada.deb:ro" "$img" bash -c "$INNER" 2>&1 | tee "$log"
  if grep -q '^ALL-OK$' "$log"; then
    RESULT[$img]="PASS"
  else
    RESULT[$img]="FAIL"
    overall=1
  fi
  rm -f "$log"
done

echo
echo "=================== Result (.deb: $(basename "$DEB")) ==================="
passed=0
for img in "${IMAGES[@]}"; do
  printf '%-6s %s\n' "${RESULT[$img]}" "$img"
  [ "${RESULT[$img]}" = PASS ] && passed=$((passed + 1))
done
if [ "$STRICT" = 1 ] && [ "$passed" -ne "${#IMAGES[@]}" ]; then overall=1; fi
[ "$passed" -gt 0 ] || { echo "No image was tested"; exit 1; }
exit "$overall"
