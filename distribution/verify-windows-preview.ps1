<#
.SYNOPSIS
  Verify a real Windows x64 preview candidate on an isolated, disposable Windows runner.
.DESCRIPTION
  Exercises the native CLI through its public headless MCP protocol, installs/uninstalls
  the actual MSI, and verifies upstream-identity sentinels. This is not a GUI launch test,
  a test of a real preinstalled GridCraft, or previous-version/cancellation qualification.
#>
param(
  [Parameter(Mandatory = $true)] [string] $ArtifactDirectory,
  [Parameter(Mandatory = $true)] [string] $OutputDirectory,
  [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9a-fA-F]{40}$')] [string] $ExpectedCommit
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'This integration gate must run on Windows with the real x64 payload.' }
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'An x64 Windows runner is required.' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$artifacts = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Proof output must be a new directory.' }
[void](New-Item -ItemType Directory -Path $OutputDirectory)
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$proofPath = Join-Path $output 'windows-preview-verification.json'
$proof = [ordered]@{
  status = 'RUNNING'
  sourceCommit = $ExpectedCommit.ToLowerInvariant()
  platform = 'windows'; architecture = 'x64'; releaseChannel = 'experimental'
  commercialSignature = $false
  guiLaunch = 'NOT_RUN: native headless CLI and MSI payload only'
  coexistence = 'PENDING: sentinel isolation, not a real upstream installation'
  futureQualification = @('previous fork version upgrade', 'interactive cancellation and full rollback')
}

function Assert-True([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}
function Json([object] $Value) { return ConvertTo-Json -InputObject $Value -Depth 60 -Compress }
function Save-Proof { $proof | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 -LiteralPath $proofPath }
function Invoke-Msi([string[]] $Arguments, [string] $LogName, [int[]] $Allowed = @(0, 3010)) {
  $log = Join-Path $output $LogName
  $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
    -ArgumentList ($Arguments + @('/qn', '/norestart', '/l*v', "`"$log`"")) -PassThru
  if (-not $process.WaitForExit(180000)) { $process.Kill(); throw "MSI timed out; see $log" }
  $process.Refresh()
  Assert-True ($process.ExitCode -in $Allowed) "MSI exited $($process.ExitCode); see $log"
  return $process.ExitCode
}

function Invoke-Rpc([string] $Method, [hashtable] $Params) {
  $script:rpcId += 1
  $id = $script:rpcId
  $script:mcp.StandardInput.WriteLine((Json @{ jsonrpc = '2.0'; id = $id; method = $Method; params = $Params }))
  $script:mcp.StandardInput.Flush()
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  while ([DateTime]::UtcNow -lt $deadline) {
    $lineTask = $script:mcp.StandardOutput.ReadLineAsync()
    $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if (-not $lineTask.Wait($remaining)) { throw "MCP timeout: $Method" }
    $line = $lineTask.Result
    if ($null -eq $line) { throw "MCP closed while handling $Method" }
    $reply = ConvertFrom-Json -InputObject $line -AsHashtable
    if ($reply.ContainsKey('id') -and $reply.id -eq $id) {
      if ($reply.ContainsKey('error')) { throw "MCP RPC error: $(Json $reply.error)" }
      return ,$reply.result
    }
  }
  throw "MCP deadline exceeded: $Method"
}
function Invoke-Tool([string] $Name, [hashtable] $Arguments, [switch] $ExpectError) {
  $result = Invoke-Rpc 'tools/call' @{ name = $Name; arguments = $Arguments }
  $isError = $result.ContainsKey('isError') -and $result.isError
  if ($ExpectError) {
    Assert-True $isError "Expected refusal from $Name, but it succeeded."
    return ,$result
  }
  Assert-True (-not $isError) "MCP tool failed: $(Json $result)"
  $texts = @($result.content | Where-Object { $_.type -eq 'text' })
  Assert-True ($texts.Count -eq 1) "Expected one JSON content block from $Name."
  return ,(ConvertFrom-Json -InputObject $texts[0].text -AsHashtable)
}
function Engine([string] $Command, [hashtable] $Params = @{}) {
  return ,(Invoke-Tool 'execute_command' @{ command = $Command; params = $Params })
}
function Read-Source {
  $read = Invoke-Tool 'read_range' @{ sheet = 'Sheet1'; range = 'A1:G2' }
  return Json $read['values']
}

function Test-NativeCli([string] $Cli, [string] $Label, [string] $ExpectedVersion) {
  $versionStart = [Diagnostics.ProcessStartInfo]::new()
  $versionStart.FileName = $Cli
  [void]$versionStart.ArgumentList.Add('--version')
  $versionStart.UseShellExecute = $false
  $versionStart.CreateNoWindow = $true
  $versionStart.RedirectStandardOutput = $true
  $versionStart.RedirectStandardError = $true
  $versionProcess = [Diagnostics.Process]::Start($versionStart)
  try {
    $versionOut = $versionProcess.StandardOutput.ReadToEndAsync()
    $versionErr = $versionProcess.StandardError.ReadToEndAsync()
    if (-not $versionProcess.WaitForExit(30000)) { $versionProcess.Kill($true); $versionProcess.WaitForExit(); throw 'CLI version command timed out.' }
    $versionText = $versionOut.Result.Trim()
    Assert-True ($versionProcess.ExitCode -eq 0) "CLI version command failed: $($versionErr.Result)"
    Assert-True ($versionText -eq "dishub-calculo-cli $ExpectedVersion (GridCraft base 0.13.0)") 'CLI name/version/base identity does not match this edition.'
  } finally { $versionProcess.Dispose() }
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $Cli
  [void]$start.ArgumentList.Add('mcp')
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $script:mcp = [Diagnostics.Process]::Start($start)
  $stderr = $script:mcp.StandardError.ReadToEndAsync()
  $script:rpcId = 0
  try {
    $hello = Invoke-Rpc 'initialize' @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'dishub-windows-preview-gate'; version = '1' } }
    Assert-True ($hello.serverInfo.version -eq $ExpectedVersion) 'Headless engine version does not match the candidate.'
    $script:mcp.StandardInput.WriteLine((Json @{ jsonrpc = '2.0'; method = 'notifications/initialized' }))
    $script:mcp.StandardInput.Flush()
    $act = Engine 'formulas.functions' @{ search = 'ACT.' }
    Assert-True (@($act | Where-Object { $_.name.StartsWith('ACT.') }).Count -eq 95) 'Expected exactly 95 ACT functions.'
    $mcFunctions = Engine 'formulas.functions' @{ search = 'MC.' }
    $mc = @($mcFunctions | Where-Object { $_.name.StartsWith('MC.') } | ForEach-Object { $_.name } | Sort-Object)
    $expectedMc = @('MC.ACTIVE', 'MC.AR1.LOGNORMAL', 'MC.AR1.NORMAL', 'MC.BINOMIAL', 'MC.HYPERGEOMETRIC', 'MC.POISSON')
    Assert-True ((Json $mc) -eq (Json $expectedMc)) 'Expected the six named native MC functions.'
    Assert-True ((Engine 'formulas.evaluate' @{ formula = '=ACT.ANNUITY(1,0)' }) -eq 1) 'ACT annuity exact oracle must equal 1.'
    $cells = [ordered]@{
      A1 = '10'
      B1 = '=IF(MC.ACTIVE(),MC.POISSON(A1,"orders"),0)'
      C1 = '=IF(MC.ACTIVE(),MC.BINOMIAL(B1,0.3,"qualified"),0)'
      D1 = '=IF(MC.ACTIVE(),MC.HYPERGEOMETRIC(MIN(4,C1),C1,B1,"capacity"),0)'
      E1 = '=IF(MC.ACTIVE(),MC.AR1.LOGNORMAL("cpl",1,10,0.3,0.6),0)'
      F1 = '=IF(AND(B1=INT(B1),C1=INT(C1),D1=INT(D1),D1>=0,D1<=C1,C1<=B1),0,1)'
      G1 = '=IF(MC.ACTIVE(),MC.AR1.NORMAL("index",1,100,2,0.4),0)'
      E2 = '=IF(MC.ACTIVE(),MC.AR1.LOGNORMAL("cpl",2,10,0.3,0.6),0)'
    }
    foreach ($cell in $cells.GetEnumerator()) { [void](Engine 'cell.set' @{ cell = $cell.Key; input = $cell.Value }) }
    $before = Read-Source
    $params = @{
      inputs = @(@{ cell = 'Sheet1!A1'; distribution = 'uniform'; min = 10; max = 10 })
      outputs = @('Sheet1!B1','Sheet1!C1','Sheet1!D1','Sheet1!E1','Sheet1!E2','Sheet1!F1','Sheet1!G1')
      iterations = 64; seed = 20261029; maxWork = 1000000; samples = $true; newSheet = 'Windows_Preview_Proof'
    }
    $first = Engine 'data.monteCarlo' $params
    Assert-True ($first.iterations -eq 64 -and $first.stochastic.countRequests -eq 192) 'Count functions were not exercised for all trials.'
    Assert-True ($first.stochastic.ar1GeneratedSteps -eq 192) 'Both AR1 families must execute their requested physical steps.'
    Assert-True ($first.outputs[5].min -eq 0 -and $first.outputs[5].max -eq 0) 'Count/integer/capacity oracle failed.'
    Assert-True ($first.outputs[3].min -gt 0 -and $first.outputs[4].min -gt 0) 'Lognormal samples must be positive.'
    Assert-True ((Read-Source) -eq $before) 'Simulation changed source cells.'
    [void](Engine 'edit.undo')
    [void](Engine 'sheet.activate' @{ sheet = 0 })
    Assert-True (@((Invoke-Tool 'inspect_workbook' @{}).sheets).Count -eq 1) 'Undo must remove the report.'
    Assert-True ((Read-Source) -eq $before) 'Undo changed source cells.'
    [void](Engine 'cell.set' @{ cell = 'E2'; input = '=IF(MC.ACTIVE(),MC.AR1.LOGNORMAL("cpl",0,10,0.3,0.6),0)' })
    $invalidBefore = Read-Source
    $invalid = @{} + $params
    $invalid.newSheet = 'Must_Not_Publish'
    $refusal = Invoke-Tool 'execute_command' @{ command = 'data.monteCarlo'; params = $invalid } -ExpectError
    Assert-True ((Json $refusal) -match 'invalid MC\.') 'The negative control must refuse the invalid MC step, not an unrelated error.'
    Assert-True ((Read-Source) -eq $invalidBefore) 'Refusal changed source cells.'
    Assert-True (@((Invoke-Tool 'inspect_workbook' @{}).sheets).Count -eq 1) 'Refusal published a report.'
    [void](Engine 'cell.set' @{ cell = 'E2'; input = $cells.E2 })
    $params.newSheet = 'Repeat_Seed_Proof'
    $repeat = Engine 'data.monteCarlo' $params
    Assert-True ((Json $repeat.outputs) -eq (Json $first.outputs)) 'Repeated controlled seed must reproduce output summaries.'
    return @{ status = 'PASS'; versionText = $versionText; actuarialFunctions = 95; nativeMCFunctions = $mc; trials = 64; countCapacityOracle = $true; bothAr1Families = $true; sourcePreserved = $true; undo = $true; invalidStepRefusedAtomically = $true; repeatedSeed = $true; cliSha256 = (Get-FileHash $Cli -Algorithm SHA256).Hash.ToLowerInvariant() }
  } finally {
    if (-not $script:mcp.HasExited) {
      $script:mcp.StandardInput.Close()
      if (-not $script:mcp.WaitForExit(5000)) { $script:mcp.Kill($true); $script:mcp.WaitForExit() }
    }
    $stderr.Result | Set-Content -Encoding utf8 -LiteralPath (Join-Path $output "$Label-mcp.stderr.log")
    $script:mcp.Dispose()
  }
}

$installFolder = Join-Path $env:LOCALAPPDATA 'Programs\DisHub\DisHub Cálculo'
$ownRegistry = 'HKCU:\Software\DisHubCalculo'
$ownAppPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\dishub-calculo.exe'
$upstreamFolder = Join-Path $env:LOCALAPPDATA 'Programs\ArtCraft\GridCraft'
$sentinelKeys = @('HKCU:\Software\GridCraft', 'HKCU:\Software\Classes\GridCraft.Workbook')
$createdSentinelKeys = [Collections.Generic.List[string]]::new()
$createdSentinelFolder = $false
$installAttempted = $false
$installCompleted = $false
$msi = $null
$portable = $null
$failure = $null
try {
  $head = (git -C $root rev-parse HEAD).Trim()
  Assert-True ($LASTEXITCODE -eq 0 -and $head -eq $ExpectedCommit) 'Verification source SHA does not match this build.'
  Assert-True (-not (git -C $root status --porcelain)) 'Verification requires clean committed source.'
  $proof.sourceTree = (git -C $root rev-parse 'HEAD^{tree}').Trim()
  $edition = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'edition.json') | ConvertFrom-Json -AsHashtable
  $version = $edition.version
  Assert-True ($version -match '^0\.1\.0-preview\.[1-9][0-9]*$') 'This gate is scoped to the first experimental preview track.'
  $manifestPath = Join-Path $artifacts "dishub-calculo-$version-windows-x64.manifest.json"
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
  Assert-True ($manifest.sourceCommit -eq $ExpectedCommit -and -not $manifest.sourceDirty) 'Candidate provenance is dirty or does not match the tested commit.'
  Assert-True ($manifest.version -eq $version -and $manifest.os -eq 'windows' -and $manifest.architecture -eq 'x64') 'Wrong candidate identity/version/platform.'
  Assert-True ($manifest.releaseChannel -eq 'experimental' -and $manifest.updatePolicy -eq 'manual' -and -not $manifest.publiclyAvailable) 'Candidate must remain manual/experimental and unpublished.'
  Assert-True (@($manifest.artifacts).Count -eq 2) 'Expected MSI and portable ZIP.'
  $expectedNames = @("dishub-calculo-$version-windows-x64.msi", "dishub-calculo-$version-windows-x64-portable.zip") | Sort-Object
  $actualNames = @($manifest.artifacts | ForEach-Object { $_.filename } | Sort-Object)
  Assert-True ((Json $actualNames) -eq (Json $expectedNames)) 'Candidate manifest must identify exactly this MSI and portable ZIP, without duplicates.'
  $artifactProofs = @()
  foreach ($artifact in $manifest.artifacts) {
    Assert-True ([IO.Path]::GetFileName($artifact.filename) -eq $artifact.filename) 'Candidate filename must be a basename.'
    $path = Join-Path $artifacts $artifact.filename
    Assert-True ((Get-Item -LiteralPath $path).Length -eq $artifact.bytes) 'Candidate size does not match its manifest.'
    Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $artifact.sha256) 'Candidate SHA256 mismatch.'
    Assert-True ($artifact.status -eq 'candidate' -and $null -eq $artifact.url) 'A verification candidate must not claim public availability.'
    $artifactProofs += @{ filename = $artifact.filename; bytes = $artifact.bytes; sha256 = $artifact.sha256; signatureStatus = [string](Get-AuthenticodeSignature -LiteralPath $path).Status }
  }
  $artifactProofs | ForEach-Object { "$($_.sha256)  $($_.filename)" } | Set-Content -Encoding ascii -LiteralPath (Join-Path $output 'SHA256SUMS.txt')
  $msi = Join-Path $artifacts "dishub-calculo-$version-windows-x64.msi"
  $zip = Join-Path $artifacts "dishub-calculo-$version-windows-x64-portable.zip"
  Assert-True ((Get-AuthenticodeSignature -LiteralPath $msi).Status -eq 'NotSigned') 'This unsigned-preview workflow must not imply commercial signing.'
  $portable = Join-Path $output 'portable'
  Expand-Archive -LiteralPath $zip -DestinationPath $portable
  $portableCli = @(Get-ChildItem $portable -Filter 'dishub-calculo-cli.exe' -Recurse -File)
  $portableApp = @(Get-ChildItem $portable -Filter 'dishub-calculo.exe' -Recurse -File)
  Assert-True ($portableCli.Count -eq 1 -and $portableApp.Count -eq 1) 'Portable archive must contain exactly one own app and CLI.'
  $proof.portableCli = Test-NativeCli $portableCli[0].FullName 'portable' $version
  $versionInfo = $portableApp[0].VersionInfo
  Assert-True ($versionInfo.ProductName -eq 'DisHub Cálculo' -and $versionInfo.ProductVersion -eq $version) 'GUI VERSIONINFO has the wrong product or version.'
  Assert-True ($versionInfo.FileMajorPart -eq 0 -and $versionInfo.FileMinorPart -eq 1 -and $versionInfo.FileBuildPart -eq 0) 'GUI numeric file version must match the 0.1.0 edition track.'
  $proof.guiFileMetadata = @{ productName = $versionInfo.ProductName; productVersion = $versionInfo.ProductVersion; numericFileVersion = @($versionInfo.FileMajorPart,$versionInfo.FileMinorPart,$versionInfo.FileBuildPart,$versionInfo.FilePrivatePart) }

  Assert-True (-not (Test-Path $installFolder) -and -not (Test-Path $ownRegistry) -and -not (Test-Path $ownAppPath)) 'Refuse to overwrite an existing DisHub installation.'
  Assert-True (-not (Test-Path $upstreamFolder)) 'Refuse to overwrite an existing upstream folder with a sentinel.'
  foreach ($key in $sentinelKeys) { Assert-True (-not (Test-Path $key)) 'Refuse to modify an existing upstream registry key.' }
  $marker = [Guid]::NewGuid().ToString()
  [void](New-Item -ItemType Directory -Path $upstreamFolder)
  $createdSentinelFolder = $true
  $sentinelFile = Join-Path $upstreamFolder 'preview-coexistence-sentinel.txt'
  Set-Content -LiteralPath $sentinelFile -Value $marker -Encoding utf8
  foreach ($key in $sentinelKeys) {
    [void](New-Item -Path $key)
    [void]$createdSentinelKeys.Add($key)
    [void](New-ItemProperty -Path $key -Name 'DisHubPreviewSentinel' -Value $marker -PropertyType String)
  }
  $sentinelHash = (Get-FileHash $sentinelFile -Algorithm SHA256).Hash
  $installAttempted = $true
  $proof.installExitCode = Invoke-Msi @('/i', "`"$msi`"", 'ALLUSERS=""', 'MSIINSTALLPERUSER=1', 'DESKTOPSHORTCUT=0', "INSTALLFOLDER=`"$installFolder`"") 'msi-install.log'
  $installCompleted = $true
  $installedCli = Join-Path $installFolder 'dishub-calculo-cli.exe'
  $installedApp = Join-Path $installFolder 'dishub-calculo.exe'
  Assert-True ((Test-Path $installedCli) -and (Test-Path $installedApp)) 'MSI did not install the actual own payload.'
  Assert-True ((Get-FileHash $installedCli -Algorithm SHA256).Hash -eq (Get-FileHash $portableCli[0].FullName -Algorithm SHA256).Hash) 'Installed CLI differs from the tested portable payload.'
  Assert-True ((Get-FileHash $installedApp -Algorithm SHA256).Hash -eq (Get-FileHash $portableApp[0].FullName -Algorithm SHA256).Hash) 'Installed GUI payload differs from portable.'
  Assert-True ((Get-ItemProperty -Path $ownRegistry -Name 'InstallDir').InstallDir.TrimEnd('\') -eq $installFolder.TrimEnd('\')) 'MSI registered an unexpected directory.'
  foreach ($notice in @('LICENSE-MIT','LICENSE-APACHE','NOTICE','ATTRIBUTION.md')) { Assert-True (Test-Path (Join-Path $installFolder $notice)) "Missing installed legal notice: $notice" }
  Assert-True (@(Get-ChildItem $installFolder -Filter 'OFL-*.txt' -File).Count -gt 0) 'Embedded official fonts require installed OFL notices.'
  $proof.installedCli = Test-NativeCli $installedCli 'installed' $version
  foreach ($key in $sentinelKeys) { Assert-True ((Get-ItemProperty -Path $key -Name 'DisHubPreviewSentinel').DisHubPreviewSentinel -eq $marker) 'Installation changed upstream registry sentinel.' }
  Assert-True ((Get-FileHash $sentinelFile -Algorithm SHA256).Hash -eq $sentinelHash) 'Installation changed upstream file sentinel.'
  $proof.installation = @{ directory = $installFolder; scope = 'current-user'; directorySelection = 'explicit isolated per-user folder'; payloadHashesMatchPortable = $true; legalNotices = $true }
  $proof.artifacts = $artifactProofs
} catch {
  $failure = $_
  $proof.error = $_.ToString()
} finally {
  if ($installAttempted -and $null -ne $msi) {
    try {
      $allowedUninstall = if ($installCompleted) { @(0,3010) } else { @(0,3010,1605) }
      $proof.uninstallExitCode = Invoke-Msi @('/x', "`"$msi`"", 'ALLUSERS=""', 'MSIINSTALLPERUSER=1') 'msi-uninstall.log' $allowedUninstall
      Assert-True (-not (Test-Path (Join-Path $installFolder 'dishub-calculo-cli.exe')) -and -not (Test-Path (Join-Path $installFolder 'dishub-calculo.exe'))) 'Uninstall left installed executable payloads.'
      Assert-True (-not (Test-Path $ownAppPath)) 'Uninstall left the own App Paths registration.'
      if (Test-Path $ownRegistry) { Assert-True ($null -eq (Get-ItemProperty -Path $ownRegistry).PSObject.Properties['InstallDir']) 'Uninstall left the own InstallDir registration.' }
      foreach ($key in $createdSentinelKeys) { Assert-True ((Get-ItemProperty -Path $key -Name 'DisHubPreviewSentinel').DisHubPreviewSentinel -eq $marker) 'Uninstall changed upstream registry sentinel.' }
      Assert-True ((Get-FileHash $sentinelFile -Algorithm SHA256).Hash -eq $sentinelHash) 'Uninstall changed upstream file sentinel.'
      $proof.uninstallation = 'PASS: own payload and application registration removed'
      $proof.coexistence = 'PASS: independently created upstream file/registry sentinels unchanged after install and uninstall; not a real upstream app installation'
    } catch {
      if ($null -eq $failure) { $failure = $_ }
      $proof.cleanupError = $_.ToString()
    }
  }
  # Only remove keys/folder created after the explicit absence checks above, never any
  # parent namespace or an existing application. This does not clean failed fork payloads.
  try {
    foreach ($key in $createdSentinelKeys) {
      if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    }
    if ($createdSentinelFolder -and (Test-Path -LiteralPath $upstreamFolder)) { Remove-Item -LiteralPath $upstreamFolder -Recurse -Force }
    if ($null -ne $portable -and (Test-Path -LiteralPath $portable)) { Remove-Item -LiteralPath $portable -Recurse -Force }
  } catch {
    if ($null -eq $failure) { $failure = $_ }
    $proof.sentinelCleanupError = $_.ToString()
  }
  $proof.status = if ($null -eq $failure) { 'PASS' } else { 'FAIL' }
  Save-Proof
}
if ($null -ne $failure) { throw $failure }
Write-Output "PASS Windows x64 experimental candidate: native 95 ACT + 6 MC, real MSI install/uninstall, sentinel coexistence. Proof: $proofPath"
