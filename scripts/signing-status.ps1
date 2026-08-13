<#
.SYNOPSIS
    Says, loudly, whether the release binaries came out signed or not.

.DESCRIPTION
    Signing is optional - a repository without the Certum settings still produces a release, just an unsigned one -
    so "is this build signed?" is answered everywhere it might be looked for:

      - a workflow annotation, at the top of the run page (GitHub Actions)
      - a per-file table in the job summary, with signer and timestamp (GitHub Actions)
      - a build message on the Messages tab, which survives the log scrolling past (AppVeyor)
      - a markdown block for the release notes
      - SIGNING_STATUS / SIGNING_SUMMARY / SIGNING_NOTES, for the steps that follow

    The state is read off the files rather than inferred from "the signing step ran".

.PARAMETER Path
    The downloads. These alone decide the reported state.

.PARAMETER EmbeddedPath
    Helpers extracted back out of the downloads. Checked but not counted: nobody downloads them, and an unsigned
    helper in an unsigned release is not news. A signed download carrying an unsigned one is - that is the signing
    order having broken - so that case alone fails the run.

.PARAMETER NotesPath
    Where to write the markdown block for the release notes. Skipped when not given.

.PARAMETER RequireSigned
    Fail when a download is not validly signed. Set when signing was supposed to happen, so a half-signed release
    cannot quietly ship.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Path,

    [string[]]$EmbeddedPath,
    [string]$NotesPath,
    [switch]$RequireSigned
)

$ErrorActionPreference = 'Stop'

function Get-SignatureInfo
{
    param([string[]]$File)

    foreach ($f in $File)
    {
        if (-not (Test-Path $f)) { throw "No such file: $f" }

        $sig = Get-AuthenticodeSignature -FilePath $f
        $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }

        # The common name is what a person recognises; the whole DN is noise in a table.
        $shortSigner = if ($signer -and $signer -match 'CN=(?<cn>[^,]+)') { $Matches.cn.Trim('"') } else { $signer }

        # Stamped is one-way: true means timestamped, false means nobody knows. TimeStamperCertificate is only
        # filled in for the legacy counter-signature format on older Windows - the AppVeyor images report nothing
        # for the RFC 3161 token sign-files.ps1's /tr produces, though signtool verify in that same build prints
        # it happily. So an absent value is reported as absent knowledge, not as a binary that will expire with
        # its certificate.
        [pscustomobject]@{
            Name    = Split-Path $f -Leaf
            Status  = $sig.Status.ToString()
            Signed  = $sig.Status -eq 'Valid'
            Signer  = $shortSigner
            Stamped = [bool]$sig.TimeStamperCertificate
        }
    }
}

$results = @(Get-SignatureInfo $Path)
$embedded = @(if ($EmbeddedPath) { Get-SignatureInfo $EmbeddedPath })

$signedCount = @($results | Where-Object Signed).Count
$total = $results.Count

$state = if ($signedCount -eq $total) { 'signed' } elseif ($signedCount -eq 0) { 'unsigned' } else { 'partial' }
$noun = "release " + $(if ($total -eq 1) { 'binary' } else { 'binaries' })

$summary = switch ($state)
{
    'signed'   { "SIGNED - valid Authenticode signature on $signedCount of $total $noun" }
    'unsigned' { "NOT SIGNED - no Authenticode signature on any of the $total $noun" }
    'partial'  { "PARTIALLY SIGNED - valid Authenticode signature on only $signedCount of $total $noun" }
}

# A signed download whose helper is not signed means the helper was signed too late, or relinked after it was.
# Unsigned either side of that is just an unsigned release.
$orphans = @(if ($signedCount) { $embedded | Where-Object { -not $_.Signed } })

# --- console ---------------------------------------------------------------------------------------------------

function Write-Row
{
    param($Result)

    $mark = if ($Result.Signed) { 'SIGNED  ' } else { 'UNSIGNED' }
    $detail = if ($Result.Signed) { "$($Result.Signer)$(if ($Result.Stamped) { ' (timestamped)' })" } else { $Result.Status }
    Write-Host ("  {0}  {1,-36}  {2}" -f $mark, $Result.Name, $detail)
}

$rule = '=' * 100
Write-Host ''
Write-Host $rule
Write-Host "  AUTHENTICODE: $summary"
Write-Host $rule
foreach ($r in $results) { Write-Row $r }
if ($orphans.Count)
{
    Write-Host "  -- embedded, and left unsigned by a signed release --"
    foreach ($r in $orphans) { Write-Row $r }
}
Write-Host $rule
Write-Host ''

# --- release notes ---------------------------------------------------------------------------------------------

# Nothing about the helpers here: a release that got as far as being published has them signed, because the
# mismatch below fails the run.
$notes = switch ($state)
{
    'signed'
    {
        @(
            "> **Signed release.** Signed by ``$($results[0].Signer)``."
        )
    }
    'unsigned'
    {
        @(
            '> **Unsigned release.** No Authenticode signature, so SmartScreen will warn.',
            '> Verify against `SHA256SUMS.txt` instead.'
        )
    }
    'partial'
    {
        @(
            "> **Partially signed release.** Only $signedCount of $total $noun came out signed.",
            '> Check each download, and verify all of them against `SHA256SUMS.txt`.'
        )
    }
}

if ($NotesPath)
{
    Set-Content -Path $NotesPath -Value (($notes -join "`n") + "`n") -Encoding UTF8
    Write-Host "Release-notes block written to $NotesPath"
}

# --- GitHub Actions --------------------------------------------------------------------------------------------

# Annotations show up at the top of the run page, above the job list. No green notice next to the error below -
# the downloads being signed is not good news when what they carry is not.
if ($env:GITHUB_ACTIONS)
{
    if ($state -eq 'signed' -and -not $orphans.Count)
    {
        Write-Host "::notice title=Code signing::$summary"
    }
    else
    {
        Write-Host "::warning title=Code signing::$summary"
    }

    if ($orphans.Count)
    {
        Write-Host "::error title=Embedded helper::$($orphans.Count) embedded helper(s) unsigned inside a signed release: $(($orphans.Name) -join ', ')"
    }
}

if ($env:GITHUB_STEP_SUMMARY)
{
    $lines = @(
        "## Code signing: $summary",
        '',
        '| File | Authenticode | Signer | Timestamped |',
        '| --- | --- | --- | --- |'
    )
    foreach ($r in $results + $orphans)
    {
        $badge = if ($r.Signed) { '**signed**' } else { "**not signed** (``$($r.Status)``)" }
        $lines += "| ``$($r.Name)`` | $badge | $(if ($r.Signer) { $r.Signer } else { '-' }) | $(if ($r.Stamped) { 'yes' } else { 'not reported' }) |"
    }
    if ($orphans.Count)
    {
        $lines += ''
        $lines += 'The helper embedded in a signed binary is itself unsigned. It is signed before the build that embeds it, so this means the order broke - see `SIGNING.md`.'
    }
    if ($state -ne 'signed')
    {
        $lines += ''
        $lines += if ($RequireSigned)
        {
            'Signing was configured for this repository but did not take - see the signing steps above.'
        }
        else
        {
            'Unsigned because the Certum settings are not configured for this repository - see `SIGNING.md`.'
        }
    }
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n")
}

if ($env:GITHUB_ENV)
{
    Add-Content -Path $env:GITHUB_ENV -Value "SIGNING_STATUS=$state"
    Add-Content -Path $env:GITHUB_ENV -Value "SIGNING_SUMMARY=$summary"
}

# Step outputs as well as the environment, so a composite action can hand them back to the calling workflow.
if ($env:GITHUB_OUTPUT)
{
    Add-Content -Path $env:GITHUB_OUTPUT -Value "status=$state"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "summary=$summary"
}

# --- AppVeyor --------------------------------------------------------------------------------------------------

# The Messages tab survives the log scrolling past.
if ($env:APPVEYOR)
{
    $category = if ($state -eq 'signed' -and -not $orphans.Count) { 'Information' } else { 'Warning' }
    $detail = ($results + $orphans | ForEach-Object {
        "$($_.Name): $(if ($_.Signed) { "signed by $($_.Signer)$(if ($_.Stamped) { ', timestamped' })" } else { "not signed ($($_.Status))" })"
    }) -join '; '

    # A message that fails to post is no reason to fail a release; the throw at the end enforces things.
    try
    {
        Add-AppveyorMessage "Code signing: $summary" -Category $category -Details $detail
    }
    catch
    {
        Write-Host "Could not post the AppVeyor build message: $($_.Exception.Message)"
    }

    # Build variables, not $env:, so the deploy step can expand them as $(SIGNING_NOTES). One line: the release
    # description is a single field.
    Set-AppveyorBuildVariable -Name 'SIGNING_STATUS' -Value $state
    Set-AppveyorBuildVariable -Name 'SIGNING_SUMMARY' -Value $summary
    Set-AppveyorBuildVariable -Name 'SIGNING_NOTES' -Value (($notes -replace '^> ', '') -join ' ')
}

# --- verdict ---------------------------------------------------------------------------------------------------

# Unconditional: this can only happen when signing ran, and what it produced is a download that vouches for an
# unsigned executable it writes to disk at run time.
if ($orphans.Count)
{
    throw "$($orphans.Count) embedded helper(s) came out unsigned in a signed release: $(($orphans.Name) -join ', '). The helpers are signed before the build that embeds them; check that ordering."
}

if ($RequireSigned -and $state -ne 'signed')
{
    throw "Signing was expected but the result is '$state'. Refusing to publish a release that claims to be signed and is not."
}
