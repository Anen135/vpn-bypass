[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$HostName = 'dev.vpnbypass.manager'
$InstallDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'VpnBypass\NativeHost'))
$ExpectedParent = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'VpnBypass'))

if (-not $InstallDirectory.StartsWith($ExpectedParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to remove a directory outside the expected installation location.'
}

foreach ($registryPath in @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts\' + $HostName,
    'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\' + $HostName
)) {
    if (Test-Path -LiteralPath $registryPath) {
        Remove-Item -Recurse -Force -LiteralPath $registryPath
    }
}

if (Test-Path -LiteralPath $InstallDirectory) {
    Remove-Item -Recurse -Force -LiteralPath $InstallDirectory
}

Write-Host 'Native host registration and program files were removed.' -ForegroundColor Green
Write-Host 'Managed Windows routes remain until you enable VPN for those sites in the extension.' -ForegroundColor Yellow
