<#
.SYNOPSIS
    Installs Certum SimplySign Desktop, the virtual smart-card reader the cloud certificate lives behind.

.DESCRIPTION
    The code signing certificate sits in Certum's cloud HSM, which signtool cannot reach. SimplySign Desktop
    emulates a local smart card reader for it: once the session is connected (connect-simplysign.ps1) the
    certificate appears in Cert:\CurrentUser\My and signtool uses it by thumbprint like any other.

    The MSI is pinned by version and SHA-256: the hash says the bytes are the ones that were reviewed. Bumping the
    version means replacing both together.

.PARAMETER Force
    Install again even when SimplySign Desktop is already present.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar makes a 260 MB download crawl in CI

# Installer version, not the executable's: this MSI ships SimplySignDesktop.exe 7.6.90.0, an unrelated number.
# Hash verified against files.certum.eu; the MSI is EV-signed by Asseco Data Systems, Certum's operator.
$Version = '9.4.3.90'
$Url = "https://files.certum.eu/software/SimplySignDesktop/Windows/$Version/SimplySignDesktop-$Version-64-bit-en.msi"
$Sha256 = 'CE2B38EF0124A574BC08E5558726099CAAC79A7C58B8D3D712F629371FE1BCB7'

$InstallDir = Join-Path $env:ProgramFiles 'Certum\SimplySign Desktop'
$Exe = Join-Path $InstallDir 'SimplySignDesktop.exe'

if ((Test-Path $Exe) -and -not $Force)
{
    Write-Host "SimplySign Desktop already installed at $Exe"
    exit 0
}

$Work = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$Installer = Join-Path $Work 'SimplySignDesktop.msi'
$Log = Join-Path $Work 'simplysign-install.log'

Write-Host "Downloading SimplySign Desktop $Version..."
Invoke-WebRequest -Uri $Url -OutFile $Installer -UseBasicParsing -TimeoutSec 600

$actual = (Get-FileHash $Installer -Algorithm SHA256).Hash
if ($actual -ne $Sha256)
{
    throw "SimplySignDesktop-$Version does not match the pinned hash.`n  expected $Sha256`n  actual   $actual`nIf Certum re-published the installer on purpose, update `$Sha256 in this script too."
}
Write-Host "Hash verified ($Sha256)"

Write-Host 'Installing (quiet, no restart)...'
$msiArgs = @('/i', "`"$Installer`"", '/quiet', '/norestart', '/l*v', "`"$Log`"", 'ALLUSERS=1', 'REBOOT=ReallySuppress')
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

# 3010 is "success, a reboot would be nice". The driver is usable without one.
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010)
{
    Write-Host "msiexec exited with $($proc.ExitCode). Last 40 lines of the install log:"
    if (Test-Path $Log) { Get-Content $Log -Tail 40 | ForEach-Object { Write-Host "  $_" } }
    throw "SimplySign Desktop installation failed (msiexec exit $($proc.ExitCode))"
}

if (-not (Test-Path $Exe))
{
    throw "msiexec reported success but $Exe is not there. The installer layout changed; update this script with it."
}

Write-Host "SimplySign Desktop $Version installed -> $Exe"
