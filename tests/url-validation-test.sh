#!/bin/sh
# The artifact URL comes out of the manifest and goes to curl. A value starting
# with `-` is read by curl as an option — `-Kcfg.txt` makes it read a config
# file and exit 0 — and every scheme libcurl supports is otherwise accepted,
# `file:///dev/zero` included. This asserts the check in front of that stays.
set -eu

root="$(dirname "$0")/.."
TWINFORGE_INSTALL_LIB=1
export TWINFORGE_INSTALL_LIB
LC_ALL=C
export LC_ALL
# shellcheck source=install.sh
. "$root/install.sh"

failures=0

# assert_https_url exits on rejection, so each call gets its own subshell.
accepts() {
  if ( assert_https_url "$1" manifest-url 1.0.0 ) >/dev/null 2>&1; then
    printf 'ok   accepted: %s\n' "$1"
  else
    printf 'FAIL rejected but should be accepted: %s\n' "$1"
    failures=$((failures + 1))
  fi
}

rejects() {
  if ( assert_https_url "$1" manifest-url 1.0.0 ) >/dev/null 2>&1; then
    printf 'FAIL accepted but should be rejected: %s\n' "$1"
    failures=$((failures + 1))
  else
    printf 'ok   rejected: %s\n' "$1"
  fi
}

accepts "https://example.com/twinforge.tar.gz"
accepts "HTTPS://example.com/twinforge.tar.gz"

rejects "-Kcfg.txt"
rejects "--output=/tmp/pwned"
rejects "file:///dev/zero"
rejects "file:///etc/passwd"
rejects "ftp://example.com/twinforge.tar.gz"
rejects "scp://example.com/twinforge.tar.gz"
rejects "http://example.com/twinforge.tar.gz"
rejects "https://"
rejects ""
rejects "https://example.com/a b.tar.gz"
rejects "$(printf 'https://example.com/a\nftp://elsewhere/b')"

if [ "$failures" -eq 0 ]; then
  printf '\nall URL checks passed\n'
else
  printf '\n%s URL check(s) failed\n' "$failures"
fi
exit "$failures"
