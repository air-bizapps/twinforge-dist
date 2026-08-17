# install.ps1's manifest-signature verifier, run rather than parsed.
#
# This is the first part of install.ps1 that is executed anywhere: everything
# else about that file is checked by the parser and by PSScriptAnalyzer, which
# say nothing about whether it works. .github/workflows/ci.yml runs this under
# `powershell` (Windows PowerShell 5.1) as well as `pwsh` (PowerShell 7), and
# the 5.1 run is the one that matters -- [RSA]::Create() there is a legacy-CSP
# RSACryptoServiceProvider, which is the single thing about this verifier that
# could not be established anywhere else.
#
#   sh tests/make-signature-fixtures.sh <dir>      # on a machine with openssl
#   pwsh tests/signature-test.ps1 <dir>
#
# The fixtures are made by openssl, not by .NET. A test that signed with .NET
# and verified with .NET would agree with itself whatever either side did with
# encodings; the property worth asserting is that this verifier accepts what the
# publisher's openssl actually produces, and refuses everything else.
#
# The cases that matter are not the ones confirming a good signature passes -- a
# verifier that returns $true unconditionally passes those. They are the ones
# that alter a byte, swap the key, truncate the signature, rename the channel or
# take the keys away, and demand a refusal.
# Not [Parameter(Mandatory)]: a missing argument would make PowerShell *prompt*
# for it, which on a CI runner is a job that hangs rather than a job that fails.
param([string]$FixtureDir)

$ErrorActionPreference = "Stop"

if (-not $FixtureDir) {
    Write-Host "usage: signature-test.ps1 <fixture-directory>"
    Write-Host "Build the fixtures first, on a machine with openssl: sh tests/make-signature-fixtures.sh <dir>"
    exit 1
}
if (-not (Test-Path -LiteralPath $FixtureDir -PathType Container)) {
    Write-Host "No fixture directory at $FixtureDir. Build it first: sh tests/make-signature-fixtures.sh <dir>"
    exit 1
}

$InstallerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    Write-Host "Could not find $InstallerPath"
    exit 1
}

# --- Reaching into install.ps1 --------------------------------------------------
# install.ps1 is one `& { ... }` block on purpose: dot-sourcing it would define
# its functions in the caller's session, which is precisely what its header
# refuses to do to a developer running `irm ... | iex`. So the functions are
# lifted out by name through the parser -- the real text of the real file, from
# the file itself, with no second copy to drift.
#
# If install.ps1 renames or removes one of these, this fails loudly here rather
# than testing something that no longer exists.

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host "install.ps1 does not parse; tests/parse-install-ps1.ps1 has the details."
    exit 1
}
$functionAsts = $ast.FindAll(
    { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

foreach ($wanted in @('Get-ManifestString', 'Get-ManifestKeys', 'Assert-SignedManifest', 'Test-ManifestSignature')) {
    $found = $functionAsts | Where-Object { $_.Name -eq $wanted } | Select-Object -First 1
    if (-not $found) {
        Write-Host "install.ps1 no longer defines $wanted, so this test is checking nothing. Update it."
        exit 1
    }
    . ([scriptblock]::Create($found.Extent.Text))
}

# install.ps1's own Fail writes the reason to the host and then throws a fixed
# sentence, so the reason does not travel with the exception. Every refusal
# below is asserted by its reason, so the test substitutes a Fail that carries
# it -- keeping the property the real one has and this depends on, which is that
# it never returns. That the real Fail throws is asserted separately, at the
# bottom.
function Fail([string]$Message) {
    throw $Message
}

# --- Reporting ------------------------------------------------------------------

$script:Failures = 0
function Report-Pass([string]$Label) { Write-Host "ok   $Label" }
function Report-Fail([string]$Label, [string]$Detail) {
    Write-Host "FAIL $Label"
    if ($Detail) { Write-Host "       $Detail" }
    $script:Failures++
}

function Assert-Accepts([string]$Label, [scriptblock]$Action) {
    try {
        & $Action | Out-Null
        Report-Pass $Label
    } catch {
        Report-Fail $Label "expected it to be accepted, but it refused with: $($_.Exception.Message)"
    }
}

function Assert-Refuses([string]$Label, [string]$Expected, [scriptblock]$Action) {
    try {
        & $Action | Out-Null
        Report-Fail $Label "expected a refusal, but it was ACCEPTED"
        return
    } catch {
        $message = $_.Exception.Message
    }
    if ($message -like "*$Expected*") {
        Report-Pass $Label
    } else {
        Report-Fail $Label "refused, but not for the expected reason`n       expected to find: $Expected`n       actual:           $message"
    }
}

# --- Fixtures -------------------------------------------------------------------

function Get-FixtureBytes([string]$Name) {
    return [System.IO.File]::ReadAllBytes((Join-Path $FixtureDir $Name))
}
function Get-FixtureText([string]$Name) {
    return [System.IO.File]::ReadAllText((Join-Path $FixtureDir $Name))
}
function Get-FixtureManifest([string]$Name) {
    return (Get-FixtureText $Name | ConvertFrom-Json)
}

$KeyModulusFile = Join-Path $FixtureDir "key-modulus.b64"
$OtherModulusFile = Join-Path $FixtureDir "other-modulus.b64"
$WeakModulusFile = Join-Path $FixtureDir "weak-modulus.b64"
foreach ($required in @($KeyModulusFile, (Join-Path $FixtureDir "good.json"), (Join-Path $FixtureDir "good.sig"))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "The fixture directory is missing $required. Rebuild it with tests/make-signature-fixtures.sh."
        exit 1
    }
}

# The key this installer carries for the rest of this file, injected through the
# documented local-testing override, under the key id "local-test". That id is
# what makes the unknown-keyId case a real test rather than a tautology: the
# list holds exactly one id, and a manifest naming any other one has to be
# refused even though the only key present would verify its signature perfectly.
$env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE = $KeyModulusFile

$GoodBytes = Get-FixtureBytes "good.json"
$GoodSignature = Get-FixtureText "good.sig"

# --- The signature itself --------------------------------------------------------

Assert-Accepts "an openssl-made signature verifies" {
    Test-ManifestSignature $GoodBytes $GoodSignature "local-test" "URL"
}

Assert-Refuses "one altered byte in the manifest is refused" "does not match its bytes" {
    Test-ManifestSignature (Get-FixtureBytes "tampered.json") (Get-FixtureText "tampered.sig") "local-test" "URL"
}

Assert-Refuses "a signature truncated mid-character is refused" "not a whole number of bytes" {
    Test-ManifestSignature $GoodBytes (Get-FixtureText "truncated-odd.sig") "local-test" "URL"
}

Assert-Refuses "a signature truncated to a whole number of bytes is refused" "does not match its bytes" {
    Test-ManifestSignature $GoodBytes (Get-FixtureText "truncated-even.sig") "local-test" "URL"
}

Assert-Refuses "a signature from another key is refused" "does not match its bytes" {
    Test-ManifestSignature (Get-FixtureBytes "other-key.json") (Get-FixtureText "other-key.sig") "local-test" "URL"
}

Assert-Refuses "an unknown keyId is refused, even with a signature that would verify" "does not carry" {
    Test-ManifestSignature (Get-FixtureBytes "unknown-keyid.json") (Get-FixtureText "unknown-keyid.sig") "some-other-key" "URL"
}

Assert-Refuses "with no keys at all, a good signature is still refused" "carries no manifest signing keys" {
    $previous = $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE
    try {
        # The shipped state: Get-ManifestKeys returns the empty list compiled
        # into install.ps1.
        $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE = $null
        Test-ManifestSignature $GoodBytes $GoodSignature "local-test" "URL"
    } finally {
        $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE = $previous
    }
}

Assert-Refuses "a key below 3072 bits is refused even when its signature is good" "below the 3072-bit minimum" {
    $previous = $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE
    try {
        $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE = $WeakModulusFile
        Test-ManifestSignature (Get-FixtureBytes "weak-key.json") (Get-FixtureText "weak-key.sig") "local-test" "URL"
    } finally {
        $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE = $previous
    }
}

Assert-Refuses "a key that is not the one that signed is refused" "does not match its bytes" {
    $previous = $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE
    try {
        # Same manifest, same good signature, a different key in the list.
        $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE = $OtherModulusFile
        Test-ManifestSignature $GoodBytes $GoodSignature "local-test" "URL"
    } finally {
        $env:TWINFORGE_DIST_PUBKEY_MODULUS_FILE = $previous
    }
}

Assert-Refuses "an empty signature file is refused" "signature file is empty" {
    Test-ManifestSignature $GoodBytes (Get-FixtureText "empty.sig") "local-test" "URL"
}

Assert-Refuses "a signature that is not base64 is refused" "not one line of base64" {
    Test-ManifestSignature $GoodBytes (Get-FixtureText "not-base64.sig") "local-test" "URL"
}

# [Convert]::FromBase64String ignores whitespace wherever it finds it, so
# without the pattern check in front of it these two would decode happily here
# and be refused by install.sh -- two installers disagreeing about the same
# file.
Assert-Refuses "a signature spread over two lines is refused" "not one line of base64" {
    Test-ManifestSignature $GoodBytes (Get-FixtureText "two-lines.sig") "local-test" "URL"
}

Assert-Refuses "base64 padding in the middle is refused" "not one line of base64" {
    Test-ManifestSignature $GoodBytes (Get-FixtureText "middle-padding.sig") "local-test" "URL"
}

Assert-Accepts "a CRLF-terminated signature file still verifies" {
    Test-ManifestSignature $GoodBytes (Get-FixtureText "crlf.sig") "local-test" "URL"
}

Assert-Refuses "no manifest bytes at all is refused" "no manifest bytes to verify" {
    Test-ManifestSignature ([byte[]]@()) $GoodSignature "local-test" "URL"
}

# --- The signed envelope ---------------------------------------------------------

Assert-Accepts "a well-formed signed manifest passes the envelope checks" {
    $keyId = Assert-SignedManifest (Get-FixtureManifest "good.json") "canary" "URL"
    if ($keyId -ne "local-test") { throw "expected the keyId back, got '$keyId'" }
}

Assert-Refuses "a manifest fetched as another channel is refused" "was fetched as channel" {
    Assert-SignedManifest (Get-FixtureManifest "good.json") "stable" "URL"
}

Assert-Refuses "the channel of a manifest signed for another channel is refused" "was fetched as channel" {
    Assert-SignedManifest (Get-FixtureManifest "wrong-channel.json") "canary" "URL"
}

Assert-Refuses "a manifest with no channel is refused" "has no 'channel'" {
    Assert-SignedManifest (Get-FixtureManifest "no-channel.json") "canary" "URL"
}

Assert-Refuses "schemaVersion 1 -- the unsigned format -- is refused" "only accepts the number 2" {
    Assert-SignedManifest (Get-FixtureManifest "schema-1.json") "canary" "URL"
}

# A *string* "2" is not the number 2, and `-ne 2` alone would have said it was:
# PowerShell coerces the right operand to the left one's type.
Assert-Refuses "schemaVersion as a JSON string is refused" "only accepts the number 2" {
    Assert-SignedManifest (Get-FixtureManifest "schema-string.json") "canary" "URL"
}

Assert-Refuses "a manifest with no keyId is refused" "no way to tell which key signed it" {
    Assert-SignedManifest (Get-FixtureManifest "no-keyid.json") "canary" "URL"
}

Assert-Refuses "a keyId outside the allowed character class is refused" "unusable 'keyId'" {
    Assert-SignedManifest (Get-FixtureManifest "bad-keyid.json") "canary" "URL"
}

# --- That install.ps1 actually calls all this ------------------------------------
# The checks above prove the verifier refuses what it should. A verifier nothing
# invokes is worth exactly nothing, and install.ps1 cannot be run here -- it
# installs TwinForge -- so its wiring is asserted from the text instead: the
# call exists, it is passed the bytes read from disk, and it happens before
# anything the manifest says is used.

$InstallerText = [System.IO.File]::ReadAllText($InstallerPath)

function Assert-Wiring([string]$Label, [bool]$Condition) {
    if ($Condition) { Report-Pass $Label } else { Report-Fail $Label "" }
}

$verifyCall = 'Test-ManifestSignature $ManifestBytes $ManifestSignature $KeyId $ManifestUrl'
$assertCall = 'Assert-SignedManifest $Manifest $Channel $ManifestUrl'
$readBytes = '[System.IO.File]::ReadAllBytes($ManifestFile)'
$versionRead = '$Version = Get-ManifestString $Manifest.version'
$artifactFetch = 'Invoke-WebRequest -Uri $ArtifactUrl'

$verifyAt = $InstallerText.IndexOf($verifyCall)
Assert-Wiring "install.ps1 calls the verifier with the bytes it read from disk" `
    (($verifyAt -ge 0) -and ($InstallerText.IndexOf($readBytes) -ge 0))
Assert-Wiring "install.ps1 checks the envelope before it verifies" `
    (($InstallerText.IndexOf($assertCall) -ge 0) -and ($InstallerText.IndexOf($assertCall) -lt $verifyAt))
Assert-Wiring "install.ps1 verifies before it reads the version" `
    (($InstallerText.IndexOf($versionRead) -gt $verifyAt) -and ($verifyAt -ge 0))
Assert-Wiring "install.ps1 verifies before it downloads the artifact" `
    (($InstallerText.IndexOf($artifactFetch) -gt $verifyAt) -and ($verifyAt -ge 0))
Assert-Wiring "install.ps1 fetches the detached signature" `
    ($InstallerText.IndexOf('$SignatureUrl = "$ManifestUrl.sig"') -ge 0)

# The real Fail, which every refusal above went through in install.ps1 itself:
# it has to be the kind that never returns.
$realFail = $functionAsts | Where-Object { $_.Name -eq 'Fail' } | Select-Object -First 1
if (-not $realFail) {
    Report-Fail "install.ps1 still defines Fail" ""
} else {
    $failBlock = [scriptblock]::Create($realFail.Extent.Text + "`nFail 'test'`n'RETURNED'")
    try {
        $result = & $failBlock 6>&1
        Report-Fail "install.ps1's Fail throws rather than returning" "it returned: $result"
    } catch {
        Report-Pass "install.ps1's Fail throws rather than returning"
    }
}

Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host "all manifest signature checks passed under PowerShell $($PSVersionTable.PSVersion)"
    exit 0
}
Write-Host "$($script:Failures) manifest signature check(s) failed under PowerShell $($PSVersionTable.PSVersion)"
exit $script:Failures
