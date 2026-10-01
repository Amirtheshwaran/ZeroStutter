#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$archivePath = Join-Path $OutputDirectory 'ZeroStutter.zip'
if (Test-Path -LiteralPath $archivePath) { throw "Package already exists: $archivePath. Choose a new output directory." }
$files = @('ZeroStutter.ps1', 'Start-ZeroStutterSession.ps1', 'Restore-ZeroStutterSession.ps1', 'Launch-ZeroStutter.ps1', 'Start-ZeroStutter.cmd', 'Measure-ZeroStutter.ps1', 'install.ps1', 'uninstall.ps1', 'profiles.json', 'src', 'schema', 'LICENSE', 'README.md')
$paths = foreach ($file in $files) { Join-Path $PSScriptRoot $file }
Compress-Archive -LiteralPath $paths -DestinationPath $archivePath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Value "$hash  ZeroStutter.zip" -Encoding ASCII
Write-Host "Created $archivePath"
