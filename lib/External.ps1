# Pinned downloads are checked against pins.json before anything runs. A mismatch
# deletes the file; never fall back to running it anyway.

function Get-SFExternalPaths {
    $root = Get-SFRoot
    return [pscustomobject]@{
        Pins     = (Join-Path $root 'external\pins.json')
        WinUtil  = (Join-Path $root 'external\winutil.json')
        W11D     = (Join-Path $root 'external\win11debloat.json')
        Cache    = (Join-Path $root 'tools\cache')
    }
}

function Get-SFFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-SFDownload {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = $OutFile + '.part'
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -ErrorAction Stop }
    finally { $ProgressPreference = $old }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

function Get-SFExternalTool {
    param([Parameter(Mandatory)][ValidateSet('winutil', 'win11debloat')][string]$Tool, [ValidateSet('Pinned', 'Latest')][string]$Source = 'Pinned')
    $paths = Get-SFExternalPaths
    $pins = Read-SFJson $paths.Pins
    $pin = Get-SFProp $pins $Tool
    if (-not (Test-Path -LiteralPath $paths.Cache)) { New-Item -ItemType Directory -Path $paths.Cache -Force | Out-Null }

    if ($Source -eq 'Pinned') {
        $file = Join-Path $paths.Cache $pin.file
        if (Test-Path -LiteralPath $file) {
            if ((Get-SFFileSha256 $file) -eq $pin.sha256.ToLowerInvariant()) {
                return [pscustomobject]@{ Path = $file; Sha256 = $pin.sha256; Tag = $pin.tag; Source = 'Pinned (cached)' }
            }
            Remove-Item -LiteralPath $file -Force
        }
        Invoke-SFDownload -Url $pin.url -OutFile $file
        $hash = Get-SFFileSha256 $file
        if ($hash -ne $pin.sha256.ToLowerInvariant()) {
            Remove-Item -LiteralPath $file -Force
            throw ("SHA256 mismatch for {0} {1}. Expected {2}, got {3}. The download was deleted and NOT run." -f $Tool, $pin.tag, $pin.sha256, $hash)
        }
        return [pscustomobject]@{ Path = $file; Sha256 = $hash; Tag = $pin.tag; Source = 'Pinned' }
    }

    # nothing to check "latest" against, so at least log the hash of what ran
    $url = $pin.latestUrl
    $tag = 'latest'
    if ($Tool -eq 'win11debloat') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri $pin.latestApi -UseBasicParsing -ErrorAction Stop
        $tag = $rel.tag_name
        $url = 'https://github.com/Raphire/Win11Debloat/archive/refs/tags/{0}.zip' -f $tag
    }
    $ext = [IO.Path]::GetExtension($pin.file)
    $file = Join-Path $paths.Cache ('{0}-latest{1}' -f $Tool, $ext)
    Invoke-SFDownload -Url $url -OutFile $file
    $hash = Get-SFFileSha256 $file
    Write-SFStatus 'WARN' ('{0}: running LATEST ({1}) without a pinned hash. SHA256 {2}' -f $Tool, $tag, $hash)
    return [pscustomobject]@{ Path = $file; Sha256 = $hash; Tag = $tag; Source = 'Latest' }
}

function Get-SFExternalItems {
    param([Parameter(Mandatory)][ValidateSet('winutil', 'win11debloat')][string]$Tool)
    $paths = Get-SFExternalPaths
    $cfgPath = if ($Tool -eq 'winutil') { $paths.WinUtil } else { $paths.W11D }
    $cfg = Read-SFJson $cfgPath
    return @($cfg.items)
}

function Resolve-SFExternalSelection {
    param(
        [Parameter(Mandatory)][ValidateSet('winutil', 'win11debloat')][string]$Tool, [Parameter(Mandatory)]$Context,
        [string]$Preset = 'HighEnd', [string[]]$Include = @(), [string[]]$Exclude = @(), [switch]$ShowAll
    )
    $basePreset = if ($Preset -eq 'Custom') { $Context.SuggestedPreset } else { $Preset }
    $rows = foreach ($it in (Get-SFExternalItems $Tool)) {
        $why = Test-SFExternalOption -Tool $Tool -Id $it.id
        $applies = $true
        $reason = ''
        if ($why) { $applies = $false; $reason = $why }
        foreach ($r in @(Get-SFProp $it 'requires' @())) {
            if ($applies -and -not (Test-SFRequirement $r $Context)) { $applies = $false; $reason = (Get-SFRequirementText $r) }
        }
        $sel = ($basePreset -in @(Get-SFProp $it 'presets' @()))
        if ($Include -contains $it.id) { $sel = $true }
        if ($Exclude -contains $it.id) { $sel = $false }
        if (-not $applies) { $sel = $false }
        $adv = [bool](Get-SFProp $it 'advanced' $false)
        [pscustomobject]@{
            Id = $it.id; Item = $it; Tool = $Tool; Applies = $applies; Reason = $reason; Selected = $sel
            Visible = ($ShowAll -or -not $adv -or $sel); Advanced = $adv
        }
    }
    return @($rows)
}

function Invoke-SFWinUtil {
    param([Parameter(Mandatory)][string[]]$Ids, [ValidateSet('Pinned', 'Latest')][string]$Source = 'Pinned', [string]$LogDir, [switch]$DryRun)
    foreach ($id in $Ids) { $why = Test-SFExternalOption -Tool 'winutil' -Id $id; if ($why) { throw $why } }
    if ($DryRun) { Write-SFStatus 'DRYRUN' ('WinUtil would run: ' + ($Ids -join ', ')); return 0 }
    $tool = Get-SFExternalTool -Tool 'winutil' -Source $Source
    # not in %TEMP%: WinUtil's "delete temp files" tweak empties it while running
    $work = if ($LogDir) { $LogDir } else { Split-Path -Parent $tool.Path }
    if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    $cfg = Join-Path $work 'winutil-config.json'
    $resultFile = Join-Path $work 'winutil-results.json'
    Save-SFJson -Object @($Ids) -Path $cfg
    Write-SFStatus 'INFO' ('WinUtil {0} ({1}) sha256 {2}' -f $tool.Tag, $tool.Source, $tool.Sha256)
    $runner = Join-Path $script:SFLibRoot 'WinUtilRunner.ps1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $runner),
        '-WinUtilPath', ('"{0}"' -f $tool.Path), '-ConfigFile', ('"{0}"' -f $cfg),
        '-TweakIds', ($Ids -join ','), '-ResultFile', ('"{0}"' -f $resultFile))
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -NoNewWindow
    try { $Host.UI.RawUI.WindowTitle = 'SteadyFrame' } catch { }   # WinUtil renames the shared console
    Write-SFWinUtilResults -ResultFile $resultFile
    return $p.ExitCode
}

function Write-SFWinUtilResults {
    param([Parameter(Mandatory)][string]$ResultFile)
    if (-not (Test-Path -LiteralPath $ResultFile)) {
        Write-SFStatus 'FAIL' 'WinUtil stopped before reporting any results (see its log in %LOCALAPPDATA%\winutil\logs)'
        return
    }
    foreach ($r in @((Read-SFJson $ResultFile).Results)) {
        if ($r.Ok) {
            $note = if ([int]$r.Errors -gt 0) { '  ({0} non-fatal errors along the way, usually files in use)' -f $r.Errors } else { '' }
            Write-SFStatus 'APPLIED' ('WinUtil ' + $r.Id + $note)
        } else {
            Write-SFStatus 'FAIL' ('WinUtil ' + $r.Id + ': ' + $r.Message)
        }
    }
}

function Invoke-SFWin11Debloat {
    param([Parameter(Mandatory)][string[]]$Flags, [ValidateSet('Pinned', 'Latest')][string]$Source = 'Pinned', [string]$LogDir, [switch]$DryRun)
    foreach ($fl in $Flags) { $why = Test-SFExternalOption -Tool 'win11debloat' -Id $fl; if ($why) { throw $why } }
    if ($DryRun) { Write-SFStatus 'DRYRUN' ('Win11Debloat would run: -' + ($Flags -join ' -')); return 0 }
    $tool = Get-SFExternalTool -Tool 'win11debloat' -Source $Source
    $dest = Join-Path (Split-Path -Parent $tool.Path) ('win11debloat-' + $tool.Tag)
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Expand-Archive -LiteralPath $tool.Path -DestinationPath $dest -Force
    $entry = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'Win11Debloat.ps1' | Select-Object -First 1
    if (-not $entry) { throw 'Win11Debloat.ps1 not found in the downloaded archive' }
    Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    Write-SFStatus 'INFO' ('Win11Debloat {0} ({1}) sha256 {2}' -f $tool.Tag, $tool.Source, $tool.Sha256)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $entry.FullName), '-Silent')
    if ($LogDir) {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $argList += @('-LogPath', ('"{0}"' -f $LogDir))
    }
    $argList += @($Flags | ForEach-Object { '-' + $_ })
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

# Only used to pick the default answer. Temp gets cleaned, so finding nothing proves nothing.
function Get-SFPriorDebloatTraces {
    $traces = @(
        @{ Name = 'Talon'; Path = (Join-Path $env:LOCALAPPDATA 'Talon') }
        @{ Name = 'WinUtil'; Path = (Join-Path $env:LOCALAPPDATA 'winutil') }
        @{ Name = 'Win11Debloat'; Path = (Join-Path $env:TEMP 'Win11Debloat') }
    )
    return @($traces | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path) } | ForEach-Object { $_.Name })
}

function Invoke-SFPrefetch {
    foreach ($t in @('winutil', 'win11debloat')) {
        $r = Get-SFExternalTool -Tool $t -Source 'Pinned'
        Write-SFStatus 'OK' ('{0} {1} cached: {2}' -f $t, $r.Tag, $r.Path)
    }
}
