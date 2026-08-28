# Install WinGet on Windows 11 IoT (no Microsoft Store)

Bootstrap **winget** on **Windows 11 IoT Enterprise / LTSC** — editions that
ship **without** the Microsoft Store.

The official IoT docs still talk about VCLibs + UI.Xaml 2.8 only. Current
WinGet (1.29+) also needs **Windows App Runtime 1.8**. Missing a dependency
makes `Add-AppxPackage` fail **silently**: `winget.exe` never shows up under
`%LOCALAPPDATA%\Microsoft\WindowsApps`.

This script:

1. Enables AppX sideloading (`AllowAllTrustedApps`) — Store stays off
2. Detects OS architecture (`x64` / `arm64` / `x86`)
3. Downloads the latest stable [winget-cli](https://github.com/microsoft/winget-cli/releases/latest) release
4. Installs dependencies in order: **VCLibs → UI.Xaml 2.8 → Windows App Runtime**
5. Installs `Microsoft.DesktopAppInstaller` and **provisions it for all users** with `License1.xml`
6. Registers the community source (`source.msix`)
7. Verifies `winget --info`

The `msstore` source is useless on IoT LTSC. The `winget` community source works without the Store.

## Requirements

- Windows 11 IoT Enterprise or LTSC (also works on 10 IoT LTSC 2021+ / Server without Store)
- Administrator PowerShell 5.1+
- Internet **or** an offline payload folder (`-OfflineDir`)
- Not Windows IoT **Core** (no Win32)

## Install

**Administrator Windows PowerShell 5.1**, copy-paste:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$f = "$env:TEMP\Install-WinGet-IoT.ps1"
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Jabe/winget-iot/main/Install-WinGet-IoT.ps1' -OutFile $f -UseBasicParsing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f
```

`-UseBasicParsing` is required on Windows PowerShell 5.1 (no IE engine). The download is written to a file and started with `-File` so `#Requires` and `-OfflineDir` / other parameters work. Append parameters after `$f`, e.g. `-File $f -SkipUiXaml`.

After success, open a **new** PowerShell:

```powershell
winget --version
winget search Git.Git
winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
```

### From a clone

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-WinGet-IoT.ps1
```

Or double-click `Install-WinGet-IoT.cmd` (UAC).

## Offline / air-gapped

```powershell
.\Install-WinGet-IoT.ps1 -OfflineDir D:\payloads\winget
```

Put these files in that folder:

| File | From |
| --- | --- |
| `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle` | [winget-cli latest](https://github.com/microsoft/winget-cli/releases/latest) |
| `e53e159d00e04f729cc2180cffd1c02e_License1.xml` | same release |
| `DesktopAppInstaller_Dependencies.zip` | same release (VCLibs + WinAppRuntime 1.8) |
| optional `Microsoft.UI.Xaml.2.8.x64.appx` | [UI.Xaml 2.8.6](https://github.com/microsoft/microsoft-ui-xaml/releases/tag/v2.8.6) |
| optional `source.msix` | `https://cdn.winget.microsoft.com/cache/source.msix` |

## Parameters

| Parameter | Meaning |
| --- | --- |
| `-OfflineDir <path>` | Use local files, no GitHub |
| `-SkipUiXaml` | Skip extra UI.Xaml 2.8 download (WinAppRuntime-only path) |
| `-SkipSource` | Do not install `source.msix` |
| `-NoProvision` | Current user only, no `Add-AppxProvisionedPackage` |
| `-WorkDir <path>` | Download/extract cache (default `%TEMP%\winget-iot-bootstrap`) |

## Alternative: PSGallery bootstrap

If the machine can reach PSGallery, Microsoft's module can pull the same bits:

```powershell
$ProgressPreference = 'SilentlyContinue'
Install-PackageProvider -Name NuGet -Force | Out-Null
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers
Repair-WinGetPackageManager -AllUsers
```

On locked-down IoT without Gallery, use this repo's script.

## If `winget` is still unknown

1. Close and reopen PowerShell (PATH: `%LOCALAPPDATA%\Microsoft\WindowsApps`)
2. Reboot
3. Check packages:

```powershell
Get-AppxPackage Microsoft.DesktopAppInstaller, Microsoft.VCLibs*, Microsoft.UI.Xaml*, Microsoft.WindowsAppRuntime*
```

Silent failure almost always means a missing dependency.

## License

Scripts: [MIT](LICENSE). Downloaded Microsoft packages keep Microsoft's licenses.
