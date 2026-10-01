# Game profiles: find supported games, print their settings cards, and the
# optional CS2 autoexec writer. Game definitions live in games\games.json.

$script:SFAutoexecBegin = '// >>> SteadyFrame (Revert.bat removes this block; edit outside it)'
$script:SFAutoexecEnd = '// <<< SteadyFrame'

function Get-SFGameDefinitions {
    return @((Read-SFJson (Join-Path (Get-SFRoot) 'games\games.json')).games)
}

function Get-SFSteamLibraries {
    param([string]$SteamPath = '')
    $steam = $SteamPath
    if (-not $steam) { $steam = (Get-SFRegistryValue 'HKCU\Software\Valve\Steam' 'SteamPath').Value }
    if (-not $steam) { $steam = (Get-SFRegistryValue 'HKLM\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath').Value }
    if (-not $steam) { return @() }
    $steam = $steam -replace '/', '\'
    $paths = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
            $paths += ($m.Groups[1].Value -replace '\\\\', '\')
        }
    }
    $seen = @{}
    $unique = foreach ($p in $paths) {
        $k = $p.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $p.TrimEnd('\') }
    }
    return @($unique)
}

function Get-SFSteamAppDir {
    param([string[]]$Libraries, [int]$AppId)
    foreach ($lib in $Libraries) {
        $acf = Join-Path $lib ('steamapps\appmanifest_{0}.acf' -f $AppId)
        if (-not (Test-Path -LiteralPath $acf)) { continue }
        $m = [regex]::Match([IO.File]::ReadAllText($acf), '"installdir"\s+"([^"]+)"')
        if (-not $m.Success) { continue }
        $dir = Join-Path $lib ('steamapps\common\' + $m.Groups[1].Value)
        if (Test-Path -LiteralPath $dir) { return $dir }
    }
    return $null
}

function Get-SFRiotProductDir {
    param([string]$Product, [string]$Default, [string]$MetadataRoot = 'C:\ProgramData\Riot Games\Metadata')
    $yaml = Join-Path $MetadataRoot ('{0}\{0}.product_settings.yaml' -f $Product)
    if (Test-Path -LiteralPath $yaml) {
        $m = [regex]::Match([IO.File]::ReadAllText($yaml), 'product_install_full_path:\s*"?([^"\r\n]+)"?')
        if ($m.Success) {
            $d = $m.Groups[1].Value.Trim() -replace '/', '\'
            if (Test-Path -LiteralPath $d) { return $d }
        }
    }
    if ($Default -and (Test-Path -LiteralPath $Default)) { return $Default }
    return $null
}

# Each result: Id, Name, Dir, Exe, ExeName, Definition
function Get-SFInstalledGames {
    param([string[]]$SteamLibraries, [string]$RiotMetadataRoot = 'C:\ProgramData\Riot Games\Metadata', [switch]$NoRiotDefaultPath)
    if (-not $PSBoundParameters.ContainsKey('SteamLibraries')) { $SteamLibraries = @(Get-SFSteamLibraries) }
    $found = foreach ($g in (Get-SFGameDefinitions)) {
        $dir = $null
        if (Get-SFProp $g 'steamAppId') { $dir = Get-SFSteamAppDir -Libraries $SteamLibraries -AppId $g.steamAppId }
        elseif (Get-SFProp $g 'riotProduct') {
            $def = if ($NoRiotDefaultPath) { '' } else { Get-SFProp $g 'defaultPath' '' }
            $dir = Get-SFRiotProductDir -Product $g.riotProduct -Default $def -MetadataRoot $RiotMetadataRoot
        }
        if (-not $dir) { continue }
        $exe = Join-Path $dir $g.exe
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        [pscustomobject]@{ Id = $g.id; Name = $g.name; Dir = $dir; Exe = $exe; ExeName = (Split-Path -Leaf $exe); Definition = $g }
    }
    return @($found)
}

function Test-SFCardItemShown {
    param($Item, $Context)
    switch (Get-SFProp $Item 'only' '') {
        'nvidia' { return [bool]$Context.HasNvidia }
        'amd' { return (@($Context.Gpus | Where-Object { $_ -match 'AMD|Radeon' }).Count -gt 0) }
        default { return $true }
    }
}

# Plain-text card lines (used for both the console and the saved file).
function Get-SFGameCardLines {
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)]$Context, [string]$Dir = '')
    $lines = @()
    $title = $Definition.name
    if ($Dir) { $title += ('   (' + $Dir + ')') }
    $lines += $title
    foreach ($s in @($Definition.card)) {
        $items = @($s.items | Where-Object { Test-SFCardItemShown $_ $Context })
        if ($items.Count -eq 0) { continue }
        $lines += ''
        $lines += ('  ' + $s.section)
        foreach ($it in $items) {
            $lines += ('    - ' + $it.do)
            $lines += ('      ' + $it.why)
        }
    }
    $src = @(Get-SFProp $Definition 'sources' @())
    if ($src.Count -gt 0) { $lines += ''; $lines += '  Sources'; foreach ($u in $src) { $lines += ('    ' + $u) } }
    return $lines
}

function Write-SFGameCards {
    param([Parameter(Mandatory)]$Context, [switch]$All)
    $games = @($Context.Games)
    $defs = @(Get-SFGameDefinitions)
    if ($All -or $games.Count -eq 0) {
        if (-not $All) { Write-Host '  None of the supported games were found, showing all cards.' -ForegroundColor DarkGray }
        $games = @($defs | ForEach-Object { [pscustomobject]@{ Definition = $_; Dir = '' } })
    }
    foreach ($g in $games) {
        $lines = Get-SFGameCardLines -Definition $g.Definition -Context $Context -Dir $g.Dir
        Write-SFHeader $lines[0]
        foreach ($l in ($lines | Select-Object -Skip 1)) {
            if ($l -match '^  \S') { Write-Host $l -ForegroundColor Gray }
            elseif ($l -match '^    - ') { Write-Host $l -ForegroundColor White }
            else { Write-Host $l -ForegroundColor DarkGray }
        }
    }
}

function Save-SFGameCards {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)
    $games = @($Context.Games)
    if ($games.Count -eq 0) { return $null }
    $out = @("SteadyFrame game settings - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd')", '')
    foreach ($g in $games) { $out += (Get-SFGameCardLines -Definition $g.Definition -Context $Context -Dir $g.Dir); $out += ''; $out += '' }
    [System.IO.File]::WriteAllLines($Path, $out, (New-Object System.Text.UTF8Encoding $false))
    return $Path
}


function New-SFCs2AutoexecBlock {
    param([Parameter(Mandatory)]$Definition, [int]$FpsMax)
    $body = @($Definition.autoexec.lines | ForEach-Object { $_.Replace('{FpsMax}', "$FpsMax") })
    return (@($script:SFAutoexecBegin) + $body + @($script:SFAutoexecEnd)) -join "`r`n"
}

# Replace an existing SteadyFrame block, or append one; everything else in the file is kept.
function Merge-SFMarkedBlock {
    param([string]$Text, [Parameter(Mandatory)][string]$Block)
    $t = if ($null -eq $Text) { '' } else { $Text }
    $b = $t.IndexOf($script:SFAutoexecBegin)
    $e = $t.IndexOf($script:SFAutoexecEnd)
    if ($b -ge 0 -and $e -gt $b) {
        return ($t.Substring(0, $b) + $Block + $t.Substring($e + $script:SFAutoexecEnd.Length))
    }
    if ($t.Length -gt 0 -and -not $t.EndsWith("`n")) { $t += "`r`n" }
    return ($t + $Block + "`r`n")
}

function Invoke-SFCs2AutoexecAction {
    param($Action, $TweakId, $Context, $Journal, [switch]$DryRun, [switch]$Interactive)
    $game = @($Context.Games | Where-Object { $_.Id -eq 'cs2' })[0]
    if (-not $game) { return (New-SFResult $TweakId 'File' 'CS2 autoexec.cfg' 'Skipped' 'CS2 not found' -Quiet) }
    $path = Join-Path (Join-Path $game.Dir $game.Definition.cfgDir) 'autoexec.cfg'
    $why = Test-SFFileWrite $path
    if ($why) { return (New-SFResult $TweakId 'File' $path 'Blocked' $why) }
    $fps = [int](Get-SFProp $Action 'fpsMax' $game.Definition.autoexec.fpsMaxDefault)
    if ($Interactive) {
        $ans = Read-SFInput ('  CS2 fps_max cap - a bit below what your PC holds in deathmatch (Enter = {0}): ' -f $fps)
        if ($ans -match '^\d{2,4}$') { $fps = [int]$ans }
    }
    $exists = Test-Path -LiteralPath $path
    $old = if ($exists) { [IO.File]::ReadAllText($path) } else { '' }
    $new = Merge-SFMarkedBlock -Text $old -Block (New-SFCs2AutoexecBlock -Definition $game.Definition -FpsMax $fps)
    if ($old -ceq $new) { return (New-SFResult $TweakId 'File' $path 'AlreadySet' ('fps_max ' + $fps)) }
    $beforeText = if ($exists) { 'existing file (kept, block added)' } else { '(no autoexec)' }
    if ($DryRun) { return (New-SFResult $TweakId 'File' $path 'DryRun' '' $beforeText ('fps_max ' + $fps)) }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $oldBytes = if ($exists) { [IO.File]::ReadAllBytes($path) } else { $null }
    [IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
    if ($Journal) {
        $before = [ordered]@{ Exists = $exists; ContentBase64 = $(if ($oldBytes) { [Convert]::ToBase64String($oldBytes) } else { '' }) }
        Add-SFJournalEntry $Journal $TweakId 'File' ([ordered]@{ Path = $path }) $before ([ordered]@{ FpsMax = $fps })
    }
    return (New-SFResult $TweakId 'File' $path 'Applied' 'add +exec autoexec to CS2 launch options if it does not load' $beforeText ('fps_max ' + $fps))
}

function Undo-SFFileEntry {
    param([Parameter(Mandatory)]$Entry, [switch]$DryRun)
    $id = Get-SFProp $Entry 'TweakId'
    $path = Get-SFProp (Get-SFProp $Entry 'Target') 'Path'
    $b = Get-SFProp $Entry 'Before'
    $why = Test-SFFileWrite $path
    if ($why) { return (New-SFResult $id 'File' $path 'Blocked' $why) }
    if (-not (Test-Path -LiteralPath $path)) { return (New-SFResult $id 'File' $path 'Skipped' 'file no longer exists') }
    if ($DryRun) { return (New-SFResult $id 'File' $path 'DryRun' 'would remove the SteadyFrame block') }
    # Only our block is removed, so edits the player made afterwards survive the undo.
    $rest = Remove-SFMarkedBlock ([IO.File]::ReadAllText($path))
    if (-not [bool](Get-SFProp $b 'Exists' $false) -and $rest.Trim() -eq '') {
        Remove-Item -LiteralPath $path -Force
        return (New-SFResult $id 'File' $path 'Applied' 'removed (did not exist before)')
    }
    [IO.File]::WriteAllText($path, $rest, (New-Object System.Text.UTF8Encoding $false))
    return (New-SFResult $id 'File' $path 'Applied' 'SteadyFrame block removed, rest of the file kept')
}

function Remove-SFMarkedBlock {
    param([string]$Text)
    $t = if ($null -eq $Text) { '' } else { $Text }
    $b = $t.IndexOf($script:SFAutoexecBegin)
    $e = $t.IndexOf($script:SFAutoexecEnd)
    if ($b -lt 0 -or $e -le $b) { return $t }
    $after = $t.Substring($e + $script:SFAutoexecEnd.Length)
    if ($after.StartsWith("`r`n")) { $after = $after.Substring(2) } elseif ($after.StartsWith("`n")) { $after = $after.Substring(1) }
    return ($t.Substring(0, $b) + $after)
}
