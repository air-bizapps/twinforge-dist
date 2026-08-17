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

# --- Platform detection -------------------------------------------------------
# v1 supports win-x64 only (see docs/superpowers/specs/2026-08-15-distribuicao-e-update-design.md, E3).

# The OS was never checked, only the architecture. Under pwsh on Linux or macOS
# the x64 check passes, %USERPROFILE% is $null, and the script proceeds to
# install into a path built from nothing. RuntimeInformation is already the type
# the architecture check uses, so this adds no dependency.
if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    Fail "This installer is for Windows.`nOn macOS and Linux, run install.sh instead:`n  curl -fsSL https://raw.githubusercontent.com/air-bizapps/twinforge-dist/main/install.sh | sh"
}

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($arch -ne [System.Runtime.InteropServices.Architecture]::X64) {
    Fail "Unsupported platform: windows/$arch`nSupported platforms: win-x64. Other Windows architectures are not built yet."
}
$PlatformTag = "win-x64"

# tar is probed here, beside the architecture check, rather than discovered at
# the extraction step — which is after a few hundred MiB have been downloaded
# and verified. `& tar` with no tar on PATH raises CommandNotFoundException,
# and the block that wraps the extraction has only a `finally`, so the
# developer got a bare PowerShell stack trace at the end of a long download
# instead of a sentence telling them what to install. install.sh gates on
# `need_cmd tar` before it does any work; this is that gate.
#
# -CommandType Application, and then invoking the resolved path: a `tar`
# function or alias in the developer's profile would satisfy a bare probe and
# then not set $LASTEXITCODE, which is the only thing the extraction below
# checks.
$TarCommand = Get-Command tar -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $TarCommand) {
    Fail "Could not find tar.exe on your PATH.`nThe release artifact is a .tar.gz, and tar has shipped with Windows since 10 1803 and Server 2019. If you are on an older build, install it (or add %SystemRoot%\System32 back to your PATH) and re-run this script."
}
$TarExe = $TarCommand.Source

# --- Install root ---------------------------------------------------------------
# Checked rather than assumed: install.sh refuses to guess when $HOME is unset,
# and %USERPROFILE% is empty often enough on service accounts and in stripped
# container images for the same refusal to be worth making here.
if ((-not $env:TWINFORGE_HOME) -and (-not $env:USERPROFILE)) {
    Fail "%USERPROFILE% is not set, so there is nowhere to install to.`nSet TWINFORGE_HOME to the directory you want TwinForge installed under, and re-run this script."
}
$HomeDir = if ($env:TWINFORGE_HOME) { $env:TWINFORGE_HOME } else { Join-Path $env:USERPROFILE ".twinforge" }
$AppDir = Join-Path $HomeDir "app"

# --- Transport ------------------------------------------------------------------
# Windows PowerShell 5.1 on an image that has not been updated negotiates
# whatever ServicePointManager was left defaulted to, and TLS 1.2 is not always
# in it. Reaching the default host at all then fails with a bare
# "underlying connection was closed". It does not bite the documented
# `irm ... | iex` entry point — irm has already negotiated by the time this
# runs — but it does bite the file saved and run later, which is how it will be
# used on locked-down images.
#
# Not restored afterwards, unlike $ProgressPreference: this is a process-wide
# static with no scope to restore into, and the assignment only ever *adds* a
# protocol to the allowed set. Nothing the developer had is taken away.
#
# Windows PowerShell only. On PowerShell 7 this property is a .NET Framework
# leftover that the HttpClient stack behind Invoke-WebRequest does not consult,
# and its default there is SystemDefault (0) — so writing Tls12 into it would,
# if anything ever did read it, *narrow* a runtime that already negotiates TLS
# 1.3. Not touching it is the conservative answer for the runtime that does not
# need it.
if ($PSVersionTable.PSVersion.Major -le 5) {
    try {
        $SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
        if (($SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) -ne [Net.SecurityProtocolType]::Tls12) {
            [Net.ServicePointManager]::SecurityProtocol = $SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
    } catch {
        # An image too old to know the enum value cannot be helped from here,
        # and that is not a reason to refuse to install.
        Write-Host "Could not enable TLS 1.2; continuing with the system default."
    }
}

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
    $currentLink = Join-Path $AppDir "current"
    # Get-Item -Force rather than Test-Path. Test-Path resolves the link, so a
    # *dangling* junction — the state a version directory removed by hand leaves
    # behind — reads as absent: the delete was skipped and New-Item then failed
    # with "already exists", wedging every re-run. And a `current` that is a real
    # directory rather than a junction made .Delete() throw a raw exception right
    # after the line saying the install was fine. install.sh's point_current
    # refuses that case by name; this is the same refusal.
    #
    # UNVERIFIED: that Get-Item -Force returns the entry for a dangling junction
    # rather than failing on it. If it does fail, this behaves as it did before
    # and the New-Item message below is the one that has to carry the developer,
    # which is why it names the path and says what to do.
    $existing = Get-Item -LiteralPath $currentLink -Force -ErrorAction SilentlyContinue
    if ($existing) {
        # Compared to the flag rather than tested for truth: PowerShell's rules
        # for whether a non-zero enum is truthy are not worth relying on where
        # getting it backwards would send a junction down the "this is a real
        # directory" branch and refuse a perfectly ordinary re-run.
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
            try {
                # .Delete() on a junction removes the link, not what it points at.
                $existing.Delete()
            } catch {
                Fail "Could not remove the existing junction at $currentLink.`n$($_.Exception.Message)"
            }
        } else {
            Fail "$currentLink is a real file or directory, not a junction, so it cannot be pointed at $Target.`nMove it aside and re-run this script."
        }
    }
    try {
        # Junction, not symlink: symlinks need elevation on Windows, junctions do not.
        New-Item -ItemType Junction -Path $currentLink -Target $Target | Out-Null
    } catch {
        Fail "Could not point 'current' at $Target.`nIf $currentLink still exists, remove it by hand and re-run this script.`n$($_.Exception.Message)"
    }
}

# Belt and braces behind the staging decision below: both ends are under $AppDir
# now, so an ordinary install never reaches the fallback. It exists because
# $AppDir\versions can itself be a junction onto another volume — people do
# relocate directories that grow to a few hundred MiB each — and there the
# rename is a cross-volume move again.
#
# The fallback runs only after Move-Item has already failed, so it cannot make
# a working case worse; and if the copy fails too, the *original* error is what
# gets reported, because that is the one that describes the real problem.
#
# UNVERIFIED: the exception type and message the provider raises for a
# cross-volume directory move. Nothing here matches on either — any move
# failure is retried as a copy — precisely because that shape could not be
# checked.
function Move-Directory([string]$From, [string]$To) {
    try {
        Move-Item -LiteralPath $From -Destination $To
        return
    } catch {
        $moveError = $_
    }
    try {
        Copy-Item -LiteralPath $From -Destination $To -Recurse -Force
        Remove-Item -LiteralPath $From -Recurse -Force
    } catch {
        throw $moveError
    }
}

# Entries are compared the way Windows resolves them, not byte for byte. The
# old `-split ";" -contains $binDir` was an exact match, so an entry that was
# quoted, or carried a trailing backslash, or was written with %USERPROFILE%
# unexpanded, did not match — and every run appended another copy.
function Get-PathEntryKey([string]$Entry) {
    $entryKey = $Entry.Trim().Trim('"').Trim()
    if (-not $entryKey) { return "" }
    $entryKey = [Environment]::ExpandEnvironmentVariables($entryKey)
    # Length > 3 so "C:\" keeps its separator and stays a root.
    if ($entryKey.Length -gt 3) { $entryKey = $entryKey.TrimEnd("\", "/") }
    return $entryKey
}

# Read and write the user PATH through the registry, preserving its value kind.
#
# [Environment]::GetEnvironmentVariable("Path", "User") *expands* a
# REG_EXPAND_SZ before returning it, and SetEnvironmentVariable writes back as
# REG_SZ. That round trip did two irreversible things to every developer who
# ran this successfully, attacker or no attacker:
#
#   1. Every %…% reference in their PATH was replaced by its expansion at
#      install time. %USERPROFILE%\AppData\Local\Microsoft\WindowsApps and
#      %JAVA_HOME%\bin became hard-coded; change JAVA_HOME afterwards and PATH
#      no longer follows it, and a roaming profile breaks weeks later with
#      nothing pointing back here.
#   2. The value was left REG_SZ, so any %VAR% entry anyone added after that —
#      by hand, or by another installer — was stored and never expanded, and
#      showed up in PATH as a literal string with percent signs in it.
#
# So: read raw with DoNotExpandEnvironmentNames, write back with the kind the
# value already had. When the value is absent the new one is created as REG_SZ,
# which is exactly what the old code produced in that case — the damage was
# always to an *existing* value, and the fresh case is deliberately left
# behaving as it did.
#
# A kind other than REG_SZ or REG_EXPAND_SZ is not edited at all. Nothing this
# script wants is worth rewriting a PATH that is already something unexpected.
#
# No WM_SETTINGCHANGE broadcast. Doing it needs a P/Invoke declaration through
# Add-Type, which is a compiler invocation at install time and fails outright
# under constrained language mode — more than this is worth for an effect the
# existing "open a new terminal" guidance already covers. That guidance stays.
#
# UNVERIFIED: whether this API has a length ceiling of its own. The
# 1024-character truncation people remember belongs to setx and the legacy
# System Properties dialog; nothing here asserts either way, and nothing here
# truncates.
function Add-BinToUserPath {
    $binDir = Join-Path $AppDir "bin"
    $binKey = Get-PathEntryKey $binDir
    $manualAdvice = "Add $binDir to your user PATH by hand (Settings, 'Edit environment variables for your account'), then open a new terminal."

    $envKey = $null
    try {
        $envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    } catch {
        $envKey = $null
    }
    if (-not $envKey) {
        Write-Host "TwinForge is installed, but HKCU\Environment could not be opened for writing, so your PATH was left alone. $manualAdvice"
        return
    }

    $backupPath = $null
    try {
        $rawPath = $envKey.GetValue("Path", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $rawPath) {
            $kind = [Microsoft.Win32.RegistryValueKind]::String
            $rawPath = ""
        } else {
            # GetValueKind throws when the value does not exist, which is why it
            # is only reached once GetValue has said it does.
            $kind = $envKey.GetValueKind("Path")
            if (($kind -ne [Microsoft.Win32.RegistryValueKind]::String) -and ($kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
                Write-Host "TwinForge is installed, but your user PATH is stored as $kind, which this script will not rewrite. $manualAdvice"
                return
            }
            if ($rawPath -isnot [string]) {
                Write-Host "TwinForge is installed, but your user PATH did not read back as a string, so it was left alone. $manualAdvice"
                return
            }
        }

        foreach ($entry in ($rawPath -split ";")) {
            if ((Get-PathEntryKey $entry) -eq $binKey) { return }
        }

        if ($rawPath) {
            # Best-effort, and never fatal: a PATH this script is about to
            # rewrite is worth a copy on disk that says what it was, because
            # nothing else on the machine records it.
            try {
                New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null
                $backupPath = Join-Path $HomeDir ("user-path-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
                Set-Content -LiteralPath $backupPath -Value $rawPath -Encoding UTF8 -NoNewline
            } catch {
                $backupPath = $null
            }
        }

        # Appended, not prepended, matching install.sh. This directory is filled
        # from a downloaded archive: putting it first would let a release
        # containing bin\git.exe or bin\ssh.exe take over those commands for
        # every shell the developer opens afterwards.
        $newPath = if ($rawPath) { "$rawPath;$binDir" } else { $binDir }
        $envKey.SetValue("Path", $newPath, $kind)
    } finally {
        $envKey.Close()
    }

    if ($backupPath) {
        Write-Host "Added $binDir to your user PATH (its previous value is saved at $backupPath). Open a new terminal for it to take effect."
    } else {
        Write-Host "Added $binDir to your user PATH. Open a new terminal for it to take effect."
    }
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
# Parse the document ourselves rather than letting Invoke-RestMethod decide.
# Invoke-RestMethod only deserializes when the response carries a JSON content
# type, and the default host here — raw.githubusercontent.com — serves .json as
# `text/plain; charset=utf-8` with nosniff. Under Invoke-RestMethod the manifest
# would come back as a plain string, every property read below would be $null,
# and the script would abort telling the developer that our manifest is
# malformed — blaming the publisher for a bug on this side, on the first command
# they ever run. Parsing unconditionally is correct for any content type the
# host sends.
#
# -OutFile rather than reading .Content: the response was buffered into the
# developer's *interactive session* with no ceiling on it, and with the progress
# bar suppressed below a server that trickles looks exactly like a hang. Going
# through a file gives the size something to be checked against, and drops the
# byte[]-vs-string handling that .Content needed on 5.1.
$ManifestFile = Join-Path ([System.IO.Path]::GetTempPath()) "twinforge-manifest-$([guid]::NewGuid()).json"
try {
    try {
        # -MaximumRedirection: Invoke-WebRequest follows redirects by default
        # with no bound, so a chain can be walked as far as the server likes.
        # Five is more than any real release host needs
        # (raw.githubusercontent.com and the GitHub release CDN each use one).
        #
        # 30 s end to end is MANIFEST_TIMEOUT_MS from the monorepo's updater —
        # this is a JSON document of a few hundred bytes, so it is many times
        # what any link a developer can work on needs.
        #
        # UNVERIFIED: what -TimeoutSec actually bounds on Windows PowerShell
        # 5.1. It maps onto HttpWebRequest.Timeout, which covers getting the
        # response rather than reading its body; the body has a separate idle
        # timeout that a server dribbling one byte at a time never trips. On
        # PowerShell 7 it maps onto HttpClient.Timeout, which does bound the
        # whole exchange. Neither could be measured here.
        #
        # UNVERIFIED: whether a redirect can walk an https URL down to http, or
        # to a non-http scheme, and whether .NET Framework's HttpWebRequest
        # refuses that on its own. curl is told explicitly (install.sh passes
        # --proto-redir '=https'); Invoke-WebRequest has no equivalent switch
        # before PowerShell 7.4's -AllowInsecureRedirect, and hand-rolling the
        # redirect loop to check each hop is exactly the kind of unrunnable code
        # this file should not grow. The artifact is checksum-verified
        # regardless of how it was reached.
        Invoke-WebRequest -Uri $ManifestUrl -OutFile $ManifestFile -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 30
    } catch {
        Fail "Could not read the channel manifest from $ManifestUrl`nCheck your network connection, and that TWINFORGE_CHANNEL=$Channel names a real channel.`n$($_.Exception.Message)"
    }

    # 1 MiB is ~500x the real manifest. Checked after the fact rather than
    # during the transfer, because Invoke-WebRequest has no size limit to pass:
    # it bounds what this script is willing to parse and trust, not what a
    # server can make it write.
    $ManifestLength = (Get-Item -LiteralPath $ManifestFile).Length
    if ($ManifestLength -gt 1048576) {
        Fail "The channel manifest at $ManifestUrl is $ManifestLength bytes. A channel manifest is a few hundred; this installer will not parse one over 1 MiB. Refusing to continue."
    }

    try {
        # ReadAllText, not Get-Content: on 5.1 Get-Content without -Encoding
        # reads with the machine's ANSI code page. This overload detects the
        # byte-order mark and defaults to UTF-8, which is what the manifest is.
        $Manifest = [System.IO.File]::ReadAllText($ManifestFile) | ConvertFrom-Json
    } catch {
        Fail "Could not read the channel manifest from $ManifestUrl`nIt is not the JSON document this installer expects. Report it — a manifest this installer cannot read is a publishing bug, not something to work around.`n$($_.Exception.Message)"
    }
} finally {
    Remove-Item -LiteralPath $ManifestFile -Force -ErrorAction SilentlyContinue
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
# The shape is checked here, not at the comparison. `$ArtifactSha256.ToLower()`
# below sits outside any catch: a manifest giving sha256 as anything without a
# ToLower to call threw a raw PowerShell error after the whole artifact had been
# downloaded. install.sh applies the same 64-hex rule, so a manifest one
# installer refuses the other refuses too.
if ($ArtifactSha256 -notmatch '\A[0-9A-Fa-f]{64}\z') {
    Fail "Manifest at $ManifestUrl gives platform $PlatformTag a 'sha256' that is not 64 hexadecimal characters. Refusing to continue."
}

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

# -PathType Leaf on both: without it a *directory* named .installed satisfies
# the marker test and a directory named twinforge.cmd satisfies the launcher
# test, and the script reports an install that is not there.
if ((Test-Path -LiteralPath $InstalledMarker -PathType Leaf) -and (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
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

# The working directory lives under $AppDir, not under %TEMP%.
#
# The FileSystem provider refuses to move a *directory* across volumes: unlike
# POSIX mv, Move-Item has no copy-and-unlink fallback. With the work directory
# under [System.IO.Path]::GetTempPath() and the destination under %USERPROFILE%
# or TWINFORGE_HOME, anyone whose %TEMP% is redirected to another drive, or who
# sets TWINFORGE_HOME=D:\..., downloaded a few hundred MiB, verified it,
# extracted it, and then died on the last step. Every time, not intermittently,
# and re-running did not help.
#
# Staging on the destination volume was chosen over adding a copy fallback,
# because it does more than avoid the error: $VersionsDir is a child of $AppDir,
# so the move that commits the payload becomes a rename within one directory —
# atomic, instant, and with no half-copied tree to reason about — instead of a
# few hundred MiB copied a second time. It is the same reason the monorepo's
# updater stages beside its target (packaging/updater/check-for-update.mjs).
#
# The cost, accepted: the download and the unpacked tree occupy space under the
# install root rather than under %TEMP% while the install runs, and a hard kill
# leaves that directory behind. The name starts with a dot and is not under
# versions\, so nothing enumerating installed versions can read it as one, and
# the `finally` below removes it on every ordinary exit.
$WorkId = [guid]::NewGuid().ToString("N")
$WorkDir = Join-Path $AppDir ".install+$WorkId"
try {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
} catch {
    Fail "Could not create a working directory at $WorkDir.`nCheck that $AppDir is writable and that the drive has room for a few hundred MiB, then re-run this script.`n$($_.Exception.Message)"
}
# The two siblings the replacement is swapped through, and the flag that says
# which of them currently holds the only usable copy of this version. Declared
# out here because the `finally` below reads all three.
$IncomingDir = Join-Path $VersionsDir ".incoming+$WorkId"
$AsideDir = Join-Path $VersionsDir ".old+$WorkId"
$AsideHoldsTheLiveVersion = $false
# The launcher is swapped in through a sibling in the same directory, so this
# one lives in bin\ rather than under $WorkDir.
$LauncherStagePath = Join-Path (Join-Path $AppDir "bin") "twinforge.cmd+$WorkId"
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
        # 30 minutes is DOWNLOAD_TIMEOUT_MS from the monorepo's downloader
        # (packaging/release-fetch.mjs). The real artifact is 223 MiB, so
        # clearing it needs 127 KiB/s sustained — well under anything a
        # developer can work on. See the manifest fetch above for what
        # -TimeoutSec is and is not known to bound on 5.1.
        Invoke-WebRequest -Uri $ArtifactUrl -OutFile $TarballPath -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 1800
    } catch {
        Fail "Download failed: $ArtifactUrl`nCheck your network connection and try again.`n$($_.Exception.Message)"
    } finally {
        $ProgressPreference = $PreviousProgressPreference
    }

    # 512 MiB is DOWNLOAD_MAX_BYTES from the same file, over twice the largest
    # artifact this project ships. Invoke-WebRequest has no size limit to pass,
    # so this cannot stop a server writing the bytes — it stops them being
    # hashed, extracted and trusted, and it says why instead of failing later
    # with something less specific.
    $TarballLength = (Get-Item -LiteralPath $TarballPath).Length
    if ($TarballLength -gt 536870912) {
        Fail "$ArtifactUrl sent $TarballLength bytes. This installer will not install an artifact over 512 MiB. Refusing to continue."
    }

    try {
        $ActualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $TarballPath).Hash
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
    & $TarExe -xzf $TarballPath -C $ExtractDir
    if ($LASTEXITCODE -ne 0) {
        Fail "Could not extract $TarballPath. The archive may be corrupted; try again."
    }

    $ExtractedVersionDir = Join-Path $ExtractDir $Version
    if (-not (Test-Path -LiteralPath $ExtractedVersionDir -PathType Container)) {
        Fail "Downloaded archive does not contain a $Version directory. This looks like a packaging bug, not a network problem — please report it."
    }
    # The launcher by name, not the directory. An archive whose bin\ existed but
    # was empty passed the old check, so the marker was written and PATH updated
    # while the launcher never appeared — and the short-circuit at the top then
    # failed forever, re-downloading a few hundred MiB on every run without ever
    # saying why.
    $ExtractedLauncher = Join-Path (Join-Path $ExtractDir "bin") "twinforge.cmd"
    if (-not (Test-Path -LiteralPath $ExtractedLauncher -PathType Leaf)) {
        Fail "Downloaded archive has no bin\twinforge.cmd launcher. This looks like a packaging bug, not a network problem — please report it."
    }

    # --- Commit ----------------------------------------------------------------
    # The old sequence deleted $VersionDir and only then moved the new tree in.
    # Anything at all in between — the cross-volume failure above, a lock on a
    # file under it, a full disk, Ctrl-C — left the developer with no copy of
    # that version, `current` dangling, and no marker to record that a
    # half-install had happened. Recovery needed a successful network round
    # trip, from a machine that had just failed one.
    #
    # So the incoming tree lands *beside* the target first, and the old one is
    # only moved aside once that has succeeded. This is the shape the monorepo's
    # updater arrived at after the same defect (`runUpdateCheck` in
    # packaging/updater/check-for-update.mjs): the move that can fail for
    # interesting reasons is the one that destroys nothing, and the two after it
    # are renames between siblings in the same directory.
    #
    # `+` in the staging names: it is outside the character class a version is
    # allowed to use, so no published version can ever collide with one of
    # these, and the leading dot keeps them out of a versions\* enumeration.
    try {
        New-Item -ItemType Directory -Path $VersionsDir -Force | Out-Null
    } catch {
        Fail "Could not create $VersionsDir.`nCheck that $AppDir is writable, then re-run this script.`n$($_.Exception.Message)"
    }
    try {
        Move-Directory $ExtractedVersionDir $IncomingDir
    } catch {
        Fail "Could not stage TwinForge $Version at $IncomingDir.`nA full disk is the usual cause. Free some space and re-run this script.`n$($_.Exception.Message)"
    }

    # A previous run may have been interrupted after $VersionDir was created but
    # before the marker was written, and a move onto an existing directory would
    # merge into it rather than replace it. Whatever is there — a complete
    # install or that debris — goes aside rather than being deleted, and is only
    # reclaimed in the `finally` once the new tree is in place.
    if (Test-Path -LiteralPath $VersionDir) {
        try {
            Move-Item -LiteralPath $VersionDir -Destination $AsideDir
            $AsideHoldsTheLiveVersion = $true
        } catch {
            Fail "Could not move the existing $VersionDir aside.`nSomething may still be running from it; close it and re-run this script.`n$($_.Exception.Message)"
        }
    }
    try {
        Move-Item -LiteralPath $IncomingDir -Destination $VersionDir
        $AsideHoldsTheLiveVersion = $false
    } catch {
        $swapError = $_
        if ($AsideHoldsTheLiveVersion) {
            # The one failure that has to be repaired rather than cleaned up.
            try {
                Move-Item -LiteralPath $AsideDir -Destination $VersionDir
                $AsideHoldsTheLiveVersion = $false
            } catch {
                Fail "Could not install TwinForge $Version into $VersionDir ($($swapError.Exception.Message)), and the copy that was there could not be put back ($($_.Exception.Message)).`nIt has not been deleted: it is at $AsideDir. Move that directory back to $VersionDir to restore this install."
            }
        }
        Fail "Could not install TwinForge $Version into $VersionDir.`nNothing that was already installed has been changed.`n$($swapError.Exception.Message)"
    }

    # bin\ after the payload, never before. bin\ is shared across every
    # installed version, so writing it first replaces the launcher of the
    # install that currently works — and then the move above is the step most
    # likely to fail. The comment that used to sit here claimed this ordering
    # while the code did the opposite; install.sh had the same wrong comment and
    # the same inversion, and both now match what they say.
    #
    # Only bin\twinforge.cmd, not `bin\*`. packaging/build-release-tarball.mjs
    # writes exactly one launcher there, so naming it loses nothing today, stops
    # a future archive adding neighbours to a directory that is on the PATH of
    # every shell the developer opens, and removes the case where the merging
    # copy left a stale launcher behind across an upgrade or downgrade.
    # install.sh copies bin/twinforge the same way and for the same reasons.
    #
    # And it is replaced through a sibling, not written over in place. Upgrading
    # while a TwinForge was running used to fail partway through `Copy-Item
    # -Force`, having already written some of bin\ — shared across versions, so
    # the damage outlived the failed install, and the marker was never written.
    # cmd.exe re-reads a running .cmd from disk by byte offset, so overwriting
    # it in place is precisely what corrupts a running instance. File.Replace is
    # one Win32 call: it either swaps the file or leaves the old one exactly as
    # it was.
    #
    # That is also the running-instance detection. Rather than guessing at
    # process names, the replace is attempted and its failure is read for what
    # it is.
    #
    # UNVERIFIED: that a running twinforge.cmd holds a share mode that makes
    # File.Replace fail rather than succeed. If it succeeds, the swap is still
    # the safe way to do it; if it fails, the message below is the right one.
    # Either way the old launcher survives, which is the property that matters.
    $BinDir = Join-Path $AppDir "bin"
    try {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
        Copy-Item -LiteralPath $ExtractedLauncher -Destination $LauncherStagePath -Force
        if (Test-Path -LiteralPath $LauncherPath -PathType Leaf) {
            [System.IO.File]::Replace($LauncherStagePath, $LauncherPath, $null)
        } else {
            [System.IO.File]::Move($LauncherStagePath, $LauncherPath)
        }
    } catch {
        Fail "TwinForge $Version is unpacked at $VersionDir, but the launcher at $LauncherPath could not be replaced.`nThe launcher that was there is untouched. A TwinForge still running is the usual cause — close it and re-run this script.`n$($_.Exception.Message)"
    }
    try {
        New-Item -ItemType File -Path $InstalledMarker -Force | Out-Null
    } catch {
        Fail "TwinForge $Version is installed, but the marker at $InstalledMarker could not be written, so re-running would download it all over again.`nCheck that $VersionDir is writable, then re-run this script.`n$($_.Exception.Message)"
    }
} finally {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    # Only ever this run's own leftovers.
    Remove-Item -LiteralPath $IncomingDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LauncherStagePath -Force -ErrorAction SilentlyContinue
    # $true means $VersionDir holds nothing usable and this directory holds what
    # it should. Nothing may delete it in that state — it is not a leftover
    # then, it is the version, and the message above tells the developer where
    # to find it. Otherwise it is the superseded copy, and reclaiming it is
    # best-effort: the install has already succeeded by the time this runs.
    if (-not $AsideHoldsTheLiveVersion) {
        Remove-Item -LiteralPath $AsideDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Set-Current $VersionDir
Add-BinToUserPath
Write-NextSteps

# The closing brace of the block opened at the top of the file, and the `&`
# that runs it. Nothing may be added below this line.
}
