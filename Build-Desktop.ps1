#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) { throw 'The desktop build requires 64-bit Windows.' }
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'dist\desktop\ZeroStutter.exe' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($OutputPath) -ine '.exe') { throw 'OutputPath must end in .exe.' }
if (Test-Path -LiteralPath $OutputPath) { throw "Output already exists: $OutputPath. Choose a new output path." }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The Windows .NET Framework C# compiler is unavailable.' }
$parent = Split-Path -Parent $OutputPath
$null = New-Item -ItemType Directory -Path $parent -Force
$source = Join-Path $PSScriptRoot 'src\ZeroStutter.Desktop.cs'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /checked+ /utf8output /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll "/out:$OutputPath" $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { throw "Desktop compilation failed (exit $LASTEXITCODE)." }
Write-Host "Desktop executable built: $OutputPath"
Write-Host 'Deploy this executable beside the ZeroStutter PowerShell scripts and src directory (Build-Package.ps1 does this).'
