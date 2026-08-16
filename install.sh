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
# Everything below is a function definition until the last line of the file,
# which is the only statement that does anything. That is not a style choice:
# the documented entry point is `curl ... | sh`, and a shell reading a script
# from a pipe executes each complete statement as it arrives. If the response
# is cut short mid-file — a dropped connection, a proxy timing out, a CDN
# error page — a script written as a flat sequence has already run everything
# up to the cut, and then exits 0 because it reached EOF cleanly. That is how a
# truncated download can delete an installed version and report success. With
# the body inside `main`, a truncated stream ends before `main` is ever called,
# so it cannot run any of it. `set -eu` is inside `main` for the same reason: a
# file cut in the middle of a top-level `set -eu` leaves a bare `set` as its
# last complete statement, which dumps the whole environment to stdout.

fail() {
  echo "$1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1. Install it and re-run this script."
}

# Defines sha256_of() against whichever of the two tools this machine has.
select_sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{print $1}'; }
  elif command -v shasum >/dev/null 2>&1; then
    sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
  else
    fail "Need sha256sum or shasum to verify the download. Install one and re-run."
  fi
}

# --- Manifest helpers ---------------------------------------------------------
# Deliberately hand-rolled instead of requiring jq: the manifest is our own
# fixed, flat shape, and only pulling the two or three fields we need means an
# unrelated field the manifest grows later cannot break an installer already
# in the wild.

manifest_get_top() {
  # $1 manifest file, $2 key name -> string value (first match, top-level)
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" \
    | head -1 \
    | sed -E "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\\1/"
}

manifest_get_artifact_field() {
  # $1 manifest file, $2 platform tag, $3 field name -> string value
  sed -n "/\"$2\"[[:space:]]*:[[:space:]]*{/,/}/p" "$1" \
    | grep -o "\"$3\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed -E "s/.*\"$3\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\\1/"
}

point_current() {
  ln -sfn "$1" "$APP_DIR/current"
}

add_bin_to_path() {
  bin_dir="$APP_DIR/bin"
  case "${SHELL:-}" in
    */zsh) profile="$HOME/.zshrc" ;;
    */bash) profile="$HOME/.bashrc" ;;
    *) profile="$HOME/.profile" ;;
  esac
  if [ -f "$profile" ] && grep -qF "$bin_dir" "$profile" 2>/dev/null; then
    return 0
  fi
  printf '\n# Added by the TwinForge installer\n%s\n' "export PATH=\"$bin_dir:\$PATH\"" >> "$profile"
  echo "Added $bin_dir to PATH in $profile (open a new shell, or run: export PATH=\"$bin_dir:\$PATH\")"
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

  CHANNEL="${TWINFORGE_CHANNEL:-canary}"
  BASE_URL="${TWINFORGE_DIST_BASE_URL:-https://raw.githubusercontent.com/air-bizapps/twinforge-dist/main}"

  need_cmd curl
  need_cmd tar
  need_cmd mktemp
  need_cmd uname
  select_sha256_tool

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
      echo "Unsupported platform: $os/$arch" >&2
      echo "Supported platforms: darwin-arm64, linux-x64. On Windows, run install.ps1 instead." >&2
      exit 1
      ;;
  esac

  # --- Fetch and read the channel manifest -----------------------------------

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/twinforge-install.XXXXXX")"
  trap cleanup EXIT INT TERM

  MANIFEST_URL="$BASE_URL/channels/$CHANNEL.json"
  MANIFEST_FILE="$WORK_DIR/manifest.json"

  echo "Fetching the $CHANNEL channel manifest..."
  if ! curl -fsSL "$MANIFEST_URL" -o "$MANIFEST_FILE"; then
    fail "Could not download the channel manifest from $MANIFEST_URL
Check your network connection, and that TWINFORGE_CHANNEL=$CHANNEL names a real channel."
  fi

  VERSION="$(manifest_get_top "$MANIFEST_FILE" version)"
  [ -n "$VERSION" ] || fail "Manifest at $MANIFEST_URL has no \"version\" field. It may be malformed, or the channel may not exist yet."

  # $VERSION becomes a directory name under $APP_DIR/versions and is
  # interpolated into the `rm -rf` below. It is remote input, so it is checked
  # before it is used as a path — "." and ".." pass the character class but
  # would aim that delete at the versions directory or the install root itself.
  case "$VERSION" in
    . | ..) fail "Manifest at $MANIFEST_URL declares an unusable version \"$VERSION\". The version is used as a directory name; \".\" and \"..\" are not names. Refusing to continue." ;;
    *[!A-Za-z0-9._-]*) fail "Manifest at $MANIFEST_URL declares an unusable version \"$VERSION\". Expected only letters, digits, dot, underscore and hyphen, because the version is used as a directory name. Refusing to continue." ;;
  esac

  ARTIFACT_URL="$(manifest_get_artifact_field "$MANIFEST_FILE" "$PLATFORM_TAG" url)"
  ARTIFACT_SHA256="$(manifest_get_artifact_field "$MANIFEST_FILE" "$PLATFORM_TAG" sha256)"
  if [ -z "$ARTIFACT_URL" ] || [ -z "$ARTIFACT_SHA256" ]; then
    fail "Manifest at $MANIFEST_URL has no artifact for platform $PLATFORM_TAG."
  fi

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
  # after a fully successful install too — the marker alone can't see that.

  if [ -f "$INSTALLED_MARKER" ] && [ -x "$APP_DIR/bin/twinforge" ]; then
    echo "TwinForge $VERSION is already installed."
    point_current "$VERSION_DIR"
    add_bin_to_path
    print_next_steps
    exit 0
  fi

  # --- Download, verify, then extract ----------------------------------------

  TARBALL="$WORK_DIR/twinforge.tar.gz"
  echo "Downloading TwinForge $VERSION for $PLATFORM_TAG..."
  if ! curl -fsSL "$ARTIFACT_URL" -o "$TARBALL"; then
    fail "Download failed: $ARTIFACT_URL
Check your network connection and try again."
  fi

  ACTUAL_SHA256="$(sha256_of "$TARBALL")"
  if [ "$ACTUAL_SHA256" != "$ARTIFACT_SHA256" ]; then
    fail "Checksum mismatch for $ARTIFACT_URL
  expected $ARTIFACT_SHA256
  actual   $ACTUAL_SHA256
The download may be corrupted or tampered with. Try again, and if it keeps happening, report it."
  fi

  EXTRACT_DIR="$WORK_DIR/extracted"
  mkdir -p "$EXTRACT_DIR"
  tar -xzf "$TARBALL" -C "$EXTRACT_DIR" || fail "Could not extract $TARBALL. The archive may be corrupted; try again."

  [ -d "$EXTRACT_DIR/$VERSION" ] || fail "Downloaded archive does not contain a $VERSION directory. This looks like a packaging bug, not a network problem — please report it."
  [ -d "$EXTRACT_DIR/bin" ] || fail "Downloaded archive has no bin/ directory. This looks like a packaging bug, not a network problem — please report it."

  # A previous run may have been interrupted after $VERSION_DIR was created but
  # before the marker was written. `mv` onto an existing directory would nest
  # into it instead of replacing it, so clear that stale, unmarked state first.
  rm -rf "$VERSION_DIR"

  mkdir -p "$VERSIONS_DIR" "$APP_DIR/bin"
  # bin/ is populated, and the marker written, only after the version directory
  # is committed below — see INSTALLED_MARKER above for why the ordering matters.
  cp -R "$EXTRACT_DIR/bin/." "$APP_DIR/bin/"
  chmod +x "$APP_DIR/bin/twinforge" 2>/dev/null || true
  mv "$EXTRACT_DIR/$VERSION" "$VERSION_DIR"
  touch "$INSTALLED_MARKER"

  point_current "$VERSION_DIR"
  add_bin_to_path
  print_next_steps
}

main "$@"
