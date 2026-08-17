#!/bin/sh
# The regression guard for the bug that made an installer on a Mac download the
# Linux tarball, verify its checksum, and report success: the old parser picked
# the platform block with a `sed` line range, so it was correct only while the
# manifest happened to be pretty-printed one key per line. channels/ was empty,
# so that format contract had never once been exercised.
#
# Every case here therefore runs against BOTH fixtures — the pretty-printed one
# and the byte-identical minified one — and asserts the same, correct answer
# from each. If they ever disagree again, this is what says so.
set -eu

root="$(dirname "$0")/.."
TWINFORGE_INSTALL_LIB=1
export TWINFORGE_INSTALL_LIB
LC_ALL=C
export LC_ALL
# shellcheck source=install.sh
. "$root/install.sh"

fixtures="$root/tests/fixtures"
work="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-manifest-test.XXXXXX")"
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

field_of() {
  # $1 fixture, $2 platform, $3 field
  manifest_scan "$fixtures/$1" "$2" > "$work/out.tsv"
  manifest_field "$work/out.tsv" "$3"
}

LINUX_URL="https://example.com/twinforge-2026.816.0-linux-x64.tar.gz"
LINUX_SHA="1111111111111111111111111111111111111111111111111111111111111111"
DARWIN_URL="https://example.com/twinforge-2026.816.0-darwin-arm64.tar.gz"
DARWIN_SHA="2222222222222222222222222222222222222222222222222222222222222222"

for shape in pretty minified; do
  f="manifest-$shape.json"
  check "$shape: version is the top-level one" "2026.816.0" "$(field_of "$f" linux-x64 version)"
  # The three fields the signature depends on. schemaVersion is read from the
  # scanner's *scalar* path, because it is a JSON number and every other field
  # here is a JSON string; the two shapes have to agree about that too.
  check "$shape: schemaVersion" "2" "$(field_of "$f" linux-x64 schemaVersion)"
  check "$shape: channel" "canary" "$(field_of "$f" linux-x64 channel)"
  check "$shape: keyId" "2026-08-canary" "$(field_of "$f" linux-x64 keyId)"
  check "$shape: linux-x64 url" "$LINUX_URL" "$(field_of "$f" linux-x64 url)"
  check "$shape: linux-x64 sha256" "$LINUX_SHA" "$(field_of "$f" linux-x64 sha256)"
  # The one that mattered: darwin-arm64 is the *second* artifact in the file,
  # so a parser that falls back to "the first url in the document" gets the
  # linux one here and gets a matching sha256 to go with it.
  check "$shape: darwin-arm64 url" "$DARWIN_URL" "$(field_of "$f" darwin-arm64 url)"
  check "$shape: darwin-arm64 sha256" "$DARWIN_SHA" "$(field_of "$f" darwin-arm64 sha256)"
  # An absent platform must come back empty — the caller turns that into "no
  # artifact for platform X" — and never into a neighbour's values.
  check "$shape: unknown platform has no url" "" "$(field_of "$f" win-x64 url)"
  check "$shape: unknown platform has no sha256" "" "$(field_of "$f" win-x64 sha256)"
done

# "version" nested inside an artifact object, placed before the top-level one.
check "nested version does not win" "2026.816.0" \
  "$(field_of manifest-nested-version.json linux-x64 version)"

# Two answers to the same question is a manifest someone has edited.
manifest_scan "$fixtures/manifest-duplicate-url.json" linux-x64 > "$work/dup.tsv"
if manifest_field "$work/dup.tsv" url >/dev/null 2>&1; then
  printf 'FAIL duplicate url is rejected\n'
  failures=$((failures + 1))
else
  printf 'ok   duplicate url is rejected\n'
fi

# Malformed input fails loudly rather than returning whatever it managed to see.
if manifest_scan "$fixtures/manifest-malformed.json" linux-x64 > "$work/bad.tsv" 2>&1; then
  printf 'FAIL malformed manifest is rejected\n'
  failures=$((failures + 1))
else
  printf 'ok   malformed manifest is rejected (%s)\n' "$(sed -n 's/^error	//p' "$work/bad.tsv" | head -1)"
fi

if [ "$failures" -eq 0 ]; then
  printf '\nall manifest parser checks passed\n'
else
  printf '\n%s manifest parser check(s) failed\n' "$failures"
fi
exit "$failures"
