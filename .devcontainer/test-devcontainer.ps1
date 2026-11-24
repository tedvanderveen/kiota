#!/usr/bin/env pwsh
#Requires -Version 7.4
<#
.SYNOPSIS
    Health check for the Kiota dev container (not a test suite for PowerShell code): every tool at the
    version CI uses, and optionally a build and test run of the repository inside the container.

.DESCRIPTION
    -Tier Tools  Checks every tool against the versions this repository pins for CI (global.json,
                 it/go/go.mod, it/dart/pubspec.yaml, .github/workflows/*.yml). Takes about a second.
    -Tier Build  Tools, then builds kiota.slnx and the VS Code extension.
    -Tier Full   Build, then runs the .NET tests, the npm package and VS Code extension tests, and one
                 integration test per language against MockServer.

    Nothing runs this automatically: run it yourself, or see .github/workflows/devcontainer.yml, which
    runs -Tier Full on amd64 and arm64. The working tree is left as the script found it.

.EXAMPLE
    pwsh .devcontainer/test-devcontainer.ps1 -Tier Full -Language python, java
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Colored console report.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Description', Justification = 'Used inside a script block.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Script-local helpers read better positionally.')]
[CmdletBinding()]
param(
    [ValidateSet('Tools', 'Build', 'Full')]
    [string] $Tier = 'Tools',

    [ValidateSet('csharp', 'go', 'java', 'python', 'ruby', 'php', 'dart', 'typescript')]
    [string[]] $Language = @('csharp', 'go', 'java', 'python', 'ruby', 'php', 'dart', 'typescript'),

    # Has MockServer tests for most languages and no suppressions in it/config.json.
    [string] $Description = './tests/Kiota.Builder.IntegrationTests/InheritingErrors.yaml'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Write-Result([string] $Name, [bool] $Passed, [string] $Detail = '') {
    $results.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Detail = $Detail })
    $status = $Passed ? "$($PSStyle.Foreground.Green)ok  " : "$($PSStyle.Foreground.Red)FAIL"
    Write-Host ('{0}{1} {2,-28} {3}' -f $status, $PSStyle.Reset, $Name, $Detail)
}

# The first capture group of $Pattern in a repository file: how the repository pins a version for CI.
function Get-Pin([string] $Path, [string] $Pattern) {
    $match = Select-String -Path $Path -Pattern $Pattern | Select-Object -First 1
    if (-not $match) { throw "No match for '$Pattern' in $Path; update $PSCommandPath to follow that file." }
    $match.Matches[0].Groups[1].Value
}

# The version a tool reports, or $null when the tool is missing or fails (a failing `dotnet --version`
# prints the SDK version global.json requests, which must not count as installed).
function Get-ToolVersion([string[]] $CommandLine, [string] $Pattern = '(\d+\.\d+(?:\.\d+){0,2})') {
    $command, $arguments = $CommandLine[0], @($CommandLine | Select-Object -Skip 1)
    if (-not (Get-Command $command -CommandType Application -ErrorAction Ignore)) { return $null }
    $ErrorActionPreference = 'Continue'  # several tools print their version on stderr
    $output = & $command @arguments 2>&1 | Out-String
    $LASTEXITCODE -eq 0 -and $output -match $Pattern ? [version]$Matches[1] : $null
}

# True when $Version starts with $Pin ("17" matches 17.0.20, "3.14" matches 3.14.10).
function Test-Pin([version] $Version, [string] $Pin) {
    $parts = $Pin.Split('.')
    $Version.Major -eq $parts[0] -and ($parts.Count -eq 1 -or $Version.Minor -eq $parts[1])
}

# Runs a step, shows its output, and fails it on a non-zero exit code or a missing command
# (the it/*.ps1 scripts report success when a command they call is not installed).
function Invoke-Step([string] $Name, [scriptblock] $Script, [string] $Path = $root) {
    Write-Host "$($PSStyle.Foreground.Cyan)== $Name$($PSStyle.Reset)"
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location $Path
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        & $Script 2>&1 | Tee-Object -Variable output | Out-Host
        $missing = ($output | Out-String) -match 'is not recognized as a name of a cmdlet|command not found'
        Write-Result $Name ($LASTEXITCODE -eq 0 -and -not $missing) ('exit {0} in {1:n0}s{2}' -f $LASTEXITCODE, $timer.Elapsed.TotalSeconds, ($missing ? ', a command was missing' : ''))
    }
    catch { Write-Result $Name $false $_.Exception.Message }
    finally { Pop-Location }
}

#region Tools: presence and versions against the CI pins
$ci = '.github/workflows/integration-tests.yml'
$sdk = [version](Get-Content global.json -Raw | ConvertFrom-Json).sdk.version
$pins = @{
    Java      = Get-Pin $ci 'java-version:\s*"?(\d+)'
    Node      = Get-Pin $ci 'node-version:\s*"?(\d+)'
    NodeExt   = Get-Pin .github/workflows/build-vscode-extension.yml 'node-version:\s*"?(\d+)'
    GoCaret   = [version](Get-Pin $ci 'go-version:\s*"?\^(\d+\.\d+)')
    GoMod     = [version](Get-Pin it/go/go.mod '^go\s+(\d+\.\d+(?:\.\d+)?)')
    Python    = Get-Pin $ci 'python-version:\s*"?(\d+\.\d+)'
    Ruby      = Get-Pin $ci 'ruby-version:\s*"?(\d+\.\d+)'
    Php       = Get-Pin $ci 'php-version:\s*"?(\d+\.\d+)'
    Dart      = [version](Get-Pin it/dart/pubspec.yaml '^\s+sdk:\s*"?\^(\d+\.\d+(?:\.\d+)?)')
}

# Name, command line that prints the version, what CI expects, and the rule the version must meet.
# dotnet --version runs in the repository root, so it fails outright when no SDK satisfies global.json.
$tools = @(
    @{ Name = '.NET SDK'; Cmd = 'dotnet', '--version'; Expect = ">= $sdk within $($sdk.ToString(2)) (global.json); if older: Rebuild Without Cache"; Rule = { param($v) (Test-Pin $v $sdk.ToString(2)) -and $v -ge $sdk } }
    @{ Name = 'Java'; Cmd = 'java', '-version'; Expect = "$($pins.Java) ($ci)"; Rule = { param($v) Test-Pin $v $pins.Java } }
    @{ Name = 'Maven'; Cmd = 'mvn', '-v'; Expect = 'any (MockServer, Java ITs)'; Rule = { $true } }
    @{ Name = 'Node.js'; Cmd = 'node', '--version'; Expect = "$($pins.Node) (integration tests), $($pins.NodeExt) (extension)"; Rule = { param($v) (Test-Pin $v $pins.Node) -and (Test-Pin $v $pins.NodeExt) } }
    @{ Name = 'Go'; Cmd = 'go', 'version'; Expect = "^$($pins.GoCaret) ($ci), >= $($pins.GoMod) (it/go/go.mod)"; Rule = { param($v) $v.Major -eq $pins.GoCaret.Major -and $v -ge $pins.GoCaret -and $v -ge $pins.GoMod } }
    @{ Name = 'Python'; Cmd = 'python3', '--version'; Expect = "$($pins.Python) ($ci)"; Rule = { param($v) Test-Pin $v $pins.Python } }
    @{ Name = 'Ruby'; Cmd = 'ruby', '--version'; Expect = "$($pins.Ruby) ($ci)"; Rule = { param($v) Test-Pin $v $pins.Ruby } }
    @{ Name = 'Bundler'; Cmd = 'bundle', '--version'; Expect = 'any (Ruby ITs)'; Rule = { $true } }
    @{ Name = 'PHP'; Cmd = 'php', '--version'; Expect = "$($pins.Php) ($ci)"; Rule = { param($v) Test-Pin $v $pins.Php } }
    @{ Name = 'Composer'; Cmd = 'composer', '--version', '--no-interaction'; Expect = 'any (PHP ITs)'; Rule = { $true } }
    @{ Name = 'Dart'; Cmd = 'dart', '--version'; Expect = "^$($pins.Dart) (it/dart/pubspec.yaml)"; Rule = { param($v) $v.Major -eq $pins.Dart.Major -and $v -ge $pins.Dart } }
    @{ Name = 'PowerShell'; Cmd = 'pwsh', '--version'; Expect = '7.x (it/*.ps1)'; Rule = { param($v) $v.Major -eq 7 } }
    @{ Name = 'GitHub CLI'; Cmd = 'gh', '--version'; Expect = 'any'; Rule = { $true } }
    @{ Name = 'reportgenerator'; Cmd = 'dotnet', 'tool', 'list', '--global'; Pattern = 'dotnet-reportgenerator-globaltool\s+(\d+\.\d+\.\d+)'; Expect = 'any (coverage tasks)'; Rule = { $true } }
    @{ Name = 'dotnet-outdated'; Cmd = 'dotnet', 'tool', 'list', '--global'; Pattern = 'dotnet-outdated-tool\s+(\d+\.\d+\.\d+)'; Expect = 'any (dotnet outdated)'; Rule = { $true } }
)

Write-Host "$($PSStyle.Foreground.Cyan)== Tools$($PSStyle.Reset)"
foreach ($tool in $tools) {
    $version = $tool.ContainsKey('Pattern') ? (Get-ToolVersion $tool.Cmd $tool.Pattern) : (Get-ToolVersion $tool.Cmd)
    Write-Result $tool.Name ($null -ne $version -and (& $tool.Rule $version)) "$($version ?? 'missing'), expects $($tool.Expect)"
}
$pipBlocked = python3 -c 'import os, sysconfig; print(os.path.exists(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")))'
Write-Result 'pip install allowed' ($pipBlocked -eq 'False') "python3 is $((Get-Command python3).Source) (not the PEP 668 system Python)"
$null = xvfb-run -a true 2>&1
Write-Result 'xvfb-run' ($LASTEXITCODE -eq 0) 'headless display for the extension tests'
#endregion

if ($Tier -in 'Build', 'Full') {
    Invoke-Step 'dotnet build' { dotnet build kiota.slnx }
    # updateContentCommand runs npm ci when the container is created; repeat it if node_modules is gone since.
    if (-not (Test-Path vscode/node_modules)) { Invoke-Step 'npm ci' { npm ci } vscode }
    Invoke-Step 'extension build' { npm run build } vscode
}

if ($Tier -eq 'Full') {
    Invoke-Step 'dotnet test' { dotnet test kiota.slnx --no-build }

    # Publish kiota for the newest framework it targets, as CI does.
    $framework = (Select-Xml -Path src/kiota/kiota.csproj -XPath '//TargetFrameworks').Node.InnerText.Split(';', [StringSplitOptions]::RemoveEmptyEntries) |
        Sort-Object { [version]($_ -replace '^net') } | Select-Object -Last 1
    $rid = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64' ? 'linux-arm64' : 'linux-x64'

    # The npm package and extension tests download the kiota release named in lib/runtime.json (CI points it
    # at the latest release first). Hand them the kiota built from this checkout instead: the npm package
    # tests find it in lib/.kiotabin/<version>/<rid>/, the extension tests through the sideloading hook in
    # vscode/packages/npm-package/lib/install.ts. The npm package tests are not sideloaded because one of
    # them checks that a download with a bad hash is rejected.
    $npmPackage = 'vscode/packages/npm-package'
    $kiotaVersion = (Get-Content "$npmPackage/lib/runtime.json" -Raw | ConvertFrom-Json).kiotaVersion
    $binDirs = 'lib/.kiotabin', 'dist/.kiotabin', '.kiotabin' | ForEach-Object { Join-Path $root $npmPackage $_ }
    $newBinDirs = $binDirs | Where-Object { -not (Test-Path $_) }
    $published = Join-Path ([System.IO.Path]::GetTempPath()) "kiota-$rid"
    Invoke-Step 'publish kiota (extension tests)' {
        dotnet publish src/kiota/kiota.csproj -c Release -r $rid --self-contained -p:PublishSingleFile=true -f $framework -o $published
        Compress-Archive -Path "$published/*" -DestinationPath "$published.zip" -Force
        $libBin = "$npmPackage/lib/.kiotabin/$kiotaVersion/$rid"
        if (-not (Test-Path $libBin)) {
            New-Item -ItemType Directory -Path (Split-Path $libBin) -Force | Out-Null
            Copy-Item $published $libBin -Recurse
        }
    }
    Invoke-Step 'extension lint' { npm run lint } vscode
    Invoke-Step 'npm package tests' { npm run test:package } vscode
    Invoke-Step 'extension tests' { $env:KIOTA_SIDELOADING_BINARY_ZIP_PATH = "$published.zip"; xvfb-run -a npm run test:vscode } vscode
    Remove-Item Env:KIOTA_SIDELOADING_BINARY_ZIP_PATH -ErrorAction Ignore
    $newBinDirs | Remove-Item -Recurse -Force -ErrorAction Ignore

    # The it/ scripts generate code, leave it/<language>.zip behind and delete the tracked it/ruby/Gemfile.lock;
    # undo whatever they change.
    $itBefore = git status --porcelain --untracked-files=all -- it
    Invoke-Step 'publish kiota (integration tests)' { dotnet publish src/kiota/kiota.csproj -c Release -p:PublishSingleFile=true -f $framework -o publish }
    foreach ($lang in $Language) {
        Invoke-Step "integration test: $lang" {
            ./it/generate-code.ps1 -descriptionUrl $Description -descriptionKey $Description -language $lang
            if ($LASTEXITCODE -eq 0) { ./it/exec-cmd.ps1 -descriptionUrl $Description -language $lang }
        }
        $null = ./it/do-clean.ps1 -language $lang 2>&1
    }
    foreach ($entry in @(git status --porcelain --untracked-files=all -- it) | Where-Object { $_ -notin $itBefore }) {
        $path = $entry.Substring(3)
        if ($entry.StartsWith('??')) { Remove-Item -LiteralPath $path -Recurse -Force } else { git checkout --quiet -- $path }
    }
}

$failed = @($results | Where-Object { -not $_.Passed })
$summary = '{0} checks, {1} failed (tier {2}, {3})' -f $results.Count, $failed.Count, $Tier, [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
Write-Host "`n$($failed ? $PSStyle.Foreground.Red : $PSStyle.Foreground.Green)$summary$($PSStyle.Reset)"
$failed | ForEach-Object { Write-Host "FAIL $($_.Check): $($_.Detail)" }
exit ($failed ? 1 : 0)
