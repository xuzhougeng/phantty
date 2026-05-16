param(
    [string]$Version,
    [string]$OutputDir = '.\zig-out\dist',
    [string]$WebView2Version = '1.0.3912.50',
    [switch]$SkipBuild,
    [switch]$SkipInstaller,
    [switch]$SkipWebView2Bundle
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

function Get-WebView2Loader {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $loaderRelativePath = 'build\native\x64\WebView2Loader.dll'
    $nugetLoader = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.web.webview2\$Version\$loaderRelativePath"
    if (Test-Path $nugetLoader) {
        return $nugetLoader
    }

    $cacheRoot = Join-Path $RepoRoot '.zig-cache\webview2'
    $packageDir = Join-Path $cacheRoot "Microsoft.Web.WebView2.$Version"
    $cachedLoader = Join-Path $packageDir $loaderRelativePath
    if (Test-Path $cachedLoader) {
        return $cachedLoader
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $nupkgPath = Join-Path $cacheRoot "Microsoft.Web.WebView2.$Version.nupkg"
    $zipPath = Join-Path $cacheRoot "Microsoft.Web.WebView2.$Version.zip"
    $packageUrl = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Version"

    if (-not (Test-Path $nupkgPath)) {
        Write-Host "Downloading Microsoft.Web.WebView2 $Version"
        Invoke-WebRequest -Uri $packageUrl -OutFile $nupkgPath
    }

    Remove-Item -Path $packageDir -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $nupkgPath -Destination $zipPath -Force
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $packageDir -Force
    } finally {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $cachedLoader)) {
        throw "WebView2Loader.dll was not found in Microsoft.Web.WebView2 $Version."
    }

    return $cachedLoader
}

function Copy-PortablePayload {
    param(
        [Parameter(Mandatory = $true)][string]$BinaryPath,
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$ReleaseVersion,
        [string]$WebView2LoaderPath
    )

    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    Copy-Item -Path $BinaryPath -Destination (Join-Path $TargetDir 'phantty.exe') -Force
    Set-Content -Path (Join-Path $TargetDir 'version.txt') -Value $ReleaseVersion -Encoding ASCII

    $sourceSkillsDir = Join-Path (Split-Path -Parent $BinaryPath) 'skills'
    if (Test-Path $sourceSkillsDir) {
        Copy-Item -Path $sourceSkillsDir -Destination (Join-Path $TargetDir 'skills') -Recurse -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($WebView2LoaderPath)) {
        Copy-Item -Path $WebView2LoaderPath -Destination (Join-Path $TargetDir 'WebView2Loader.dll') -Force
    }
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
$portableWebView2Dir = Join-Path $resolvedOutputDir 'portable-webview2'
$installerDir = Join-Path $resolvedOutputDir 'installer'
$stagingDir = Join-Path $installerDir 'staging'
$setupExe = Join-Path $installerDir 'phantty-setup.exe'
$versionFile = Join-Path $stagingDir 'version.txt'
$sedFile = Join-Path $installerDir 'phantty-installer.sed'
$webView2LoaderPath = $null

if (-not $SkipWebView2Bundle) {
    $webView2LoaderPath = Get-WebView2Loader -RepoRoot $repoRoot -Version $WebView2Version
}

Remove-Item -Path $portableDir, $portableWebView2Dir, $installerDir -Recurse -Force -ErrorAction SilentlyContinue

Copy-PortablePayload -BinaryPath $binaryPath -TargetDir $portableDir -ReleaseVersion $releaseVersion
if ($webView2LoaderPath) {
    Copy-PortablePayload -BinaryPath $binaryPath -TargetDir $portableWebView2Dir -ReleaseVersion $releaseVersion -WebView2LoaderPath $webView2LoaderPath
}

if ($SkipInstaller) {
    Write-Host "Portable build: $(Join-Path $portableDir 'phantty.exe')"
    if ($webView2LoaderPath) {
        Write-Host "Portable WebView2 build: $(Join-Path $portableWebView2Dir 'phantty.exe')"
    }
    Write-Host 'Installer build skipped. Unsigned IExpress installers are prone to Windows Defender false positives.'
    exit 0
}

New-Item -ItemType Directory -Path $installerDir, $stagingDir -Force | Out-Null

Copy-Item -Path $binaryPath -Destination (Join-Path $stagingDir 'phantty.exe') -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'Install-Phantty.ps1') -Destination (Join-Path $stagingDir 'Install-Phantty.ps1') -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'install.cmd') -Destination (Join-Path $stagingDir 'install.cmd') -Force
if ($webView2LoaderPath) {
    Copy-Item -Path $webView2LoaderPath -Destination (Join-Path $stagingDir 'WebView2Loader.dll') -Force
}
Set-Content -Path $versionFile -Value $releaseVersion -Encoding ASCII

$sedFiles = @(
    'FILE0=phantty.exe',
    'FILE1=Install-Phantty.ps1',
    'FILE2=install.cmd',
    'FILE3=version.txt'
)
$sedSourceFiles = @(
    '%FILE0%=',
    '%FILE1%=',
    '%FILE2%=',
    '%FILE3%='
)
if ($webView2LoaderPath) {
    $sedFiles += 'FILE4=WebView2Loader.dll'
    $sedSourceFiles += '%FILE4%='
}

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
$($sedFiles -join "`r`n")
[SourceFiles]
SourceFiles0=$stagingDir\
[SourceFiles0]
$($sedSourceFiles -join "`r`n")
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
if ($webView2LoaderPath) {
    Write-Host "Portable WebView2 build: $(Join-Path $portableWebView2Dir 'phantty.exe')"
}
Write-Host "Installer build: $setupExe"
