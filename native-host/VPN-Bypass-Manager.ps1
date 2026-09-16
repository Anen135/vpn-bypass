[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('add', 'remove')]
    [string] $Action,

    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 253)]
    [string] $Target,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'
$RouteMetric = 7
$StateDirectory = Join-Path $env:ProgramData 'VpnBypassManager'
$StatePath = Join-Path $StateDirectory 'routes.json'

function Write-OperationResult {
    param(
        [Parameter(Mandatory = $true)] [bool] $Ok,
        [Parameter(Mandatory = $true)] [bool] $Changed,
        [string[]] $Addresses = @(),
        [string] $ErrorMessage = $null
    )

    $result = [ordered]@{
        ok        = $Ok
        changed   = $Changed
        addresses = @($Addresses)
        error     = $ErrorMessage
    }

    $json = $result | ConvertTo-Json -Compress -Depth 4
    [IO.File]::WriteAllText($ResultPath, $json, [Text.UTF8Encoding]::new($false))
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'PowerShell must run as Administrator.'
    }
}

function Assert-Target {
    param([string] $Name)

    $normalized = $Name.Trim().TrimEnd('.').ToLowerInvariant()
    if ([Uri]::CheckHostName($normalized) -ne [UriHostNameType]::Dns -or -not $normalized.Contains('.')) {
        throw 'Target must be a valid DNS hostname.'
    }
    return $normalized
}

function Get-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [PSCustomObject]@{ Version = 1; Entries = @() }
    }

    try {
        $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $StatePath | ConvertFrom-Json
        if ($null -eq $state.Entries) {
            $state | Add-Member -MemberType NoteProperty -Name Entries -Value @() -Force
        }
        $state.Entries = @($state.Entries)
        return $state
    }
    catch {
        throw "Cannot read route state: $($_.Exception.Message)"
    }
}

function Save-State {
    param([Parameter(Mandatory = $true)] $State)

    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        $null = New-Item -ItemType Directory -Path $StateDirectory -Force
    }

    $temporaryPath = "$StatePath.tmp"
    $json = $State | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -Force -LiteralPath $temporaryPath -Destination $StatePath
}

function Get-RouteKey {
    param($Entry)
    return '{0}|{1}|{2}|{3}' -f $Entry.Prefix, $Entry.InterfaceIndex, $Entry.NextHop, $Entry.RouteMetric
}

function Get-PhysicalDefaultRoute {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('IPv4', 'IPv6')]
        [string] $AddressFamily
    )

    $defaultPrefix = if ($AddressFamily -eq 'IPv4') { '0.0.0.0/0' } else { '::/0' }
    $emptyNextHop = if ($AddressFamily -eq 'IPv4') { '0.0.0.0' } else { '::' }
    $candidates = foreach ($route in @(Get-NetRoute -AddressFamily $AddressFamily -DestinationPrefix $defaultPrefix -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
        if ($route.NextHop -eq $emptyNextHop) {
            continue
        }

        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if ($null -eq $adapter -or $adapter.Status -ne 'Up' -or -not $adapter.HardwareInterface) {
            continue
        }

        $ipInterface = Get-NetIPInterface -AddressFamily $AddressFamily -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        $interfaceMetric = if ($null -eq $ipInterface) { 0 } else { [int] $ipInterface.InterfaceMetric }
        [PSCustomObject]@{
            Gateway        = [string] $route.NextHop
            InterfaceIndex = [int] $route.InterfaceIndex
            TotalMetric    = [int] $route.RouteMetric + $interfaceMetric
        }
    }

    return $candidates | Sort-Object TotalMetric | Select-Object -First 1
}

function Remove-ManagedEntries {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $targetEntries = @($State.Entries | Where-Object { $_.Target -eq $Name })
    $remainingEntries = @($State.Entries | Where-Object { $_.Target -ne $Name })
    $changed = $false

    foreach ($entry in $targetEntries) {
        if (-not $entry.Managed) {
            continue
        }

        $key = Get-RouteKey $entry
        $stillReferenced = $remainingEntries | Where-Object { $_.Managed -and (Get-RouteKey $_) -eq $key } | Select-Object -First 1
        if ($null -ne $stillReferenced) {
            continue
        }

        foreach ($store in @('ActiveStore', 'PersistentStore')) {
            $routes = Get-NetRoute -DestinationPrefix $entry.Prefix `
                -InterfaceIndex $entry.InterfaceIndex `
                -NextHop $entry.NextHop `
                -PolicyStore $store `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.RouteMetric -eq $entry.RouteMetric }

            if ($routes) {
                $null = @($routes | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue)
                $changed = $true
            }
        }
    }

    $State.Entries = $remainingEntries
    return $changed
}

function Add-TargetRoutes {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $changed = Remove-ManagedEntries -State $State -Name $Name
    Save-State -State $State

    $addresses = @([Net.Dns]::GetHostAddresses($Name) |
        Where-Object { $_.AddressFamily -in @([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.AddressFamily]::InterNetworkV6) } |
        Sort-Object IPAddressToString -Unique)

    if ($addresses.Count -eq 0) {
        throw "The domain $Name has no IPv4 or IPv6 addresses."
    }

    $addedAddresses = [Collections.Generic.List[string]]::new()
    foreach ($address in $addresses) {
        $family = if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 'IPv4' } else { 'IPv6' }
        $prefixLength = if ($family -eq 'IPv4') { 32 } else { 128 }
        $routeInfo = Get-PhysicalDefaultRoute -AddressFamily $family
        if ($null -eq $routeInfo) {
            continue
        }

        $prefix = '{0}/{1}' -f $address.IPAddressToString, $prefixLength
        $matchingStateEntry = $State.Entries | Where-Object {
            $_.Managed -and
            $_.Prefix -eq $prefix -and
            $_.InterfaceIndex -eq $routeInfo.InterfaceIndex -and
            $_.NextHop -eq $routeInfo.Gateway -and
            $_.RouteMetric -eq $RouteMetric
        } | Select-Object -First 1

        $existingRoute = Get-NetRoute -DestinationPrefix $prefix `
            -InterfaceIndex $routeInfo.InterfaceIndex `
            -NextHop $routeInfo.Gateway `
            -PolicyStore ActiveStore `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.RouteMetric -eq $RouteMetric } |
            Select-Object -First 1

        $managed = $null -ne $matchingStateEntry
        if ($null -eq $existingRoute) {
            $null = New-NetRoute -DestinationPrefix $prefix `
                -InterfaceIndex $routeInfo.InterfaceIndex `
                -NextHop $routeInfo.Gateway `
                -RouteMetric $RouteMetric `
                -ErrorAction Stop
            $managed = $true
            $changed = $true
        }

        $State.Entries += [PSCustomObject]@{
            Target         = $Name
            Prefix         = $prefix
            InterfaceIndex = [int] $routeInfo.InterfaceIndex
            NextHop        = [string] $routeInfo.Gateway
            RouteMetric    = $RouteMetric
            Managed        = $managed
        }
        Save-State -State $State
        $addedAddresses.Add($address.IPAddressToString)
    }

    if ($addedAddresses.Count -eq 0) {
        throw 'No physical default route is available for the resolved addresses.'
    }

    return [PSCustomObject]@{
        Changed   = $changed
        Addresses = $addedAddresses.ToArray()
    }
}

try {
    Assert-Administrator
    $Target = Assert-Target -Name $Target
    $state = Get-State

    if ($Action -eq 'add') {
        $operation = Add-TargetRoutes -State $state -Name $Target
        Write-OperationResult -Ok $true -Changed $operation.Changed -Addresses $operation.Addresses
    }
    else {
        $knownAddresses = @($state.Entries |
            Where-Object { $_.Target -eq $Target } |
            ForEach-Object { ($_.Prefix -split '/')[0] })
        $changed = Remove-ManagedEntries -State $state -Name $Target
        Save-State -State $state
        Write-OperationResult -Ok $true -Changed $changed -Addresses $knownAddresses
    }
}
catch {
    Write-OperationResult -Ok $false -Changed $false -ErrorMessage $_.Exception.Message
    exit 1
}
