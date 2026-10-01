# Dependency-free, read-only checks for ZeroStutter.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPaths = @(
    (Join-Path $repoRoot 'ZeroStutter.ps1'),
    (Join-Path $repoRoot 'install.ps1'),
    (Join-Path $repoRoot 'uninstall.ps1'),
    (Join-Path $repoRoot 'src\ZeroStutter.Core.psm1')
)
foreach ($path in $scriptPaths) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $details = $errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }
        throw "PowerShell parse failure in $path. $($details -join '; ')"
    }
}

$profilesPath = Join-Path $repoRoot 'profiles.json'
$profilesDocument = Get-Content -LiteralPath $profilesPath -Raw | ConvertFrom-Json -ErrorAction Stop
Import-Module (Join-Path $repoRoot 'src\ZeroStutter.Core.psm1') -Force
$profiles = @(Get-ZeroStutterProfiles -Path $profilesPath)
if ($profiles.Count -ne @($profilesDocument.profiles).Count) { throw 'Unexpected profile count.' }

$noTargets = @(Get-ZeroStutterTargetProcesses -Profiles $profiles -Processes @())
$noActions = @(Set-ZeroStutterProfilePriorities -Targets $noTargets -ManagedProcesses @{})
if ($noTargets.Count -ne 0 -or $noActions.Count -ne 0) { throw 'Empty process scans should be harmless.' }$testProfile = [pscustomobject]@{
    name = 'Test Game'; executable = 'testgame.exe'; category = 'Test'; priorityClass = 'AboveNormal'
}
$testProcess = [pscustomobject]@{
    Id = 42001
    ProcessName = 'TestGame'
    PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    StartTime = (Get-Date).AddMinutes(-1)
    HasExited = $false
}
$targets = @(Get-ZeroStutterTargetProcesses -Profiles @($testProfile) -Processes @($testProcess))
if ($targets.Count -ne 1 -or $targets[0].ProcessId -ne 42001) { throw 'Case-insensitive matching failed.' }

$managed = @{}
$actions = @(Set-ZeroStutterProfilePriorities -Targets $targets -ManagedProcesses $managed)
if ([string]$testProcess.PriorityClass -ne 'AboveNormal' -or $managed.Count -ne 1 -or $actions.Count -ne 1) {
    throw 'Opt-in priority application did not record original state.'
}
$secondTargets = @(Get-ZeroStutterTargetProcesses -Profiles @($testProfile) -Processes @($testProcess))
$null = Set-ZeroStutterProfilePriorities -Targets $secondTargets -ManagedProcesses $managed
if ($managed.Count -ne 1) { throw 'Repeated scans created duplicate restore records.' }

$restoreResults = @(Restore-ZeroStutterPriorities -ManagedProcesses $managed)
if ([string]$testProcess.PriorityClass -ne 'Normal' -or $managed.Count -ne 0 -or $restoreResults.Count -ne 1) {
    throw 'Priority restoration failed.'
}

$observeProfile = [pscustomobject]@{
    name = 'Observed Game'; executable = 'observe.exe'; category = 'Test'; priorityClass = 'Observe'
}
$observeProcess = [pscustomobject]@{
    Id = 42002
    ProcessName = 'observe'
    PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    StartTime = (Get-Date).AddMinutes(-1)
    HasExited = $false
}
$observeTargets = @(Get-ZeroStutterTargetProcesses -Profiles @($observeProfile) -Processes @($observeProcess))
$null = Set-ZeroStutterProfilePriorities -Targets $observeTargets -ManagedProcesses $managed
if ([string]$observeProcess.PriorityClass -ne 'Normal' -or $managed.Count -ne 0) { throw 'Observe-only profile changed a process.' }

$externalProfile = [pscustomobject]@{ name = 'External change'; executable = 'external.exe'; category = 'Test'; priorityClass = 'AboveNormal' }
$externalProcess = [pscustomobject]@{
    Id = 42003
    ProcessName = 'external'
    PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    StartTime = (Get-Date).AddMinutes(-1)
    HasExited = $false
}
$externalTargets = @(Get-ZeroStutterTargetProcesses -Profiles @($externalProfile) -Processes @($externalProcess))
$null = Set-ZeroStutterProfilePriorities -Targets $externalTargets -ManagedProcesses $managed
$externalProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
$null = Restore-ZeroStutterPriorities -ManagedProcesses $managed
if ([string]$externalProcess.PriorityClass -ne 'High') { throw 'Cleanup overwrote a later priority change.' }
$alreadyRaisedProcess = [pscustomobject]@{
    Id = 42004
    ProcessName = 'alreadyraised'
    PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
    StartTime = (Get-Date).AddMinutes(-1)
    HasExited = $false
}
$alreadyRaisedProfile = [pscustomobject]@{ name = 'Already raised'; executable = 'alreadyraised.exe'; category = 'Test'; priorityClass = 'AboveNormal' }
$alreadyRaised = @(Get-ZeroStutterTargetProcesses -Profiles @($alreadyRaisedProfile) -Processes @($alreadyRaisedProcess))
$null = Set-ZeroStutterProfilePriorities -Targets $alreadyRaised -ManagedProcesses $managed
if ([string]$alreadyRaisedProcess.PriorityClass -ne 'AboveNormal' -or $managed.Count -ne 0) {
    throw 'A pre-existing AboveNormal priority was claimed or changed.'
}
$highPriorityProcess = [pscustomobject]@{
    Id = 42005
    ProcessName = 'highpriority'
    PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
    StartTime = (Get-Date).AddMinutes(-1)
    HasExited = $false
}
$highTarget = [pscustomobject]@{
    ProfileName = 'High priority'; ProcessName = 'highpriority'; Process = $highPriorityProcess
    ConfiguredPriority = 'AboveNormal'; PriorityClass = 'High'; ProcessId = 42005; Status = 'Not changed'
}
$null = Set-ZeroStutterProfilePriorities -Targets @($highTarget) -ManagedProcesses $managed
if ([string]$highPriorityProcess.PriorityClass -ne 'High' -or $managed.Count -ne 0) {
    throw 'A pre-existing high priority was changed.'
}
$tempProfile = Join-Path ([IO.Path]::GetTempPath()) ('zerostutter-invalid-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $invalidDocument = @{
        version = 1
        profiles = @(@{
            name = 'Invalid'; executable = '..\other.exe'; category = 'Test'; priorityClass = 'High'
        })
    }
    $invalidDocument | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tempProfile -Encoding UTF8
    $rejected = $false
    try { $null = Get-ZeroStutterProfiles -Path $tempProfile } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid profile path/priority was not rejected.' }
    $shapeDocument = @{
        version = 1
        profiles = @{
            name = 'Object instead of array'; executable = 'object.exe'; category = 'Test'; priorityClass = 'Observe'
        }
    }
    $shapeDocument | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tempProfile -Encoding UTF8
    $rejectedShape = $false
    try { $null = Get-ZeroStutterProfiles -Path $tempProfile } catch { $rejectedShape = $true }
    if (-not $rejectedShape) { throw 'A profile object was accepted instead of a profiles array.' }
} finally {
    Remove-Item -LiteralPath $tempProfile -Force -ErrorAction SilentlyContinue
}


$schema = Get-Content -LiteralPath (Join-Path $repoRoot 'schema\profiles.schema.json') -Raw | ConvertFrom-Json -ErrorAction Stop
foreach ($profile in $profiles) {
    if ([string]$profile.executable -notmatch [string]$schema.properties.profiles.items.properties.executable.pattern) {
        throw "Profile executable does not match the schema: $($profile.executable)"
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ZeroStutter-Test-' + [guid]::NewGuid().ToString('N'))
$testInstall = Join-Path $testRoot 'ZeroStutter'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$originalLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = $testRoot
    & (Join-Path $repoRoot 'install.ps1') -SkipShortcut | Out-Null
    foreach ($relative in @('ZeroStutter.ps1', 'profiles.json', 'src\ZeroStutter.Core.psm1', 'schema\profiles.schema.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $testInstall $relative) -PathType Leaf)) {
            throw "Installer did not copy $relative."
        }
    }

    $customProfilesPath = Join-Path $testInstall 'profiles.json'
    $customProfiles = Get-Content -LiteralPath $customProfilesPath -Raw | ConvertFrom-Json
    $customProfiles.profiles[0].category = 'Custom category'
    $customProfiles | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $customProfilesPath -Encoding UTF8
    & (Join-Path $repoRoot 'install.ps1') -SkipShortcut | Out-Null
    $preservedProfiles = Get-Content -LiteralPath $customProfilesPath -Raw | ConvertFrom-Json
    if ($preservedProfiles.profiles[0].category -ne 'Custom category') { throw 'Installer overwrote a valid user profile.' }

    '{"version":"1.0.0","profiles":[]}' | Set-Content -LiteralPath $customProfilesPath -Encoding UTF8
    & (Join-Path $repoRoot 'install.ps1') -SkipShortcut | Out-Null
    if (@(Get-ChildItem -LiteralPath $testInstall -Filter 'profiles.json.backup-*').Count -eq 0) {
        throw 'Installer did not back up an incompatible profile file.'
    }
    $resetProfileDoc = Get-Content -LiteralPath $customProfilesPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($resetProfileDoc.version -ne 1 -or @($resetProfileDoc.profiles).Count -lt 1) { throw 'Installer did not install valid defaults after backup.' }

    Set-Content -LiteralPath (Join-Path $testInstall 'keep.txt') -Value 'user file'
    & (Join-Path $repoRoot 'uninstall.ps1') -SkipShortcut | Out-Null
    if (Test-Path -LiteralPath $customProfilesPath) { throw 'Uninstaller left an installed profile behind.' }
    if (-not (Test-Path -LiteralPath (Join-Path $testInstall 'keep.txt'))) {
        throw 'Uninstaller removed a file it did not install.'
    }
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $fullTestRoot = [IO.Path]::GetFullPath($testRoot)
    $fullTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($fullTestRoot.StartsWith($fullTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Remove-Module ZeroStutter.Core -ErrorAction SilentlyContinue
& (Join-Path $repoRoot 'ZeroStutter.ps1') -Once | Out-Null
if (-not $?) { throw 'Read-only -Once scan failed.' }
Write-Host "All ZeroStutter checks passed. Parsed $($scriptPaths.Count) PowerShell files and validated $($profiles.Count) profiles."
