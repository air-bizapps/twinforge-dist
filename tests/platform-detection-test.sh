#!/bin/sh
# install.sh's platform detection, run rather than read.
#
# tests/platform-detection-test.ps1 exists because install.ps1 told a healthy
# machine its CPU was not built yet. install.sh had no equivalent, and then
# acquired the same shape of hazard from the other direction: darwin-x64 is a
# real target now, and `uname -m` on a Mac answers for the *process*, not the
# machine. An Apple Silicon Mac whose terminal is translated by Rosetta reports
# x86_64 -- Terminal or iTerm with "Open using Rosetta" ticked, a shell started
# by `arch -x86_64`, a terminal hosted inside an x86 process. While darwin-x64
# was unsupported that produced a refusal. It would now install the emulated
# build and keep updating to it forever, saying nothing.
#
# So the cases below are run, not asserted about the text: `uname` and `sysctl`
# are replaced on PATH and the real block is lifted out of the real install.sh
# and executed against them. Sourcing install.sh is not an option here the way
# it is in manifest-parse-test.sh -- TWINFORGE_INSTALL_LIB stops before `main`,
# and this block lives inside it.
set -eu

root="$(dirname "$0")/.."
installer="$root/install.sh"
LC_ALL=C
export LC_ALL

work="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-platform-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  # $1 what, $2 expected, $3 actual
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

# Between the two section banners, so that the day someone moves this code the
# test says the block is gone instead of quietly checking an empty file.
sed -n '/^  # --- Platform detection /,/^  # --- Fetch and read the channel manifest /p' \
  "$installer" > "$work/block.sh"
if ! grep -q 'PLATFORM_TAG=' "$work/block.sh"; then
  printf 'FAIL install.sh has no platform-detection block between the section banners\n'
  exit 1
fi

# say and fail are install.sh's, reduced to what these cases read. fail keeps
# its exit, because a refusal that returned would let the case continue and
# report a tag nobody was given.
cat > "$work/harness.sh" <<'HARNESS'
say() { printf '%s\n' "$@"; }
fail() { printf 'REFUSED: %s\n' "$1" >&2; exit 1; }
. "$BLOCK"
printf 'tag=%s\n' "$PLATFORM_TAG"
HARNESS

mkdir -p "$work/bin"
cat > "$work/bin/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) printf '%s\n' "$STUB_OS" ;;
  -m) printf '%s\n' "$STUB_ARCH" ;;
esac
STUB
# Three ways a real sysctl answers, because they are three different facts and
# the block must not conflate them: the key is 1, the key is 0, and the key is
# not there at all (Intel Macs have no hw.optional.arm64, and `sysctl -n` on a
# missing key exits non-zero and prints nothing).
cat > "$work/bin/sysctl" <<'STUB'
#!/bin/sh
if [ "${STUB_NO_SYSCTL:-0}" = 1 ]; then exit 127; fi
if [ "$2" = hw.optional.arm64 ] && [ -n "${STUB_ARM64:-}" ]; then
  printf '%s\n' "$STUB_ARM64"
  exit 0
fi
exit 1
STUB
chmod +x "$work/bin/uname" "$work/bin/sysctl"

detect() {
  # $1 uname -s, $2 uname -m, $3 hw.optional.arm64 ("" = key absent),
  # $4 1 to remove sysctl from the machine entirely
  env PATH="$work/bin:$PATH" BLOCK="$work/block.sh" \
    STUB_OS="$1" STUB_ARCH="$2" STUB_ARM64="$3" STUB_NO_SYSCTL="${4:-0}" \
    sh "$work/harness.sh" 2>&1 | tr '\n' ' '
}

check "Apple Silicon, native shell" \
  "tag=darwin-arm64 " "$(detect Darwin arm64 1)"

# The case this file was written for.
check "Apple Silicon under Rosetta installs the arm64 build, and says so" \
  "This is an Apple Silicon Mac, but the shell running this script is translated by Rosetta, so uname reports x86_64. Installing the native arm64 build. tag=darwin-arm64 " \
  "$(detect Darwin x86_64 1)"

check "a real Intel Mac gets darwin-x64" \
  "tag=darwin-x64 " "$(detect Darwin x86_64 0)"

# Not the same as "the answer was 0", and it must not be treated as Rosetta:
# guessing upward here installs an arm64 build on a machine that cannot run it.
check "an Intel Mac whose sysctl has no such key still gets darwin-x64" \
  "tag=darwin-x64 " "$(detect Darwin x86_64 '')"

check "no sysctl at all is not evidence of Apple Silicon" \
  "tag=darwin-x64 " "$(detect Darwin x86_64 '' 1)"

# The probe is Darwin-only: a Linux box with some other sysctl answering that
# name must not be talked into an arm64 tag.
check "Linux x86_64 is untouched by the Rosetta probe" \
  "tag=linux-x64 " "$(detect Linux x86_64 1)"

check "Linux aarch64 is refused, naming the tag as well as the uname pair" \
  "REFUSED: Unsupported platform: Linux/aarch64 (platform tag linux-arm64) " \
  "$(detect Linux aarch64 '')"

check "an operating system nobody builds for is refused" \
  "REFUSED: Unsupported platform: FreeBSD/amd64 (platform tag FreeBSD-x64) " \
  "$(detect FreeBSD amd64 '')"

if [ "$failures" -ne 0 ]; then
  printf '\n%s check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall platform-detection checks passed\n'
