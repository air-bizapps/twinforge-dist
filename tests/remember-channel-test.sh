#!/bin/sh
# install.sh's remember_channel, run rather than read.
#
# The updater falls back to `canary` whenever TWINFORGE_CHANNEL is unset, so a
# `stable` install that forgets its channel drifts to canary on the first
# update from a new shell. These cases run the real function, sourced from the
# real install.sh, against a throwaway HOME.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
TWINFORGE_INSTALL_LIB=1
export TWINFORGE_INSTALL_LIB
# shellcheck source=install.sh
. "$root/install.sh"
set +e

LC_ALL=C
export LC_ALL

work="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-channel-test.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
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

fresh_home() {
  HOME="$work/$1"
  mkdir -p "$HOME"
  export HOME
}

count_lines() {
  # $1 file, $2 fixed string
  if [ -f "$1" ]; then grep -cF "$2" "$1"; else echo 0; fi
}

os_tag=linux
SHELL=/bin/zsh

# 1. First install writes the line once, and a shell that reads the file sees it.
fresh_home first
CHANNEL=stable
remember_channel >/dev/null
check "first install writes the channel" 1 "$(count_lines "$HOME/.zshrc" 'export TWINFORGE_CHANNEL="stable"')"
check "a shell reading the profile sees it" stable "$(sh -c '. "$1"; printf %s "$TWINFORGE_CHANNEL"' sh "$HOME/.zshrc")"

# 2. Re-running with the same channel does not duplicate it.
remember_channel >/dev/null
check "re-run does not duplicate" 1 "$(count_lines "$HOME/.zshrc" 'export TWINFORGE_CHANNEL=')"

# 3. Re-running with another channel replaces the line instead of adding one.
CHANNEL=canary
remember_channel >/dev/null
check "switching channel leaves one line" 1 "$(count_lines "$HOME/.zshrc" 'export TWINFORGE_CHANNEL=')"
check "switching channel writes the new one" 1 "$(count_lines "$HOME/.zshrc" 'export TWINFORGE_CHANNEL="canary"')"

# 4. Unrelated content in the profile survives the rewrite.
fresh_home keep
printf 'alias ll="ls -l"\nexport TWINFORGE_CHANNEL="canary"\n# end\n' > "$HOME/.zshrc"
CHANNEL=stable
remember_channel >/dev/null
check "unrelated lines survive" 'alias ll="ls -l"|export TWINFORGE_CHANNEL="stable"|# end' "$(paste -sd'|' "$HOME/.zshrc")"

# 5. Unknown shell: nothing written, the exact line is handed over.
fresh_home unknown
SHELL=/usr/bin/fish
out="$(remember_channel)"
check "unknown shell writes nothing" 0 "$(find "$HOME" -type f | wc -l | tr -d ' ')"
check "unknown shell prints the line" 1 "$(printf '%s\n' "$out" | grep -cF 'export TWINFORGE_CHANNEL="stable"')"
SHELL=/bin/zsh

# 6. A channel name that is not a plain token is never written into a startup file.
fresh_home invalid
CHANNEL='stable"; rm -rf ~; "'
remember_channel >/dev/null
check "unsafe channel writes nothing" 0 "$(find "$HOME" -type f | wc -l | tr -d ' ')"
CHANNEL=stable

# 7. A read-only profile never fails the install.
fresh_home readonly
printf '# managed elsewhere\n' > "$HOME/.zshrc"
chmod a-w "$HOME/.zshrc"
remember_channel >/dev/null 2>&1
check "read-only profile returns 0" 0 "$?"

if [ "$failures" -ne 0 ]; then
  printf '%s case(s) failed\n' "$failures"
  exit 1
fi
printf 'all remember_channel cases passed\n'
