#Requires -Version 5.1
<#
.SYNOPSIS
    Installiert winget (Windows Package Manager) auf Windows 11 IoT Enterprise
    ohne Microsoft Store, inklusive aller Dependencies und der License.

.DESCRIPTION
    Zielplattform: Windows 11 IoT Enterprise / LTSC (kein Store).
    Holt die jeweils neueste stabile GitHub-Release von microsoft/winget-cli,
    installiert die passenden Architecture-Dependencies (VCLibs, UWPDesktop,
    Windows App Runtime) plus Microsoft.UI.Xaml.2.8 (laut Microsoft-IoT-Doku)
    und provisioniert DesktopAppInstaller systemweit mit License1.xml.

    Ohne VCLibs / WinAppRuntime / UI.Xaml schlaegt die Installation oft still
    fehl -- winget.exe erscheint dann nicht unter WindowsApps.

.PARAMETER OfflineDir
    Ordner mit bereits heruntergeladenen Dateien (air-gapped IoT).
    Erwartet:
      - Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
      - *License1.xml
      - DesktopAppInstaller_Dependencies.zip
      optional: Microsoft.UI.Xaml.2.8.<arch>.appx
      optional: source.msix

.PARAMETER SkipUiXaml
    UI.Xaml 2.8 nicht extra holen (neuere winget-Releases ziehen WinAppRuntime).

.PARAMETER SkipSource
    winget-Source-Paket (cdn.winget.microsoft.com/cache/source.msix) nicht installieren.

.PARAMETER NoProvision
    Nur fuer den aktuellen Benutzer installieren, nicht systemweit provisionieren.

.EXAMPLE
    # Als Administrator:
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
        throw 'Dieses Script muss als Administrator laufen (PowerShell "Als Administrator ausfuehren").'
    }
}

function Get-NativeArch {
    # PROCESSOR_ARCHITECTURE ist auf ARM64-Windows "ARM64", auch wenn die
    # PowerShell x64-emuliert laeuft. Fuer AppX zaehlt die OS-Architektur.
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
        default { throw "Nicht unterstuetzte Architektur: $osArch" }
    }
}

function Enable-AppxSideloading {
    Write-Step 'Sideloading fuer AppX aktivieren (ohne Store noetig)'

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
            throw 'Datei leer oder nicht geschrieben.'
        } catch {
            Write-Warning "    Versuch $i fehlgeschlagen: $($_.Exception.Message)"
            Start-Sleep -Seconds (3 * $i)
        }
    }
    throw "Download fehlgeschlagen nach $Retries Versuchen: $Uri"
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
        throw "SHA256 mismatch fuer $(Split-Path $File -Leaf). Erwartet $expected, erhalten $actual"
    }
    Write-Ok "SHA256 OK  $(Split-Path $File -Leaf)"
}

function Get-LatestReleaseAssets {
    Write-Step 'Neueste stabile winget-Release von GitHub ermitteln'

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
        Write-Warning "GitHub API nicht erreichbar ($($_.Exception.Message)) -- Fallback auf latest/download Permalinks."
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
            Write-Warning "    UI.Xaml Direct-Download fehlgeschlagen, versuche NuGet nupkg."
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
        throw "Microsoft.UI.Xaml.2.8.appx fuer $Arch nicht im nupkg gefunden."
    }
    Copy-Item $appx.FullName $outFile -Force
    Write-Ok "UI.Xaml 2.8 aus NuGet extrahiert ($Arch)"
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
        Write-Ok "installiert: $name"
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '0x80073D06|already installed|bereits installiert|0x80073CFB') {
            Write-Host "    bereits vorhanden: $name" -ForegroundColor Yellow
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
        Write-Ok 'systemweit provisioniert (alle Benutzer)'
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '0x80073CFB|already|bereits') {
            Write-Host '    Package war bereits provisioniert.' -ForegroundColor Yellow
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
Write-Host "Windows 11 IoT  |  Architektur: $arch  |  $([Environment]::OSVersion.VersionString)" -ForegroundColor White

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
    Write-Step "Offline-Modus: $OfflineDir"
    if (-not (Test-Path $OfflineDir)) { throw "OfflineDir nicht gefunden: $OfflineDir" }

    $bundlePath  = Get-ChildItem -Path $OfflineDir -Filter 'Microsoft.DesktopAppInstaller_*.msixbundle' | Select-Object -First 1 -ExpandProperty FullName
    $licensePath = Get-ChildItem -Path $OfflineDir -Filter '*License1.xml' | Select-Object -First 1 -ExpandProperty FullName
    $depsZip     = Get-ChildItem -Path $OfflineDir -Filter 'DesktopAppInstaller_Dependencies.zip' | Select-Object -First 1 -ExpandProperty FullName
    $uiXamlPath  = Get-ChildItem -Path $OfflineDir -Filter "Microsoft.UI.Xaml.2.8*$arch*.appx" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $uiXamlPath) {
        $uiXamlPath = Get-ChildItem -Path $OfflineDir -Filter 'Microsoft.UI.Xaml.2.8.appx' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    $sourcePath  = Get-ChildItem -Path $OfflineDir -Filter 'source.msix' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

    if (-not $bundlePath)  { throw 'OfflineDir: Microsoft.DesktopAppInstaller_*.msixbundle fehlt.' }
    if (-not $licensePath) { throw 'OfflineDir: *License1.xml fehlt.' }
    if (-not $depsZip)     { throw 'OfflineDir: DesktopAppInstaller_Dependencies.zip fehlt.' }
} else {
    $rel = Get-LatestReleaseAssets

    Write-Step 'Pakete herunterladen'
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

    # VCLibs Desktop-Framework extra (aka.ms) -- laut Microsoft-IoT-Doku Pflicht.
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
            Write-Warning "aka.ms VCLibs nicht geladen -- Dependencies.zip muss ausreichen."
            $vclibsAka = $null
        }
    }

    if (-not $SkipUiXaml) {
        Write-Step 'Microsoft.UI.Xaml.2.8 laden (Microsoft IoT-Dokumentation)'
        try {
            $uiXamlPath = Get-UiXamlPackage -Arch $arch -DestDir $WorkDir
        } catch {
            Write-Warning "UI.Xaml 2.8 konnte nicht geladen werden: $($_.Exception.Message)"
            Write-Warning "Neuere winget-Releases brauchen stattdessen Windows App Runtime 1.8 aus der Dependencies.zip."
        }
    }

    if (-not $SkipSource) {
        Write-Step 'winget Source-Paket laden'
        $sourcePath = Join-Path $WorkDir 'source.msix'
        try {
            Invoke-FileDownload -Uri 'https://cdn.winget.microsoft.com/cache/source.msix' -OutFile $sourcePath
        } catch {
            Write-Warning "source.msix nicht geladen. 'winget source reset --force' nach dem Reboot versuchen."
            $sourcePath = $null
        }
    }
}

# ---------------------------------------------------------------------------
# Dependencies aus Zip
# ---------------------------------------------------------------------------

Write-Step "Dependencies.zip entpacken ($arch)"
$depsRoot = Join-Path $WorkDir 'deps'
if (Test-Path $depsRoot) { Remove-Item $depsRoot -Recurse -Force }
Expand-Archive -Path $depsZip -DestinationPath $depsRoot -Force

$archDir = Get-ChildItem -Path $depsRoot -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $arch } |
    Select-Object -First 1

$searchRoot = if ($archDir) { $archDir.FullName } else { $depsRoot }
$depFiles = @(Get-ChildItem -Path $searchRoot -Recurse -Include *.appx, *.msix, *.msixbundle -File -ErrorAction SilentlyContinue)

if ($depFiles.Count -eq 0) {
    throw "Keine AppX-Pakete fuer Architektur '$arch' in DesktopAppInstaller_Dependencies.zip gefunden."
}

$depFiles = @(Get-SortedDependencyFiles -Files $depFiles)

Write-Ok ("{0} Dependency-Pakete gefunden:" -f $depFiles.Count)
$depFiles | ForEach-Object { Write-Host "      - $($_.Name)" }

# Extra VCLibs / UI.Xaml vor die Zip-Deps setzen, falls vorhanden
$extraDeps = @()
if ($vclibsAka -and (Test-Path $vclibsAka)) { $extraDeps += $vclibsAka }
if ($uiXamlPath -and (Test-Path $uiXamlPath)) { $extraDeps += $uiXamlPath }

Write-Step 'Dependencies installieren (Reihenfolge: VCLibs -> UI.Xaml -> WinAppRuntime)'
foreach ($extra in $extraDeps) {
    Install-AppxSafe -Path $extra
}
foreach ($dep in $depFiles) {
    Install-AppxSafe -Path $dep.FullName
}

$allDepPaths = @($extraDeps) + @($depFiles | ForEach-Object { $_.FullName })

# ---------------------------------------------------------------------------
# DesktopAppInstaller + License
# ---------------------------------------------------------------------------

Write-Step 'winget (Microsoft.DesktopAppInstaller) installieren'
Install-AppxSafe -Path $bundlePath -DependencyPath $allDepPaths

if (-not $NoProvision) {
    Write-Step 'Fuer alle Benutzer provisionieren (License1.xml)'
    Provision-AppxSafe -PackagePath $bundlePath -LicensePath $licensePath -DependencyPackagePath $allDepPaths
}

if ($sourcePath -and (Test-Path $sourcePath)) {
    Write-Step 'winget Source registrieren'
    Install-AppxSafe -Path $sourcePath
}

Refresh-Path

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

Write-Step 'Pruefen'

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
winget.exe ist noch nicht im PATH.
Ohne VCLibs / UI.Xaml / WinAppRuntime schlaegt die Installation still fehl.
Bitte:
  1) PowerShell neu oeffnen
  2) falls dann immer noch unbekannt: Reboot
Pakete pruefen:
  Get-AppxPackage Microsoft.DesktopAppInstaller, Microsoft.VCLibs*, Microsoft.UI.Xaml*, Microsoft.WindowsAppRuntime*
'@
    exit 1
}

Write-Ok "winget gefunden: $($wingetCmd.Source)"
& $wingetCmd.Source --info

try {
    & $wingetCmd.Source source reset --force --disable-interactivity 2>$null | Out-Null
} catch { }

Write-Host ''
Write-Host 'Fertig. Neue PowerShell oeffnen, dann z.B.:' -ForegroundColor Green
Write-Host '    winget --version'
Write-Host '    winget search Git.Git'
Write-Host '    winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements'
Write-Host ''
Write-Host 'Hinweis: msstore-Quelle braucht den Microsoft Store und ist auf IoT LTSC nutzlos.' -ForegroundColor DarkGray
Write-Host '         Community-Quelle "winget" funktioniert ohne Store.' -ForegroundColor DarkGray
