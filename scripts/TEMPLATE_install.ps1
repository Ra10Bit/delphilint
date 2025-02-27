#!/usr/bin/env -S powershell -File
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

##{STARTREPLACE}##
Write-Host -ForegroundColor Red "This script is a template. Do not run it directly."
Exit 1
##{ENDREPLACE}##
$DelphiLintFolder = Join-Path $env:APPDATA "DelphiLint"
$BinFolder = (Join-Path $DelphiLintFolder "bin")

function New-AppDataPath {
  New-Item -Path $DelphiLintFolder -ItemType Directory -ErrorAction Ignore | Out-Null
  New-Item -ItemType Directory $BinFolder -Force -ErrorAction Ignore | Out-Null
  Write-Host "Created DelphiLint folder."
}

function Clear-RegistryEntry {
  $RegistryPath = "HKCU:\SOFTWARE\Embarcadero\BDS\$RegistryVersion\Known Packages"
  
  if (Test-Path $RegistryPath) {
    (Get-ItemProperty -Path $RegistryPath).PSObject.Properties `
    | Where-Object { $_.Value -eq "DelphiLint" } `
    | ForEach-Object {
      Remove-Item $_.Name -ErrorAction Continue
      Remove-ItemProperty -Path $RegistryPath -Name $_.Name -ErrorAction Continue
      if ($?) {
        Write-Host "Removed existing DelphiLint install at $($_.Name)."
      }
    }
  }
}

function Copy-BuildArtifacts {
  # Copy JAR file
  $JarFile = "delphilint-server-$Version.jar"
  if (Test-Path (Join-Path $PSScriptRoot $JarFile)) {
    Copy-Item -Path (Join-Path $PSScriptRoot $JarFile) -Destination (Join-Path $DelphiLintFolder $JarFile) -Force
    Write-Host "Copied $JarFile."
  }
  else {
    Write-Host -ForegroundColor Yellow "Warning: $JarFile not found."
  }
  
  # Copy dof2dproj.exe
  if (Test-Path (Join-Path $PSScriptRoot "dof2dproj.exe")) {
    Copy-Item -Path (Join-Path $PSScriptRoot "dof2dproj.exe") -Destination (Join-Path $DelphiLintFolder "dof2dproj.exe") -Force
    Write-Host "Copied dof2dproj.exe."
  }
  else {
    Write-Host -ForegroundColor Yellow "Warning: dof2dproj.exe not found."
  }
  
  # Copy delphilint.ini
  if (Test-Path (Join-Path $PSScriptRoot "delphilint.ini")) {
    Copy-Item -Path (Join-Path $PSScriptRoot "delphilint.ini") -Destination (Join-Path $DelphiLintFolder "delphilint.ini") -Force
    Write-Host "Copied delphilint.ini."
  }
  else {
    Write-Host -ForegroundColor Yellow "Warning: delphilint.ini not found."
  }
  
  # Check for Delphi client BPL
  $BplName = "DelphiLintClient-$Version-$VersionName.bpl"
  $HasDelphiClient = Test-Path (Join-Path $PSScriptRoot $BplName)
  if ($HasDelphiClient) {
    Copy-Item -Path (Join-Path $PSScriptRoot $BplName) -Destination (Join-Path $DelphiLintFolder $BplName) -Force
    Write-Host "Copied $BplName."
  }
  else {
    Write-Host -ForegroundColor Yellow "Warning: Delphi client files ($BplName) not found. Skipping Delphi IDE integration."
  }
  
  return $HasDelphiClient
}

function Get-WebView2 {
  $TempFolder = (Join-Path $DelphiLintFolder "tmp")
  New-Item -ItemType Directory $TempFolder -Force -ErrorAction Ignore | Out-Null

  $WebViewZip = (Join-Path $TempFolder "webview.zip")

  Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.2210.55" -OutFile $WebViewZip

  Add-Type -Assembly System.IO.Compression.FileSystem
  $Archive = [System.IO.Compression.ZipFile]::OpenRead($WebViewZip)
  try {
    $Archive.Entries |
    Where-Object { $_.FullName -eq "build/native/x86/WebView2Loader.dll" } |
    ForEach-Object {
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, (Join-Path $BinFolder "WebView2Loader.dll"), $true)
      Write-Host "Downloaded $($_.Name) from NuGet."
    }
  }
  finally {
    $Archive.Dispose()
  }

  Remove-Item $TempFolder -Recurse -Force -ErrorAction Continue
}

function Add-RegistryEntry { 
  $BplName = "DelphiLintClient-$Version-$VersionName.bpl"
  $BplPath = Join-Path $DelphiLintFolder $BplName
  
  try {
    New-ItemProperty -Path "HKCU:\SOFTWARE\Embarcadero\BDS\$RegistryVersion\Known Packages" `
      -Name $BplPath `
      -Value 'DelphiLint' `
      -PropertyType String -ErrorAction SilentlyContinue | Out-Null

    Write-Host "Added Delphi IDE registry entry for $BplName."
  }
  catch {
    Write-Host -ForegroundColor Yellow "Warning: Could not add registry entry for Delphi IDE integration."
  }
}

function Install-VSCodeExtension {
  $VsixFile = "delphilint-vscode-$Version.vsix"
  $VsixPath = Join-Path $PSScriptRoot $VsixFile
  
  if (Test-Path $VsixPath) {
    Write-Host "Installing VS Code extension..."
    
    # Check if code command is available
    $codeCommand = Get-Command code -ErrorAction SilentlyContinue
    
    if ($codeCommand) {
      # Force install the extension
      $output = & code --force --install-extension $VsixPath 2>&1
      
      if ($LASTEXITCODE -eq 0) {
        Write-Host "VS Code extension installed successfully."
        
        # Prompt to restart VS Code
        Write-Host -ForegroundColor Yellow "Please restart all VS Code windows for the extension to take effect."
      }
      else {
        Write-Host -ForegroundColor Yellow "Warning: VS Code extension installation returned: $output"
      }
    }
    else {
      Write-Host -ForegroundColor Yellow "Warning: VS Code command not found in PATH. Please install the extension manually."
    }
  }
  else {
    Write-Host -ForegroundColor Yellow "Warning: VS Code extension file ($VsixFile) not found."
  }
}

Write-Host "Setting up DelphiLint $Version."
New-AppDataPath
$HasDelphiClient = Copy-BuildArtifacts

# Only execute these functions if Delphi client files are present
if ($HasDelphiClient) {
  Write-Host "Delphi client files found. Setting up Delphi IDE integration..."
  Get-WebView2
  Clear-RegistryEntry
  Add-RegistryEntry
}
else {
  Write-Host "Skipping Delphi IDE integration setup as client files were not found."
}

Install-VSCodeExtension
Write-Host -ForegroundColor Green "Install completed for DelphiLint $Version."