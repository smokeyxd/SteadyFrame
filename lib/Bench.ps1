# FPS measurement with PresentMon (Intel, MIT license): it reads frame timings from Windows'
# event tracing and never touches the game process, so anti-cheats leave it alone. Needs admin.

function ConvertFrom-SFPresentMonCsv {
    param([Parameter(Mandatory)][string]$Path)
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { return , ([double[]]@()) }
    $columns = $rows[0].PSObject.Properties.Name
    $col = @('MsBetweenPresents', 'MsBetweenAppStart') | Where-Object { $columns -contains $_ } | Select-Object -First 1
    if (-not $col) { throw 'The PresentMon output has no frame time column.' }
    $out = New-Object System.Collections.Generic.List[double]
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($r in $rows) {
        $v = 0.0
        if ([double]::TryParse("$($r.$col)", [Globalization.NumberStyles]::Float, $inv, [ref]$v) -and $v -gt 0) { $out.Add($v) }
    }
    return , $out.ToArray()
}

# "1% low" here is the FPS at the 99th percentile frame time: 99% of frames were at least this fast.
function Get-SFFrameStats {
    param([double[]]$FrameTimesMs)
    $ft = [double[]]@($FrameTimesMs | Where-Object { $_ -gt 0 })
    if ($ft.Count -lt 20) { return $null }
    $sorted = [double[]]$ft.Clone()
    [Array]::Sort($sorted)
    $totalMs = 0.0
    foreach ($x in $ft) { $totalMs += $x }
    $pct = { param($q) $sorted[[math]::Max(0, [math]::Ceiling($q * $sorted.Count) - 1)] }
    return [pscustomobject]@{
        Frames  = $ft.Count
        Seconds = [math]::Round($totalMs / 1000, 1)
        AvgFps  = [math]::Round($ft.Count / ($totalMs / 1000), 1)
        Low1    = [math]::Round(1000 / (& $pct 0.99), 1)
        Low01   = [math]::Round(1000 / (& $pct 0.999), 1)
    }
}

function Get-SFBenchmarkDir {
    $dir = Join-Path (Get-SFRoot) 'runs\fps'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-SFBenchmarkHistory {
    param([Parameter(Mandatory)][string]$Game)
    $p = Join-Path (Get-SFBenchmarkDir) (($Game -replace '\.exe$', '') + '.json')
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Read-SFJson $p)
}

function Invoke-SFBenchmark {
    param([Parameter(Mandatory)][string]$Game, [int]$Seconds = 60, [string]$Label = '', [int]$Countdown = 10)
    $exeName = if ($Game -match '\.exe$') { $Game } else { "$Game.exe" }
    $base = $exeName -replace '\.exe$', ''
    $tool = Get-SFExternalTool -Tool 'presentmon' -Source 'Pinned'
    $dir = Get-SFBenchmarkDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csv = Join-Path $dir ('{0}-{1}.csv' -f $base, $stamp)
    if (-not $Label) { $Label = Get-Date -Format 'yyyy-MM-dd HH:mm' }

    Write-Host ''
    Write-Host '  When the countdown ends, switch to the game and play the same scene as last time.'
    Write-Host ('  It records for {0} seconds and beeps when it''s done.' -f $Seconds)
    for ($i = $Countdown; $i -gt 0; $i--) {
        Write-Host ("`r  Starting in {0,2} s " -f $i) -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host "`r  Recording...        "
    try { [console]::Beep(660, 150) } catch { }

    $argList = @('--process_name', $exeName, '--output_file', ('"{0}"' -f $csv), '--timed', $Seconds, '--terminate_after_timed',
        '--no_console_stats', '--session_name', 'SteadyFrame', '--stop_existing_session')
    $p = Start-Process -FilePath $tool.Path -ArgumentList $argList -PassThru -NoNewWindow
    # PresentMon waits on its own; the extra minute is only for a stuck trace session
    if (-not $p.WaitForExit(($Seconds + 60) * 1000)) {
        try { $p.Kill() } catch { }
        throw 'PresentMon did not finish in time.'
    }
    try { [console]::Beep(880, 400) } catch { }

    if (-not (Test-Path -LiteralPath $csv)) { throw "Nothing was recorded. Was $exeName running and on screen?" }
    $stats = Get-SFFrameStats (ConvertFrom-SFPresentMonCsv $csv)
    if (-not $stats) { throw "Too few frames were recorded from $exeName. Was it on screen the whole time?" }

    $entry = [pscustomobject][ordered]@{
        Label = $Label; Time = (Get-Date).ToString('o'); Game = $exeName; Seconds = $stats.Seconds
        Frames = $stats.Frames; AvgFps = $stats.AvgFps; Low1 = $stats.Low1; Low01 = $stats.Low01; Csv = (Split-Path -Leaf $csv)
    }
    $all = @(Get-SFBenchmarkHistory $exeName) + $entry
    Save-SFJson -Object @($all) -Path (Join-Path $dir ($base + '.json'))
    return @($all)
}

function Write-SFBenchmarkTable {
    param([Parameter(Mandatory)]$Runs)
    $runs = @($Runs)
    if ($runs.Count -eq 0) { return }
    $first = $runs[0]
    Write-SFHeader ('FPS for ' + $first.Game)
    Write-Host ('  {0,-22} {1,9} {2,9} {3,9}' -f 'Run', 'Average', '1% low', '0.1% low') -ForegroundColor Gray
    foreach ($r in $runs) {
        $delta = ''
        if ($r -ne $first -and [double]$first.AvgFps -gt 0) { $delta = '   ({0:+0;-0}% avg, {1:+0;-0}% 1% low vs first)' -f (($r.AvgFps / $first.AvgFps - 1) * 100), (($r.Low1 / $first.Low1 - 1) * 100) }
        $label = "$($r.Label)"
        if ($label.Length -gt 22) { $label = $label.Substring(0, 22) }
        Write-Host ('  {0,-22} {1,9:N1} {2,9:N1} {3,9:N1}{4}' -f $label, $r.AvgFps, $r.Low1, $r.Low01, $delta)
    }
    Write-Host ''
    Write-Host '  Compare runs from the same place in the game. A few % up or down is normal run-to-run noise.' -ForegroundColor DarkGray
}
