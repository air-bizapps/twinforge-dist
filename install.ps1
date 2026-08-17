# TwinForge installer (Windows).
#
#   irm https://raw.githubusercontent.com/air-bizapps/twinforge-dist/main/install.ps1 | iex
#
# Installs into $env:USERPROFILE\.twinforge\app and prints the next step
# (enrollment) when done. Safe to re-run: if the channel's version is already
# installed, it just repoints `current` and exits.
#
# Env overrides:
#   TWINFORGE_CHANNEL       channel to install (default: canary). `stable`
#                           stays closed until enrollment exists.
#   TWINFORGE_DIST_BASE_URL base URL serving channels/<channel>.json
#                           (default: this repo's raw main branch). Used for
#                           testing against a local manifest.
#   TWINFORGE_HOME          overrides the install root (default:
#                           $env:USERPROFILE\.twinforge), matching what the
#                           installed server itself honors.
#
# Everything below lives inside one script block, invoked once at the bottom of
# the file. That is not a style choice. The documented entry point is
# `irm ... | iex`, and Invoke-Expression executes the string it is given in the
# *caller's own session* — it creates no scope of its own. Written flat, this
# file defined Fail, Set-Current, Get-ArtifactField, Add-BinToUserPath,
# Write-NextSteps, $Version, $Manifest, $Channel, $arch, $WorkDir and $AppDir in
# the developer's live session, clobbering whatever they had under those names,
# and left $ErrorActionPreference = "Stop" set there for the rest of the day —
# so the next Get-ChildItem over a folder with one unreadable subdirectory
# terminated their pipeline instead of continuing, with nothing to connect it
# back to an installer that had failed at the checksum an hour earlier.
#
# `& { ... }` runs the block in a child scope: the functions and the variables
# below (including the two preference variables) are discarded when it returns,
# and a `throw` inside it still unwinds all the way out — which is what Fail
# relies on. The wrapper also means a truncated response cannot half-run this
# file: iex parses the whole string before executing any of it, and a cut
# anywhere inside the block is a syntax error rather than a script that stops
# in the middle of the install.

& {

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    # `throw` (not `exit`): this script is meant to be run via
    # `irm ... | iex`, which executes it in the *caller's own session* rather
    # than a child process. `exit` there would close the developer's whole
    # terminal instead of just stopping the install. `throw` unwinds through
    # any open try/finally (so working-directory cleanup still runs) and out of
    # the enclosing script block, stopping the install without touching the
    # host session.
    Write-Host $Message -ForegroundColor Red
    throw "TwinForge install aborted."
}

# --- URL validation ------------------------------------------------------------
# Nothing validated the artifact URL before it reached Invoke-WebRequest, and
# the checksum is no defence here because the *fetch itself* is the payload.
#
# On Windows PowerShell 5.1 Invoke-WebRequest routes anything that is not http
# or https through WebRequest.Create, which happily returns a FileWebRequest. A
# manifest publishing file://///evil.example.com/share/a.tar.gz — or a bare UNC
# path, which [uri] coercion turns into a file URI — makes the OS open an SMB
# connection to the attacker's host and negotiate NTLM with the developer's
# credentials. That happens before a single byte is hashed. ftp:// is live on
# 5.1 for the same reason.
#
# So the rule is the one the monorepo's updater already applies to the same
# field (packaging/updater/check-for-update.mjs, `assertHttpsUrl`) and the one
# install.sh applies (`assert_https_url`): https://, or refuse. The message is
# install.sh's, so a manifest one installer rejects the other rejects with the
# same words.
#
# UNVERIFIED: PowerShell 7 uses HttpClient, which rejects file:// outright, so
# the credential-capture half of this is believed to be 5.1-specific. Neither
# runtime was available to confirm it. The check is unconditional either way.
function Assert-HttpsUrl([string]$Url, [string]$ManifestUrl, [string]$VersionLabel) {
    # Rejected before the scheme check so the message can be specific: a URL
    # with whitespace or control characters in it is not a URL, and it is also
    # how a manifest would forge extra lines into the messages this script
    # prints. Printable ASCII only, matching install.sh's *[!!-~]* class.
    if ($Url -match '[^\x21-\x7E]') {
        Fail "Manifest at $ManifestUrl points $VersionLabel at a URL containing whitespace or control characters. Refusing to continue."
    }
    # [uri] on a string that is not a URL does not throw — it builds a
    # *relative* URI, whose .Scheme property then throws instead. Hence the
    # IsAbsoluteUri test before the scheme is ever read.
    $parsed = $null
    try { $parsed = [uri]$Url } catch { $parsed = $null }
    if ((-not $parsed) -or (-not $parsed.IsAbsoluteUri) -or ($parsed.Scheme -ne "https")) {
        Fail "Manifest at $ManifestUrl points $VersionLabel at `"$Url`". Releases are downloaded over https:// only. Refusing to continue."
    }
}

# The manifest URL is built from TWINFORGE_DIST_BASE_URL, which is a documented
# local-testing override set by the person running the script, not a value the
# manifest gets to choose — so it is not forced to https, exactly as install.sh
# leaves it unforced. It *is* held to http or https, which install.sh has no
# need to do: curl only ever downloads with the scheme it is given, while
# Invoke-WebRequest on 5.1 turns file:// and a UNC path into an SMB round trip
# that leaks credentials. Anything a local test wants (http://localhost:8080,
# https://…) still works.
function Assert-ManifestUrl([string]$Url) {
    if ($Url -match '[^\x21-\x7E]') {
        Fail "The channel manifest URL contains whitespace or control characters. Check TWINFORGE_DIST_BASE_URL. Refusing to continue."
    }
    $parsed = $null
    try { $parsed = [uri]$Url } catch { $parsed = $null }
    if ((-not $parsed) -or (-not $parsed.IsAbsoluteUri) -or (($parsed.Scheme -ne "https") -and ($parsed.Scheme -ne "http"))) {
        Fail "The channel manifest URL `"$Url`" is not an http:// or https:// URL.`nTWINFORGE_DIST_BASE_URL is a local-testing override; set it to an http or https base URL, or unset it to use the default. Refusing to continue."
    }
}

$Channel = if ($env:TWINFORGE_CHANNEL) { $env:TWINFORGE_CHANNEL } else { "canary" }
$BaseUrl = if ($env:TWINFORGE_DIST_BASE_URL) { $env:TWINFORGE_DIST_BASE_URL } else { "https://raw.githubusercontent.com/air-bizapps/twinforge-dist/main" }
$HomeDir = if ($env:TWINFORGE_HOME) { $env:TWINFORGE_HOME } else { Join-Path $env:USERPROFILE ".twinforge" }
$AppDir = Join-Path $HomeDir "app"

# --- Platform detection -------------------------------------------------------
# v1 supports win-x64 only (see docs/superpowers/specs/2026-08-15-distribuicao-e-update-design.md, E3).

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($arch -ne [System.Runtime.InteropServices.Architecture]::X64) {
    Fail "Unsupported platform: windows/$arch`nSupported platforms: win-x64. Other Windows architectures are not built yet."
}
$PlatformTag = "win-x64"

# --- Manifest helpers ----------------------------------------------------------
# The manifest is parsed into an object below, so an unrelated field the
# manifest grows later cannot break this: we only read the properties we need.

function Get-ArtifactField($Manifest, [string]$Field) {
    $artifact = $Manifest.artifacts.$PlatformTag
    if (-not $artifact) { return $null }
    return $artifact.$Field
}

# Every value read out of the manifest goes through this before it is used.
#
# PowerShell's comparison operators become *filters* when the left operand is a
# collection: with "version": ["a","b"], `$Version -notmatch '...'` returns the
# elements that fail the pattern rather than $true or $false, and an empty array
# is falsy — so the version guard passed without validating anything, and
# `-eq "."` did the same. Downstream, Join-Path with an array right operand
# produces an *array of paths*, Test-Path over it emits one boolean per path,
# and a two-element array is truthy in `if` whatever the booleans are. On a
# machine with a previous install that meant: "already installed", then
# Set-Current deletes the working `current` junction, then New-Item fails
# because -Target cannot take an array. A healthy install with no `current`,
# blaming the junction. No download, no checksum, no privileges needed.
#
# So a manifest field is a JSON string or it is nothing. install.sh's scanner
# emits only string values, so a number or an array reads there as a missing
# field; this refuses it by name instead, which is the more useful of the two
# and rejects exactly the same documents.
function Get-ManifestString($Value, [string]$Field, [string]$ManifestUrl) {
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) {
        Fail "Manifest at $ManifestUrl declares `"$Field`" as a $($Value.GetType().Name), not a string. Every field this installer reads has to be a JSON string. Refusing to continue."
    }
    return $Value
}

function Set-Current([string]$Target) {
    try {
        $currentLink = Join-Path $AppDir "current"
        if (Test-Path $currentLink) {
            (Get-Item $currentLink -Force).Delete()
        }
        # Junction, not symlink: symlinks need elevation on Windows, junctions do not.
        New-Item -ItemType Junction -Path $currentLink -Target $Target | Out-Null
    } catch {
        Fail "Could not point 'current' at $Target.`n$($_.Exception.Message)"
    }
}

function Add-BinToUserPath {
    $binDir = Join-Path $AppDir "bin"
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -and ($userPath -split ";" -contains $binDir)) { return }
    $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "Added $binDir to your user PATH. Open a new terminal for it to take effect."
}

function Write-NextSteps {
    Write-Host ""
    Write-Host "TwinForge $Version is installed at $AppDir."
    Write-Host ""
    Write-Host "It will not start until this machine is enrolled with your organization's"
    Write-Host "instance. Next step:"
    Write-Host ""
    Write-Host "  twinforge enroll"
    Write-Host ""
    Write-Host "(Open a new terminal first if this was your first install, so $AppDir\bin is on your PATH.)"
}

# --- Fetch and read the channel manifest ---------------------------------------

$ManifestUrl = "$BaseUrl/channels/$Channel.json"
Assert-ManifestUrl $ManifestUrl
Write-Host "Fetching the $Channel channel manifest..."
# Fetch the bytes and parse them ourselves rather than letting Invoke-RestMethod
# decide. Invoke-RestMethod only deserializes when the response carries a JSON
# content type, and the default host here — raw.githubusercontent.com — serves
# .json as `text/plain; charset=utf-8` with nosniff. Under Invoke-RestMethod the
# manifest would come back as a plain string, every property read below would be
# $null, and the script would abort telling the developer that our manifest is
# malformed — blaming the publisher for a bug on this side, on the first command
# they ever run. Parsing unconditionally is correct for any content type the
# host sends.
try {
    # -MaximumRedirection: Invoke-WebRequest follows redirects by default with
    # no bound, so a chain can be walked as far as the server likes. Five is
    # more than any real release host needs (raw.githubusercontent.com and the
    # GitHub release CDN each use one).
    #
    # UNVERIFIED: whether a redirect can walk an https URL down to http, or to
    # a non-http scheme, and whether .NET Framework's HttpWebRequest refuses
    # that on its own. curl is told explicitly (install.sh passes --proto-redir
    # '=https'); Invoke-WebRequest has no equivalent switch before PowerShell
    # 7.4's -AllowInsecureRedirect, and hand-rolling the redirect loop to check
    # each hop is exactly the kind of unrunnable code this file should not grow.
    # The artifact is checksum-verified regardless of how it was reached.
    $ManifestBody = (Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -MaximumRedirection 5).Content
    # Windows PowerShell 5.1 hands back .Content as a byte array rather than a
    # string for content types it does not classify as text, so decode when
    # that is what arrived. Whichever shape it is, it is parsed the same way.
    if ($ManifestBody -is [byte[]]) {
        $ManifestBody = [System.Text.Encoding]::UTF8.GetString($ManifestBody)
    }
    $Manifest = $ManifestBody | ConvertFrom-Json
} catch {
    Fail "Could not read the channel manifest from $ManifestUrl`nCheck your network connection, and that TWINFORGE_CHANNEL=$Channel names a real channel.`n$($_.Exception.Message)"
}

# A top-level JSON array would make every property read below return an array
# of member values, which is the collection-filter problem again one level up.
if ($Manifest -is [System.Array]) {
    Fail "Manifest at $ManifestUrl is a JSON array, not a JSON object. It may be malformed, or the channel may not exist yet."
}

$Version = Get-ManifestString $Manifest.version "version" $ManifestUrl
if (-not $Version) {
    Fail "Manifest at $ManifestUrl has no 'version' field. It may be malformed, or the channel may not exist yet."
}

# $Version becomes a directory name under $AppDir\versions and is interpolated
# into the Remove-Item below. It is remote input, so it is checked before it is
# used as a path — `.` and `..` pass the character class but would aim that
# delete at the versions directory or the install root itself.
#
# \A and \z, not ^ and $: in .NET regex `$` also matches immediately before a
# trailing newline, so "1.0.0`n<anything>" would pass a `$`-anchored check.
if (($Version -notmatch '\A[A-Za-z0-9._-]+\z') -or ($Version -eq ".") -or ($Version -eq "..")) {
    Fail "Manifest at $ManifestUrl declares an unusable version '$Version'. Expected only letters, digits, dot, underscore and hyphen (and not '.' or '..'), because the version is used as a directory name. Refusing to continue."
}
# The check above rejects "." and ".." by name, which leaves "..." — three dots
# match the character class and are neither literal. Win32 path normalisation
# strips trailing periods from the final component, so <AppDir>\versions\...
# resolves to <AppDir>\versions, which made the Test-Path below succeed against
# the versions directory and aimed a recursive delete at every installed
# version. Any name that is nothing but dots, and any name ending in one, is
# refused here; the normalisation test after $VersionDir is built is the
# backstop for whatever this rule has not thought of.
if (($Version -match '\A\.+\z') -or $Version.EndsWith(".")) {
    Fail "Manifest at $ManifestUrl declares an unusable version '$Version'. Windows strips trailing dots from a directory name, so this one would not name the directory it appears to. Refusing to continue."
}
# Reserved device names are not filenames, and Test-Path against one returns
# true in any directory — so the archive-shape checks below were satisfied by a
# path that does not exist. The reservation applies to the stem, so NUL.txt is
# reserved exactly as NUL is.
#
# UNVERIFIED: the Test-Path behaviour. The reservation itself is documented
# (Win32 naming rules); that Test-Path C:\anything\NUL returns true was reported
# rather than reproduced here.
if ($Version.Split(".")[0] -match '\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z') {
    Fail "Manifest at $ManifestUrl declares an unusable version '$Version'. That is a reserved Windows device name and cannot be a directory. Refusing to continue."
}

$ArtifactUrl = Get-ManifestString (Get-ArtifactField $Manifest "url") "artifacts.$PlatformTag.url" $ManifestUrl
$ArtifactSha256 = Get-ManifestString (Get-ArtifactField $Manifest "sha256") "artifacts.$PlatformTag.sha256" $ManifestUrl
if (-not $ArtifactUrl -or -not $ArtifactSha256) {
    Fail "Manifest at $ManifestUrl has no artifact for platform $PlatformTag."
}
Assert-HttpsUrl $ArtifactUrl $ManifestUrl $Version

$VersionsDir = Join-Path $AppDir "versions"
$VersionDir = Join-Path $VersionsDir $Version
# The backstop for the version-name rules above: whatever the manifest asked
# for, the path this script is about to create, delete and extract into must
# still end in exactly that name once Windows has normalised it. If it does
# not, the name is aimed somewhere other than where it reads, and that is the
# whole of the "..." bug regardless of which spelling produced it.
# GetFullPath does no I/O — it is string normalisation — so this is safe to run
# against a path that does not exist yet.
#
# UNVERIFIED: that GetFullPath performs the trailing-period trim on both .NET
# Framework (PowerShell 5.1) and .NET (PowerShell 7). It is documented Win32
# behaviour, not something reproduced here, which is why the explicit rules
# above do not lean on it.
try {
    $NormalizedVersionDir = [System.IO.Path]::GetFullPath($VersionDir)
} catch {
    Fail "Manifest at $ManifestUrl declares a version '$Version' that does not form a usable path under $VersionsDir.`n$($_.Exception.Message)"
}
if ([System.IO.Path]::GetFileName($NormalizedVersionDir) -ne $Version) {
    Fail "Manifest at $ManifestUrl declares a version '$Version' that Windows normalises to something else ($NormalizedVersionDir). Refusing to continue."
}
# Written only after the version directory AND bin\ are both fully in place.
# Idempotency is gated on this, not on $VersionDir existing, because a
# directory existing while bin\ is still incomplete (interrupted disk-full,
# permission error, Ctrl-C) must not read as "already installed" forever.
$InstalledMarker = Join-Path $VersionDir ".installed"
# packaging/build-release-tarball.mjs names the Windows launcher twinforge.cmd
# (not twinforge, which is the POSIX name).
$LauncherPath = Join-Path (Join-Path $AppDir "bin") "twinforge.cmd"

# --- Idempotent short-circuit --------------------------------------------------
# Also requires the launcher to still be there: bin\ is shared across every
# version (not per-version, unlike the marker above), so it can go missing
# after a fully successful install too — the marker alone can't see that.

if ((Test-Path $InstalledMarker) -and (Test-Path $LauncherPath)) {
    Write-Host "TwinForge $Version is already installed."
    Set-Current $VersionDir
    Add-BinToUserPath
    Write-NextSteps
    # `return`, not `exit`: at the top level of the block (not inside a
    # function) it ends the block the same way reaching its closing brace
    # would, without the `exit`-via-iex risk described in Fail above.
    return
}

# --- Download, verify, then extract --------------------------------------------

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "twinforge-install-$([guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
} catch {
    Fail "Could not create a temporary working directory at $WorkDir.`n$($_.Exception.Message)"
}
try {
    $TarballPath = Join-Path $WorkDir "twinforge.tar.gz"
    Write-Host "Downloading TwinForge $Version for $PlatformTag... (a few hundred MiB; no progress is shown)"
    # Windows PowerShell 5.1 renders the Invoke-WebRequest progress bar
    # synchronously, and at this artifact's size that rendering dominates the
    # transfer — the download looks hung. Scoped to this one call and restored
    # in `finally`, not set at the top of the script: the documented entry
    # point is `irm ... | iex`, which runs in the *caller's own session*, so a
    # top-level assignment would silently disable progress bars in the
    # developer's terminal for everything they run afterwards.
    $PreviousProgressPreference = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $ArtifactUrl -OutFile $TarballPath -UseBasicParsing -MaximumRedirection 5
    } catch {
        Fail "Download failed: $ArtifactUrl`nCheck your network connection and try again.`n$($_.Exception.Message)"
    } finally {
        $ProgressPreference = $PreviousProgressPreference
    }

    try {
        $ActualSha256 = (Get-FileHash -Algorithm SHA256 -Path $TarballPath).Hash
    } catch {
        Fail "Could not compute the checksum of the downloaded file at $TarballPath.`n$($_.Exception.Message)"
    }
    if ($ActualSha256.ToLower() -ne $ArtifactSha256.ToLower()) {
        Fail "Checksum mismatch for $ArtifactUrl`n  expected $ArtifactSha256`n  actual   $ActualSha256`nThe download may be corrupted or tampered with. Try again, and if it keeps happening, report it."
    }

    # The release artifact is a .tar.gz on every platform, including Windows
    # (packaging/build-release-tarball.mjs always tars, never zips, the final
    # artifact). Expand-Archive only understands .zip, so it cannot open this;
    # `tar` is what actually extracts it, and has shipped in Windows since
    # 10 1803 / Server 2019 (bsdtar), which is also what windows-latest CI runners have.
    $ExtractDir = Join-Path $WorkDir "extracted"
    try {
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    } catch {
        Fail "Could not create the extraction directory at $ExtractDir.`n$($_.Exception.Message)"
    }
    & tar -xzf $TarballPath -C $ExtractDir
    if ($LASTEXITCODE -ne 0) {
        Fail "Could not extract $TarballPath. The archive may be corrupted; try again."
    }

    $ExtractedVersionDir = Join-Path $ExtractDir $Version
    if (-not (Test-Path $ExtractedVersionDir)) {
        Fail "Downloaded archive does not contain a $Version directory. This looks like a packaging bug, not a network problem — please report it."
    }
    $ExtractedBinDir = Join-Path $ExtractDir "bin"
    if (-not (Test-Path $ExtractedBinDir)) {
        Fail "Downloaded archive has no bin\ directory. This looks like a packaging bug, not a network problem — please report it."
    }

    try {
        # A previous run may have been interrupted after $VersionDir was
        # created but before the marker was written. Move-Item onto an
        # existing directory would merge into it instead of replacing it, so
        # clear that stale, unmarked state first. bin\ is populated, and the
        # marker written, only after the version directory is committed below
        # — see $InstalledMarker above for why the ordering matters.
        if (Test-Path $VersionDir) {
            Remove-Item -Path $VersionDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $VersionsDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $AppDir "bin") -Force | Out-Null
        Copy-Item -Path (Join-Path $ExtractedBinDir "*") -Destination (Join-Path $AppDir "bin") -Recurse -Force
        Move-Item -Path $ExtractedVersionDir -Destination $VersionDir
        New-Item -ItemType File -Path $InstalledMarker -Force | Out-Null
    } catch {
        Fail "Could not install TwinForge $Version into $AppDir.`n$($_.Exception.Message)"
    }
} finally {
    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Set-Current $VersionDir
Add-BinToUserPath
Write-NextSteps

# The closing brace of the block opened at the top of the file, and the `&`
# that runs it. Nothing may be added below this line.
}
