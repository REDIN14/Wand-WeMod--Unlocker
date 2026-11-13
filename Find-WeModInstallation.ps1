# Read-only WeMod / Wand installation locator (Windows PowerShell 5.1+)
# Examples:
#   .\Find-WeModInstallation.ps1
#   .\Find-WeModInstallation.ps1 -First
#   .\Find-WeModInstallation.ps1 -FullScan
#
# Does not modify installed applications or subscription settings.

[CmdletBinding()]
param(
    [switch]$First,
    [switch]$FullScan
)

$script:FoundInstallations = New-Object 'System.Collections.Generic.List[object]'
$script:SeenPaths = @{}

function Add-WeModExecutable {
    param([string]$Candidate, [string]$Source)

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return }

    $candidatePath = [Environment]::ExpandEnvironmentVariables($Candidate.Trim())
    if ($candidatePath -match '^"([^"]+)"(?:,\d+)?$') {
        $candidatePath = $Matches[1]
    } else {
        $candidatePath = $candidatePath -replace ',\d+$', ''
    }

    if ([IO.Path]::GetFileName($candidatePath) -notin @('WeMod.exe', 'Wand.exe')) { return }
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { return }

    try {
        $file = Get-Item -LiteralPath $candidatePath -ErrorAction Stop
        $fullPath = $file.FullName
        if ($script:SeenPaths.ContainsKey($fullPath)) { return }
        $script:SeenPaths[$fullPath] = $true

        $version = $file.VersionInfo.ProductVersion
        if ([string]::IsNullOrWhiteSpace($version)) {
            $version = $file.VersionInfo.FileVersion
        }
        if ([string]::IsNullOrWhiteSpace($version) -and $file.Directory.Name -match '^app-(.+)$') {
            $version = $Matches[1]
        }

        $script:FoundInstallations.Add([pscustomobject]@{
            Executable       = $fullPath
            InstallDirectory = $file.Directory.FullName
            Version          = $version
            Source           = $Source
        })
    } catch {
        Write-Verbose "Cannot inspect $candidatePath : $_"
    }
}

function Search-WeModDirectory {
    param([string]$Directory, [string]$Source)

    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    $directoryPath = [Environment]::ExpandEnvironmentVariables($Directory.Trim('"'))
    if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) { return }

    foreach ($exe in @('WeMod.exe', 'Wand.exe')) {
        Add-WeModExecutable -Candidate (Join-Path $directoryPath $exe) -Source $Source
    }

    # Electron/Squirrel often keeps multiple app-<version> directories.
    Get-ChildItem -LiteralPath $directoryPath -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($exe in @('WeMod.exe', 'Wand.exe')) {
            Add-WeModExecutable -Candidate (Join-Path $_.FullName $exe) -Source $Source
        }
    }
}

# 1. Running processes: exact location of a currently running instance.
try {
    Get-CimInstance Win32_Process -Filter "Name='WeMod.exe' OR Name='Wand.exe'" -ErrorAction Stop | ForEach-Object {
        Add-WeModExecutable -Candidate $_.ExecutablePath -Source 'Running process'
    }
} catch {
    Write-Verbose "Process lookup unavailable: $_"
}

# 2. Registered Windows application paths and uninstall records.
foreach ($root in @('HKCU:', 'HKLM:')) {
    foreach ($exe in @('WeMod.exe', 'Wand.exe')) {
        $regPath = "$root\Software\Microsoft\Windows\CurrentVersion\App Paths\$exe"
        try {
            $key = Get-Item -LiteralPath $regPath -ErrorAction Stop
            Add-WeModExecutable -Candidate $key.GetValue('') -Source "App Paths: $root"
            Search-WeModDirectory -Directory $key.GetValue('Path') -Source "App Paths: $root"
        } catch {
            Write-Verbose "No App Paths entry: $regPath"
        }
    }

    foreach ($uninstallPath in @(
        "$root\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "$root\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )) {
        Get-ChildItem -LiteralPath $uninstallPath -ErrorAction SilentlyContinue | ForEach-Object {
            $entry = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $entry -and $entry.DisplayName -match '(?i)\b(WeMod|Wand)\b') {
                Search-WeModDirectory -Directory $entry.InstallLocation -Source 'Uninstall registry'
                Add-WeModExecutable -Candidate $entry.DisplayIcon -Source 'Uninstall registry'
            }
        }
    }
}

# 3. Start Menu and desktop shortcuts, including custom installation locations.
$shortcutRoots = @()
if ($env:APPDATA) { $shortcutRoots += Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
if ($env:ProgramData) { $shortcutRoots += Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs' }
$shortcutRoots += [Environment]::GetFolderPath('Desktop')
if ($env:PUBLIC) { $shortcutRoots += Join-Path $env:PUBLIC 'Desktop' }
$shortcutRoots = $shortcutRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique

try {
    $shell = New-Object -ComObject WScript.Shell -ErrorAction Stop
    foreach ($root in $shortcutRoots) {
        Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $_.BaseName -match '(?i)WeMod|Wand'
        } | ForEach-Object {
            try {
                $target = $shell.CreateShortcut($_.FullName).TargetPath
                Add-WeModExecutable -Candidate $target -Source 'Windows shortcut'
            } catch {
                Write-Verbose "Cannot resolve shortcut: $($_.FullName)"
            }
        }
    }
} catch {
    Write-Verbose "Windows shortcut API unavailable: $_"
}

# 4. Common locations, including old/new product directory names.
$roots = @()
foreach ($base in @(
    $env:LOCALAPPDATA,
    $env:APPDATA,
    $env:ProgramFiles,
    [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
    $env:ProgramW6432
)) {
    if ([string]::IsNullOrWhiteSpace($base)) { continue }
    foreach ($relative in @('WeMod', 'Wand', 'Programs\WeMod', 'Programs\Wand')) {
        $roots += Join-Path $base $relative
    }
}
$roots | Select-Object -Unique | ForEach-Object {
    Search-WeModDirectory -Directory $_ -Source 'Common install location'
}

# 5. Optional slow fallback for portable installs on other drives.
if ($FullScan) {
    Write-Warning 'FullScan searches every file-system drive and may take a long time.'
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
        foreach ($exe in @('WeMod.exe', 'Wand.exe')) {
            Get-ChildItem -LiteralPath $drive.Root -Filter $exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                Add-WeModExecutable -Candidate $_.FullName -Source 'Full drive scan'
            }
        }
    }
}

if ($script:FoundInstallations.Count -eq 0) {
    Write-Warning 'No WeMod/Wand executable found. Try -FullScan for unregistered portable installs.'
    return
}

if ($First) {
    # Priority: running process, Windows registration, shortcuts, common folders.
    $script:FoundInstallations | Select-Object -First 1
} else {
    $script:FoundInstallations
}
