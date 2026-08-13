<#
.SYNOPSIS
    Points SimplySign Desktop's settings at unattended use, before it is ever started.

.DESCRIPTION
    SimplySign Desktop is a tray application built for a human. connect-simplysign.ps1 logs in through /autologin
    rather than the dialog, so the dialog settings here are only a fallback if a future version drops that flag.

    The load-bearing values are the rest: they keep the session usable for a whole build without a second prompt -
    the PIN stays in the CSP while connected, and the certificate is not pulled out of the store on disconnect.

.PARAMETER VerifyOnly
    Report what is set and exit non-zero if it does not match, without writing anything.
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

$RegistryPath = 'HKCU:\Software\Certum\SimplySign'

$Settings = [ordered]@{
    # Without these the login dialog never appears and there is nothing to type into.
    ShowLoginDialogOnStart      = 1
    ShowLoginDialogOnAppRequest = 1
    # Nothing about this account should outlive the runner.
    RememberLastUserName        = 0
    Autostart                   = 0
    # Certificate in the store and PIN in the CSP for as long as the session is up, or signtool prompts per file.
    UnregisterCertificatesOnDisconnect = 0
    RememberPINinCSP            = 1
    ForgetPINinCSPonDisconnect  = 1
    # English UI, so window titles match what connect-simplysign.ps1 expects.
    LangID                      = 9
}

function Get-Setting
{
    param([string]$Name)

    try
    {
        return (Get-ItemProperty -Path $RegistryPath -Name $Name -ErrorAction Stop).$Name
    }
    catch
    {
        return $null
    }
}

if ($VerifyOnly)
{
    $bad = @()
    foreach ($name in $Settings.Keys)
    {
        $actual = Get-Setting $name
        $state = if ($actual -eq $Settings[$name]) { 'ok' } else { 'MISMATCH' }
        Write-Host ("  {0,-34} expected {1}, actual {2} [{3}]" -f $name, $Settings[$name], $(if ($null -eq $actual) { '<unset>' } else { $actual }), $state)
        if ($actual -ne $Settings[$name]) { $bad += $name }
    }
    if ($bad.Count)
    {
        throw "SimplySign is not configured for unattended use: $($bad -join ', ')"
    }
    Write-Host 'SimplySign registry configuration verified.'
    exit 0
}

if (-not (Test-Path $RegistryPath))
{
    New-Item -Path $RegistryPath -Force | Out-Null
}

foreach ($name in $Settings.Keys)
{
    Set-ItemProperty -Path $RegistryPath -Name $name -Value $Settings[$name] -Type DWord
    Write-Host ("  {0,-34} = {1}" -f $name, $Settings[$name])
}

foreach ($name in $Settings.Keys)
{
    $actual = Get-Setting $name
    if ($actual -ne $Settings[$name])
    {
        throw "Failed to set $name (wanted $($Settings[$name]), read back $actual)"
    }
}

Write-Host "SimplySign configured for unattended use under $RegistryPath"
