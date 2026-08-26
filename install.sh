#!/bin/sh
# TwinForge installer (macOS, Linux).
#
#   curl -fsSL https://raw.githubusercontent.com/air-bizapps/twinforge-dist/main/install.sh | sh
#
# Installs into ~/.twinforge/app and prints the next step (enrollment) when
# done. Safe to re-run: if the channel's version is already installed, it
# just repoints `current` and exits.
#
# Env overrides:
#   TWINFORGE_CHANNEL       channel to install (default: canary). `stable`
#                           stays closed until enrollment exists.
#   TWINFORGE_DIST_BASE_URL base URL serving channels/<channel>.json
#                           (default: this repo's raw main branch). Used for
#                           testing against a local manifest.
#   TWINFORGE_HOME          overrides the install root (default: ~/.twinforge),
#                           matching what the installed server itself honors.
#   TWINFORGE_DIST_PUBKEY_FILE
#                           a PEM public key to accept manifest signatures
#                           from, INSTEAD OF the keys built into this script,
#                           under the key id "local-test". For testing a
#                           locally signed manifest. It overrides *which key*
#                           is trusted and nothing else: there is no override
#                           that skips the verification.
#
# Everything below is a function definition, and the only statement that does
# anything is the `main "$@"` at the end. That is not a style choice:
# the documented entry point is `curl ... | sh`, and a shell reading a script
# from a pipe executes each complete statement as it arrives. If the response
# is cut short mid-file -- a dropped connection, a proxy timing out, a CDN
# error page -- a script written as a flat sequence has already run everything
# up to the cut, and then exits 0 because it reached EOF cleanly. That is how a
# truncated download can delete an installed version and report success. With
# the body inside `main`, a truncated stream ends before `main` is ever called,
# so it cannot run any of it -- and the brace group below closes the remaining
# gap. `set -eu` is inside `main` for the same reason: a
# file cut in the middle of a top-level `set -eu` leaves a bare `set` as its
# last complete statement, which dumps the whole environment to stdout.

# The whole body is one brace group, closed on the last line. Wrapping the file
# in `main` is not by itself enough for something served over a pipe: the shell
# still executes each complete *top-level* statement as it arrives, and a
# truncation that ends mid-word leaves a bare word, which is a complete command.
# Found by sweeping every byte offset of this file: cut at byte 2351, the last
# thing on the line was the `sa` of `say() {`, and macOS has an /usr/sbin/sa, so
# the shell ran it. Inside a brace group there is no complete top-level
# statement until the closing brace arrives, so every short read is a syntax
# error and nothing at all runs.
{

# printf, never echo. Under dash -- /bin/sh on Debian and Ubuntu, so most of the
# audience -- and under macOS /bin/sh, `echo` expands backslash escapes in its
# argument. The messages below interpolate $ARTIFACT_URL and $ARTIFACT_SHA256
# straight from the manifest, so a `url` containing \c truncates the rest of the
# message under dash, deleting exactly the line "The download may be corrupted
# or tampered with", and \n injects lines that read like success. Confirmed on
# both shells. Every message this script emits goes through these two.
say() {
  printf '%s\n' "$@"
}

fail() {
  printf '%s\n' "$@" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1. Install it and re-run this script."
}

# Defines sha256_of() against whichever of the two tools this machine has.
#
# The file arrives on stdin rather than as an argument. Given a path containing
# a backslash or a newline -- $TMPDIR is whatever the environment says it is --
# both tools escape the filename and prefix the whole line with a backslash, so
# `awk {print $1}` returns \<hash>, which then fails the comparison with the
# tampering warning. Reading stdin means there is no filename in the output to
# escape.
select_sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum < "$1" | awk '{print $1}'; }
  elif command -v shasum >/dev/null 2>&1; then
    sha256_of() { shasum -a 256 < "$1" | awk '{print $1}'; }
  else
    fail "Need sha256sum or shasum to verify the download. Install one and re-run."
  fi
}

# --- Manifest signature -------------------------------------------------------
# The channel manifest is the root of trust: it names the URL and the sha256
# that this script will download and execute. The artifacts are pinned by the
# manifest; until this section existed, nothing pinned the manifest, so whoever
# could write channels/<channel>.json could run code on every machine that
# installed from here. The design is
# docs/superpowers/specs/2026-08-17-assinatura-do-manifest-design.md in the
# product repository.
#
# RSA PKCS#1 v1.5 over SHA-256, detached, over the exact bytes of the .json --
# and the reason is not cryptographic. Three verifiers have to exist without a
# new dependency: this script, install.ps1 on Windows PowerShell 5.1, and the
# Node inside an installed client. Ed25519 does not exist in .NET Framework at
# all and ECDSA P-256 needs .NET 4.7+, so RSA is the floor of that
# intersection.
#
# What is NOT here, on purpose: a replay guard. The updater refuses a manifest
# whose `sequence` is lower than one it has already accepted
# (packaging/updater/check-for-update.mjs, `assertNotReplayed`), because it runs
# every six hours on a machine that has a record of what it saw last. A fresh
# install has no such record -- there is no previous sequence to compare with,
# and inventing a floor here would only refuse the first install. This is an
# absence by decision, not an omission.

# The keys whose signatures this installer accepts, as records of
#
#   keyId: <id>
#   -----BEGIN PUBLIC KEY-----
#   ...
#   -----END PUBLIC KEY-----
#
# one after another. A LIST, always, even when it holds one key: rotation is a
# three-release dance (release N adds key B to the accepted list and is signed
# with A, N+1 is signed with both, N+2 drops A), and that only works if the
# accepted set was plural from the first release ever published. A single key
# baked in as a scalar cannot be retrofitted onto clients that already shipped.
# install.ps1 carries the same list in the other representation it can read, and
# tests/key-parity-test.sh is what asserts the two agree. The monorepo carries a
# third copy -- inside the release tarball, which is what the updater verifies
# with -- and its packaging/install-script.test.mjs is what asserts all three.
#
# The entry below is the public half of the pair from the signing ceremony in
# section 3 of the design; the private half is a secret of the `sign` job, in an
# Environment with a required reviewer, and never leaves it. This is public key
# material, which is why it can live in a public repository -- no private key
# material may.
#
# An empty list refuses every manifest, and so does a manifest signed by a key
# that is not listed here. That is the design: failing closed is the point, and
# an "accept anything while we get set up" phase is exactly the hole that someone
# who can write this repository would use.
manifest_key_material() {
  # The local-testing override replaces the list rather than adding to it, so
  # what a test exercises is one known key and not a mixture. It overrides which
  # key is trusted; it cannot switch the verification off.
  #
  # This function is read through `$(...)` in two of its three callers, so a
  # `fail` here exits only that subshell and the caller carries on with an empty
  # key list -- which refuses, but says "this installer carries no keys" when the
  # truth is "your override points at nothing". main() therefore checks the
  # override itself, before any of this runs, so the accurate message is the only
  # one an ordinary run can produce.
  if [ -n "${TWINFORGE_DIST_PUBKEY_FILE:-}" ]; then
    [ -f "$TWINFORGE_DIST_PUBKEY_FILE" ] \
      || fail "TWINFORGE_DIST_PUBKEY_FILE is set to \"$TWINFORGE_DIST_PUBKEY_FILE\", which is not a file."
    say "keyId: local-test"
    cat -- "$TWINFORGE_DIST_PUBKEY_FILE"
    return 0
  fi
  cat <<'KEYS'
keyId: 2026-08-canary
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA4cL70zPjyEgukxZuYUCs
iTFj0hkNKQENK62WGiPFzwVFLShbpp1VpGQs7I7GszdEIzFwtnUBGHuM8UBT0aEI
3eV3mgWgCnvxotJsV9nS46nJ/qbHCxsVniv7ZmsCrfbpSFB1oDXkB3nWHpE77Rbx
aeunyBWwS0FZx6n35UF+6ChSzOKlFdIeeVg8PPZ0u90p6mRsKKz2O8IDA4Fqzoye
L/UdmmEQ1E98gMozg/JMXB7D+hF5lWF+2mqnhJmuysOaO75HUbDNhAS57MUQX3B/
F0Cr2rtwKH04hSXT43XF7EiBclpT5GwLBqaVGvqi0yWwBfv1qkzhcTVABlmYofZd
c6OmZbr5FloJHuO8JMpXscTAkF3II1BTS17spWGutfjuzOeCkIjQsxEiSNt/RaCJ
NI9YDgTKjySeYUclV5qJJwEex7bWXxiqUTugHpdp1uK93gK26venr94Y5EIMvApI
D2UrQAjhtNVgbiDQcxgEOpEXXUTR2hGARjI80KvBcxWrAgMBAAE=
-----END PUBLIC KEY-----
KEYS
}

manifest_key_ids() {
  manifest_key_material | sed -n 's/^keyId: //p'
}

manifest_key_pem() {
  # $1 keyId -> that key's PEM on stdout, or nothing at all if this installer
  # does not carry it. Nothing, never a different key: an unknown key id is an
  # unknown key, and trying the others in turn would make the field decorative
  # and turn a rotation mistake into silence.
  manifest_key_material | awk -v want="$1" '
    /^keyId: / { copying = (substr($0, 8) == want); next }
    copying { print }
  '
}

# Everything the signed format requires, checked before the manifest is read for
# meaning, and each field named individually when it is wrong. "Malformed
# manifest" is the message that makes someone go looking for a way to skip the
# check.
#
# This runs *before* verify_manifest_signature, matching the order in
# packaging/updater/check-for-update.mjs (`assertSignedManifest`, then
# `verifyManifestSignature`), and the order is safe for a reason worth stating:
# these fields were parsed out of the very bytes that are about to be verified,
# so a predicate on them becomes authenticated the moment the signature checks
# out. Running it first only changes which message a broken manifest gets.
assert_signed_manifest() {
  # $1 the scan output, $2 the channel that was asked for, $3 the manifest URL.
  asm_schema="$(manifest_field "$1" schemaVersion)" \
    || fail "Manifest at $3 declares \"schemaVersion\" more than once. Refusing to guess which one is meant."
  if [ "$asm_schema" != "2" ]; then
    fail "Manifest at $3 declares schemaVersion \"$asm_schema\"; this installer only accepts 2, the signed format." \
      "There is deliberately no compatible mode for unsigned manifests. Refusing to continue."
  fi

  asm_key_id="$(manifest_field "$1" keyId)" \
    || fail "Manifest at $3 declares \"keyId\" more than once. Refusing to guess which one is meant."
  [ -n "$asm_key_id" ] \
    || fail "Manifest at $3 has no \"keyId\", so there is no way to tell which key signed it. Refusing to continue."
  # Held to the same character class as the version, which the format on the
  # product side does not do (it accepts any non-empty string). The reason is
  # local: this id reaches `awk -v`, which expands escape sequences in the value
  # it is given, so a keyId containing a backslash would be looked up as
  # something other than what the manifest said. Refusing it costs nothing --
  # an id outside this class could never match a key this installer carries, so
  # the alternative outcome is the same refusal with a worse message.
  case "$asm_key_id" in
    *[!A-Za-z0-9._-]*)
      fail "Manifest at $3 declares an unusable \"keyId\". Expected only letters, digits, dot, underscore and hyphen. Refusing to continue."
      ;;
  esac

  asm_channel="$(manifest_field "$1" channel)" \
    || fail "Manifest at $3 declares \"channel\" more than once. Refusing to guess which one is meant."
  [ -n "$asm_channel" ] \
    || fail "Manifest at $3 has no \"channel\". Without it, a signature over one channel is a signature over every channel. Refusing to continue."
  if [ "$asm_channel" != "$2" ]; then
    fail "Manifest at $3 says it is channel \"$asm_channel\", but it was fetched as channel \"$2\"." \
      "A signature over one channel is not a signature over another. Refusing to continue."
  fi
}

# Verify the detached signature over the *exact bytes* of the manifest file.
#
# The bytes are the point. The signature covers what the server sent, so
# anything that re-serialises the document first -- pretty-printing it, running
# it through a JSON tool, even adding a trailing newline -- verifies nothing.
# This is why the file downloaded to disk is what both the scanner and openssl
# are pointed at, and why nothing in between rewrites it.
verify_manifest_signature() {
  # $1 manifest file, $2 detached signature file (one line of base64),
  # $3 the keyId the manifest names, $4 the manifest URL, for messages.
  #
  # The two working files are named after $2, which is always inside this run's
  # own scratch directory (and, in tests/, inside the test's).
  vms_pem="$2.pem"
  vms_der="$2.der"

  if [ -z "$(manifest_key_ids)" ]; then
    fail "Refusing the channel manifest at $4: this installer carries no manifest signing keys, so no manifest can be accepted." \
      "The key list in this script is empty on purpose. The production key is added by the signing ceremony described in section 3 of the design, and until that has happened, refusing is the intended behaviour and not a fault to work around." \
      "If you are testing a locally signed manifest, point TWINFORGE_DIST_PUBKEY_FILE at its public key."
  fi

  manifest_key_pem "$3" > "$vms_pem"
  if [ ! -s "$vms_pem" ]; then
    fail "Refusing the channel manifest at $4: it says it was signed with key \"$3\", which this installer does not carry." \
      "Keys this installer accepts: $(manifest_key_ids | tr '\n' ' ' | sed 's/ *$//')." \
      "Refusing rather than trying the others -- an unknown key id is an unknown key."
  fi

  # The strength of the key is checked, not assumed, because the failure it
  # prevents is silent: a 1024-bit key added to the list above by a later hand
  # would verify signatures exactly as happily as a strong one, and nothing else
  # in this system would ever mention it. `openssl rsa -pubin` also fails
  # outright on a key that is not RSA, so this is both checks in one command.
  # The modulus comes back as hex, so 3072 bits is 768 characters.
  vms_modulus="$(openssl rsa -pubin -in "$vms_pem" -noout -modulus 2>/dev/null | sed -n 's/^Modulus=//p')"
  case "$vms_modulus" in
    "" | *[!0-9A-Fa-f]*)
      fail "The signing key \"$3\" built into this installer is not an RSA public key openssl can read. This is a packaging fault, not a bad manifest."
      ;;
  esac
  if [ "${#vms_modulus}" -lt 768 ]; then
    fail "The signing key \"$3\" built into this installer is $((${#vms_modulus} * 4)) bits, below the 3072-bit minimum this project signs with. This is a packaging fault, not a bad manifest."
  fi

  # The .sig is a text file holding one line of base64, so the trailing newline
  # is transport and not signature: command substitution drops it, and a single
  # trailing CR is dropped too, so a file that travelled through something
  # CRLF-flavoured still verifies. Everything else has to be canonical base64.
  #
  # Validated here in the shell *before* openssl sees it, because openssl's
  # decoder is lenient: it skips characters it does not recognise, so "not
  # base64 at all" and a truncated line both decode to some shorter buffer,
  # reach the verify, and come back as "does not match" -- the right answer for
  # the wrong reason, with a message that sends the reader looking at the
  # manifest instead of at the signature. packaging/manifest-signature.mjs
  # rolls its own strict base64 for exactly this reason.
  vms_cr="$(printf '\r')"
  vms_b64="$(cat "$2")"
  vms_b64="${vms_b64%"$vms_cr"}"
  case "$vms_b64" in
    "")
      fail "Refusing the channel manifest at $4: its detached signature file is empty. A manifest is only accepted with its signature alongside it."
      ;;
    *[!A-Za-z0-9+/=]*)
      fail "Refusing the channel manifest at $4: its detached signature is not one line of base64. Expected the base64 of an RSA signature and nothing else."
      ;;
    *=*[!=]*)
      fail "Refusing the channel manifest at $4: its detached signature has base64 padding in the middle of it, so it is not one signature."
      ;;
  esac
  if [ "$(( ${#vms_b64} % 4 ))" -ne 0 ]; then
    fail "Refusing the channel manifest at $4: its detached signature is ${#vms_b64} base64 characters, which is not a whole number of bytes. A truncated download looks exactly like this."
  fi

  if ! printf '%s\n' "$vms_b64" | openssl base64 -d -A > "$vms_der" 2>/dev/null; then
    fail "Refusing the channel manifest at $4: its detached signature could not be decoded from base64."
  fi
  [ -s "$vms_der" ] \
    || fail "Refusing the channel manifest at $4: its detached signature decodes to no bytes at all."
  # Round trip, which catches what the character class cannot: padding bits that
  # are not zero, and a length the decoder was willing to round off. Same check,
  # same reason, as the decodeSignature round trip in
  # packaging/manifest-signature.mjs.
  if [ "$(openssl base64 -A -in "$vms_der")" != "$vms_b64" ]; then
    fail "Refusing the channel manifest at $4: its detached signature is not canonical base64, so it is not the signature that was published."
  fi

  if ! openssl dgst -sha256 -verify "$vms_pem" -signature "$vms_der" "$1" >/dev/null 2>&1; then
    fail "Refusing the channel manifest at $4: its detached signature does not match its bytes under key \"$3\"." \
      "The manifest was modified after it was signed, or it was signed by a key this installer does not trust."
  fi
}

# --- Manifest parsing ---------------------------------------------------------
# Still no jq -- it is not guaranteed present, and requiring it would turn a
# missing package into a failed install. What is required is awk, which POSIX
# mandates and which this script already used for the checksum.
#
# The previous version selected the platform block with a `sed` line range and
# then took the first `url`/`sha256` in it. That is only correct if the manifest
# is pretty-printed one key per line. Reproduced on a `jq -c` manifest: the
# range matched the whole document, so a Mac got the *first* url and the *first*
# sha256 in the file -- the linux-x64 pair. Both fields came from the same wrong
# block, so they agreed, the checksum verified, extraction succeeded, and the
# installer reported success while installing another platform's tarball. No
# attacker needed: anyone regenerating the manifest without an indent argument.
#
# So the manifest is scanned as JSON -- whitespace-independent, depth-aware,
# and loud on anything malformed rather than helpfully returning a neighbour's
# value. `version` is read at the top level only (the old grep took the first
# match anywhere, so a `version` nested inside an earlier artifact object won,
# despite the comment claiming top-level), and url/sha256 only from
# artifacts.<platform>. Keys are joined with SUBSEP, a byte a valid JSON key
# cannot contain, so no key can spell out another key's path.
#
# Values come back with their JSON escapes intact rather than unescaped: every
# field this script reads is then checked against a character class that no
# escape sequence can pass, so unescaping would only add a way to smuggle a
# newline or a quote into a value.
manifest_scan() {
  # $1 manifest file, $2 platform tag
  # -> "<field>\t<value>" lines for schemaVersion, channel, keyId, version, url
  # and sha256, in file order.
  # Exits 2 after an "error\t<what>" line if the document is not well-formed.
  awk -v platform="$2" '
    function fatal(msg) {
      printf("error\t%s\n", msg)
      exit 2
    }
    function ws(   c) {
      while (i <= n) {
        c = substr(doc, i, 1)
        if (c == " " || c == "\t" || c == "\n" || c == "\r") i++
        else break
      }
    }
    function at() {
      if (i > n) fatal("it ends in the middle of a value")
      return substr(doc, i, 1)
    }
    function parse_string(   out, c) {
      if (at() != "\"") fatal("expected a string at byte " i)
      i++
      out = ""
      while (i <= n) {
        c = substr(doc, i, 1)
        if (c == "\\") { out = out c substr(doc, i + 1, 1); i += 2; continue }
        if (c == "\"") { i++; return out }
        if (c < " ") fatal("a string contains an unescaped control character at byte " i)
        out = out c
        i++
      }
      fatal("a string is never closed")
    }
    function parse_scalar(path,   start) {
      start = i
      while (i <= n) {
        c = substr(doc, i, 1)
        if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r") break
        i++
      }
      if (i == start) fatal("unexpected character at byte " i)
      # Numbers, true, false and null land here, and exactly one of them is
      # read: schemaVersion, which the format defines as the number 2. It is
      # emitted from here and never from emit() below, so a *string* "2" reads
      # as a missing schemaVersion and is refused -- the same rule as every
      # other field, which has to be a JSON string, applied in the one place
      # where the type is the other way round.
      if (path == "schemaVersion") printf("schemaVersion\t%s\n", substr(doc, start, i - start))
    }
    function parse_array(path,   c) {
      i++
      ws()
      if (at() == "]") { i++; return }
      for (;;) {
        parse_value(path SUBSEP "[]")
        ws()
        c = at()
        if (c == ",") { i++; continue }
        if (c == "]") { i++; return }
        fatal("expected , or ] in an array at byte " i)
      }
    }
    function parse_object(path,   key, child, c) {
      i++
      ws()
      if (at() == "}") { i++; return }
      for (;;) {
        ws()
        key = parse_string()
        child = (path == "") ? key : path SUBSEP key
        ws()
        if (at() != ":") fatal("expected : after the key " key)
        i++
        parse_value(child)
        ws()
        c = at()
        if (c == ",") { i++; continue }
        if (c == "}") { i++; return }
        fatal("expected , or } in an object at byte " i)
      }
    }
    function parse_value(path,   c) {
      ws()
      c = at()
      if (c == "{") { parse_object(path); return }
      if (c == "[") { parse_array(path); return }
      if (c == "\"") { emit(path, parse_string()); return }
      parse_scalar(path)
    }
    function emit(path, value) {
      if (path == "version") printf("version\t%s\n", value)
      # Top level only, like version: the paths are joined with SUBSEP, so a
      # "channel" or "keyId" nested inside an artifact object has a path that is
      # not this one and is not read.
      else if (path == "channel") printf("channel\t%s\n", value)
      else if (path == "keyId") printf("keyId\t%s\n", value)
      else if (path == want_url) printf("url\t%s\n", value)
      else if (path == want_sha) printf("sha256\t%s\n", value)
    }
    BEGIN {
      want_url = "artifacts" SUBSEP platform SUBSEP "url"
      want_sha = "artifacts" SUBSEP platform SUBSEP "sha256"
    }
    { doc = doc $0 "\n" }
    END {
      n = length(doc)
      i = 1
      ws()
      if (i > n) fatal("it is empty")
      if (at() != "{") fatal("it is not a JSON object")
      parse_object("")
      ws()
      if (i <= n) fatal("there is content after the end of the top-level object")
    }
  ' "$1"
}

manifest_field() {
  # $1 scan output, $2 field name -> the one value, or exit 1 if declared twice.
  # Declared twice is a hard error, not a last-one-wins: two answers to the
  # same question is exactly the shape of a manifest someone has edited.
  awk -F '\t' -v k="$2" '
    $1 == k { count++; value = $2 }
    END {
      if (count > 1) exit 1
      if (count == 1) print value
    }
  ' "$1"
}

# The artifact URL is remote input, and it reaches `curl` in option position.
# Two separate problems, both closed here:
#
#   1. A value starting with `-` is read by curl as an *option*. A manifest
#      whose url is `-Kcfg.txt` makes curl read a config file from the
#      developer's working directory instead of downloading anything --
#      honouring its `output =` and `url =` directives -- and exit 0, so the
#      caller's error check sees a successful download. The checksum is no
#      defence: this changes what curl *does*, not what it downloads. `--`
#      before the URL in the calls below closes the option-position half.
#   2. curl accepts every scheme libcurl was built with. `file:///dev/zero`
#      wrote 6.8 GB in five seconds here before it was killed.
#
# So the URL is required to be https:// -- the same rule, and the same message,
# that the updater applies in the monorepo (packaging/updater/check-for-update.mjs,
# `assertHttpsUrl`), so a manifest that one accepts the other accepts too.
assert_https_url() {
  # $1 url, $2 the manifest URL it came from, $3 the version it is for
  case "$1" in
    # Rejected before the scheme check so the message can be specific: a URL
    # with whitespace or control characters in it is not a URL, and it is also
    # how a manifest would try to forge extra lines into the messages below.
    *[!!-~]*)
      fail "Manifest at $2 points $3 at a URL containing whitespace or control characters. Refusing to continue."
      ;;
  esac
  case "$1" in
    [Hh][Tt][Tt][Pp][Ss]://?*) ;;
    *)
      fail "Manifest at $2 points $3 at \"$1\". Releases are downloaded over https:// only. Refusing to continue."
      ;;
  esac
}

point_current() {
  # `ln` relies on $APP_DIR/current being a symlink or absent. If it is a real
  # directory -- an earlier extraction that landed in the wrong place, a manual
  # copy -- GNU ln fails with "cannot overwrite directory", which on the
  # already-installed path arrived immediately after the line saying the install
  # was fine. install.ps1:56-67 wraps the same step in a try/catch with a real
  # message; this is that message.
  if [ -e "$APP_DIR/current" ] && [ ! -L "$APP_DIR/current" ]; then
    fail "$APP_DIR/current is a real file or directory, not a symlink, so it cannot be pointed at $1." \
      "Move it aside and re-run this script."
  fi
  ln -sfn "$1" "$APP_DIR/current" \
    || fail "Could not point $APP_DIR/current at $1." \
      "Check that $APP_DIR is writable, then re-run this script."
}

# Which startup file does this shell actually read? Prints it, or prints
# nothing when there is no answer worth defending.
#
# The old three-way case got this wrong three ways, and then printed that the
# PATH had been set up regardless: bash went to ~/.bashrc, which macOS Terminal
# never reads because it opens bash as a *login* shell; an unset or unrecognised
# $SHELL went to ~/.profile, which fish never reads and which $SHELL being empty
# in containers and CI made the common case rather than the rare one; and the
# chosen file was created if absent, so a machine whose ~/.bash_profile does not
# source ~/.bashrc got a brand new, permanently dead ~/.bashrc.
path_profile_file() {
  case "${SHELL:-}" in
    */zsh)
      # zsh reads .zshrc for every interactive shell, login or not, and
      # creating it shadows nothing.
      say "$HOME/.zshrc"
      ;;
    */bash)
      if [ "$os_tag" = darwin ]; then
        # Terminal and iTerm open login shells, which read the first of
        # .bash_profile, .bash_login, .profile that exists and stop there. So
        # append to whichever that is -- and only create .bash_profile when none
        # of them exists, because creating it in front of an existing .profile
        # would stop .profile being read at all.
        if [ -f "$HOME/.bash_profile" ]; then say "$HOME/.bash_profile"
        elif [ -f "$HOME/.bash_login" ]; then say "$HOME/.bash_login"
        elif [ -f "$HOME/.profile" ]; then say "$HOME/.profile"
        else say "$HOME/.bash_profile"
        fi
      else
        # On Linux the interactive shell a developer gets from a terminal is
        # non-login, and reads .bashrc.
        say "$HOME/.bashrc"
      fi
      ;;
    */sh | */dash | */ksh | */ksh93 | */mksh)
      say "$HOME/.profile"
      ;;
    *)
      # fish, nushell, an unset $SHELL, something newer than this script. Any
      # guess here is a promise that is false about half the time, and a wrong
      # promise is worse than none: say so, and hand over the exact line.
      ;;
  esac
}

add_bin_to_path() {
  bin_dir="$APP_DIR/bin"
  # Appended, not prepended, and matching install.ps1:73, which appends. This
  # directory is filled from a downloaded archive: putting it first would let a
  # release containing bin/git, bin/ssh or bin/sudo take over those commands for
  # every interactive shell the developer opens afterwards, forever. Last means
  # it can add the launcher without being able to replace anything.
  path_line="export PATH=\"\$PATH:$bin_dir\""
  profile="$(path_profile_file)"

  if [ -z "$profile" ]; then
    say "" \
      "TwinForge did not change your PATH: SHELL is \"${SHELL:-unset}\", and this" \
      "script does not know which startup file that shell reads. Add this line to" \
      "it yourself:" \
      "" \
      "  $path_line"
    return 0
  fi

  # The exact line, not a substring of it. `grep -qF "$bin_dir"` matched the
  # directory anywhere in the file -- inside a comment, inside an unrelated
  # PATH -- while missing the same line written with $HOME unexpanded, so the
  # second run appended a duplicate. Matching the whole line against the line
  # this script writes is exact for the case that matters: its own second run.
  if [ -f "$profile" ] && grep -qxF "$path_line" "$profile" 2>/dev/null; then
    return 0
  fi
  # This one must never fail the install. It runs after everything is installed
  # and correct, and a read-only profile is ordinary -- dotfiles managed by
  # chezmoi or stow, or a file left root-owned by an earlier sudo run. Under a
  # bare `set -e` that `>>` exited before the next-steps output and re-running
  # failed at the identical spot forever, insisting a complete, working install
  # was broken.
  # 2>/dev/null before the append, not after: redirections are set up left to
  # right, so with the append first the shell prints its own "Permission denied"
  # to the real stderr before the suppression takes effect, and the developer
  # gets a raw diagnostic on top of the explanation below.
  if printf '\n# Added by the TwinForge installer\n%s\n' "$path_line" 2>/dev/null >> "$profile"; then
    say "Added $bin_dir to PATH in $profile (open a new shell, or run: $path_line)"
  else
    say "" \
      "TwinForge is installed, but $profile could not be written (it may be" \
      "read-only, or owned by another user). Add this line to it yourself:" \
      "" \
      "  $path_line"
  fi
}

# Say what the next command actually is, and say it truthfully. This text has
# been wrong twice, in opposite directions, and both times because it described
# an intention rather than the code:
#
#   1. It pointed at `twinforge enroll` before that subcommand existed, so the
#      word fell through the launcher's `case` and booted the server -- 192
#      database migrations from a command the reader believed was enrolling.
#   2. It then claimed the install "will not start until this machine is
#      enrolled". Also false: `evaluateBoot` answers
#      `{ allow: true, reason: "not enrolled; running standalone" }` for an
#      unbound machine, on purpose. Enrollment gates a machine that HAS a
#      binding; it has never gated a machine that has none.
#
# The cost of (2) is quieter than (1) and therefore worse: the reader either
# does not try, or tries "just to check" and gets the same surprise migrations
# that (1) caused. So this now states the two facts separately -- it runs, and
# enrolling is what links it to an organization -- and shows `enroll` with the
# argument it actually requires (without `--instance` it exits 2 with usage).
print_next_steps() {
  cat <<EOF

TwinForge $VERSION is installed at $APP_DIR.

Start it with:

  twinforge

It runs as a local instance on this machine. To link it to your organization's
instance instead:

  twinforge enroll --instance https://twinforge.your-org.com

(Open a new shell first if this was your first install, so $APP_DIR/bin is on your PATH.)
EOF
}

cleanup() {
  rm -rf "$WORK_DIR"
}

main() {
  set -eu

  # C, not the user's locale. Every character class below (the version name,
  # the hash, the URL) is collated by the locale otherwise, so what counts as
  # A-Z or as a printable character stops being a fixed set -- and grep, sed and
  # awk stop being deterministic across the machines this runs on.
  LC_ALL=C
  export LC_ALL

  CHANNEL="${TWINFORGE_CHANNEL:-canary}"
  BASE_URL="${TWINFORGE_DIST_BASE_URL:-https://raw.githubusercontent.com/air-bizapps/twinforge-dist/main}"

  need_cmd curl
  need_cmd tar
  need_cmd mktemp
  need_cmd uname
  need_cmd id
  select_sha256_tool
  # A hard dependency, with no "verify only if openssl happens to be here"
  # path behind it. Such a fallback is a downgrade oracle: it is precisely what
  # someone who can write the channel manifest wants to exist, because making
  # openssl look absent is far easier than forging a signature. So the check is
  # unconditional and the message says what to install (design, section 2).
  command -v openssl >/dev/null 2>&1 || fail \
    "Missing required command: openssl." \
    "TwinForge verifies the signature on the channel manifest before it installs anything, and openssl is what performs that check. Install it and re-run this script (Debian and Ubuntu: apt-get install openssl; Fedora: dnf install openssl; Alpine: apk add openssl; macOS ships with it)." \
    "There is deliberately no way to install without the check."

  # See manifest_key_material: checked here so that a mistyped override path
  # reads as a mistyped override path, and not as "this installer carries no
  # keys".
  if [ -n "${TWINFORGE_DIST_PUBKEY_FILE:-}" ] && [ ! -f "$TWINFORGE_DIST_PUBKEY_FILE" ]; then
    fail "TWINFORGE_DIST_PUBKEY_FILE is set to \"$TWINFORGE_DIST_PUBKEY_FILE\", which is not a file." \
      "Point it at the PEM public key that signs your test manifest, or unset it to use the keys built into this script."
  fi

  # `sudo sh -c "$(curl ...)"` is a thing people do to installers, and this one
  # would have gone along with it: $HOME is root's, so it installs into
  # /root/.twinforge, adds the PATH line to root's profile, and reports success
  # -- leaving the developer with nothing on their own account. Being root
  # inside a container image is different and stays allowed; $SUDO_USER is what
  # separates the two.
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    fail "Do not install TwinForge with sudo." \
      "It installs into \$HOME, which under sudo is root's: the files would land in /root/.twinforge and the PATH line in root's profile, and ${SUDO_USER} would end up with nothing." \
      "Re-run this script as ${SUDO_USER}, without sudo."
  fi

  [ -n "${HOME:-}" ] || fail "\$HOME is not set. TwinForge needs it to know where to install."
  TWINFORGE_HOME_DIR="${TWINFORGE_HOME:-$HOME/.twinforge}"
  APP_DIR="$TWINFORGE_HOME_DIR/app"

  # --- Platform detection ----------------------------------------------------

  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os_tag="darwin" ;;
    Linux) os_tag="linux" ;;
    *) os_tag="$os" ;;
  esac
  case "$arch" in
    arm64 | aarch64) arch_tag="arm64" ;;
    x86_64 | amd64) arch_tag="x64" ;;
    *) arch_tag="$arch" ;;
  esac
  PLATFORM_TAG="$os_tag-$arch_tag"

  case "$PLATFORM_TAG" in
    darwin-arm64 | linux-x64) ;;
    *)
      fail "Unsupported platform: $os/$arch" \
        "Supported platforms: darwin-arm64, linux-x64. On Windows, run install.ps1 instead."
      ;;
  esac

  # --- Fetch and read the channel manifest -----------------------------------

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-install.XXXXXX")"
  # INT and TERM re-raise rather than just running cleanup and returning. A
  # handler that returns hands control back to the shell, which carries on with
  # the next command, so a Ctrl-C landing between two commands was absorbed
  # entirely and the install continued, with its temp directory already deleted.
  # Removing the handler and killing ourselves with the same signal is what
  # makes the script die of it, and gives the caller the 128+n status that says
  # so.
  trap cleanup EXIT
  trap 'cleanup; trap - INT EXIT; kill -INT $$' INT
  trap 'cleanup; trap - TERM EXIT; kill -TERM $$' TERM

  MANIFEST_URL="$BASE_URL/channels/$CHANNEL.json"
  MANIFEST_FILE="$WORK_DIR/manifest.json"

  say "Fetching the $CHANNEL channel manifest..."
  # 30 s end to end, matching MANIFEST_TIMEOUT_MS in the monorepo's updater:
  # this is a JSON document of a few hundred bytes, so 30 s is many times what
  # it needs on any link a developer can work on, and it bounds a server that
  # dribbles a byte at a time -- which no inactivity default catches, because
  # such a connection is never idle. 1 MiB is ~500x the real manifest and still
  # small enough that the parser below stays instant.
  #
  # Not https-only, unlike the artifact URL: $BASE_URL is a documented local
  # override (TWINFORGE_DIST_BASE_URL), set by the person running the script,
  # not a value the manifest gets to choose.
  if ! curl -fsSL --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
      -o "$MANIFEST_FILE" -- "$MANIFEST_URL"; then
    fail "Could not download the channel manifest from $MANIFEST_URL
Check your network connection, and that TWINFORGE_CHANNEL=$CHANNEL names a real channel."
  fi

  # The detached signature, fetched with the same timeouts and a bound of its
  # own: a base64 RSA-3072 signature is 512 characters and a newline, and 8 KiB
  # is sixteen times that. A .sig of 4 GB is the same denial of service as a
  # manifest of 4 GB, which is why it gets a ceiling rather than inheriting the
  # manifest's. Same number as MANIFEST_SIGNATURE_MAX_BYTES in the monorepo's
  # updater.
  #
  # A missing .sig is a refusal, not a 404 to explain away: a manifest is only
  # accepted with its signature beside it, and there is no unsigned mode.
  SIG_URL="$MANIFEST_URL.sig"
  SIG_FILE="$WORK_DIR/manifest.json.sig"
  if ! curl -fsSL --connect-timeout 10 --max-time 30 --max-filesize 8192 \
      -o "$SIG_FILE" -- "$SIG_URL"; then
    fail "The channel manifest at $MANIFEST_URL has no usable detached signature at $SIG_URL." \
      "A manifest is only accepted with its signature alongside it; there is deliberately no unsigned mode." \
      "Check your network connection, and that TWINFORGE_CHANNEL=$CHANNEL names a real channel."
  fi

  MANIFEST_FIELDS="$WORK_DIR/fields.tsv"
  if ! manifest_scan "$MANIFEST_FILE" "$PLATFORM_TAG" > "$MANIFEST_FIELDS"; then
    fail "Could not read the channel manifest at $MANIFEST_URL: $(sed -n 's/^error	//p' "$MANIFEST_FIELDS" | head -1).
It is not the JSON document this installer expects. Report it -- a manifest this
installer cannot read is a publishing bug, not something to work around."
  fi

  # Nothing below this line is read from the manifest until its signature has
  # been checked. The two calls read the fields of the *already parsed*
  # document, which is the one thing that has to happen first -- a key cannot be
  # selected without knowing which key the manifest names -- and they decide
  # nothing on their own: the keyId is a hint about which key to try, and a
  # wrong one simply fails below.
  say "Verifying the signature on the $CHANNEL channel manifest..."
  assert_signed_manifest "$MANIFEST_FIELDS" "$CHANNEL" "$MANIFEST_URL"
  KEY_ID="$(manifest_field "$MANIFEST_FIELDS" keyId)"
  verify_manifest_signature "$MANIFEST_FILE" "$SIG_FILE" "$KEY_ID" "$MANIFEST_URL"

  VERSION="$(manifest_field "$MANIFEST_FIELDS" version)" \
    || fail "Manifest at $MANIFEST_URL declares \"version\" more than once. Refusing to guess which one is meant."
  [ -n "$VERSION" ] || fail "Manifest at $MANIFEST_URL has no \"version\" field. It may be malformed, or the channel may not exist yet."

  # $VERSION becomes a directory name under $APP_DIR/versions and is
  # interpolated into the `rm -rf` below. It is remote input, so it is checked
  # before it is used as a path -- "." and ".." pass the character class but
  # would aim that delete at the versions directory or the install root itself.
  case "$VERSION" in
    . | ..) fail "Manifest at $MANIFEST_URL declares an unusable version \"$VERSION\". The version is used as a directory name; \".\" and \"..\" are not names. Refusing to continue." ;;
    *[!A-Za-z0-9._-]*) fail "Manifest at $MANIFEST_URL declares an unusable version \"$VERSION\". Expected only letters, digits, dot, underscore and hyphen, because the version is used as a directory name. Refusing to continue." ;;
  esac

  ARTIFACT_URL="$(manifest_field "$MANIFEST_FIELDS" url)" \
    || fail "Manifest at $MANIFEST_URL declares \"url\" more than once for platform $PLATFORM_TAG. Refusing to guess which one is meant."
  ARTIFACT_SHA256="$(manifest_field "$MANIFEST_FIELDS" sha256)" \
    || fail "Manifest at $MANIFEST_URL declares \"sha256\" more than once for platform $PLATFORM_TAG. Refusing to guess which one is meant."
  if [ -z "$ARTIFACT_URL" ] || [ -z "$ARTIFACT_SHA256" ]; then
    fail "Manifest at $MANIFEST_URL has no artifact for platform $PLATFORM_TAG."
  fi
  assert_https_url "$ARTIFACT_URL" "$MANIFEST_URL" "$VERSION"

  # The hash is compared case-insensitively, and its shape is checked before
  # it is used. install.ps1 already lowercases both sides, because Get-FileHash
  # returns uppercase while sha256sum and shasum return lowercase; comparing raw
  # here meant the two installers disagreed about the manifest's contract. A
  # hash computed on a Windows runner would have kept every Windows install
  # working and aborted every macOS and Linux one with "corrupted or tampered
  # with" -- release engineering chasing a supply-chain incident that never
  # happened. Nothing validated the field's shape either, so a truncated or
  # empty-ish hash reached the comparison as a plausible-looking mismatch.
  case "$ARTIFACT_SHA256" in
    *[!0-9A-Fa-f]*)
      fail "Manifest at $MANIFEST_URL gives platform $PLATFORM_TAG a \"sha256\" that is not hexadecimal. Refusing to continue."
      ;;
  esac
  [ "${#ARTIFACT_SHA256}" -eq 64 ] || fail "Manifest at $MANIFEST_URL gives platform $PLATFORM_TAG a \"sha256\" of ${#ARTIFACT_SHA256} characters. A sha256 is 64. Refusing to continue."
  ARTIFACT_SHA256="$(printf '%s' "$ARTIFACT_SHA256" | tr 'ABCDEF' 'abcdef')"

  VERSIONS_DIR="$APP_DIR/versions"
  VERSION_DIR="$VERSIONS_DIR/$VERSION"
  # Written only after the version directory AND bin/ are both fully in place.
  # Idempotency is gated on this, not on $VERSION_DIR existing, because a
  # directory existing while bin/ is still incomplete (interrupted disk-full,
  # permission error, Ctrl-C) must not read as "already installed" forever.
  INSTALLED_MARKER="$VERSION_DIR/.installed"

  # --- Idempotent short-circuit ----------------------------------------------
  # Also requires the launcher to still be there: bin/ is shared across every
  # version (not per-version, unlike the marker above), so it can go missing
  # after a fully successful install too -- the marker alone can't see that.

  if [ -f "$INSTALLED_MARKER" ] && [ -x "$APP_DIR/bin/twinforge" ]; then
    say "TwinForge $VERSION is already installed."
    point_current "$VERSION_DIR"
    add_bin_to_path
    print_next_steps
    exit 0
  fi

  # --- Download, verify, then extract ----------------------------------------

  TARBALL="$WORK_DIR/twinforge.tar.gz"
  say "Downloading TwinForge $VERSION for $PLATFORM_TAG... (a few hundred MiB; no progress is shown)"
  # 30 minutes and 512 MiB, the same two numbers the monorepo's downloader uses
  # (DOWNLOAD_TIMEOUT_MS / DOWNLOAD_MAX_BYTES in packaging/release-fetch.mjs).
  # The real release artifact is 223 MiB: 30 minutes needs 127 KiB/s (~1 Mbit/s)
  # sustained to clear it, which is well under anything a developer can work on,
  # and 512 MiB is over twice the largest artifact this project ships. --proto
  # keeps a redirect from walking off https:// after assert_https_url has had
  # its say.
  if ! curl -fsSL --proto '=https' --proto-redir '=https' \
      --connect-timeout 30 --max-time 1800 --max-filesize 536870912 \
      -o "$TARBALL" -- "$ARTIFACT_URL"; then
    fail "Download failed: $ARTIFACT_URL
Check your network connection and try again."
  fi

  ACTUAL_SHA256="$(sha256_of "$TARBALL" | tr 'ABCDEF' 'abcdef')"
  if [ "$ACTUAL_SHA256" != "$ARTIFACT_SHA256" ]; then
    fail "Checksum mismatch for $ARTIFACT_URL
  expected $ARTIFACT_SHA256
  actual   $ACTUAL_SHA256
The download may be corrupted or tampered with. Try again, and if it keeps happening, report it."
  fi

  EXTRACT_DIR="$WORK_DIR/extracted"
  mkdir -p "$EXTRACT_DIR" \
    || fail "Could not create the extraction directory at $EXTRACT_DIR."
  # --no-same-owner / --no-same-permissions: GNU tar running as root restores
  # ownership and setuid bits straight from the archive. Root is refused above
  # when it came from sudo, but a container image building as root is a real and
  # supported case, and there the flags are what keep an archive from deciding
  # who owns the extracted tree.
  tar -xzf "$TARBALL" --no-same-owner --no-same-permissions -C "$EXTRACT_DIR" || fail "Could not extract $TARBALL. The archive may be corrupted; try again."

  [ -d "$EXTRACT_DIR/$VERSION" ] || fail "Downloaded archive does not contain a $VERSION directory. This looks like a packaging bug, not a network problem -- please report it."
  [ -f "$EXTRACT_DIR/bin/twinforge" ] || fail "Downloaded archive has no bin/twinforge launcher. This looks like a packaging bug, not a network problem -- please report it."

  mkdir -p "$VERSIONS_DIR" \
    || fail "Could not create $VERSIONS_DIR." \
      "Check that $HOME has space and that $APP_DIR is writable, then re-run this script."
  # A previous run may have been interrupted after $VERSION_DIR was created but
  # before the marker was written. `mv` onto an existing directory would nest
  # into it instead of replacing it, so clear that stale, unmarked state first.
  rm -rf "$VERSION_DIR" \
    || fail "Could not remove the incomplete $VERSION_DIR left by an earlier run." \
      "Remove it by hand and re-run this script."

  # The payload is committed first, then bin/, then the marker that says both
  # are there. bin/ is shared across every installed version, so writing it
  # first replaces the launcher of the install that currently works -- and the
  # move that follows is the step most likely to fail, because $EXTRACT_DIR is
  # under $TMPDIR and $VERSION_DIR under $HOME, usually different filesystems,
  # which makes it a multi-hundred-MiB copy rather than a rename. Losing it
  # (disk full, realistically) after bin/ had already been replaced left the
  # machine with the new launcher over the old payload, `current` still pointing
  # at the old version, and no marker.
  mv "$EXTRACT_DIR/$VERSION" "$VERSION_DIR" \
    || fail "Could not move the unpacked TwinForge $VERSION into $VERSION_DIR." \
      "This copies a few hundred MiB across filesystems, so a full disk is the usual cause. Free some space and re-run this script."
  mkdir -p "$APP_DIR/bin" \
    || fail "Could not create $APP_DIR/bin." \
      "Check that $APP_DIR is writable, then re-run this script."
  # Only the launcher, not `cp -R bin/.`. bin/ holds exactly one file --
  # packaging/build-release-tarball.mjs writes bin/twinforge and nothing else --
  # so copying the directory wholesale gained nothing and accepted whatever a
  # future archive happened to contain into a directory that is on the PATH of
  # every shell. Naming the one file also means an upgrade or downgrade cannot
  # leave a stale launcher behind, which a merging `cp -R` never pruned.
  cp "$EXTRACT_DIR/bin/twinforge" "$APP_DIR/bin/twinforge" \
    || fail "Could not install the launcher into $APP_DIR/bin/twinforge." \
      "Check who owns that file (an earlier run under sudo is the usual cause), then re-run this script."
  # Not `2>/dev/null || true`. When this genuinely failed -- foreign ownership
  # from an earlier sudo run, a read-only mount, a restrictive ACL -- the script
  # carried on, wrote the marker, and printed "installed", and the developer got
  # `permission denied` from the first command they ran. Worse: the marker was
  # then set while the [ -x ] half of the short-circuit at the top stayed false,
  # so every re-run re-downloaded the whole artifact and ended in the same
  # place. The [ -x ] test is repeated after chmod because an ACL can deny
  # execution even where chmod itself succeeds.
  chmod +x "$APP_DIR/bin/twinforge" \
    || fail "Could not make $APP_DIR/bin/twinforge executable." \
      "Check who owns $APP_DIR/bin (an earlier run under sudo is the usual cause) and that its filesystem is writable, then re-run this script."
  [ -x "$APP_DIR/bin/twinforge" ] \
    || fail "$APP_DIR/bin/twinforge is still not executable after chmod." \
      "A filesystem mounted noexec, or an ACL denying execution, would do this. Fix that and re-run this script."
  touch "$INSTALLED_MARKER" \
    || fail "TwinForge $VERSION is installed, but the marker at $INSTALLED_MARKER could not be written, so re-running would download it all over again." \
      "Check that $VERSION_DIR is writable, then re-run this script."

  point_current "$VERSION_DIR"
  add_bin_to_path
  print_next_steps
}

# The only statement in this file that does anything -- see the header.
#
# Sourcing it with TWINFORGE_INSTALL_LIB=1 defines the functions and installs
# nothing, which is how tests/ exercises the manifest parser and the URL check
# against fixtures. Nothing else reads this variable, and a truncated stream
# still cannot reach this line.
[ "${TWINFORGE_INSTALL_LIB:-}" = "1" ] || main "$@"

}
