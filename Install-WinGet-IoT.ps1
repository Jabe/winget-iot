#Requires -Version 5.1
<#
.SYNOPSIS
    Install winget (Windows Package Manager) on Windows 11 IoT Enterprise
    without the Microsoft Store, including dependencies and the license.

.DESCRIPTION
    Target: Windows 11 IoT Enterprise / LTSC (no Store).
    Downloads the latest stable GitHub release of microsoft/winget-cli,
    installs the matching architecture dependencies (VCLibs, UWPDesktop,
    Windows App Runtime) plus Microsoft.UI.Xaml.2.8 (per Microsoft IoT docs)
    and provisions DesktopAppInstaller for all users with License1.xml.

    Without VCLibs / WinAppRuntime / UI.Xaml the install often fails silently
    -- winget.exe never appears under WindowsApps.

.PARAMETER OfflineDir
    Folder of already-downloaded files (air-gapped IoT).
    Expected:
      - Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
      - *License1.xml
      - DesktopAppInstaller_Dependencies.zip
      optional: Microsoft.UI.Xaml.2.8.<arch>.appx
      optional: source.msix

.PARAMETER SkipUiXaml
    Do not download extra UI.Xaml 2.8 (newer winget releases pull WinAppRuntime).

.PARAMETER SkipSource
    Do not install the winget source package (cdn.winget.microsoft.com/cache/source.msix).

.PARAMETER NoProvision
    Install for the current user only, do not provision system-wide.

.EXAMPLE
    # As Administrator:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WinGet-IoT.ps1

.EXAMPLE
    .\Install-WinGet-IoT.ps1 -OfflineDir D:\payloads\winget
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $env:TEMP 'winget-iot-bootstrap'),
    [string]$OfflineDir,
    [switch]$SkipUiXaml,
    [switch]$SkipSource,
    [switch]$NoProvision
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator (PowerShell "Run as administrator").'
    }
}

function Get-NativeArch {
    # PROCESSOR_ARCHITECTURE is "ARM64" on ARM64 Windows even when
    # PowerShell is running x64-emulated. AppX needs the OS architecture.
    $osArch = $env:PROCESSOR_ARCHITECTURE
    try {
        $cs = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($cs.OSArchitecture -match 'ARM') { $osArch = 'ARM64' }
        elseif ($cs.OSArchitecture -match '64') { $osArch = 'AMD64' }
    } catch { }

    switch ($osArch.ToUpperInvariant()) {
        'AMD64' { 'x64' }
        'X86'   { 'x86' }
        'ARM64' { 'arm64' }
        'ARM'   { 'arm' }
        default { throw "Unsupported architecture: $osArch" }
    }
}

function Enable-AppxSideloading {
    Write-Step 'Enable AppX sideloading (no Store required)'

    $unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    if (-not (Test-Path $unlock)) {
        New-Item -Path $unlock -Force | Out-Null
    }
    New-ItemProperty -Path $unlock -Name AllowAllTrustedApps -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $unlock -Name AllowDevelopmentWithoutDevLicense -PropertyType DWord -Value 1 -Force | Out-Null

    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'
    if (-not (Test-Path $policy)) {
        New-Item -Path $policy -Force | Out-Null
    }
    New-ItemProperty -Path $policy -Name AllowAllTrustedApps -PropertyType DWord -Value 1 -Force | Out-Null

    Write-Ok 'AllowAllTrustedApps = 1'
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$Retries = 3,
        [int]$TimeoutSec = 600
    )

    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-Host "    Download ($i/$Retries): $Uri"
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec
            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) {
                $sizeMb = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
                Write-Ok ("{0}  ({1} MB)" -f (Split-Path $OutFile -Leaf), $sizeMb)
                return
            }
            throw 'File empty or not written.'
        } catch {
            Write-Warning "    Attempt $i failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (3 * $i)
        }
    }
    throw "Download failed after $Retries attempts: $Uri"
}

function Test-FileHashIfPresent {
    param(
        [Parameter(Mandatory)][string]$File,
        [string]$HashFile
    )
    if (-not $HashFile -or -not (Test-Path $HashFile)) { return }
    $expected = ((Get-Content -Path $HashFile -Raw) -split '\s+')[0].Trim()
    if ($expected -notmatch '^[A-Fa-f0-9]{64}$') { return }
    $actual = (Get-FileHash -Path $File -Algorithm SHA256).Hash
    if ($actual -ne $expected) {
        throw "SHA256 mismatch for $(Split-Path $File -Leaf). Expected $expected, got $actual"
    }
    Write-Ok "SHA256 OK  $(Split-Path $File -Leaf)"
}

function Get-LatestReleaseAssets {
    Write-Step 'Resolve latest stable winget release from GitHub'

    $api = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
    $headers = @{
        'User-Agent' = 'Install-WinGet-IoT'
        'Accept'     = 'application/vnd.github+json'
    }

    try {
        $release = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 60
        Write-Ok "Release $($release.tag_name)  ($($release.published_at))"
        return [pscustomobject]@{
            Tag        = $release.tag_name
            Assets     = $release.assets
            BundleUrl  = ($release.assets | Where-Object { $_.name -like 'Microsoft.DesktopAppInstaller_*.msixbundle' } | Select-Object -First 1).browser_download_url
            LicenseUrl = ($release.assets | Where-Object { $_.name -like '*License1.xml' } | Select-Object -First 1).browser_download_url
            DepsUrl    = ($release.assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' } | Select-Object -First 1).browser_download_url
            BundleHashUrl = ($release.assets | Where-Object { $_.name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt' } | Select-Object -First 1).browser_download_url
            DepsHashUrl   = ($release.assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.txt' } | Select-Object -First 1).browser_download_url
        }
    } catch {
        Write-Warning "GitHub API unreachable ($($_.Exception.Message)) -- falling back to latest/download permalinks."
        $base = 'https://github.com/microsoft/winget-cli/releases/latest/download'
        return [pscustomobject]@{
            Tag        = 'latest'
            Assets     = @()
            BundleUrl  = "$base/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
            LicenseUrl = "$base/e53e159d00e04f729cc2180cffd1c02e_License1.xml"
            DepsUrl    = "$base/DesktopAppInstaller_Dependencies.zip"
            BundleHashUrl = "$base/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt"
            DepsHashUrl   = "$base/DesktopAppInstaller_Dependencies.txt"
        }
    }
}

function Get-UiXamlPackage {
    param(
        [Parameter(Mandatory)][string]$Arch,
        [Parameter(Mandatory)][string]$DestDir
    )

    $fileName = "Microsoft.UI.Xaml.2.8.$Arch.appx"
    $outFile  = Join-Path $DestDir $fileName
    $uris = @(
        "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/$fileName"
    )

    foreach ($uri in $uris) {
        try {
            Invoke-FileDownload -Uri $uri -OutFile $outFile
            return $outFile
        } catch {
            Write-Warning "    UI.Xaml direct download failed, trying NuGet nupkg."
        }
    }

    $nupkg = Join-Path $DestDir 'Microsoft.UI.Xaml.2.8.6.nupkg'
    Invoke-FileDownload -Uri 'https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6' -OutFile $nupkg
    $zip = [System.IO.Path]::ChangeExtension($nupkg, '.zip')
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Rename-Item $nupkg $zip
    $extract = Join-Path $DestDir 'uixaml-nupkg'
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    $appx = Get-ChildItem -Path $extract -Recurse -Filter 'Microsoft.UI.Xaml.2.8.appx' |
        Where-Object { $_.FullName -match [regex]::Escape("\$Arch\") } |
        Select-Object -First 1
    if (-not $appx) {
        throw "Microsoft.UI.Xaml.2.8.appx for $Arch not found in nupkg."
    }
    Copy-Item $appx.FullName $outFile -Force
    Write-Ok "UI.Xaml 2.8 extracted from NuGet ($Arch)"
    return $outFile
}

function Get-SortedDependencyFiles {
    param([Parameter(Mandatory)][System.IO.FileInfo[]]$Files)

    $rank = {
        param($f)
        $n = $f.Name
        if ($n -match 'VCLibs\.140\.00(?!\.UWPDesktop)') { return 0 }
        if ($n -match 'VCLibs.*UWPDesktop|VCLibs.*Desktop') { return 1 }
        if ($n -match 'UI\.Xaml') { return 2 }
        if ($n -match 'WindowsAppRuntime|WinAppRuntime') { return 3 }
        return 4
    }

    $Files | Sort-Object { & $rank $_ }, Name
}

function Get-AppxIdentityFromFile {
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{
        Path         = $Path
        Name         = $null
        Version      = $null
        Architecture = $null
        Publisher    = $null
        Key          = $Path
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
            if (-not $entry) { return $result }
            $stream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($stream)
                [xml]$xml = $reader.ReadToEnd()
            } finally {
                $stream.Dispose()
            }
        } finally {
            $zip.Dispose()
        }

        $id = $xml.GetElementsByTagName('Identity') | Select-Object -First 1
        if (-not $id) { return $result }

        $name = $id.GetAttribute('Name')
        $arch = $id.GetAttribute('ProcessorArchitecture')
        $publisher = $id.GetAttribute('Publisher')
        $ver = $null
        try { $ver = [version]$id.GetAttribute('Version') } catch { }

        $result.Name = $name
        $result.Version = $ver
        $result.Architecture = $arch
        $result.Publisher = $publisher
        $result.Key = '{0}|{1}|{2}' -f $name, $arch, $publisher
        return $result
    } catch {
        return $result
    }
}

function Select-UniqueAppxPackages {
    param([Parameter(Mandatory)][string[]]$Paths)

    $best = @{}
    foreach ($p in $Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $id = Get-AppxIdentityFromFile -Path $p
        if (-not $best.ContainsKey($id.Key)) {
            $best[$id.Key] = $id
            continue
        }
        $prev = $best[$id.Key]
        if ($id.Version -and ((-not $prev.Version) -or $id.Version -gt $prev.Version)) {
            $best[$id.Key] = $id
        }
    }

    $files = [System.IO.FileInfo[]]@(
        $best.Values | ForEach-Object { Get-Item -LiteralPath $_.Path }
    )
    if ($files.Count -eq 0) { return @() }
    @(Get-SortedDependencyFiles -Files $files)
}

function Test-AppxAlreadyPresent {
    param($ErrorRecord)

    $text = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ex = $ErrorRecord.Exception
        while ($null -ne $ex) {
            $text += ' ' + $ex.Message
            if ($ex.HResult) { $text += ' ' + ('{0:X8}' -f $ex.HResult) }
            $ex = $ex.InnerException
        }
        $text += ' ' + $ErrorRecord.FullyQualifiedErrorId
        if ($ErrorRecord.ErrorDetails) { $text += ' ' + $ErrorRecord.ErrorDetails.Message }
    } else {
        $text = [string]$ErrorRecord
    }

    # ERROR_PACKAGE_ALREADY_EXISTS (0x80073CFB), ERROR_INSTALL_PACKAGE_DOWNGRADE (0x80073D06).
    # AppX localizes the message (en-US and de-DE are both common on IoT images).
    $text -match (
        '80073CFB|80073D06|' +
        'already installed|package already exists|higher version of this package|' +
        'reinstallation of the package was blocked|' +
        'bereits installiert|Neuinstallation des Pakets wurde blockiert'
    )
}

function Install-AppxSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$DependencyPath
    )

    $name = Split-Path $Path -Leaf
    Write-Host "    Add-AppxPackage  $name"
    $params = @{
        Path                      = $Path
        ForceApplicationShutdown  = $true
        ErrorAction               = 'Stop'
    }
    if ($DependencyPath -and $DependencyPath.Count -gt 0) {
        $params['DependencyPath'] = $DependencyPath
    }
    try {
        Add-AppxPackage @params
        Write-Ok "installed: $name"
    } catch {
        if (Test-AppxAlreadyPresent $_) {
            Write-Host "    already present: $name" -ForegroundColor Yellow
        } else {
            throw
        }
    }
}

function Provision-AppxSafe {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$LicensePath,
        [string[]]$DependencyPackagePath
    )

    Write-Host "    Add-AppxProvisionedPackage  $(Split-Path $PackagePath -Leaf)"
    $params = @{
        Online      = $true
        PackagePath = $PackagePath
        LicensePath = $LicensePath
        ErrorAction = 'Stop'
    }
    if ($DependencyPackagePath -and $DependencyPackagePath.Count -gt 0) {
        $params['DependencyPackagePath'] = $DependencyPackagePath
    }
    try {
        Add-AppxProvisionedPackage @params | Out-Null
        Write-Ok 'provisioned system-wide (all users)'
    } catch {
        if (Test-AppxAlreadyPresent $_) {
            Write-Host '    Package was already provisioned.' -ForegroundColor Yellow
        } else {
            throw
        }
    }
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"

    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ($env:Path -notlike "*$windowsApps*") {
        $env:Path = "$env:Path;$windowsApps"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Assert-Administrator
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$arch = Get-NativeArch
Write-Host "Windows 11 IoT  |  Architecture: $arch  |  $([Environment]::OSVersion.VersionString)" -ForegroundColor White

Enable-AppxSideloading

if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

$bundlePath  = $null
$licensePath = $null
$depsZip     = $null
$uiXamlPath  = $null
$sourcePath  = $null
$vclibsAka   = $null

if ($OfflineDir) {
    Write-Step "Offline mode: $OfflineDir"
    if (-not (Test-Path $OfflineDir)) { throw "OfflineDir not found: $OfflineDir" }

    $bundlePath  = Get-ChildItem -Path $OfflineDir -Filter 'Microsoft.DesktopAppInstaller_*.msixbundle' | Select-Object -First 1 -ExpandProperty FullName
    $licensePath = Get-ChildItem -Path $OfflineDir -Filter '*License1.xml' | Select-Object -First 1 -ExpandProperty FullName
    $depsZip     = Get-ChildItem -Path $OfflineDir -Filter 'DesktopAppInstaller_Dependencies.zip' | Select-Object -First 1 -ExpandProperty FullName
    $uiXamlPath  = Get-ChildItem -Path $OfflineDir -Filter "Microsoft.UI.Xaml.2.8*$arch*.appx" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $uiXamlPath) {
        $uiXamlPath = Get-ChildItem -Path $OfflineDir -Filter 'Microsoft.UI.Xaml.2.8.appx' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    $sourcePath  = Get-ChildItem -Path $OfflineDir -Filter 'source.msix' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

    if (-not $bundlePath)  { throw 'OfflineDir: Microsoft.DesktopAppInstaller_*.msixbundle is missing.' }
    if (-not $licensePath) { throw 'OfflineDir: *License1.xml is missing.' }
    if (-not $depsZip)     { throw 'OfflineDir: DesktopAppInstaller_Dependencies.zip is missing.' }
} else {
    $rel = Get-LatestReleaseAssets

    Write-Step 'Download packages'
    $bundlePath  = Join-Path $WorkDir 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    $licensePath = Join-Path $WorkDir 'License1.xml'
    $depsZip     = Join-Path $WorkDir 'DesktopAppInstaller_Dependencies.zip'
    $bundleHash  = Join-Path $WorkDir 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt'
    $depsHash    = Join-Path $WorkDir 'DesktopAppInstaller_Dependencies.txt'

    Invoke-FileDownload -Uri $rel.BundleUrl  -OutFile $bundlePath
    Invoke-FileDownload -Uri $rel.LicenseUrl -OutFile $licensePath
    Invoke-FileDownload -Uri $rel.DepsUrl    -OutFile $depsZip

    if ($rel.BundleHashUrl) {
        try { Invoke-FileDownload -Uri $rel.BundleHashUrl -OutFile $bundleHash } catch { }
        Test-FileHashIfPresent -File $bundlePath -HashFile $bundleHash
    }
    if ($rel.DepsHashUrl) {
        try { Invoke-FileDownload -Uri $rel.DepsHashUrl -OutFile $depsHash } catch { }
        Test-FileHashIfPresent -File $depsZip -HashFile $depsHash
    }

    # Extra VCLibs Desktop framework (aka.ms) -- required by Microsoft IoT docs.
    $vclibsUri = switch ($arch) {
        'x64'   { 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' }
        'arm64' { 'https://aka.ms/Microsoft.VCLibs.arm64.14.00.Desktop.appx' }
        'x86'   { 'https://aka.ms/Microsoft.VCLibs.x86.14.00.Desktop.appx' }
        default { $null }
    }
    $vclibsAka = $null
    if ($vclibsUri) {
        $vclibsAka = Join-Path $WorkDir "Microsoft.VCLibs.$arch.14.00.Desktop.appx"
        try {
            Invoke-FileDownload -Uri $vclibsUri -OutFile $vclibsAka
        } catch {
            Write-Warning "aka.ms VCLibs not downloaded -- Dependencies.zip must be enough."
            $vclibsAka = $null
        }
    }

    if (-not $SkipUiXaml) {
        Write-Step 'Download Microsoft.UI.Xaml.2.8 (Microsoft IoT documentation)'
        try {
            $uiXamlPath = Get-UiXamlPackage -Arch $arch -DestDir $WorkDir
        } catch {
            Write-Warning "Could not download UI.Xaml 2.8: $($_.Exception.Message)"
            Write-Warning "Newer winget releases need Windows App Runtime 1.8 from Dependencies.zip instead."
        }
    }

    if (-not $SkipSource) {
        Write-Step 'Download winget source package'
        $sourcePath = Join-Path $WorkDir 'source.msix'
        try {
            Invoke-FileDownload -Uri 'https://cdn.winget.microsoft.com/cache/source.msix' -OutFile $sourcePath
        } catch {
            Write-Warning "source.msix not downloaded. Try 'winget source reset --force' after reboot."
            $sourcePath = $null
        }
    }
}

# ---------------------------------------------------------------------------
# Dependencies from zip
# ---------------------------------------------------------------------------

Write-Step "Extract Dependencies.zip ($arch)"
$depsRoot = Join-Path $WorkDir 'deps'
if (Test-Path $depsRoot) { Remove-Item $depsRoot -Recurse -Force }
Expand-Archive -Path $depsZip -DestinationPath $depsRoot -Force

$archDir = Get-ChildItem -Path $depsRoot -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $arch } |
    Select-Object -First 1

$searchRoot = if ($archDir) { $archDir.FullName } else { $depsRoot }
$depFiles = @(Get-ChildItem -Path $searchRoot -Recurse -Include '*.appx', '*.msix', '*.msixbundle' -File -ErrorAction SilentlyContinue)

if ($depFiles.Count -eq 0) {
    throw "No AppX packages for architecture '$arch' in DesktopAppInstaller_Dependencies.zip."
}

$depFiles = @(Get-SortedDependencyFiles -Files $depFiles)

Write-Ok ("{0} dependency packages in zip:" -f $depFiles.Count)
$depFiles | ForEach-Object { Write-Host "      - $($_.Name)" }

# aka.ms VCLibs / extra UI.Xaml are often the same package family as a zip
# entry. Passing both as -DependencyPath throws 0x80073CF9 ("specified
# multiple times. Each package specified needs to be unique.").
$extraDeps = @()
if ($vclibsAka -and (Test-Path -LiteralPath $vclibsAka)) { $extraDeps += $vclibsAka }
if ($uiXamlPath -and (Test-Path -LiteralPath $uiXamlPath)) { $extraDeps += $uiXamlPath }

$allDepPaths = @($extraDeps) + @($depFiles | ForEach-Object { $_.FullName })
$uniqueDepFiles = @(Select-UniqueAppxPackages -Paths $allDepPaths)
$allDepPaths = @($uniqueDepFiles | ForEach-Object { $_.FullName })

Write-Ok ("{0} unique packages after identity dedup:" -f $allDepPaths.Count)
$uniqueDepFiles | ForEach-Object { Write-Host "      - $($_.Name)" }

Write-Step 'Install dependencies (order: VCLibs -> UI.Xaml -> WinAppRuntime)'
foreach ($dep in $uniqueDepFiles) {
    Install-AppxSafe -Path $dep.FullName
}

# ---------------------------------------------------------------------------
# DesktopAppInstaller + License
# ---------------------------------------------------------------------------

Write-Step 'Install winget (Microsoft.DesktopAppInstaller)'
Install-AppxSafe -Path $bundlePath -DependencyPath $allDepPaths

if (-not $NoProvision) {
    Write-Step 'Provision for all users (License1.xml)'
    Provision-AppxSafe -PackagePath $bundlePath -LicensePath $licensePath -DependencyPackagePath $allDepPaths
}

if ($sourcePath -and (Test-Path $sourcePath)) {
    Write-Step 'Register winget source'
    Install-AppxSafe -Path $sourcePath
}

Refresh-Path

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

Write-Step 'Verify'

$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
$wingetExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'

if (-not $wingetCmd -and (Test-Path $wingetExe)) {
    $wingetCmd = Get-Command $wingetExe
}

if (-not $wingetCmd) {
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    if ($pkg) {
        $candidate = Join-Path $pkg.InstallLocation 'winget.exe'
        if (Test-Path $candidate) { $wingetCmd = Get-Command $candidate }
    }
}

if (-not $wingetCmd) {
    Write-Warning @'
winget.exe is not on PATH yet.
Without VCLibs / UI.Xaml / WinAppRuntime the install fails silently.
Please:
  1) Open a new PowerShell window
  2) If it is still unknown: reboot
Check packages:
  Get-AppxPackage Microsoft.DesktopAppInstaller, Microsoft.VCLibs*, Microsoft.UI.Xaml*, Microsoft.WindowsAppRuntime*
'@
    exit 1
}

Write-Ok "winget found: $($wingetCmd.Source)"
& $wingetCmd.Source --info

try {
    & $wingetCmd.Source source reset --force --disable-interactivity 2>$null | Out-Null
} catch { }

Write-Host ''
Write-Host 'Done. Open a new PowerShell, then e.g.:' -ForegroundColor Green
Write-Host '    winget --version'
Write-Host '    winget search Git.Git'
Write-Host '    winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements'
Write-Host ''
Write-Host 'Note: the msstore source needs the Microsoft Store and is useless on IoT LTSC.' -ForegroundColor DarkGray
Write-Host '      The community source "winget" works without the Store.' -ForegroundColor DarkGray
