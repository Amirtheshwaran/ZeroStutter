#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = '', [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?$')][string]$Version = '0.1.0-beta.1')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$archivePath = Join-Path $OutputDirectory 'ZeroStutter.zip'
if (Test-Path -LiteralPath $archivePath) { throw "Package already exists: $archivePath. Choose a new output directory." }
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt')) { throw 'SHA256SUMS.txt already exists. Choose a new output directory.' }
$files = @('ZeroStutter.ps1', 'Start-ZeroStutterSession.ps1', 'Restore-ZeroStutterSession.ps1', 'Launch-ZeroStutter.ps1', 'Start-ZeroStutter.cmd', 'Measure-ZeroStutter.ps1', 'Build-Desktop.ps1', 'Build-Package.ps1', 'install.ps1', 'uninstall.ps1', 'profiles.json', 'src', 'schema', 'tests', 'LICENSE', 'README.md', 'CONTRIBUTING.md', 'ROADMAP.md', 'docs')
$stage = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('package-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stage
foreach ($file in $files) {
    $source = Join-Path $PSScriptRoot $file
    if (-not (Test-Path -LiteralPath $source)) { throw "Required package source is missing: $file" }
    Copy-Item -LiteralPath $source -Destination $stage -Recurse
}
# Compile the exact source files that are included and hashed in this package.
& (Join-Path $stage 'Build-Desktop.ps1') -OutputPath (Join-Path $stage 'ZeroStutter.exe')
$sourceCommit = 'unknown'
$sourceDirty = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    try {
        $revision = & git -C $PSScriptRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            $sourceCommit = [string]$revision
            $status = @(& git -C $PSScriptRoot status --porcelain --untracked-files=normal 2>$null)
            if ($LASTEXITCODE -eq 0) { $sourceDirty = $status.Count -gt 0 }
        }
    } catch {
        # Downloaded source/package ZIPs have no .git directory. Their file hashes
        # remain useful without claiming an unverifiable commit or clean tree.
    }
}
$manifest = [ordered]@{ Version=$Version; SourceCommit=$sourceCommit; SourceDirty=$sourceDirty; BuiltUtc=[DateTime]::UtcNow.ToString('o'); Platform='Windows x64'; Signed=$false; Files=@() }
$manifest.Files = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{ Path=$_.FullName.Substring($stage.Length+1).Replace('\','/'); SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'build-manifest.json') -Encoding UTF8
Compress-Archive -LiteralPath @(Get-ChildItem -LiteralPath $stage | Select-Object -ExpandProperty FullName) -DestinationPath $archivePath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Value "$hash  ZeroStutter.zip" -Encoding ASCII
Write-Host "Created $archivePath"
