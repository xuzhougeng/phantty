param(
    [string]$Version,
    [string]$OutputDir = '.\zig-out\dist',
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ReleaseVersion {
    param([string]$ExplicitVersion)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitVersion)) {
        return $ExplicitVersion.Trim()
    }

    try {
        $gitVersion = (& git describe --tags --always --dirty 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $trimmed = $gitVersion.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                return $trimmed
            }
        }
    } catch {
    }

    return (Get-Date -Format 'yyyy.MM.dd')
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$resolvedOutputDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir))
$releaseVersion = Get-ReleaseVersion -ExplicitVersion $Version

if (-not $SkipBuild) {
    Push-Location $repoRoot
    try {
        & zig build -Doptimize=ReleaseFast
        if ($LASTEXITCODE -ne 0) {
            throw 'zig build -Doptimize=ReleaseFast failed.'
        }
    } finally {
        Pop-Location
    }
}

$binaryPath = Join-Path $repoRoot 'zig-out\bin\phantty.exe'
if (-not (Test-Path $binaryPath)) {
    throw "Expected release binary was not found: $binaryPath"
}

$portableDir = Join-Path $resolvedOutputDir 'portable'
$installerDir = Join-Path $resolvedOutputDir 'installer'
$stagingDir = Join-Path $installerDir 'staging'
$setupExe = Join-Path $installerDir 'phantty-setup.exe'
$versionFile = Join-Path $stagingDir 'version.txt'
$sedFile = Join-Path $installerDir 'phantty-installer.sed'

Remove-Item -Path $portableDir, $installerDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $portableDir, $installerDir, $stagingDir -Force | Out-Null

Copy-Item -Path $binaryPath -Destination (Join-Path $portableDir 'phantty.exe') -Force
Set-Content -Path (Join-Path $portableDir 'version.txt') -Value $releaseVersion -Encoding ASCII

Copy-Item -Path $binaryPath -Destination (Join-Path $stagingDir 'phantty.exe') -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'Install-Phantty.ps1') -Destination (Join-Path $stagingDir 'Install-Phantty.ps1') -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'install.cmd') -Destination (Join-Path $stagingDir 'install.cmd') -Force
Set-Content -Path $versionFile -Value $releaseVersion -Encoding ASCII

$sedBody = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=1
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=Phantty has been installed to your user profile and added to the Start menu.
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=<None>
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
TargetName=$setupExe
FriendlyName=Phantty Setup
AppLaunched=cmd.exe /c install.cmd
AdminQuietInstCmd=cmd.exe /c install.cmd /quiet
UserQuietInstCmd=cmd.exe /c install.cmd /quiet
FILE0=phantty.exe
FILE1=Install-Phantty.ps1
FILE2=install.cmd
FILE3=version.txt
[SourceFiles]
SourceFiles0=$stagingDir\
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
%FILE3%=
"@

Set-Content -Path $sedFile -Value $sedBody -Encoding ASCII

Push-Location $installerDir
try {
    & iexpress.exe /N $sedFile
    if ($LASTEXITCODE -ne 0) {
        throw 'IExpress failed to create the installer.'
    }
} finally {
    Pop-Location
}

Write-Host "Portable build: $(Join-Path $portableDir 'phantty.exe')"
Write-Host "Installer build: $setupExe"
