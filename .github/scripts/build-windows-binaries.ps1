# Builds every Impacket example script in examples/ into a standalone Windows
# .exe with PyInstaller. Written for the GitHub Actions windows-latest runner
# (already-elevated, VC++ Build Tools preinstalled) -- not meant to be run
# interactively on an arbitrary machine.

[CmdletBinding()]
param (
    [string]$SourceDir = $PWD,
    [string]$OutputDir = (Join-Path $PWD 'dist-bin'),
    [string]$TempDir = $env:TEMP
)

$ErrorActionPreference = 'Stop'

$npcapVersion = '1.80'
$npcapSDKVersion = '1.13'
$npcapUrl = "https://npcap.com/dist/npcap-$npcapVersion.exe"
$npcapSDKUrl = "https://npcap.com/dist/npcap-sdk-$npcapSDKVersion.zip"
$vsBuildToolsUrl = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'

# Tools that need something more than `pyinstaller --onefile examples\$tool.py`
$toolExtras = @{
    'ntlmrelayx' = @{
        # cryptography is a hard dependency of attacks/rpcattack.py and httpattacks/*attack.py,
        # which get pulled in unconditionally by the attacks/__init__.py plugin loader below
        Packages             = @('pydivert', 'cryptography')
        # tkinter gets pulled in by a transitive import for no reason and breaks the onefile build.
        # --collect-all impacket.examples.ntlmrelayx is required because attacks/__init__.py loads
        # its plugins by enumerating .py files on disk at runtime (importlib.resources.files(...)
        # .iterdir()), which only finds them in a frozen build if they were collected as data too.
        # --collect-all pydivert bundles WinDivert64.dll/.sys, which pydivert loads via a path
        # relative to its own __file__ rather than through a traceable import.
        ExtraPyInstallerArgs = @('--exclude-module', 'tkinter', '--collect-all', 'impacket.examples.ntlmrelayx', '--collect-all', 'pydivert')
    }
    'krbrelayx'  = @{
        # krbrelayx.py imports PROTOCOL_ATTACKS from the same attacks package as ntlmrelayx, so it
        # hits the same dynamic plugin loader and needs the same cryptography dependency and collection
        Packages             = @('cryptography')
        ExtraPyInstallerArgs = @('--exclude-module', 'tkinter', '--collect-all', 'impacket.examples.ntlmrelayx')
    }
    'kintercept' = @{
        # kintercept.py does `import asyncore`, which was removed from the stdlib in Python 3.12
        Packages = @('pyasyncore')
    }
    'sniff'      = @{
        Packages   = @('pcapy-ng')
        NeedsNpcap = $true
    }
    'split'      = @{
        Packages   = @('pcapy-ng')
        NeedsNpcap = $true
    }
}

function Test-VCToolsAvailable {
    $vswherePath = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswherePath)) {
        return $false
    }

    $installationPath = & $vswherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    return [bool]$installationPath
}

function Install-VCBuildTools {
    param ([string]$TempDir)

    if (Test-VCToolsAvailable) {
        Write-Host 'VC++ Build Tools already available, skipping install.'
        return
    }

    Write-Host 'Installing VC++ Build Tools...'
    $installer = Join-Path -Path $TempDir -ChildPath 'vs_buildtools.exe'
    Invoke-WebRequest -Uri $vsBuildToolsUrl -OutFile $installer
    Start-Process -FilePath $installer -ArgumentList '--quiet', '--wait', '--add', 'Microsoft.VisualStudio.Workload.VCTools;includeRecommended' -Wait
}

# $ErrorActionPreference = 'Stop' only catches PowerShell-native errors, not a nonzero exit code
# from an external process -- a failed `pip install` would otherwise go unnoticed and just produce
# a silently-broken exe later, since PyInstaller doesn't require its imports to actually succeed.
function Invoke-Native {
    $exe = $args[0]
    $exeArgs = $args[1..($args.Count - 1)]
    & $exe @exeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "'$($args -join ' ')' failed with exit code $LASTEXITCODE"
    }
}

# Downloads the Npcap SDK (needed to compile pcapy-ng) and the Npcap driver
# installer (bundled into the sniff/split exes so end users can install it).
# The installer is only ever downloaded, never run: the free/non-OEM Npcap
# installer has no silent-install switch (/S is an OEM-only feature), so
# running it here would just hang the runner waiting for GUI input that will
# never come. Compiling pcapy-ng only needs the SDK headers/libs below, not
# an actual installed driver.
# Returns the path to the driver installer so it can be passed to --add-binary.
function Install-Npcap {
    param ([string]$TempDir)

    $sdkFolder = Join-Path -Path $TempDir -ChildPath 'npcap-sdk'
    if (-not (Test-Path -Path $sdkFolder)) {
        Write-Host 'Downloading Npcap SDK...'
        $sdkArchive = Join-Path -Path $TempDir -ChildPath 'npcap-sdk.zip'
        Invoke-WebRequest -Uri $npcapSDKUrl -OutFile $sdkArchive
        Expand-Archive -Path $sdkArchive -DestinationPath $sdkFolder -Force
    }

    # pcapy-ng's setup.py reads this to find Include/ and Lib/x64/ under the SDK root
    $env:WPDPACK_BASE = $sdkFolder

    # examples/sniff.py and examples/split.py hardcode this exact filename when they
    # look for the bundled installer under sys._MEIPASS at runtime -- do not rename it.
    $npcapInstallerPath = Join-Path -Path $TempDir -ChildPath 'npcap.exe'
    if (-not (Test-Path -Path $npcapInstallerPath)) {
        Write-Host 'Downloading Npcap installer...'
        Invoke-WebRequest -Uri $npcapUrl -OutFile $npcapInstallerPath
    }

    return $npcapInstallerPath
}

$SourceDir = (Resolve-Path -Path $SourceDir).Path

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Resolve-Path -Path $OutputDir).Path

$TempDir = Join-Path -Path $TempDir -ChildPath 'impacket-build'
if (Test-Path -Path $TempDir) {
    Remove-Item -Path $TempDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

$examplesDir = Join-Path -Path $SourceDir -ChildPath 'examples'
$tools = Get-ChildItem -Path $examplesDir -Filter '*.py' | ForEach-Object { $_.BaseName } | Sort-Object

Write-Host "Discovered $($tools.Count) tools to build."

Set-Location -Path $SourceDir

Invoke-Native python -m venv .venv
.\.venv\Scripts\Activate.ps1

# pip.exe can't overwrite itself while running on Windows ("To modify pip, please run
# python.exe -m pip install --upgrade pip"), so use `python -m pip` everywhere, which
# is also just the generally-recommended way to invoke pip.
Invoke-Native python -m pip install --upgrade pip
Invoke-Native python -m pip install -r requirements.txt
Invoke-Native python -m pip install pyinstaller
Invoke-Native python setup.py install

$npcapInstallerPath = $null
$failedTools = @()

foreach ($tool in $tools) {
    Write-Host "=== Building $tool ==="

    try {
        $pyInstallerArgs = New-Object System.Collections.Generic.List[string]
        $pyInstallerArgs.Add('--onefile')
        $pyInstallerArgs.Add('--noconfirm')

        if ($toolExtras.ContainsKey($tool)) {
            $extra = $toolExtras[$tool]

            # Must run before the Packages loop below: pcapy-ng's setup.py reads $env:WPDPACK_BASE
            # (set by Install-Npcap) at compile time, so installing it before this ran would fall
            # back to pcapy-ng's hardcoded (nonexistent) c:\wpdpack path and fail to find pcap.h.
            if ($extra.ContainsKey('NeedsNpcap') -and $extra['NeedsNpcap']) {
                Install-VCBuildTools -TempDir $TempDir
                if (-not $npcapInstallerPath) {
                    $npcapInstallerPath = Install-Npcap -TempDir $TempDir
                }

                $pyInstallerArgs.Add('--add-binary')
                $pyInstallerArgs.Add("$npcapInstallerPath;.")
            }

            foreach ($package in $extra['Packages']) {
                Invoke-Native python -m pip install $package
            }

            if ($extra.ContainsKey('ExtraPyInstallerArgs')) {
                $pyInstallerArgs.AddRange([string[]]$extra['ExtraPyInstallerArgs'])
            }
        }

        Invoke-Native pyinstaller @pyInstallerArgs (Join-Path -Path $examplesDir -ChildPath "$tool.py")

        $builtExe = Join-Path -Path $SourceDir -ChildPath "dist\$tool.exe"
        if (-not (Test-Path -Path $builtExe)) {
            throw "PyInstaller did not produce $builtExe"
        }

        Copy-Item -Path $builtExe -Destination $OutputDir -Force
    }
    catch {
        Write-Warning "Failed to build $tool`: $_"
        $failedTools += $tool
    }
}

deactivate
Set-Location -Path $SourceDir

Write-Host ''
Write-Host "Built $($tools.Count - $failedTools.Count)/$($tools.Count) tools into $OutputDir"

if ($failedTools.Count -gt 0) {
    Write-Warning "The following tools failed to build: $($failedTools -join ', ')"
    exit 1
}
