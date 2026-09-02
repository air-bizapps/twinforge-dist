# install.ps1's platform detection, run rather than parsed.
#
# This exists because of a bug that a parser, a linter and a human reader all
# looked straight past. The installer said this, on a healthy x64 Windows 11
# machine running the documented `irm ... | iex`:
#
#     Unsupported platform: windows/
#     Supported platforms: win-x64. Other Windows architectures are not built yet.
#
# The architecture is missing from that sentence because the value was $null.
# install.ps1 read it from
# [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture, and a
# type literal binds against the assemblies loaded in the *caller's own
# session* -- which, for `irm ... | iex`, is the developer's live session and
# not ours. PSReadLine 2.0.0 carries an internal type of that exact name with
# only IsOSPlatform and OSDescription on it, and Windows PowerShell loads
# PSReadLine into every interactive session. Evidence from the affected session:
#
#     [System.Runtime.InteropServices.RuntimeInformation].Assembly.Location
#       -> ...\Modules\PSReadLine\2.0.0\Microsoft.PowerShell.PSReadLine.dll
#     ...GetMember('OSArchitecture').Count  -> 0
#
# and Windows PowerShell 5.1 answers a missing static *property* with $null in
# complete silence, even under $ErrorActionPreference = "Stop".
#
# What is NOT tested here is that shadowing itself. It could not be synthesised
# in a fresh process: Add-Type in memory, Add-Type -OutputAssembly followed by
# Assembly.LoadFrom, and Import-Module over a binary module were each tried on
# the affected machine and mscorlib won every time. Only PowerShell's own module
# loading reproduces it, and CI's PSReadLine is a version without the shim, so a
# test built on it would pass everywhere for the wrong reason. The invariant is
# asserted directly instead, at the bottom: install.ps1 names no such type at
# all. That is the property that makes the class of bug impossible rather than
# merely unlikely, and it is checkable from here.

$ErrorActionPreference = "Stop"

$InstallerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    Write-Host "Could not find $InstallerPath"
    exit 1
}

# --- Reaching into install.ps1 --------------------------------------------------
# Same approach as signature-test.ps1: the functions are lifted out by name
# through the parser, from the real text of the real file, because dot-sourcing
# install.ps1 would run the install.

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host "install.ps1 does not parse; tests/parse-install-ps1.ps1 has the details."
    exit 1
}
$InstallerText = [System.IO.File]::ReadAllText($InstallerPath)
$functionAsts = $ast.FindAll(
    { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

foreach ($wanted in @('Test-WindowsHost', 'Get-HostArchitecture')) {
    $found = $functionAsts | Where-Object { $_.Name -eq $wanted } | Select-Object -First 1
    if (-not $found) {
        Write-Host "install.ps1 no longer defines $wanted, so this test is checking nothing. Update it."
        exit 1
    }
    . ([scriptblock]::Create($found.Extent.Text))
}

# --- Reporting ------------------------------------------------------------------

$script:Failures = 0
function Report-Pass([string]$Label) { Write-Host "ok   $Label" }
function Report-Fail([string]$Label, [string]$Detail) {
    Write-Host "FAIL $Label"
    if ($Detail) { Write-Host "       $Detail" }
    $script:Failures++
}
function Assert-Equal([string]$Label, $Expected, $Actual) {
    if ($Expected -eq $Actual) { Report-Pass $Label }
    else { Report-Fail $Label "expected [$Expected], got [$Actual]" }
}
function Assert-True([string]$Label, [bool]$Condition) {
    if ($Condition) { Report-Pass $Label } else { Report-Fail $Label "" }
}

# --- Architecture, over the environment the OS actually sets --------------------
# The process environment is global, so every case restores it.

$savedArch = $env:PROCESSOR_ARCHITECTURE
$savedArch6432 = $env:PROCESSOR_ARCHITEW6432

function Set-ArchEnv($Architecture, $Architew6432) {
    if ($null -eq $Architecture) { Remove-Item Env:PROCESSOR_ARCHITECTURE -ErrorAction SilentlyContinue }
    else { $env:PROCESSOR_ARCHITECTURE = $Architecture }
    if ($null -eq $Architew6432) { Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue }
    else { $env:PROCESSOR_ARCHITEW6432 = $Architew6432 }
}

try {
    Set-ArchEnv "AMD64" $null
    Assert-Equal "AMD64 is win-x64" "x64" (Get-HostArchitecture)

    # A 32-bit powershell.exe out of SysWOW64 on a 64-bit machine. Without
    # PROCESSOR_ARCHITEW6432 this reads as x86 and a supported machine is
    # refused -- the same false negative this whole file is about, arriving by
    # a different road.
    Set-ArchEnv "x86" "AMD64"
    Assert-Equal "WOW64 (x86 process, AMD64 machine) is win-x64" "x64" (Get-HostArchitecture)

    Set-ArchEnv "ARM64" $null
    Assert-Equal "ARM64 is arm64, not x64" "arm64" (Get-HostArchitecture)

    # ARM64 running the x86 emulator: the machine is still ARM64 and must not be
    # sold a win-x64 build.
    Set-ArchEnv "x86" "ARM64"
    Assert-Equal "emulated x86 on ARM64 is arm64" "arm64" (Get-HostArchitecture)

    Set-ArchEnv "x86" $null
    Assert-Equal "a genuinely 32-bit machine is x86" "x86" (Get-HostArchitecture)

    Set-ArchEnv "amd64" $null
    Assert-Equal "the match is case-insensitive" "x64" (Get-HostArchitecture)

    Set-ArchEnv " AMD64 " $null
    Assert-Equal "surrounding whitespace is trimmed" "x64" (Get-HostArchitecture)

    # The regression, stated as behaviour: an undetectable architecture must
    # come back as nothing, so the caller can say "could not find out" instead
    # of naming an architecture it never read. The old code could not tell the
    # two apart -- that is exactly how it came to print "windows/".
    Set-ArchEnv $null $null
    Assert-True "neither variable set yields nothing, not a bogus tag" ($null -eq (Get-HostArchitecture))

    Set-ArchEnv "   " $null
    Assert-True "a whitespace-only value yields nothing" ($null -eq (Get-HostArchitecture))

    Set-ArchEnv "" ""
    Assert-True "empty values yield nothing" ($null -eq (Get-HostArchitecture))
} finally {
    Set-ArchEnv $savedArch $savedArch6432
}

# The machine this test runs on. CI runs it on windows-latest under both
# runtimes, so a build that cannot identify its own runner is a failure.
Assert-Equal "this runner is detected as win-x64" "x64" (Get-HostArchitecture)
Assert-True "this runner is detected as Windows" (Test-WindowsHost)

# --- Which host counts as Windows ----------------------------------------------
# Driven through Test-WindowsHost's parameters because $PSVersionTable is
# read-only: an earlier attempt to fake an edition by assigning to it failed
# silently on the rebind and then *mutated the real table* through
# $PSVersionTable.PSEdition = ..., which quietly poisoned every case after it.
# The parameters exist so that cannot happen again.
#
# The last row is the one with teeth. PSEdition arrived in PowerShell 5.1, so on
# 5.0 and earlier it is absent, and a first version of this function tested for
# "Desktop" and therefore answered "not Windows" on a Windows machine -- the
# same lie as the bug at the top of this file, wearing a different hat.

Assert-True  "Windows PowerShell 5.1 is a Windows host" (Test-WindowsHost "Desktop" $null)
Assert-True  "PowerShell 7 on Windows is a Windows host" (Test-WindowsHost "Core" $true)
Assert-True  "PowerShell 7 on Linux or macOS is not" (-not (Test-WindowsHost "Core" $false))
Assert-True  "a host too old to report PSEdition is still Windows" (Test-WindowsHost "" $null)

# --- ...and survives the caller having StrictMode on ----------------------------
# Called with no arguments, so the defaults are bound -- which is the whole
# point. A default parameter value is evaluated at binding time, before the body
# runs, so `$WindowsFlag = $IsWindows` is read on 5.1 even though the first
# branch would have returned without it. Under StrictMode that read throws, and
# `irm ... | iex` runs install.ps1 in the caller's own session, so their profile
# decides. A first version of this function had the bare variable and refused a
# healthy Windows machine with:
#
#     A variável '$IsWindows' não pode ser recuperada porque ainda não foi definida.
#
# StrictMode is set in a child scope so it does not leak into the rest of this
# file; it is dynamically scoped, so the call below still runs under it. Verified
# to go red against the bare-variable version -- without that, this shape would
# be a test that passes because it never reaches the hazard.
#
# Neither Assert-Equal nor Assert-True is used here, and that is not fussiness.
# Both compare through a boolean coercion -- `$true -eq "threw: ..."` is $true,
# because a non-empty string casts to $true -- so handing either of them the
# caught message produces a pass. The first version of this test did exactly
# that and reported "ok" against the bare-variable install.ps1.
$strictError = $null
$strictOk = & {
    Set-StrictMode -Version Latest
    try { [bool](Test-WindowsHost) } catch { $script:strictError = $_.Exception.Message; $false }
}
if ($strictOk -eq $true) { Report-Pass "detection survives a caller with StrictMode on" }
else { Report-Fail "detection survives a caller with StrictMode on" $strictError }

# --- The two refusals are different sentences -----------------------------------
# "I could not determine your architecture" and "your architecture is not built
# yet" are different facts and send the reader to different places. The bug this
# file documents was the first being reported as the second.

Assert-True "install.ps1 refuses separately when the architecture is unknown" `
    ($InstallerText.IndexOf('Could not determine this machine') -ge 0)
Assert-True "install.ps1 still refuses an architecture that is not x64" `
    ($InstallerText.IndexOf('Unsupported platform: windows/') -ge 0)

# --- The invariant: no platform fact comes from a caller-resolved type ----------
# Asserted over the AST, not the text, so the explanatory comments above the
# code -- which necessarily name the type -- are invisible to it.

$typeNames = $ast.FindAll(
    { $args[0] -is [System.Management.Automation.Language.TypeExpressionAst] }, $true) |
    ForEach-Object { $_.TypeName.FullName }
$offenders = @($typeNames | Where-Object { $_ -match 'RuntimeInformation|OSPlatform|InteropServices\.Architecture' })

if ($offenders.Count -gt 0) {
    Report-Fail "install.ps1 resolves no platform type out of the caller's session" `
        ("it names $($offenders -join ', '). A type literal binds against the assemblies loaded in " +
         "the session running the documented irm-pipe-iex, and PSReadLine 2.0.0 ships its own " +
         "System.Runtime.InteropServices.RuntimeInformation with no OSArchitecture on it. Read the " +
         "architecture from PROCESSOR_ARCHITEW6432/PROCESSOR_ARCHITECTURE instead.")
} else {
    Report-Pass "install.ps1 resolves no platform type out of the caller's session"
}

Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host "all platform detection checks passed under PowerShell $($PSVersionTable.PSVersion)"
    exit 0
}
Write-Host "$($script:Failures) platform detection check(s) failed under PowerShell $($PSVersionTable.PSVersion)"
exit $script:Failures
