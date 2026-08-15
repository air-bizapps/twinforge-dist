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

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    # `throw` (not `exit`): this script is meant to be run via
    # `irm ... | iex`, which executes it in the *caller's own session* rather
    # than a child process. `exit` there would close the developer's whole
    # terminal instead of just stopping the install. `throw` unwinds through
    # any open try/finally (so temp-dir cleanup still runs) and stops at the
    # top of the script without touching the host session.
    Write-Host $Message -ForegroundColor Red
    throw "TwinForge install aborted."
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
    $ManifestBody = (Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing).Content
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

$Version = $Manifest.version
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

$ArtifactUrl = Get-ArtifactField $Manifest "url"
$ArtifactSha256 = Get-ArtifactField $Manifest "sha256"
if (-not $ArtifactUrl -or -not $ArtifactSha256) {
    Fail "Manifest at $ManifestUrl has no artifact for platform $PlatformTag."
}

$VersionsDir = Join-Path $AppDir "versions"
$VersionDir = Join-Path $VersionsDir $Version
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
    # `return`, not `exit`: at this top level (not inside a function) it ends
    # the script the same way reaching the end of the file would, without the
    # `exit`-via-iex risk described in Fail above.
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
        Invoke-WebRequest -Uri $ArtifactUrl -OutFile $TarballPath -UseBasicParsing
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
