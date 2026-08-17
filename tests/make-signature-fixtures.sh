#!/bin/sh
# Build the manifest-signature fixture bundle that tests/signature-test.ps1
# verifies.
#
# Why a shell script makes the fixtures for a PowerShell test: the point of the
# Windows job is that install.ps1's verifier accepts what the *publisher*
# produces, and the publisher signs with openssl. A PowerShell test that both
# signs and verifies with .NET would agree with itself no matter what either
# side did with encodings. So the signatures below are made by openssl, on
# Linux, and carried to Windows as files -- which is also the one place where
# "install.sh and install.ps1 accept the same manifest" is actually asserted
# rather than asserted about.
#
#   sh tests/make-signature-fixtures.sh <output-directory>
#
# No key material is committed: every key here is generated on the spot and
# lives only for the length of the CI job.
set -eu

out="${1:-}"
[ -n "$out" ] || {
  printf 'usage: %s <output-directory>\n' "$0" >&2
  exit 2
}
mkdir -p "$out"

command -v openssl >/dev/null 2>&1 || {
  printf 'openssl is required to build the signature fixtures.\n' >&2
  exit 1
}

keys="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-fixture-keys.XXXXXX")"
trap 'rm -rf "$keys"' EXIT

openssl genrsa -out "$keys/good.pem" 3072 2>/dev/null
openssl genrsa -out "$keys/other.pem" 3072 2>/dev/null
openssl genrsa -out "$keys/weak.pem" 1024 2>/dev/null

# The base64 modulus is the representation install.ps1 carries, because Windows
# PowerShell 5.1 has no PEM parser. openssl prints it as hex; od turns the
# decoded bytes back into hex for the comparison in tests/key-parity-test.sh,
# and here we go the other way with openssl's own base64.
modulus_b64() {
  # $1 private key -> one line of base64
  #
  # Octal escapes and `printf %b`, not \xNN: POSIX defines %b for \0ddd and
  # says nothing about hex, and /bin/sh here is dash.
  escaped="$(openssl rsa -in "$1" -noout -modulus 2>/dev/null \
    | sed 's/^Modulus=//' \
    | awk '
        function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
        {
          n = length($0)
          for (i = 1; i <= n; i += 2) {
            printf("\\0%03o", hexval(substr($0, i, 1)) * 16 + hexval(substr($0, i + 1, 1)))
          }
        }')"
  printf '%b' "$escaped" | openssl base64 -A
}

modulus_b64 "$keys/good.pem" > "$out/key-modulus.b64"
modulus_b64 "$keys/other.pem" > "$out/other-modulus.b64"
modulus_b64 "$keys/weak.pem" > "$out/weak-modulus.b64"

write_manifest() {
  # $1 target, $2 schemaVersion (verbatim JSON), $3 channel, $4 keyId
  cat > "$out/$1" <<EOF
{
  "schemaVersion": $2,
  "channel": "$3",
  "keyId": "$4",
  "sequence": 1,
  "version": "1.0.0",
  "artifacts": {
    "win-x64": {
      "url": "https://127.0.0.1:1/twinforge.tar.gz",
      "sha256": "1111111111111111111111111111111111111111111111111111111111111111"
    }
  }
}
EOF
}

sign() {
  # $1 manifest name, $2 private key, $3 signature name
  openssl dgst -sha256 -sign "$2" -out "$keys/sig.bin" "$out/$1"
  openssl base64 -A -in "$keys/sig.bin" -out "$out/$3"
  printf '\n' >> "$out/$3"
  rm -f "$keys/sig.bin"
}

# The good one, and the scenarios that differ from it only in the envelope.
write_manifest good.json 2 canary local-test
sign good.json "$keys/good.pem" good.sig

write_manifest unknown-keyid.json 2 canary some-other-key
sign unknown-keyid.json "$keys/good.pem" unknown-keyid.sig

write_manifest wrong-channel.json 2 stable local-test
sign wrong-channel.json "$keys/good.pem" wrong-channel.sig

write_manifest schema-1.json 1 canary local-test
sign schema-1.json "$keys/good.pem" schema-1.sig

write_manifest schema-string.json '"2"' canary local-test
sign schema-string.json "$keys/good.pem" schema-string.sig

sed '/"channel"/d' "$out/good.json" > "$out/no-channel.json"
sign no-channel.json "$keys/good.pem" no-channel.sig

sed '/"keyId"/d' "$out/good.json" > "$out/no-keyid.json"
sign no-keyid.json "$keys/good.pem" no-keyid.sig

# A keyId outside the character class both installers hold it to.
write_manifest bad-keyid.json 2 canary 'local test'
sign bad-keyid.json "$keys/good.pem" bad-keyid.sig

# One byte: "1.0.0" becomes "1.0.1". The signature stays the good one, which is
# the whole attack -- a manifest edited after it was signed.
sed 's/1\.0\.0/1.0.1/' "$out/good.json" > "$out/tampered.json"
cp "$out/good.sig" "$out/tampered.sig"

# Signed by a real key that is simply not the one the installer carries.
cp "$out/good.json" "$out/other-key.json"
sign other-key.json "$keys/other.pem" other-key.sig

# Below the 3072-bit floor, and correctly signed with that key, so only the
# strength check can refuse it.
cp "$out/good.json" "$out/weak-key.json"
sign weak-key.json "$keys/weak.pem" weak-key.sig

# Truncation has two shapes: a cut that leaves a partial base64 character, and
# one that leaves a whole number of bytes and can only be caught by the RSA
# verification itself.
cut -c1-511 "$out/good.sig" > "$out/truncated-odd.sig"
cut -c1-508 "$out/good.sig" > "$out/truncated-even.sig"

# The line terminator is transport, not signature.
awk '{ printf("%s\r\n", $0) }' "$out/good.sig" > "$out/crlf.sig"

# Signature-shaped things that are not signatures.
: > "$out/empty.sig"
printf 'this is not base64 at all!\n' > "$out/not-base64.sig"
{ cat "$out/good.sig"; cat "$out/good.sig"; } > "$out/two-lines.sig"
printf 'AA==AA==\n' > "$out/middle-padding.sig"

printf 'signature fixtures written to %s\n' "$out"
