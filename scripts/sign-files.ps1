<#
.SYNOPSIS
    Authenticode-signs the release binaries with the Certum cloud certificate.

.DESCRIPTION
    Runs after connect-simplysign.ps1 has put the certificate in Cert:\CurrentUser\My; signtool picks it up by
    thumbprint like any other certificate.

    Timestamped, so the binaries stay valid after the certificate expires. The signature is verified before
    returning: signtool exiting 0 and the file carrying a chain that validates are different claims.

.PARAMETER Path
    Files to sign.

.PARAMETER Thumbprint
    SHA-1 thumbprint of the signing certificate. Defaults to $env:CERTUM_CERTIFICATE_SHA1.

.PARAMETER TimestampServer
    RFC 3161 timestamp server. Defaults to $env:CERTUM_TIMESTAMP_SERVER, then Certum's.

.PARAMETER IntermediateUrl
    Where to fetch the intermediate certificate signtool embeds in the chain. Defaults to
    $env:CERTUM_INTERMEDIATE_URL, then Certum's CCSCA 2021 intermediate.

.PARAMETER Description
    signtool /d - the name Windows shows in the UAC and SmartScreen dialogs. Only used for files with no
    FileDescription of their own; a binary with a version resource keeps the string that is in it, so the value
    stays in a single place per project.

.PARAMETER DescriptionUrl
    signtool /du - where "more information" in those dialogs points. Defaults to $env:CERTUM_DESCRIPTION_URL,
    then the repository the build is running out of. A project with a site of its own passes it instead.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Path,

    [string]$Thumbprint = $env:CERTUM_CERTIFICATE_SHA1,
    [string]$TimestampServer = $env:CERTUM_TIMESTAMP_SERVER,
    [string]$IntermediateUrl = $env:CERTUM_INTERMEDIATE_URL,
    [string]$Description,
    [string]$DescriptionUrl = $env:CERTUM_DESCRIPTION_URL
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $Thumbprint) { throw 'No certificate thumbprint. Set CERTUM_CERTIFICATE_SHA1 (see SIGNING.md).' }
if (-not $TimestampServer) { $TimestampServer = 'http://time.certum.pl' }
if (-not $IntermediateUrl) { $IntermediateUrl = 'https://repository.certum.pl/ccsca2021.cer' }

# The repository is where "more information" should land for a project with no site of its own, and the CI knows
# which repository this is - so the common case needs no per-project configuration at all.
if (-not $DescriptionUrl)
{
    if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY)
    {
        $DescriptionUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY"
    }
    elseif ($env:APPVEYOR_REPO_PROVIDER -eq 'gitHub' -and $env:APPVEYOR_REPO_NAME)
    {
        $DescriptionUrl = "https://github.com/$env:APPVEYOR_REPO_NAME"
    }
}

# Strip everything that is not a hex digit: the certificate dialog copies thumbprints with spaces, and a pasted
# value can pick up a newline or BOM. None survive the comparison, and all look like "certificate not found".
$Thumbprint = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()

# setup-msbuild puts MSBuild on PATH but not the SDK tools, so signtool has to be found by hand: newest Windows
# 10/11 SDK, x64 build.
function Get-SignTool
{
    $onPath = Get-Command 'signtool.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    ) | Where-Object { $_ -and (Test-Path $_) }

    $candidates = foreach ($root in $roots)
    {
        Get-ChildItem -Path $root -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq 'x64' }
    }

    # The SDK version is the directory above x64 ("10.0.22621.0"). Older SDKs drop signtool straight into bin\x64,
    # where that name is "bin" and parses as nothing, so those sort last.
    $best = $candidates | Sort-Object -Descending -Property @{ Expression = {
        $v = $null
        if ([version]::TryParse($_.Directory.Parent.Name, [ref]$v)) { $v } else { [version]'0.0' }
    } } | Select-Object -First 1

    if (-not $best) { throw 'signtool.exe not found. Is the Windows SDK installed on this runner?' }
    return $best.FullName
}

$signTool = Get-SignTool
Write-Host "signtool: $signTool"

# X509Store rather than the Cert: drive, same reason as connect-simplysign.ps1: the provider serves a cached view
# within a process, and this runs right after a certificate was registered.
$store = [System.Security.Cryptography.X509Certificates.X509Store]::new('My', 'CurrentUser')
try
{
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    $cert = @($store.Certificates | Where-Object { $_.Thumbprint -eq $Thumbprint })
}
finally
{
    $store.Close()
}
if (-not $cert)
{
    throw "Certificate $Thumbprint is not in CurrentUser\My. Run connect-simplysign.ps1 first, and check that CERTUM_CERTIFICATE_SHA1 is the thumbprint of the certificate that account holds."
}
Write-Host "certificate: $($cert[0].Subject)"
Write-Host "timestamp:   $TimestampServer"

# /ac wants the intermediate as a file. Fetched per run rather than checked in, so the chain stays current if
# Certum re-issues; it is a public certificate.
$intermediate = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) 'certum-intermediate.cer'
Write-Host "Fetching intermediate certificate from $IntermediateUrl"
Invoke-WebRequest -Uri $IntermediateUrl -OutFile $intermediate -UseBasicParsing -TimeoutSec 120

$signArgs = @(
    'sign',
    '/sha1', $Thumbprint,
    '/fd', 'sha256',        # file digest
    '/td', 'sha256',        # timestamp digest
    '/tr', $TimestampServer,
    '/ac', $intermediate,
    '/v'
)

if ($DescriptionUrl) { $signArgs += @('/du', $DescriptionUrl) }

# /d is what Windows puts in the UAC and SmartScreen dialogs; left off it falls back to the file name, so a user
# would be asked to approve a bare "Something-x64.exe" out of the downloads folder. Preferring the binary's own
# FileDescription keeps that string in the version resource rather than in the workflow; only files without one
# fall back to what the caller passed.
function Get-SignDescription
{
    param([string]$File)

    $fileDescription = (Get-Item $File).VersionInfo.FileDescription
    if (-not [string]::IsNullOrWhiteSpace($fileDescription)) { return $fileDescription.Trim() }
    return $Description
}

foreach ($file in $Path)
{
    if (-not (Test-Path $file)) { throw "Nothing to sign at $file" }

    $fileArgs = $signArgs
    $description = Get-SignDescription $file
    if ($description) { $fileArgs += @('/d', $description) }

    $shownAs = if ($description) { " as '$description'" } else { '' }

    Write-Host ''
    Write-Host "Signing $file$shownAs"

    # Timestamp servers rate-limit, and a release should not fall over on one refused request.
    for ($attempt = 1; $attempt -le 3; $attempt++)
    {
        & $signTool @fileArgs $file
        if ($LASTEXITCODE -eq 0) { break }

        if ($attempt -eq 3) { throw "signtool failed on $file after $attempt attempts (exit $LASTEXITCODE)" }
        Write-Host "  signtool exit $LASTEXITCODE, retrying in 15s..."
        Start-Sleep -Seconds 15
    }

    & $signTool verify /pa /v $file
    if ($LASTEXITCODE -ne 0) { throw "$file was signed but the signature does not verify (signtool verify exit $LASTEXITCODE)" }
}

Write-Host ''
Write-Host "Signed and verified $($Path.Count) file(s)."
