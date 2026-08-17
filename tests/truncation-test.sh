#!/bin/sh
# The regression guard for the reason install.sh is written as function
# definitions with one call at the end: it is served to `curl ... | sh`, and a
# shell reading from a pipe runs each complete statement as it arrives. A flat
# script cut short mid-file ran everything above the cut and then exited 0.
#
# Truncate the file at a spread of byte offsets, feed each one to `sh` on stdin
# — which is what the pipe does — and require that nothing ran: no stdout (every
# message this installer prints goes to stdout), and not a byte changed in a
# sandbox HOME and TMPDIR. Syntax errors on stderr are the expected outcome and
# are ignored.
#
# Every offset that stops short of the closing brace is required to run nothing
# at all, including the ones that end mid-word: the body is one brace group, so
# until that brace arrives there is no complete top-level statement for the
# shell to run. Before the group existed, a cut at byte 2351 left the `sa` of
# `say() {` as a bare command, and macOS has an /usr/sbin/sa.
#
# The final line is therefore excluded: a file that includes the closing brace
# is a complete script and is supposed to install.
#
# STRIDE is how many byte offsets to skip between attempts; every line boundary
# is always tested regardless. Set STRIDE=1 for the exhaustive run (slow: one
# shell per byte of the file).
set -eu

root="$(dirname "$0")/.."
src="$root/install.sh"
stride="${STRIDE:-7}"

work="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-truncation-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

home="$work/home"
tmp="$work/tmp"
mkdir -p "$home/.twinforge/app/versions/2026.816.0" "$home/.twinforge/app/bin" "$tmp"
printf 'the payload of an install that already works\n' > "$home/.twinforge/app/versions/2026.816.0/server.js"
: > "$home/.twinforge/app/versions/2026.816.0/.installed"
printf '#!/bin/sh\n' > "$home/.twinforge/app/bin/twinforge"
chmod +x "$home/.twinforge/app/bin/twinforge"

snapshot() {
  find "$home" "$tmp" -exec ls -ld {} +
}
baseline="$(snapshot)"

total="$(wc -c < "$src" | tr -d ' ')"
last_line="$(tail -1 "$src" | wc -c | tr -d ' ')"
limit=$((total - last_line))

# Every line boundary, plus every $stride-th byte.
offsets="$(awk -v limit="$limit" -v stride="$stride" '
  { pos += length($0) + 1; if (pos <= limit) print pos }
  END {
    for (i = 1; i <= limit; i += stride) print i
  }
' "$src" | sort -n -u)"

failures=0
tried=0
for offset in $offsets; do
  head -c "$offset" "$src" > "$work/truncated.sh"
  out="$(env -i PATH="$PATH" HOME="$home" TMPDIR="$tmp" \
    TWINFORGE_DIST_BASE_URL="file://$work/no-such-manifest-source" \
    sh < "$work/truncated.sh" 2>/dev/null || true)"
  tried=$((tried + 1))
  if [ -n "$out" ]; then
    printf 'FAIL truncated at %s of %s bytes produced output: %s\n' "$offset" "$total" "$out"
    failures=$((failures + 1))
  fi
  if [ "$(snapshot)" != "$baseline" ]; then
    printf 'FAIL truncated at %s of %s bytes changed the filesystem\n' "$offset" "$total"
    failures=$((failures + 1))
    break
  fi
done

if [ "$failures" -eq 0 ]; then
  printf 'ok   %s truncations of %s bytes (stride %s) ran nothing\n' "$tried" "$total" "$stride"
else
  printf '\n%s truncation check(s) failed\n' "$failures"
fi
exit "$failures"
