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
  # -> "<field>\t<value>" lines for version, url and sha256, in file order.
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
    function parse_scalar(   start) {
      start = i
      while (i <= n) {
        c = substr(doc, i, 1)
        if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r") break
        i++
      }
      if (i == start) fatal("unexpected character at byte " i)
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

print_next_steps() {
  cat <<EOF

TwinForge $VERSION is installed at $APP_DIR.

It will not start until this machine is enrolled with your organization's
instance. Next step:

  twinforge enroll

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

  MANIFEST_FIELDS="$WORK_DIR/fields.tsv"
  if ! manifest_scan "$MANIFEST_FILE" "$PLATFORM_TAG" > "$MANIFEST_FIELDS"; then
    fail "Could not read the channel manifest at $MANIFEST_URL: $(sed -n 's/^error	//p' "$MANIFEST_FIELDS" | head -1).
It is not the JSON document this installer expects. Report it -- a manifest this
installer cannot read is a publishing bug, not something to work around."
  fi

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
