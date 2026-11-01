<#
.SYNOPSIS
  Real Windows regression: refusal of an existing installation must preserve its settings.
.DESCRIPTION
  Disposable CI runner only. Invokes the actual gate and its finally path before any candidate
  code or MSI executes. The RED control changes only a private temporary copy's cleanup block.
  Registry cleanup is limited to the absent-before-test key and this fixture's exact marker.
#>
param(
  [Parameter(Mandatory = $true)] [string] $OutputDirectory,
  [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9a-fA-F]{40}$')] [string] $ExpectedCommit
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Requires an isolated Windows x64 CI runner.' }
$key = 'HKCU:\Software\DisHubCalculo'
$property = 'UpgradePreservationSentinel'
$gate = Join-Path $PSScriptRoot 'verify-windows-preview.ps1'
$marker = "foreign-existing-setting-$([Guid]::NewGuid())"
$createdKey = $false
$createdMarker = $false
$failure = $null
$proof = [ordered]@{ status = 'RUNNING'; sourceCommit = $ExpectedCommit; nativeInstallExecuted = $false }
function Require([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
Require (-not (Test-Path -LiteralPath $key)) 'Refuse to run against a pre-existing settings key.'
Require (-not (Test-Path -LiteralPath $OutputDirectory)) 'Proof directory must be new.'
[void](New-Item -ItemType Directory -Path $OutputDirectory)
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$artifacts = Join-Path $output 'empty-artifacts'
[void](New-Item -ItemType Directory -Path $artifacts)
function Invoke-ExpectedRefusal([string] $Script, [string] $Name) {
  $rejected = $false
  $errorText = ''
  $resultDirectory = Join-Path $output $Name
  try { & $Script -ArtifactDirectory $artifacts -OutputDirectory $resultDirectory -ExpectedCommit $ExpectedCommit }
  catch { $rejected = $true; $errorText = $_.ToString() }
  Require $rejected 'Gate unexpectedly accepted the pre-existing installation.'
  Require ($errorText -like '*Refuse to overwrite an existing DisHub installation.*') "Unexpected rejection: $errorText"
  $result = Get-Content -Raw -LiteralPath (Join-Path $resultDirectory 'windows-preview-verification.json') | ConvertFrom-Json -AsHashtable
  Require ($result.status -eq 'FAIL' -and $result.error -like '*Refuse to overwrite an existing DisHub installation.*') 'Refusal proof does not identify the installation preflight.'
  foreach ($field in @('portableCli', 'installExitCode', 'previousInstallExitCode', 'upgradeExitCode', 'uninstallExitCode')) {
    Require (-not $result.ContainsKey($field)) "Preflight must not execute native/installer work: $field"
  }
  Require (-not $result.ContainsKey('sentinelCleanupError')) 'Gate cleanup itself failed.'
  return @{ status = 'EXPECTED_REFUSAL'; proofPath = (Join-Path $resultDirectory 'windows-preview-verification.json') }
}
try {
  [void](New-Item -Path $key)
  $createdKey = $true
  [void](New-ItemProperty -LiteralPath $key -Name $property -Value $marker -PropertyType String)
  $createdMarker = $true
  $proof.green = Invoke-ExpectedRefusal $gate 'green'
  Require ((Get-ItemPropertyValue -LiteralPath $key -Name $property) -ceq $marker) 'GREEN: the real gate deleted or changed pre-existing settings.'
  $proof.green.markerPreserved = $true

  # Exact restoration of the reported defect in a private copy, never the checked-out gate.
  $text = Get-Content -Raw -LiteralPath $gate
  $guarded = @'
    if ($createdRegistrySentinel -and (Test-Path $ownRegistry)) {
      $sentinelProperty = (Get-ItemProperty -LiteralPath $ownRegistry).PSObject.Properties['UpgradePreservationSentinel']
      if ($null -ne $sentinelProperty -and $sentinelProperty.Value -eq $marker) {
        Remove-ItemProperty -LiteralPath $ownRegistry -Name 'UpgradePreservationSentinel'
      }
    }
'@
  $normalized = $text.Replace("`r`n", "`n")
  Require (($normalized.Split([string[]]@($guarded), [StringSplitOptions]::None).Count - 1) -eq 1) 'Expected exactly one ownership guard for the RED control.'
  $legacy = "    if (Test-Path `$ownRegistry) { Remove-ItemProperty -LiteralPath `$ownRegistry -Name 'UpgradePreservationSentinel' -ErrorAction SilentlyContinue }"
  $controlFolder = Join-Path $output 'private-red-copy'
  [void](New-Item -ItemType Directory -Path $controlFolder)
  $controlGate = Join-Path $controlFolder 'verify-windows-preview.ps1'
  $normalized.Replace($guarded, $legacy) | Set-Content -Encoding utf8 -LiteralPath $controlGate
  $proof.red = Invoke-ExpectedRefusal $controlGate 'red'
  $remaining = (Get-ItemProperty -LiteralPath $key).PSObject.Properties[$property]
  Require ($null -eq $remaining) 'RED control did not reproduce the old deletion defect.'
  $proof.red.originalDefectDetected = $true
  # Restore only the fixture-owned marker so cleanup follows the same ownership contract.
  [void](New-ItemProperty -LiteralPath $key -Name $property -Value $marker -PropertyType String)
} catch { $failure = $_; $proof.error = $_.ToString() }
finally {
  try {
    if ($createdKey -and (Test-Path -LiteralPath $key)) {
      $state = Get-Item -LiteralPath $key
      $value = (Get-ItemProperty -LiteralPath $key).PSObject.Properties[$property]
      if ($createdMarker -and $null -ne $value -and $value.Value -ceq $marker) {
        Remove-ItemProperty -LiteralPath $key -Name $property
      }
      $state = Get-Item -LiteralPath $key
      Require ($state.GetValueNames().Count -eq 0 -and $state.GetSubKeyNames().Count -eq 0) 'Unexpected state in fixture key; refuse recursive or foreign cleanup.'
      Remove-Item -LiteralPath $key
    }
    $proof.fixtureCleanup = 'PASS: only the fixture-owned value and empty key removed'
  } catch { if ($null -eq $failure) { $failure = $_ }; $proof.cleanupError = $_.ToString() }
  $proof.status = if ($null -eq $failure) { 'PASS' } else { 'FAIL' }
  $proof | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $output 'cleanup-ownership-verification.json')
}
if ($null -ne $failure) { throw $failure }
Write-Output 'PASS cleanup ownership: actual gate preserves foreign settings; isolated RED control detects original deletion.'
