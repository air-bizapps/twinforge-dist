#!/bin/sh
# The two installers carry the same signing keys in two different
# representations: install.sh holds PEM, because that is what openssl reads, and
# install.ps1 holds a base64 modulus, because Windows PowerShell 5.1 has no PEM
# parser. Two copies of one key that drift apart in silence is a real failure
# mode -- and the shape it takes is the worst kind, because the installer that
# still works hides the one that does not until somebody on the other operating
# system tries.
#
# So this asserts they are the same key: same ids, in the same order, same
# modulus, and an exponent of 65537 -- which install.ps1 hard-codes and cannot
# check for itself, since the modulus is all it carries.
#
# Both lists are empty today, and this passes by agreeing that they are. It
# becomes the check that matters on the day the signing ceremony adds the first
# real key.
set -eu

root="$(dirname "$0")/.."
LC_ALL=C
export LC_ALL

# Sourced, so the ids and PEMs come out of install.sh's own functions rather
# than from a second parser written here that could disagree with it. The
# override is cleared first: what is being compared is what the file *ships*.
unset TWINFORGE_DIST_PUBKEY_FILE || true
TWINFORGE_INSTALL_LIB=1
export TWINFORGE_INSTALL_LIB
# shellcheck source=install.sh
. "$root/install.sh"

command -v openssl >/dev/null 2>&1 || {
  printf 'openssl is required to compare the two key representations.\n' >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-key-parity.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failures=0

fail_check() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# install.ps1's entries, one per line, as "<keyId> <base64 modulus>". Comment
# lines are dropped first so that an example written in a comment cannot be
# mistaken for a key -- and so that the shape this depends on is stated in
# install.ps1 next to the list itself.
grep -v '^[[:space:]]*#' "$root/install.ps1" \
  | sed -n 's/.*KeyId = "\([^"]*\)"; ModulusBase64 = "\([^"]*\)".*/\1 \2/p' \
  > "$work/ps-keys.txt"

manifest_key_ids > "$work/sh-ids.txt"
sed 's/ .*//' "$work/ps-keys.txt" > "$work/ps-ids.txt"

sh_count="$(wc -l < "$work/sh-ids.txt" | tr -d ' ')"
ps_count="$(wc -l < "$work/ps-ids.txt" | tr -d ' ')"

if [ "$sh_count" != "$ps_count" ]; then
  fail_check "install.sh carries $sh_count signing key(s) and install.ps1 carries $ps_count."
elif ! cmp -s "$work/sh-ids.txt" "$work/ps-ids.txt"; then
  fail_check "the two installers carry different key ids, or the same ids in a different order:
       install.sh:  $(tr '\n' ' ' < "$work/sh-ids.txt")
       install.ps1: $(tr '\n' ' ' < "$work/ps-ids.txt")"
else
  printf 'ok   both installers carry the same %s key id(s)\n' "$sh_count"
fi

# Nothing below runs when the lists disagree about what they hold.
if [ "$failures" -eq 0 ] && [ "$sh_count" -gt 0 ]; then
  while IFS=' ' read -r key_id modulus_b64; do
    [ -n "$key_id" ] || continue
    manifest_key_pem "$key_id" > "$work/key.pem"

    pem_modulus="$(openssl rsa -pubin -in "$work/key.pem" -noout -modulus 2>/dev/null \
      | sed -n 's/^Modulus=//p' | tr 'abcdef' 'ABCDEF')"
    if [ -z "$pem_modulus" ]; then
      fail_check "install.sh's PEM for \"$key_id\" is not an RSA public key openssl can read."
      continue
    fi

    # The other direction from the one make-signature-fixtures.sh goes: decode
    # the base64 and print it as hex, which needs nothing but od.
    ps_modulus="$(printf '%s' "$modulus_b64" | openssl base64 -d -A 2>/dev/null \
      | od -An -tx1 | tr -d ' \n' | tr 'abcdef' 'ABCDEF')"
    if [ -z "$ps_modulus" ]; then
      fail_check "install.ps1's modulus for \"$key_id\" is not decodable base64."
      continue
    fi

    if [ "$pem_modulus" != "$ps_modulus" ]; then
      fail_check "\"$key_id\" is a different key in the two installers.
       install.sh  modulus starts $(printf '%s' "$pem_modulus" | cut -c1-32)... (${#pem_modulus} hex digits)
       install.ps1 modulus starts $(printf '%s' "$ps_modulus" | cut -c1-32)... (${#ps_modulus} hex digits)"
    else
      printf 'ok   "%s" is the same modulus in both installers\n' "$key_id"
    fi

    # install.ps1 hard-codes the exponent as 65537 because a bare modulus does
    # not carry one. A key generated with any other exponent would verify in
    # install.sh and fail in install.ps1, on Windows only, with a message about
    # the signature rather than about the key.
    if openssl rsa -pubin -in "$work/key.pem" -noout -text 2>/dev/null | grep -q 'Exponent: 65537'; then
      printf 'ok   "%s" uses the exponent install.ps1 assumes (65537)\n' "$key_id"
    else
      fail_check "\"$key_id\" does not use exponent 65537, which install.ps1 hard-codes. That key cannot be verified on Windows."
    fi

    if [ "${#pem_modulus}" -lt 768 ]; then
      fail_check "\"$key_id\" is $(( ${#pem_modulus} * 4 )) bits, below the 3072 bits this project signs with."
    else
      printf 'ok   "%s" is %s bits\n' "$key_id" "$(( ${#pem_modulus} * 4 ))"
    fi
  done < "$work/ps-keys.txt"
fi

if [ "$sh_count" -eq 0 ] && [ "$failures" -eq 0 ]; then
  printf 'ok   neither installer carries a signing key yet, so both refuse every manifest\n'
  printf '     (that is the shipped state until the signing ceremony; see the design, section 3)\n'
fi

if [ "$failures" -eq 0 ]; then
  printf '\nthe two installers agree about their signing keys\n'
else
  printf '\n%s key parity check(s) failed\n' "$failures"
fi
exit "$failures"
