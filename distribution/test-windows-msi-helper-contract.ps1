<#
.SYNOPSIS
  Fail fast on real MSI/COM helper contracts before a Rust build, on disposable Windows CI only.
.DESCRIPTION
  AST-extracts the actual named gate functions; it never dot-sources the gate's installer body.
  The pinned public 0.1.0 MSI is hash-verified, queried, installed per-user, inventoried and removed.
#>
param(
  [Parameter(Mandatory = $true)] [string] $OutputDirectory,
  [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9a-fA-F]{40}$')] [string] $ExpectedCommit
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Requires disposable Windows x64 GitHub Actions, never a user workstation.' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ((git -C $root rev-parse HEAD).Trim() -ne $ExpectedCommit -or $LASTEXITCODE -ne 0 -or (git -C $root status --porcelain)) { throw 'The prebuild probe requires exact clean candidate source.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Proof directory must be new.' }
[void](New-Item -ItemType Directory -Path $OutputDirectory)
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$proof = [ordered]@{ status = 'RUNNING'; sourceCommit = $ExpectedCommit; sourceTree = (git -C $root rev-parse 'HEAD^{tree}').Trim(); lastProductInventory = @(); rustBuildExecuted = $false }
$gate = Join-Path $PSScriptRoot 'verify-windows-preview.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($gate, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The real gate must parse before extracting helper contracts.' }
foreach ($name in @('Assert-True', 'Invoke-Msi', 'Get-MsiIdentity', 'Get-OwnInstalledProducts')) {
  $definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
  if ($definitions.Count -ne 1) { throw "Expected exactly one actual helper definition: $name" }
  if ($name -eq 'Get-MsiIdentity') { $identityDefinition = $definitions[0].Extent.Text }
  . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$proof.actualHelpersSha256 = (Get-FileHash -LiteralPath $gate -Algorithm SHA256).Hash.ToLowerInvariant()
$installFolder = Join-Path $env:LOCALAPPDATA 'Programs\DisHub\DisHub Cálculo'
$ownRegistry = 'HKCU:\Software\DisHubCalculo'
$ownAppPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\dishub-calculo.exe'
$msi = Join-Path $output 'dishub-calculo-0.1.0-preview.1-windows-x64.msi'
$installAttempted = $false
$installCompleted = $false
$failure = $null
try {
  Assert-True (-not (Test-Path $installFolder) -and -not (Test-Path $ownRegistry) -and -not (Test-Path $ownAppPath)) 'Refuse to overwrite an existing DisHub installation.'
  $before = @(Get-OwnInstalledProducts)
  $proof.beforeProductInventory = $before
  Assert-True ($before.Count -eq 0) 'Refuse to modify an existing related MSI product.'
  $url = 'https://github.com/betosaco/gridcraft/releases/download/dishub-calculo-v0.1.0-preview.1/dishub-calculo-0.1.0-preview.1-windows-x64.msi'
  $sha256 = '5af1906b28ab04b092847d2d03e0c0fc9a13c17dc803a0b9d53ae95456abdadc'
  Invoke-WebRequest -Uri $url -OutFile $msi
  Assert-True ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant() -eq $sha256) 'Previous public MSI hash mismatch; do not query or execute it.'
  $outputs = @(Get-MsiIdentity $msi)
  $proof.identityOutputCount = $outputs.Count
  $proof.identityOutputTypes = @($outputs | ForEach-Object { if ($null -eq $_) { '<null>' } else { $_.GetType().FullName } })
  Assert-True ($outputs.Count -eq 1 -and $outputs[0] -is [hashtable]) 'Get-MsiIdentity must emit exactly one hashtable, with no COM pipeline output.'
  $identity = $outputs[0]
  Assert-True ($identity.Count -eq 4) 'MSI identity must contain exactly the four required properties.'
  Assert-True ($identity.ProductCode -eq '{DBD3420C-F479-4268-B31D-251A035C9516}' -and $identity.UpgradeCode -eq '{05C18FF9-F9BE-5BD2-968F-4C229F64BD17}' -and $identity.ProductName -eq 'DisHub Cálculo' -and $identity.ProductVersion -eq '0.1.0') 'Pinned public MSI identity does not match its actual known four properties.'
  $proof.identity = $identity
  # Read-only RED control: restore only the three old output statements in a private helper.
  $legacyDefinition = $identityDefinition.Replace("`r`n", "`n").Replace("`r", "`n")
  foreach ($change in @(
    @{ before = 'function Get-MsiIdentity('; after = 'function Get-LegacyMsiIdentityControl(' },
    @{ before = '[void]$view.Execute()'; after = '$view.Execute()' },
    @{ before = '[void]$view.Close()'; after = '$view.Close()' },
    @{ before = 'return ,$identity'; after = 'return $identity' }
  )) {
    Assert-True ([regex]::Matches($legacyDefinition, [regex]::Escape($change.before)).Count -eq 1) 'RED helper restoration must match exactly one actual statement.'
    $legacyDefinition = $legacyDefinition.Replace($change.before, $change.after)
  }
  . ([scriptblock]::Create($legacyDefinition))
  $legacyOutputs = @(Get-LegacyMsiIdentityControl $msi)
  $legacyExact = $legacyOutputs.Count -eq 1 -and $legacyOutputs[0] -is [hashtable] -and $legacyOutputs[0].Count -eq 4
  $proof.readOnlyRedControl = @{
    outputCount = $legacyOutputs.Count
    outputTypes = @($legacyOutputs | ForEach-Object { if ($null -eq $_) { '<null>' } else { $_.GetType().FullName } })
    originalPipelineDefectReproduced = -not $legacyExact
  }
  Assert-True (-not $legacyExact) 'Original COM pipeline defect was not reproduced; preserve output type diagnostics and investigate before building.'
  $proof.previousMsi = @{ url = $url; sha256 = $sha256 }
  $installAttempted = $true
  $proof.installExitCode = Invoke-Msi @('/i', "`"$msi`"", 'ALLUSERS=""', 'MSIINSTALLPERUSER=1', 'DESKTOPSHORTCUT=0', "INSTALLFOLDER=`"$installFolder`"") 'msi-helper-install.log'
  $installCompleted = $true
  $installed = @(Get-OwnInstalledProducts)
  $proof.installedProductInventory = $installed
  Assert-True ($installed.Count -eq 1 -and $installed[0].PSChildName -eq $identity.ProductCode -and $installed[0].DisplayName -eq $identity.ProductName -and $installed[0].DisplayVersion -eq $identity.ProductVersion) 'Authoritative MSI inventory must identify exactly the pinned installed product.'
  $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  Assert-True ($installed[0].Context -eq 2 -and $installed[0].UserSid -eq $currentSid -and $installed[0].AssignmentType -eq '0') 'MSI helper must preserve strict current-user unmanaged context.'
  Assert-True ((Test-Path (Join-Path $installFolder 'dishub-calculo.exe')) -and (Test-Path (Join-Path $installFolder 'dishub-calculo-cli.exe'))) 'The pinned MSI did not install the actual payload.'
} catch { $failure = $_; $proof.error = $_.ToString() }
finally {
  if ($installAttempted) {
    try {
      $allowed = if ($installCompleted) { @(0,3010) } else { @(0,3010,1605) }
      $proof.uninstallExitCode = Invoke-Msi @('/x', "`"$msi`"", 'ALLUSERS=""', 'MSIINSTALLPERUSER=1') 'msi-helper-uninstall.log' $allowed
      $after = @(Get-OwnInstalledProducts)
      $proof.afterProductInventory = $after
      Assert-True ($after.Count -eq 0) 'Prebuild cleanup left a registered related MSI product.'
      Assert-True (-not (Test-Path (Join-Path $installFolder 'dishub-calculo.exe')) -and -not (Test-Path (Join-Path $installFolder 'dishub-calculo-cli.exe')) -and -not (Test-Path $ownAppPath)) 'Prebuild cleanup left payload or App Paths registration.'
      if (Test-Path -LiteralPath $installFolder) {
        Assert-True (@(Get-ChildItem -LiteralPath $installFolder -Force).Count -eq 0) 'Unexpected files remain in the fixture directory; refuse recursive cleanup.'
        Remove-Item -LiteralPath $installFolder
        $proof.emptyFixtureDirectoryRemoved = $true
      }
      # These exact keys were absent before this fixture installed its verified MSI.
      # Remove only empty leftovers, deepest first; preserve and refuse any unexpected values.
      $proof.emptyFixtureKeysRemoved = @()
      foreach ($key in @('HKCU:\Software\DisHubCalculo\Capabilities\FileAssociations', 'HKCU:\Software\DisHubCalculo\Capabilities', 'HKCU:\Software\DisHubCalculo\Installer', $ownRegistry)) {
        if (Test-Path -LiteralPath $key) {
          $state = Get-Item -LiteralPath $key
          Assert-True ($state.GetValueNames().Count -eq 0 -and $state.GetSubKeyNames().Count -eq 0) 'Unexpected registry state after fixture uninstall; refuse foreign or recursive cleanup.'
          Remove-Item -LiteralPath $key
          $proof.emptyFixtureKeysRemoved += $key
        }
      }
      $proof.cleanup = 'PASS: verified fixture MSI uninstalled; only its absent-before empty registry keys removed, only its empty absent-before application directory removed'
    } catch { if ($null -eq $failure) { $failure = $_ }; $proof.cleanupError = $_.ToString() }
  }
  $proof.status = if ($null -eq $failure) { 'PASS' } else { 'FAIL' }
  $proof | ConvertTo-Json -Depth 15 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $output 'msi-helper-contract-verification.json')
}
if ($null -ne $failure) { throw $failure }
Write-Output 'PASS prebuild real COM/MSI helpers: one exact identity object, strict per-user inventory and uninstall cleanup.'
