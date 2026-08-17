#!/bin/sh
# The channel manifest names the URL and the sha256 that install.sh downloads
# and executes. Its signature is the only thing standing between "whoever can
# write channels/canary.json" and "code execution on every machine that
# installs from here", so the checks that matter here are not the ones that
# confirm a good signature passes -- a verifier that always returns true passes
# those. They are the ones that alter a byte, swap the key, truncate the
# signature, rename the channel, or take the keys away, and demand a refusal.
#
# Every case below runs against a real RSA-3072 key pair and a real openssl
# signature, generated here rather than committed: no key material lives in
# this public repository, not even a test key.
set -eu

root="$(dirname "$0")/.."
TWINFORGE_INSTALL_LIB=1
export TWINFORGE_INSTALL_LIB
LC_ALL=C
export LC_ALL
# shellcheck source=install.sh
. "$root/install.sh"

command -v openssl >/dev/null 2>&1 || {
  printf 'openssl is required to run this test, and is a hard dependency of install.sh itself.\n' >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-signature-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failures=0

# --- Reporting ----------------------------------------------------------------

pass() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# verify_manifest_signature and assert_signed_manifest both end in `fail`, which
# exits, so each call gets its own subshell. Output is captured rather than
# discarded: a refusal that refuses for the wrong reason is a refusal that will
# stop refusing when the wrong reason goes away, so every case below also says
# which sentence it expects.
accepts() {
  # $1 label, then the command
  label="$1"
  shift
  if out="$( "$@" 2>&1 )"; then
    pass "$label"
  else
    bad "$label
       expected it to be accepted, but it refused with:
       $out"
  fi
}

refuses() {
  # $1 label, $2 a fragment the refusal has to contain, then the command
  label="$1"
  expect="$2"
  shift 2
  if out="$( "$@" 2>&1 )"; then
    bad "$label
       expected a refusal, but it was ACCEPTED"
  elif ! printf '%s' "$out" | grep -qF "$expect"; then
    bad "$label
       refused, but not for the expected reason
       expected to find: $expect
       actual:           $out"
  else
    pass "$label"
  fi
}

# --- Fixtures -----------------------------------------------------------------

openssl genrsa -out "$work/key.pem" 3072 2>/dev/null
openssl rsa -in "$work/key.pem" -pubout -out "$work/pub.pem" 2>/dev/null
# A second, equally valid key. The signature it makes is well-formed, correctly
# encoded, and over exactly these bytes -- everything except made by a key this
# installer carries.
openssl genrsa -out "$work/other-key.pem" 3072 2>/dev/null
openssl rsa -in "$work/other-key.pem" -pubout -out "$work/other-pub.pem" 2>/dev/null
# Long enough to sign with, short enough to be refused on strength.
openssl genrsa -out "$work/weak-key.pem" 1024 2>/dev/null
openssl rsa -in "$work/weak-key.pem" -pubout -out "$work/weak-pub.pem" 2>/dev/null

write_manifest() {
  # $1 target file, $2 schemaVersion (verbatim JSON), $3 channel, $4 keyId,
  # $5 version, $6 artifact url
  cat > "$1" <<EOF
{
  "schemaVersion": $2,
  "channel": "$3",
  "keyId": "$4",
  "sequence": 1,
  "version": "$5",
  "artifacts": {
    "linux-x64": {
      "url": "$6",
      "sha256": "1111111111111111111111111111111111111111111111111111111111111111"
    },
    "darwin-arm64": {
      "url": "$6",
      "sha256": "1111111111111111111111111111111111111111111111111111111111111111"
    }
  }
}
EOF
}

sign_with() {
  # $1 private key, $2 manifest file, $3 signature file
  openssl dgst -sha256 -sign "$1" -out "$work/sig.bin.tmp" "$2"
  openssl base64 -A -in "$work/sig.bin.tmp" -out "$3"
  printf '\n' >> "$3"
  rm -f "$work/sig.bin.tmp"
}

# The URL every fixture points at. https, so it passes the URL check, and a
# port nothing listens on, so the end-to-end case below fails at the download
# rather than downloading a few hundred MiB.
DEAD_URL="https://127.0.0.1:1/twinforge.tar.gz"

write_manifest "$work/manifest.json" 2 canary local-test 1.0.0 "$DEAD_URL"
sign_with "$work/key.pem" "$work/manifest.json" "$work/manifest.json.sig"

# The key the installer carries for the rest of this file. This is the
# documented local-testing override, and it registers the key under the id
# "local-test" -- which is what makes the unknown-keyId case below a real test
# rather than a tautology: the list holds exactly one id, and a manifest naming
# any other one has to be refused even though the only key present would verify
# its signature perfectly.
TWINFORGE_DIST_PUBKEY_FILE="$work/pub.pem"
export TWINFORGE_DIST_PUBKEY_FILE

fields_of() {
  # $1 manifest file -> the scan output, in a file named after it
  manifest_scan "$1" linux-x64 > "$1.tsv"
  printf '%s\n' "$1.tsv"
}

# --- The signature itself -----------------------------------------------------

accepts "a good signature verifies" \
  verify_manifest_signature "$work/manifest.json" "$work/manifest.json.sig" local-test URL

# One byte. "1.0.0" becomes "1.0.1" -- a manifest edited to name a different
# release, which is the whole attack in one character.
sed 's/1\.0\.0/1.0.1/' "$work/manifest.json" > "$work/tampered.json"
cp "$work/manifest.json.sig" "$work/tampered.json.sig"
cmp -s "$work/manifest.json" "$work/tampered.json" && bad "the tampered fixture is identical to the good one"
refuses "one altered byte in the manifest is refused" "does not match its bytes" \
  verify_manifest_signature "$work/tampered.json" "$work/tampered.json.sig" local-test URL

# Truncation, twice, because it has two distinct shapes. Cut to a length that is
# not a whole number of base64 characters, and cut to one that is: the first is
# refused by the encoding rules, the second decodes cleanly into a signature
# that is simply too short, and only the RSA verification can say so.
cp "$work/manifest.json" "$work/trunc.json"
cut -c1-511 "$work/manifest.json.sig" > "$work/trunc.json.sig"
refuses "a signature truncated mid-character is refused" "not a whole number of bytes" \
  verify_manifest_signature "$work/trunc.json" "$work/trunc.json.sig" local-test URL

cp "$work/manifest.json" "$work/trunc4.json"
cut -c1-508 "$work/manifest.json.sig" > "$work/trunc4.json.sig"
refuses "a signature truncated to a whole number of bytes is refused" "does not match its bytes" \
  verify_manifest_signature "$work/trunc4.json" "$work/trunc4.json.sig" local-test URL

# Signed by a key that is not the one this installer carries. Well-formed,
# correctly encoded, over exactly these bytes.
cp "$work/manifest.json" "$work/otherkey.json"
sign_with "$work/other-key.pem" "$work/otherkey.json" "$work/otherkey.json.sig"
refuses "a signature from another key is refused" "does not match its bytes" \
  verify_manifest_signature "$work/otherkey.json" "$work/otherkey.json.sig" local-test URL

# A keyId the installer does not carry. The signature here is good and the one
# key present would verify it: only the lookup refuses this, which is what makes
# "try every key in turn" a different program from this one.
refuses "an unknown keyId is refused, even with a signature that would verify" "does not carry" \
  verify_manifest_signature "$work/manifest.json" "$work/manifest.json.sig" some-other-key URL

# The shipped state: no keys at all, so nothing is accepted. These two run
# inside the command substitution `refuses` already opens, so the environment
# they change is a subshell's and nothing leaks into the cases after them.
# Both are invoked by name, through `refuses`, which shellcheck cannot follow.
# shellcheck disable=SC2329
verify_with_no_keys() {
  unset TWINFORGE_DIST_PUBKEY_FILE
  verify_manifest_signature "$@"
}
# shellcheck disable=SC2329
verify_with_weak_key() {
  TWINFORGE_DIST_PUBKEY_FILE="$work/weak-pub.pem"
  export TWINFORGE_DIST_PUBKEY_FILE
  verify_manifest_signature "$@"
}

refuses "with no keys at all, a good signature is still refused" "carries no manifest signing keys" \
  verify_with_no_keys "$work/manifest.json" "$work/manifest.json.sig" local-test URL

# Signature-shaped inputs that are not signatures.
: > "$work/empty.json.sig"
cp "$work/manifest.json" "$work/empty.json"
refuses "an empty signature file is refused" "signature file is empty" \
  verify_manifest_signature "$work/empty.json" "$work/empty.json.sig" local-test URL

cp "$work/manifest.json" "$work/junk.json"
printf 'this is not base64 at all!\n' > "$work/junk.json.sig"
refuses "a signature that is not base64 is refused" "not one line of base64" \
  verify_manifest_signature "$work/junk.json" "$work/junk.json.sig" local-test URL

cp "$work/manifest.json" "$work/twoline.json"
{ cat "$work/manifest.json.sig"; cat "$work/manifest.json.sig"; } > "$work/twoline.json.sig"
refuses "a signature spread over two lines is refused" "not one line of base64" \
  verify_manifest_signature "$work/twoline.json" "$work/twoline.json.sig" local-test URL

cp "$work/manifest.json" "$work/midpad.json"
printf 'AA==AA==\n' > "$work/midpad.json.sig"
refuses "base64 padding in the middle is refused" "padding in the middle" \
  verify_manifest_signature "$work/midpad.json" "$work/midpad.json.sig" local-test URL

# A signature file that travelled through something CRLF-flavoured still
# verifies: the trailing CR is transport, exactly as the trailing newline is.
cp "$work/manifest.json" "$work/crlf.json"
awk '{ printf("%s\r\n", $0) }' "$work/manifest.json.sig" > "$work/crlf.json.sig"
accepts "a CRLF-terminated signature file still verifies" \
  verify_manifest_signature "$work/crlf.json" "$work/crlf.json.sig" local-test URL

# A key below the 3072-bit floor is a packaging fault, and it is refused on
# sight rather than being allowed to verify things.
cp "$work/manifest.json" "$work/weak.json"
sign_with "$work/weak-key.pem" "$work/weak.json" "$work/weak.json.sig"
refuses "a key below 3072 bits is refused even when its signature is good" "below the 3072-bit minimum" \
  verify_with_weak_key "$work/weak.json" "$work/weak.json.sig" local-test URL

# --- The signed envelope ------------------------------------------------------

accepts "a well-formed signed manifest passes the envelope checks" \
  assert_signed_manifest "$(fields_of "$work/manifest.json")" canary URL

# The one that makes a canary signature not a stable signature.
refuses "a manifest fetched as another channel is refused" "was fetched as channel" \
  assert_signed_manifest "$(fields_of "$work/manifest.json")" stable URL

write_manifest "$work/nochannel.json" 2 canary local-test 1.0.0 "$DEAD_URL"
sed '/"channel"/d' "$work/nochannel.json" > "$work/nochannel2.json"
refuses "a manifest with no channel is refused" "has no \"channel\"" \
  assert_signed_manifest "$(fields_of "$work/nochannel2.json")" canary URL

write_manifest "$work/schema1.json" 1 canary local-test 1.0.0 "$DEAD_URL"
refuses "schemaVersion 1 -- the unsigned format -- is refused" "only accepts 2" \
  assert_signed_manifest "$(fields_of "$work/schema1.json")" canary URL

# A *string* "2" is not the number 2. The scanner emits schemaVersion only from
# the scalar path, so this reads as a missing field, and the refusal has to
# happen rather than the string comparing equal to "2".
write_manifest "$work/schemastring.json" '"2"' canary local-test 1.0.0 "$DEAD_URL"
refuses "schemaVersion as a JSON string is refused" "only accepts 2" \
  assert_signed_manifest "$(fields_of "$work/schemastring.json")" canary URL

sed '/"keyId"/d' "$work/manifest.json" > "$work/nokey.json"
refuses "a manifest with no keyId is refused" "no way to tell which key signed it" \
  assert_signed_manifest "$(fields_of "$work/nokey.json")" canary URL

write_manifest "$work/oddkey.json" 2 canary 'local\ttest' 1.0.0 "$DEAD_URL"
refuses "a keyId outside the allowed character class is refused" "unusable \"keyId\"" \
  assert_signed_manifest "$(fields_of "$work/oddkey.json")" canary URL

# --- End to end, through main() ------------------------------------------------
# The checks above prove the verifier refuses what it should. These prove
# install.sh actually calls it, and calls it before it does anything with what
# the manifest says -- a verifier nothing invokes is worth exactly nothing.

e2e_home="$work/home"
mkdir -p "$e2e_home" "$work/dist/channels"

run_installer() {
  # Runs main() against a manifest served from disk. curl reads file:// URLs;
  # only the *artifact* URL is held to https, and these fixtures point it at a
  # closed port, so a run that gets past verification dies at the download and
  # says so.
  ( TWINFORGE_HOME="$e2e_home/install" \
    TWINFORGE_CHANNEL=canary \
    TWINFORGE_DIST_BASE_URL="file://$work/dist" \
    main ) 2>&1
}

cp "$work/manifest.json" "$work/dist/channels/canary.json"
cp "$work/manifest.json.sig" "$work/dist/channels/canary.json.sig"
if out="$(run_installer)"; then
  bad "end to end: a run that reaches the artifact download should fail there"
elif printf '%s' "$out" | grep -qF "Download failed"; then
  pass "end to end: a signed manifest is verified and the install proceeds"
else
  bad "end to end: a signed manifest should have been accepted
       actual: $out"
fi

# The same run with one byte changed, and with the signature that used to match
# it. Nothing may be downloaded.
cp "$work/tampered.json" "$work/dist/channels/canary.json"
out="$(run_installer)" && bad "end to end: a tampered manifest must not install"
if printf '%s' "$out" | grep -qF "does not match its bytes"; then
  pass "end to end: a tampered manifest is refused"
else
  bad "end to end: a tampered manifest was refused for the wrong reason
       actual: $out"
fi
if printf '%s' "$out" | grep -qF "Downloading TwinForge"; then
  bad "end to end: a tampered manifest reached the artifact download"
else
  pass "end to end: a tampered manifest never reaches the artifact download"
fi

# A missing .sig is a refusal in its own words, not a 404 blamed on the network.
cp "$work/manifest.json" "$work/dist/channels/canary.json"
rm -f "$work/dist/channels/canary.json.sig"
out="$(run_installer)" && bad "end to end: an unsigned manifest must not install"
if printf '%s' "$out" | grep -qF "no unsigned mode"; then
  pass "end to end: a manifest with no signature beside it is refused"
else
  bad "end to end: a manifest with no signature was refused for the wrong reason
       actual: $out"
fi
cp "$work/manifest.json.sig" "$work/dist/channels/canary.json.sig"

# openssl is a hard dependency, and the refusal happens before anything is
# fetched. Proven by running main() with a PATH holding every command it needs
# up to that point -- and only those.
#
# In a *fresh* shell, via an absolute /bin/sh, rather than a subshell of this
# one: a shell remembers where it found a command, and the command hash of this
# process (which has been running openssl since its first line) is inherited by
# every subshell, so `command -v openssl` there answers from memory and the
# restricted PATH proves nothing. Reproduced: the case passed against an
# install.sh with no openssl check at all until it was moved out here.
fake_bin="$work/fakebin"
mkdir -p "$fake_bin"
for cmd in curl tar mktemp uname id sha256sum shasum; do
  resolved="$(command -v "$cmd" 2>/dev/null || true)"
  [ -n "$resolved" ] && ln -sf "$resolved" "$fake_bin/$cmd"
done
out="$( PATH="$fake_bin" TWINFORGE_HOME="$e2e_home/install" \
        TWINFORGE_DIST_BASE_URL="file://$work/dist" TWINFORGE_INSTALL_LIB=1 \
        /bin/sh -c '. "$1"; main' sh "$(cd "$root" && pwd)/install.sh" 2>&1 )" \
  && bad "end to end: without openssl the install must not proceed"
if printf '%s' "$out" | grep -qF "Missing required command: openssl"; then
  pass "end to end: without openssl the install refuses, naming openssl"
else
  bad "end to end: without openssl the refusal did not name openssl
       actual: $out"
fi

if [ "$failures" -eq 0 ]; then
  printf '\nall manifest signature checks passed\n'
else
  printf '\n%s manifest signature check(s) failed\n' "$failures"
fi
exit "$failures"
