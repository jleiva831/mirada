#!/usr/bin/env bash
# Tests the Mirada AppImage in containers that have no Python and no Qt.
# Usage: packaging/test/test-appimage.sh <path-to.AppImage> [image...]
# PACKAGING_STRICT=1 (CI): every image must pass; a skipped image or a failed pull counts as FAIL.
set -uo pipefail

DEFAULT_IMAGES=(debian:12-slim ubuntu:22.04 ubuntu:24.04)
STRICT="${PACKAGING_STRICT:-0}"

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "Usage: $0 <path-to.AppImage> [image...]" >&2
  exit 2
fi
APPIMAGE="$(realpath "$1")"
shift
if [ $# -gt 0 ]; then IMAGES=("$@"); else IMAGES=("${DEFAULT_IMAGES[@]}"); fi

# Expected version from the file name Mirada-<version>-x86_64.AppImage (empty if it does not match).
EXPECTED_VERSION=""
name="$(basename "$APPIMAGE")"
if [[ "$name" =~ ^Mirada-([0-9][^-]*)-x86_64\.AppImage$ ]]; then EXPECTED_VERSION="${BASH_REMATCH[1]}"; fi

read -r -d '' INNER <<'INNER_EOF' || true
set -u
export DEBIAN_FRONTEND=noninteractive
fail() { echo "FAILED-STEP: $*"; exit 1; }
step() { echo "--- $*"; }

step "No Python/Qt in the container"
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  fail "python is present in the test container, the test would be meaningless"
fi
if ldconfig -p 2>/dev/null | grep -qE 'libxcb-cursor|libQt6|libportaudio'; then
  fail "libxcb-cursor/Qt6/portaudio are present in the container, the test would be meaningless"
fi
echo "ok: no python3, xcb-cursor, Qt6 or portaudio in the container"

# Test-container tooling (not part of the app). No FUSE needed thanks to extract-and-run.
# xvfb pulls in X server libraries, but explicitly NOT libxcb-cursor0 and no python.
step "Install test tooling (xvfb, xauth)"
echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries
apt-get update -qq >/dev/null 2>&1 || fail "apt-get update"
apt-get install -y -qq --no-install-recommends xvfb xauth >/tmp/install.log 2>&1 || { tail -20 /tmp/install.log; fail "test tooling"; }
if command -v python3 >/dev/null 2>&1; then fail "python3 was installed by the test tooling"; fi
if dpkg -s libxcb-cursor0 >/dev/null 2>&1; then fail "libxcb-cursor0 was installed by the test tooling"; fi
echo "ok: tooling installed, still no python3 and no libxcb-cursor0"

# Run the AppImage as a normal user (some runtimes refuse root), from a copy so the
# mounted volume can stay read-only.
useradd -m tester >/dev/null 2>&1 || fail "useradd"
cp /pkg/app.AppImage /home/tester/app.AppImage
chmod +x /home/tester/app.AppImage
chown tester /home/tester/app.AppImage

as_tester() { su tester -s /bin/bash -c "cd /home/tester && $*"; }

step "--appimage-extract-and-run --version"
VERSION_OUT="$(as_tester "./app.AppImage --appimage-extract-and-run --version" 2>&1)" || fail "--version exited non-zero: $VERSION_OUT"
echo "$VERSION_OUT"
case "$VERSION_OUT" in "mirada "[0-9]*) ;; *) fail "unexpected version output: $VERSION_OUT" ;; esac
if [ -n "${EXPECTED_VERSION:-}" ] && [ "$VERSION_OUT" != "mirada $EXPECTED_VERSION" ]; then
  fail "version output '$VERSION_OUT' does not match AppImage version '$EXPECTED_VERSION'"
fi

step "Extract the AppImage"
as_tester "./app.AppImage --appimage-extract" >/dev/null 2>&1 || fail "--appimage-extract"
ROOT=/home/tester/squashfs-root
PY="$ROOT/usr/python/bin/python3"
[ -x "$PY" ] || fail "bundled python missing at $PY"
[ -f "$ROOT/usr/share/metainfo/io.github.jleiva831.mirada.metainfo.xml" ] || fail "AppStream metainfo missing"

step "License documentation"
DOC="$ROOT/usr/share/doc/mirada"
[ -s "$DOC/THIRD-PARTY-NOTICES.txt" ] || fail "$DOC/THIRD-PARTY-NOTICES.txt missing or empty"
[ -d "$DOC/licenses" ] || fail "$DOC/licenses missing"
[ -n "$(find "$DOC/licenses" -type f -size +0c 2>/dev/null | head -n1)" ] || fail "$DOC/licenses has no non-empty file"
echo "ok: THIRD-PARTY-NOTICES.txt and $(find "$DOC/licenses" -type f -size +0c | wc -l) license files present"

step "Launcher isolation (cwd and PYTHONPATH must not be able to shadow the app)"
mkdir -p /tmp/evil
echo 'raise SystemExit("EVIL")' > /tmp/evil/mirada.py
chmod -R a+rX /tmp/evil
ISO_OUT="$(su tester -s /bin/bash -c "cd /tmp/evil && PYTHONPATH=/tmp/evil /home/tester/app.AppImage --appimage-extract-and-run --version" 2>&1)"
echo "$ISO_OUT"
[ "$ISO_OUT" = "$VERSION_OUT" ] || fail "launcher is not isolated: got '$ISO_OUT', expected '$VERSION_OUT'"

check_run() { # <label> <env-prefix> <command run from the home directory>
  local label="$1" envp="$2" cmd="$3"
  as_tester "$envp timeout 10 $cmd" >/tmp/run.log 2>&1
  local rc=$?
  cat /tmp/run.log
  [ "$rc" -eq 124 ] || fail "$label: exit $rc (expected 124 = ran until timeout)"
  if grep -qiE 'Traceback|could not load the Qt platform plugin|Aborted|core dumped|Segmentation|error while loading shared libraries' /tmp/run.log; then
    fail "$label: traceback, platform plugin or shared library error in log"
  fi
  echo "OK: $label"
}

step "Window start, offscreen"
check_run "offscreen --start" "QT_QPA_PLATFORM=offscreen" "./app.AppImage --appimage-extract-and-run --start"

step "Window start, xcb under Xvfb (libxcb-cursor must be bundled)"
check_run "xcb --start (xvfb)" "QT_QPA_PLATFORM=xcb" \
  "xvfb-run -a -s '-screen 0 1280x800x24' ./app.AppImage --appimage-extract-and-run --start"

step "PortAudio is bundled"
PA="$(find "$ROOT" -name 'libportaudio.so*' 2>/dev/null | head -n1)"
[ -n "$PA" ] || fail "libportaudio is not bundled in the AppImage"
echo "bundled: $PA"

audio_probe() { # prints "<AUDIO_OK> <AUDIO_ERR>" using the bundled python
  as_tester "LD_LIBRARY_PATH=$ROOT/usr/lib $PY -I -c 'import mirada.audio as a; print(a.AUDIO_OK, a.AUDIO_ERR)'" 2>&1
}

step "Voice tracking without ALSA/JACK in the container: must degrade cleanly"
PROBE="$(audio_probe)" || fail "audio probe crashed: $PROBE"
echo "$PROBE"
case "$PROBE" in "True "*|"False "*) ;; *) fail "audio probe printed something unexpected: $PROBE" ;; esac
echo "(the clean window starts above are the benchmark here)"

step "Voice tracking with libasound2 + libjack-jackd2-0 in the container: AUDIO_OK must be True"
alsa_pkg=libasound2; apt-cache show libasound2t64 >/dev/null 2>&1 && alsa_pkg=libasound2t64  # renamed in Ubuntu 24.04 (time_t)
apt-get install -y -qq --no-install-recommends "$alsa_pkg" libjack-jackd2-0 >/tmp/audio-libs.log 2>&1 \
  || { tail -20 /tmp/audio-libs.log; fail "installing libasound2/libjack-jackd2-0"; }
if command -v python3 >/dev/null 2>&1; then fail "python3 was installed together with the audio libraries"; fi
PROBE="$(audio_probe)" || fail "audio probe crashed: $PROBE"
echo "$PROBE"
case "$PROBE" in "True "*) ;; *) fail "AUDIO_OK is not True although ALSA and JACK are installed: $PROBE" ;; esac

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
  docker run --rm -e "EXPECTED_VERSION=$EXPECTED_VERSION" -v "$APPIMAGE:/pkg/app.AppImage:ro" "$img" bash -c "$INNER" 2>&1 | tee "$log"
  if grep -q '^ALL-OK$' "$log"; then
    RESULT[$img]="PASS"
  else
    RESULT[$img]="FAIL"
    overall=1
  fi
  rm -f "$log"
done

echo
echo "=================== Result (AppImage: $(basename "$APPIMAGE")) ==================="
passed=0
for img in "${IMAGES[@]}"; do
  printf '%-6s %s\n' "${RESULT[$img]}" "$img"
  [ "${RESULT[$img]}" = PASS ] && passed=$((passed + 1))
done
if [ "$STRICT" = 1 ] && [ "$passed" -ne "${#IMAGES[@]}" ]; then overall=1; fi
[ "$passed" -gt 0 ] || { echo "No image was tested"; exit 1; }
exit "$overall"
