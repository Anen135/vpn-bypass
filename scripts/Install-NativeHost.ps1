[CmdletBinding()]
param(
    [ValidateSet('Chrome', 'Edge', 'Both')]
    [string] $Browser = 'Both'
)

$ErrorActionPreference = 'Stop'
$HostName = 'dev.vpnbypass.manager'
$ExtensionId = 'alhckcekmoalpnnpokflgpkajcpdbdfi'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$HostProject = Join-Path $ProjectRoot 'native-host\VpnBypass.NativeHost.csproj'
$ManagerScript = Join-Path $ProjectRoot 'native-host\VPN-Bypass-Manager.ps1'
$InstallDirectory = Join-Path $env:LOCALAPPDATA 'VpnBypass\NativeHost'
$PublishDirectory = Join-Path $env:TEMP ('vpn-bypass-publish-' + [Guid]::NewGuid().ToString('N'))

try {
    Write-Host 'Building native messaging host...'
    & dotnet publish $HostProject `
        --configuration Release `
        --runtime win-x64 `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:DebugType=None `
        --output $PublishDirectory

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }

    $null = New-Item -ItemType Directory -Path $InstallDirectory -Force
    Copy-Item -Force -LiteralPath (Join-Path $PublishDirectory 'VpnBypass.NativeHost.exe') -Destination $InstallDirectory
    Copy-Item -Force -LiteralPath $ManagerScript -Destination $InstallDirectory

    $manifestPath = Join-Path $InstallDirectory "$HostName.json"
    $hostPath = Join-Path $InstallDirectory 'VpnBypass.NativeHost.exe'
    $manifest = [ordered]@{
        name            = $HostName
        description     = 'VPN Bypass route manager for Windows'
        path            = $hostPath
        type            = 'stdio'
        allowed_origins = @("chrome-extension://$ExtensionId/")
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($manifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))

    $registryPaths = switch ($Browser) {
        'Chrome' { 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\' + $HostName }
        'Edge' { 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\' + $HostName }
        'Both' {
            'HKCU:\Software\Google\Chrome\NativeMessagingHosts\' + $HostName
            'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\' + $HostName
        }
    }

    foreach ($registryPath in $registryPaths) {
        $null = New-Item -Path $registryPath -Force
        Set-Item -Path $registryPath -Value $manifestPath
    }

    Write-Host ''
    Write-Host 'Native host installed successfully.' -ForegroundColor Green
    Write-Host "Expected extension ID: $ExtensionId"
    Write-Host "Load this unpacked extension: $(Join-Path $ProjectRoot 'extension')"
}
finally {
    if (Test-Path -LiteralPath $PublishDirectory) {
        Remove-Item -Recurse -Force -LiteralPath $PublishDirectory
    }
}
