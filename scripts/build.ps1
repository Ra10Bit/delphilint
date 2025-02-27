#!/usr/bin/env -S powershell -File

<#
.SYNOPSIS
  Builds and packages all DelphiLint projects.
.DESCRIPTION
  Builds all DelphiLint projects:
  * DelphiLintClient (Delphi and JavaScript)
  * delphilint-server (Java)
  * delphilint-vscode (TypeScript)

  The built artifacts are then packaged into versioned folders and zip files.
.PARAMETER ShowOutput
  Display detailed output.
.PARAMETER SkipCompanion
  Skip building the VSCode companion extension.
.PARAMETER SkipClient
  Skip building the Delphi client.
.PARAMETER DelphiVersions
  Any number of Delphi package versions, optionally specifying an installation path.
.EXAMPLE
  build.ps1 280
  Build and package all DelphiLint projects using a standard Delphi 11 Alexandria installation.
.EXAMPLE
  build.ps1 -SkipClient
  Build and package all DelphiLint projects except the Delphi client.
.EXAMPLE
  build.ps1 "290=C:\Custom Path\Embarcadero\23.0"
  Build and package all DelphiLint projects using a non-standard Delphi 12 Athens installation.
#>

param(
    [switch]$ShowOutput,
    [switch]$SkipCompanion,
    [switch]$SkipClient = ($args.Count -eq 0), # ˜˜˜˜˜˜˜˜˜ SkipClient ˜˜ ˜˜˜˜˜˜˜˜˜ ˜˜˜˜ ˜˜˜ ˜˜˜˜˜˜˜˜˜˜
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$DelphiVersions
)

$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot/common" -Force

$Global:DelphiVersionMap = @{
    "280" = [DelphiVersion]::new("11", "Alexandria", "280", "22.0")
    "290" = [DelphiVersion]::new("12", "Athens", "290", "23.0")
}

class DelphiVersion {
    [string]$ProductVersion
    [string]$Name
    [string]$PackageVersion
    [string]$RegistryVersion

    DelphiVersion([string]$ProductVersion, [string]$Name, [string]$PackageVersion, [string]$RegistryVersion) {
        $this.ProductVersion = $ProductVersion
        $this.Name = $Name
        $this.PackageVersion = $PackageVersion
        $this.RegistryVersion = $RegistryVersion
    }
}

class DelphiInstall {
    [DelphiVersion]$Version
    [string]$InstallationPath

    DelphiInstall([string]$PackageVersion) {
        $this.Version = $Global:DelphiVersionMap[$PackageVersion]
        $this.InstallationPath = "C:\Program Files (x86)\Embarcadero\Studio\$($this.Version.RegistryVersion)"
    }

    DelphiInstall([string]$PackageVersion, [string]$InstallationPath) {
        $this.Version = $Global:DelphiVersionMap[$PackageVersion]
        $this.InstallationPath = $InstallationPath
    }
}

class PackagingConfig {
    [DelphiInstall]$Delphi
    [Hashtable]$Artifacts
    [string]$Version

    PackagingConfig([DelphiInstall]$Delphi) {
        $this.Delphi = $Delphi
        $this.Artifacts = @{}
        $this.Version = Get-Version
    }

    [string] GetOutputBplName() {
        return "DelphiLintClient-$($this.Version)-$($this.Delphi.Version.Name).bpl"
    }

    [string] GetInputBplPath() {
        $Ver = $this.Delphi.Version.PackageVersion
        return Join-Path $PSScriptRoot "../client/source/target/$Ver/Release/DelphiLintClient$Ver.bpl"
    }

    [string] GetPackageFolderName() {
        return "DelphiLint-$($this.Version)-$($this.Delphi.Version.Name)"
    }
}

$DelphiInstalls = $DelphiVersions `
| ForEach-Object { , ($_ -split '=') } `
| Where-Object {
    $SupportedVersion = $DelphiVersionMap.ContainsKey($_[0])

    if (-not $SupportedVersion) {
        Write-Host "Delphi version '$($_[0])' is not compatible with DelphiLint, ignoring."
    }

    return $SupportedVersion
} `
| ForEach-Object {
    if ($_.Length -gt 1) {
        return [DelphiInstall]::new($_[0], $_[1])
    }
    else {
        return [DelphiInstall]::new($_[0])
    }
}

if ($DelphiInstalls.Length -eq 0 -and $SkipClient) {
    # Create a default packaging config when skipping client
    $DelphiInstalls = @([DelphiInstall]::new("290")) # Use 290 (Delphi 12) as default
    Write-Host "Creating default package configuration for Delphi 12 (client build will be skipped)"
}
elseif ($DelphiInstalls.Length -eq 0) {
    Write-Problem "Please supply at least one version to build for."
    Exit
}

$Version = Get-Version
Write-Host "Get-Version: $Version"
$StaticVersion = $Version -replace "\+dev.*$", "+dev"
Write-Host "StaticVersion: $StaticVersion"
$GitHash = (git rev-parse --short HEAD)  # If you need to keep the git hash
Write-Host "GitHash: $GitHash"
# ˜˜˜˜˜˜˜ git ˜˜˜ ˜˜ ˜˜˜˜˜˜, ˜˜˜˜˜˜˜˜ ˜˜˜˜˜˜ ˜˜˜˜˜˜˜˜ ˜˜˜˜˜˜
$CleanVersion = $Version -replace "\.[a-f0-9]{7}$", ""
Write-Host "CleanVersion: $CleanVersion"

$ServerJar = Join-Path $PSScriptRoot "../server/delphilint-server/target/delphilint-server-$Version.jar"
$CompanionVsix = Join-Path $PSScriptRoot "../companion/delphilint-vscode/delphilint-vscode-$CleanVersion.vsix"

$TargetDir = Join-Path $PSScriptRoot "../target"

function Assert-Exists([string]$Path) {
    if (Test-Path $Path) {
        Write-Status -Status Success "$(Resolve-PathToRoot $Path) exists."
    }
    else {
        Write-Status -Status Problem "$Path does not exist."
        Exit
    }
}

function Test-ClientVersion([string]$Path, [string]$Version) {
    $Split = Split-Version $Version

    $DevVersionStr = if ($Split.Dev) { "True" } else { "False" }

    $DlVersionContent = Get-Content $Path -Raw
    $MatchMajor = $DlVersionContent -imatch ".*{MAJOR}$($Split.Major){\/MAJOR}.*"
    $MatchMinor = $DlVersionContent -imatch ".*{MINOR}$($Split.Minor){\/MINOR}.*"
    $MatchPatch = $DlVersionContent -imatch ".*{PATCH}$($Split.Patch){\/PATCH}.*"
    $MatchDevVersion = $DlVersionContent -imatch ".*{DEV}$DevVersionStr{\/DEV}.*"

    return $MatchMajor -and $MatchMinor -and $MatchPatch -and $MatchDevVersion
}

function Assert-ClientVersion([string]$Version, [string]$Message) {
    $Path = (Join-Path $PSScriptRoot "../client/source/dlversion.inc")

    if (Test-ClientVersion -Path $Path -Version $Version) {
        Write-Status -Status Success "Version is set correctly as $Version in dlversion.inc."
    }
    else {
        Write-Status -Status Problem "Version is not set correctly as $Version in dlversion.inc."
        Exit
    }
}

function Assert-ExitCode([string]$Desc) {
    if ($LASTEXITCODE) {
        throw "$Desc failed with code $LASTEXITCODE"
    }
}

function Invoke-ClientCompile([PackagingConfig]$Config) {
    Push-Location (Join-Path $PSScriptRoot ..\client\source)
    try {
        & cmd /c "`"$($Config.Delphi.InstallationPath)\\bin\\rsvars.bat`" && msbuild DelphiLintClient$($Config.Delphi.Version.PackageVersion).dproj /p:config=`"Release`""
        Assert-ExitCode "Delphi compile"
    }
    finally {
        Pop-Location
    }
}

function Invoke-ServerCompile() {
    Push-Location (Join-Path $PSScriptRoot ..\server)
    try {
        & .\buildversioned.ps1
    }
    finally {
        Pop-Location
    }
}

function Invoke-DOF2DPROJCompile([DelphiInstall]$Delphi) {
    Write-Host "Compiling DOF2DPROJ utility..."
    $ProjectPath = Join-Path $PSScriptRoot "..\utils\DOF2DPROJ\dof2dproj.dproj"
  
    Push-Location (Join-Path $PSScriptRoot "..\utils\DOF2DPROJ")
    try {
        & cmd /c "`"$($Delphi.InstallationPath)\bin\rsvars.bat`" && msbuild dof2dproj.dproj /p:config=`"Release`""
        Assert-ExitCode "DOF2DPROJ compile"
      
        # Get the output EXE path
        $OutputPath = Join-Path $PSScriptRoot "..\utils\DOF2DPROJ\Win32\Release\dof2dproj.exe"
      
        # Add to common artifacts so it's included in all packages
        $CommonArtifacts.Add($OutputPath, "dof2dproj.exe")
    }
    finally {
        Pop-Location
    }
}

function Invoke-VscCompanionCompile {
    Push-Location (Join-Path $PSScriptRoot ..\companion\delphilint-vscode)
    try {
        # Clear npm cache first
        & npm cache clean --force
        
        # Delete existing node_modules and package-lock.json
        if (Test-Path node_modules) {
            Remove-Item -Recurse -Force node_modules
        }
        if (Test-Path package-lock.json) {
            Remove-Item -Force package-lock.json
        }

        # Backup original package.json
        Copy-Item package.json package.json.bak -Force

        # Update version in package.json to use clean version
        $packageJson = Get-Content "package.json" | ConvertFrom-Json
        $packageJson.version = $CleanVersion  # This should be "1.3.0" etc.
        $packageJson | ConvertTo-Json -Depth 100 | Set-Content "package.json"

        & npm install --no-package-lock
        Assert-ExitCode "VS Code companion npm install"
      
        # Package without git info
        & npx -y @vscode/vsce package --skip-license --no-git-tag-version
        Assert-ExitCode "VS Code companion build"

        # Restore original package.json
        Move-Item package.json.bak package.json -Force
    }
    finally {
        Pop-Location
    }
}

function Clear-TargetFolder {
    New-Item -ItemType Directory $TargetDir -Force | Out-Null
    Get-ChildItem -Path $TargetDir -Recurse | Remove-Item -Force -Recurse
}

function New-BatchScript([string]$Path, [string]$PSScriptPath) {
    $BatchScript = @(
        '@echo off',
        'echo Checking for administrative privileges...',
        'net session >nul 2>&1',
        'if %errorLevel% == 0 (',
        '    echo Admin rights confirmed.',
        ') else (',
        '    echo This script requires administrative privileges.',
        '    echo Please run as administrator.',
        '    pause',
        '    exit /b 1',
        ')',
        '',
        "powershell -ExecutionPolicy Bypass -File `"%~dp0\$PSScriptPath`"",
        'pause'
    )
  
    Set-Content -Path $Path -Value $BatchScript
}

function New-SetupScript([string]$Path, [PackagingConfig]$Config) {
    $MacroContents = "`$Version = '$($Config.Version)'`n`$VersionName = '$($Config.Delphi.Version.Name)'`n`$RegistryVersion = '$($Config.Delphi.Version.RegistryVersion)'`n"

    Copy-Item (Join-Path $PSScriptRoot TEMPLATE_install.ps1) $Path
    $Content = Get-Content -Raw $Path
    $Content = $Content -replace "##\{STARTREPLACE\}##(.|\n)*##\{ENDREPLACE\}##", $MacroContents
    Set-Content -Path $Path -Value $Content
}

function New-PackageFolder([PackagingConfig]$Config, [hashtable]$Artifacts) {
    $Path = (Join-Path $TargetDir $Config.GetPackageFolderName())
    New-Item -ItemType Directory $Path -Force

    $Artifacts.GetEnumerator() | ForEach-Object {
        # Create the directory structure if it contains subdirectories
        $DestPath = Join-Path $Path $_.Value
        $DestDir = Split-Path -Parent $DestPath
        if (-not (Test-Path $DestDir)) {
            New-Item -ItemType Directory $DestDir -Force
        }
        Copy-Item -Path $_.Key -Destination $DestPath
    }

    $InstallScriptPath = (Join-Path $Path "install.ps1")
    New-SetupScript -Path $InstallScriptPath -Config $Config
    New-BatchScript -Path (Join-Path $Path "install.bat") -PSScriptPath "install.ps1"
}

function Get-PackageFolder([string]$DelphiVersion) {
    return Join-Path $TargetDir "DelphiLint-$Version-$($_.Install.DelphiVersion)"
}

function Invoke-Project([hashtable]$Project) {
    if ($Project.Prerequisite) {
        Write-Host -ForegroundColor Yellow "Preconditions:"
        & $Project.Prerequisite
        Write-Host
    }

    $Time = Measure-Command {
        $Output = ""

        if ($ShowOutput) {
            & $Project.Build | ForEach-Object { Write-Host $_ }
        }
        else {
            $Output = (& $Project.Build)
        }

        if ($LASTEXITCODE -eq 0) {
            Write-Host -ForegroundColor Green "Succeeded" -NoNewline
        }
        else {
            $Output | ForEach-Object { Write-Host $_ }
            Write-Problem "Failed."
            Exit
        }
    }
    Write-Host -ForegroundColor Green " in $($Time.TotalSeconds) seconds."

    if ($Project.Postrequisite) {
        Write-Host
        Write-Host -ForegroundColor Yellow "Postconditions:"
        & $Project.Postrequisite
    }
}

#-----------------------------------------------------------------------------------------------------------------------

$StandaloneArtifacts = @{}
$CommonArtifacts = @{}

$PackagingConfigs = $DelphiInstalls | ForEach-Object { [PackagingConfig]::new($_) }

$Projects = @(
    @{
        "Name"          = "Build client"
        "Prerequisite"  = {
            Assert-ClientVersion -Version $Version
            $PackagingConfigs | ForEach-Object { Assert-Exists $_.Delphi.InstallationPath }
        }
        "Build"         = {
            $PackagingConfigs | ForEach-Object {
                Invoke-ClientCompile -Config $_
                $_.Artifacts.Add($_.GetInputBplPath(), $_.GetOutputBplName())
                Write-Host "Built for Delphi $($_.Delphi.Version.Name) ($($_.Delphi.Version.PackageVersion))."
            }
            else {
                Write-Host -ForegroundColor Yellow "-SkipClient flag passed - skipping Delphi client build."
            }
        }
        "Postrequisite" = {
            $PackagingConfigs | ForEach-Object {
                Assert-Exists $_.GetInputBplPath()
            }
        }
    },
    @{
        "Name"          = "Build server"
        "Build"         = {
            Invoke-ServerCompile
            $StandaloneArtifacts.Add($ServerJar, "delphilint-server-$Version.jar");
            $CommonArtifacts.Add($ServerJar, "delphilint-server-$Version.jar");
            $DelphiLintIniPath = Join-Path $PSScriptRoot "..\utils\delphilint.ini"
            if (Test-Path $DelphiLintIniPath) {
                $CommonArtifacts.Add($DelphiLintIniPath, "delphilint.ini")
            }
            else {
                Write-Warning "delphilint.ini not found at: $DelphiLintIniPath"
            }
        }
        "Postrequisite" = {
            Assert-Exists $ServerJar
        }
    },
    @{
        "Name"          = "Build VS Code companion"
        "Build"         = {
            if ($SkipCompanion) {
                Write-Host -ForegroundColor Yellow "-SkipCompanion flag passed - skipping build."
            }
            else {
                Invoke-VscCompanionCompile
                $StandaloneArtifacts.Add($CompanionVsix, "delphilint-vscode-$StaticVersion.vsix");
                # Add VSIX to common artifacts so it's included in all packages
                $CommonArtifacts.Add($CompanionVsix, "delphilint-vscode-$StaticVersion.vsix")
            }
        }
        "Postrequisite" = {
            if (-not $SkipCompanion) {
                Assert-Exists $CompanionVsix
            }
        }
    },
    @{
        "Name"          = "Build DOF2DPROJ utility"
        "Build"         = {
            # Use the first Delphi installation to compile DOF2DPROJ
            if ($DelphiInstalls.Length -gt 0) {
                Invoke-DOF2DPROJCompile -Delphi $DelphiInstalls[0]
            }
            elseif ($SkipClient) {
                # If skipping client and no Delphi version specified, use default Delphi install
                $DefaultDelphi = [DelphiInstall]::new("290")  # Use Delphi 12
                Invoke-DOF2DPROJCompile -Delphi $DefaultDelphi
            }
        }
        "Postrequisite" = {
            $OutputPath = Join-Path $PSScriptRoot "..\utils\DOF2DPROJ\Win32\Release\dof2dproj.exe"
            Assert-Exists $OutputPath
        }
    },
    @{
        "Name"          = "Collate build artifacts"
        "Build"         = {
            Clear-TargetFolder
            $StandaloneArtifacts.GetEnumerator() | ForEach-Object {
                Copy-Item -Path $_.Key -Destination (Join-Path $TargetDir $_.Value)
            }
            $PackagingConfigs | ForEach-Object {
                New-PackageFolder -Config $_ -Artifacts ($CommonArtifacts + $_.Artifacts)
            }
        }
        "Postrequisite" = {
            $StandaloneArtifacts.Values | ForEach-Object {
                Assert-Exists (Join-Path $TargetDir $_)
            }

            $PackagingConfigs | ForEach-Object {
                $PackageFolder = (Join-Path $TargetDir $_.GetPackageFolderName())

                $CommonArtifacts.Values | ForEach-Object {
                    Assert-Exists (Join-Path $PackageFolder $_)
                }

                $_.Artifacts.Values | ForEach-Object {
                    Assert-Exists (Join-Path $PackageFolder $_)
                }
            }
        }
    },
    @{
        "Name"          = "Zip build artifacts"
        "Build"         = {
            $PackagingConfigs | ForEach-Object {
                $PackageFolder = Join-Path $TargetDir $_.GetPackageFolderName()
                $ZippedPackage = "${PackageFolder}.zip"
                Compress-Archive $PackageFolder -DestinationPath $ZippedPackage -Force
            }
        }
        "Postrequisite" = {
            $PackagingConfigs | ForEach-Object {
                $ZippedPackage = "$($_.GetPackageFolderName()).zip"
                Assert-Exists (Join-Path $TargetDir $ZippedPackage)
            }
        }
    }
);

#-----------------------------------------------------------------------------------------------------------------------

Write-Title "Packaging DelphiLint ${Version}"

$Time = Measure-Command {
    $Projects | ForEach-Object {
        Write-Header $_.Name
      
        if ($_.Name -eq "Build client" -and $SkipClient) {
            Write-Host -ForegroundColor Yellow "-SkipClient flag passed - skipping Delphi client build."
        }
        else {
            Invoke-Project $_
        }
    }
}

Write-Title "DelphiLint $Version packaged"
Write-Host "Succeeded in $($Time.TotalSeconds) seconds."