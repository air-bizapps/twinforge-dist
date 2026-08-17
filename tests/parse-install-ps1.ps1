# Syntax-only check of install.ps1: does the PowerShell parser accept it?
#
# It runs nothing. install.ps1 downloads a few hundred MiB, rewrites the user
# PATH and creates junctions; the point here is to know that the file is
# well-formed without any of that happening.
#
# This is the single highest-value gate available for a file that has never
# been executed on any machine, and it is worth having under both runtimes:
# .github/workflows/ci.yml runs it under pwsh (PowerShell 7) and under
# `powershell` (Windows PowerShell 5.1), which is what the audience gets from a
# stock Start menu.
#
# ParseFile, not `[scriptblock]::Create` on the text: ParseFile reports the file
# and line of every error, and reports all of them rather than stopping at the
# first.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$target = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    Write-Host "Could not find $target"
    exit 1
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$parseErrors) | Out-Null

if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host "install.ps1 does not parse ($($parseErrors.Count) error(s)):"
    foreach ($parseError in $parseErrors) {
        $extent = $parseError.Extent
        Write-Host ("  {0}:{1}:{2} {3}" -f $extent.File, $extent.StartLineNumber, $extent.StartColumnNumber, $parseError.Message)
    }
    exit 1
}

Write-Host "install.ps1 parses cleanly under PowerShell $($PSVersionTable.PSVersion) ($($tokens.Count) tokens)."
