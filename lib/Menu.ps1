# Console only. Keep engine logic out of here so a GUI can replace this file.

function Read-SFInput {
    param([string]$Prompt)
    Write-Host ''
    Write-Host $Prompt -ForegroundColor White -NoNewline
    $line = Read-Host
    # $null = input closed (piped input ran out). Callers treat it as cancel, otherwise menus loop forever.
    if ($null -eq $line) { return $null }
    return $line.Trim()
}

function Confirm-SF {
    param([string]$Prompt, [switch]$DefaultYes)
    $suffix = if ($DefaultYes) { ' [Y/n] ' } else { ' [y/N] ' }
    $a = Read-SFInput ($Prompt + $suffix)
    if ($a -eq '') { return [bool]$DefaultYes }
    return ($a -match '^(?i)(y|yes|s|sim)$')
}

function ConvertFrom-SFNumberList {
    param([string]$Text, [int]$Max)
    $nums = @()
    foreach ($part in ($Text -split '[,\s]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            for ($i = $a; $i -le $b; $i++) { $nums += $i }
        } elseif ($part -match '^\d+$') { $nums += [int]$part }
        else { return $null }
    }
    return @($nums | Where-Object { $_ -ge 1 -and $_ -le $Max } | Sort-Object -Unique)
}

# Radio groups: picking one row clears the others in its group. updatePolicy always needs one
# picked, so its rows can't be cleared.
function Switch-SFChecklistRow {
    param([Parameter(Mandatory)]$Rows, [int]$Index)
    $rows = @($Rows)
    if ($Index -lt 0 -or $Index -ge $rows.Count) { return }
    $r = $rows[$Index]
    if (Get-SFProp $r 'Locked' $false) { return }
    $g = Get-SFProp $r 'Group'
    if ($g) {
        if (-not $r.Selected) { foreach ($o in $rows) { if ((Get-SFProp $o 'Group') -eq $g) { $o.Selected = $false } }; $r.Selected = $true }
        elseif ($g -ne 'updatePolicy') { $r.Selected = $false }
    } else {
        $r.Selected = -not $r.Selected
    }
}

function Set-SFChecklistAll {
    param([Parameter(Mandatory)]$Rows, [bool]$Selected)
    foreach ($r in @($Rows)) {
        if (Get-SFProp $r 'Group') { continue }
        if ($Selected -and (Get-SFProp $r 'Locked' $false)) { continue }
        $r.Selected = $Selected
    }
}

function New-SFChecklistState {
    param([Parameter(Mandatory)]$Rows)
    $rows = @($Rows)
    $first = 0
    for ($i = 0; $i -lt $rows.Count; $i++) { if (-not (Get-SFProp $rows[$i] 'Locked' $false)) { $first = $i; break } }
    return [pscustomobject]@{ Rows = $rows; Cursor = $first; Top = 0 }
}

function Invoke-SFChecklistKey {
    param([Parameter(Mandatory)]$State, [string]$Key)
    $last = $State.Rows.Count - 1
    switch ($Key) {
        'Up' { $State.Cursor = [math]::Max(0, $State.Cursor - 1) }
        'Down' { $State.Cursor = [math]::Min($last, $State.Cursor + 1) }
        'PageUp' { $State.Cursor = [math]::Max(0, $State.Cursor - 10) }
        'PageDown' { $State.Cursor = [math]::Min($last, $State.Cursor + 10) }
        'Home' { $State.Cursor = 0 }
        'End' { $State.Cursor = $last }
        'Space' { Switch-SFChecklistRow -Rows $State.Rows -Index $State.Cursor }
        'a' { Set-SFChecklistAll -Rows $State.Rows -Selected $true }
        'n' { Set-SFChecklistAll -Rows $State.Rows -Selected $false }
    }
}

# Also moves State.Top so the highlighted row stays on screen.
function Get-SFChecklistLines {
    param([Parameter(Mandatory)]$State, [string]$Title, [int]$Width = 100, [int]$Height = 40)
    $rows = $State.Rows
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(@((New-SFSeg ('  ' + $Title) 'White')))
    if (@($rows | Where-Object { (Get-SFProp $_ 'Tag' '') -eq '[C]' }).Count -gt 0) {
        [void]$lines.Add(@((New-SFSeg '  [C] = weak or no proof, some are placebo. Off by default; measure before keeping one.' 'Yellow')))
    }
    [void]$lines.Add(@())

    $display = New-Object System.Collections.ArrayList
    $section = $null
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $sec = Get-SFProp $rows[$i] 'Section'
        if ($sec -and $sec -ne $section) { $section = $sec; [void]$display.Add([pscustomobject]@{ Section = $sec; Row = -1 }) }
        [void]$display.Add([pscustomobject]@{ Section = $null; Row = $i })
    }
    $cur = 0
    for ($d = 0; $d -lt $display.Count; $d++) { if ($display[$d].Row -eq $State.Cursor) { $cur = $d; break } }

    $detailHeight = 5
    $listHeight = [math]::Max(3, $Height - $lines.Count - $detailHeight - 3)
    if ($cur -lt $State.Top) { $State.Top = $cur }
    if ($cur -gt 0 -and $cur -eq $State.Top -and $display[$cur - 1].Row -eq -1) { $State.Top = $cur - 1 }
    if ($cur -ge $State.Top + $listHeight) { $State.Top = $cur - $listHeight + 1 }
    $State.Top = [math]::Max(0, [math]::Min($State.Top, [math]::Max(0, $display.Count - $listHeight)))

    for ($j = 0; $j -lt $listHeight; $j++) {
        $d = $State.Top + $j
        if ($d -ge $display.Count) { [void]$lines.Add(@()); continue }
        $item = $display[$d]
        if ($item.Row -lt 0) { [void]$lines.Add(@((New-SFSeg ('  -- ' + $item.Section + ' --') 'Cyan'))); continue }
        $r = $rows[$item.Row]
        $locked = [bool](Get-SFProp $r 'Locked' $false)
        $box = if ($locked) { '[-]' } elseif ($r.Selected) { '[x]' } else { '[ ]' }
        $tag = Get-SFProp $r 'Tag' ''
        $note = if ($locked) { '   (n/a: ' + (Get-SFProp $r 'LockReason' '') + ')' } else { '' }
        if ($item.Row -eq $State.Cursor) {
            $text = ' > {0} {1}{2}{3}' -f $box, $(if ($tag) { $tag + ' ' } else { '' }), $r.Label, $note
            [void]$lines.Add(@((New-SFSeg $text.PadRight($Width) 'White' 'DarkCyan')))
        } else {
            $color = if ($locked) { 'DarkGray' } elseif ($r.Selected) { 'Green' } else { 'Gray' }
            $segs = @((New-SFSeg ('   ' + $box + ' ') $color))
            if ($tag) { $segs += New-SFSeg ($tag + ' ') 'DarkGray' }
            $segs += New-SFSeg $r.Label $color
            if ($note) { $segs += New-SFSeg $note 'DarkGray' }
            [void]$lines.Add($segs)
        }
    }

    [void]$lines.Add(@((New-SFSeg ('  ' + ('-' * [math]::Max(10, $Width - 4))) 'DarkGray')))
    $r = $rows[$State.Cursor]
    $detail = Get-SFProp $r 'Detail' ''
    if (Get-SFProp $r 'Locked' $false) { $detail = 'Not available on this PC: ' + (Get-SFProp $r 'LockReason' '') + "`n" + $detail }
    $wrapped = @(Split-SFWrapped -Text $detail -Width ([math]::Max(20, $Width - 4)))
    for ($j = 0; $j -lt $detailHeight; $j++) {
        if ($j -lt $wrapped.Count) { [void]$lines.Add(@((New-SFSeg ('  ' + $wrapped[$j]) 'Gray'))) } else { [void]$lines.Add(@()) }
    }
    $selected = @($rows | Where-Object { $_.Selected }).Count
    [void]$lines.Add(@((New-SFSeg ('  {0} of {1} selected' -f $selected, $rows.Count) 'White')))
    [void]$lines.Add(@((New-SFSeg '  Up/Down move   Space tick   A all   N none   Enter continue   Esc cancel' 'DarkGray')))
    return , $lines.ToArray()
}

# Row fields: Label, Detail, Selected, Locked, LockReason, Section, Group, Tag. Returns $null on cancel.
function Show-SFChecklist {
    param([string]$Title, [Parameter(Mandatory)]$Rows)
    $rows = @($Rows)
    if ($rows.Count -eq 0 -or -not (Test-SFKeyConsole)) { return (Show-SFChecklistLines -Title $Title -Rows $rows) }
    $state = New-SFChecklistState $rows
    Enter-SFFrameMode
    try {
        $fresh = $true
        while ($true) {
            $lines = Get-SFChecklistLines -State $state -Title $Title -Width ([Console]::WindowWidth - 1) -Height ([Console]::WindowHeight - 1)
            Write-SFFrame -Lines $lines -Fresh:$fresh
            $fresh = $false
            $k = Read-SFKey
            if ($k -eq 'Enter') { return $rows }
            if ($k -eq 'Escape' -or $k -eq 'q') { return $null }
            Invoke-SFChecklistKey -State $state -Key $k
        }
    } finally {
        Exit-SFFrameMode
    }
}

function Write-SFLine {
    param($Segments)
    foreach ($s in @($Segments)) {
        if ($null -eq $s -or -not $s.Text) { continue }
        if ($s.Back) { Write-Host $s.Text -NoNewline -ForegroundColor $s.Color -BackgroundColor $s.Back }
        else { Write-Host $s.Text -NoNewline -ForegroundColor $s.Color }
    }
    Write-Host ''
}

function Get-SFMenuLines {
    param($Header = @(), [Parameter(Mandatory)]$Items, [int]$Cursor = 0, [string]$Footer = '', [int]$Width = 100)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in $Header) { [void]$lines.Add($l) }
    [void]$lines.Add(@())
    $items = @($Items)
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $label = '{0}) {1}' -f $it.Key, $it.Label
        if ($i -eq $Cursor) {
            $text = ' > ' + $label + $(if ($it.Note) { '  ' + $it.Note } else { '' })
            [void]$lines.Add(@((New-SFSeg $text.PadRight($Width) 'White' 'DarkCyan')))
        } else {
            $segs = @((New-SFSeg ('   ' + $label) 'Gray'))
            if ($it.Note) { $segs += New-SFSeg ('  ' + $it.Note) $(if ($it.NoteColor) { $it.NoteColor } else { 'DarkGray' }) }
            [void]$lines.Add($segs)
        }
    }
    if ($Footer) { [void]$lines.Add(@()); [void]$lines.Add(@((New-SFSeg ('  ' + $Footer) 'DarkGray'))) }
    return , $lines.ToArray()
}

# Escape picks the '0' item (Exit / Back); without a real console it falls back to a typed answer.
function Show-SFMenu {
    param($Header = @(), [Parameter(Mandatory)]$Items, [string]$Footer = '', [string[]]$ExtraKeys = @(), [string]$Prompt = '  Choice: ')
    $items = @($Items)
    $keys = @($items | ForEach-Object { "$($_.Key)".ToLowerInvariant() })
    if (-not (Test-SFKeyConsole)) {
        foreach ($l in (Get-SFMenuLines -Header $Header -Items $items -Cursor -1 -Footer $Footer)) { Write-SFLine $l }
        return (Read-SFInput $Prompt)
    }
    Enter-SFFrameMode
    try {
        $cur = 0
        $fresh = $true
        while ($true) {
            Write-SFFrame -Lines (Get-SFMenuLines -Header $Header -Items $items -Cursor $cur -Footer $Footer -Width ([Console]::WindowWidth - 1)) -Fresh:$fresh
            $fresh = $false
            $k = Read-SFKey
            if ($k -eq 'Up') { $cur = ($cur - 1 + $items.Count) % $items.Count }
            elseif ($k -eq 'Down') { $cur = ($cur + 1) % $items.Count }
            elseif ($k -eq 'Enter') { return $keys[$cur] }
            elseif ($k -eq 'Escape') { if ($keys -contains '0') { return '0' } else { return $null } }
            elseif ($k -and ($keys -contains $k -or $ExtraKeys -contains $k)) { return $k }
        }
    } finally {
        Exit-SFFrameMode
    }
}

function Show-SFChecklistLines {
    param([string]$Title, [Parameter(Mandatory)]$Rows)
    $rows = @($Rows)
    $hasC = (@($rows | Where-Object { (Get-SFProp $_ 'Tag' '') -eq '[C]' }).Count -gt 0)
    while ($true) {
        Write-SFHeader $Title
        if ($hasC) {
            Write-Host '  [C] = popular tweaks with weak or no proof behind them. Some are placebo. They are here because' -ForegroundColor Yellow
            Write-Host '  people ask for them, they are off by default, and nothing promises they help: benchmark before keeping one.' -ForegroundColor Yellow
        }
        $section = $null
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $sec = Get-SFProp $r 'Section'
            if ($sec -and $sec -ne $section) { $section = $sec; Write-Host ''; Write-Host ('  -- ' + $sec + ' --') -ForegroundColor Gray }
            $locked = [bool](Get-SFProp $r 'Locked' $false)
            $box = if ($locked) { '[-]' } elseif ($r.Selected) { '[x]' } else { '[ ]' }
            $color = if ($locked) { 'DarkGray' } elseif ($r.Selected) { 'Green' } else { 'Gray' }
            $tag = Get-SFProp $r 'Tag' ''
            Write-Host ('  {0} {1,3}. ' -f $box, ($i + 1)) -ForegroundColor $color -NoNewline
            if ($tag) { Write-Host ($tag + ' ') -ForegroundColor DarkGray -NoNewline }
            Write-Host $r.Label -ForegroundColor $color -NoNewline
            if ($locked) { Write-Host ('   (n/a: ' + (Get-SFProp $r 'LockReason' '') + ')') -ForegroundColor DarkGray }
            else { Write-Host '' }
        }
        Write-Host ''
        Write-Host '  Numbers toggle (3  3,5  3-7) | i 3 = details | a = all | n = none | Enter = continue | q = cancel' -ForegroundColor DarkGray
        $cmd = Read-SFInput '  > '
        if ($null -eq $cmd) { return $null }
        if ($cmd -eq '') { return $rows }
        if ($cmd -match '^(?i)q$') { return $null }
        if ($cmd -match '^(?i)a$') { Set-SFChecklistAll -Rows $rows -Selected $true; continue }
        if ($cmd -match '^(?i)n$') { Set-SFChecklistAll -Rows $rows -Selected $false; continue }
        if ($cmd -match '^(?i)i\s*(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -ge 1 -and $n -le $rows.Count) {
                Write-Host ''
                Write-Host ('  ' + $rows[$n - 1].Label) -ForegroundColor White
                foreach ($line in ("$(Get-SFProp $rows[$n - 1] 'Detail' '')" -split "`n")) { Write-Host ('    ' + $line) -ForegroundColor Gray }
                [void](Read-SFInput '  (Enter to go back) ')
            }
            continue
        }
        $nums = ConvertFrom-SFNumberList $cmd $rows.Count
        if ($null -eq $nums) { Write-Host '  Did not understand that.' -ForegroundColor Yellow; continue }
        foreach ($n in $nums) { Switch-SFChecklistRow -Rows $rows -Index ($n - 1) }
    }
}

function Format-SFTweakDetail {
    param($Tweak)
    $lines = @('Tier ' + $Tweak.tier + ' - ' + $(switch ($Tweak.tier) { 'A' { 'proven / vendor-documented' } 'B' { 'situational' } default { 'weak evidence, placebo or cosmetic' } }))
    $lines += ('Why: ' + $Tweak.why)
    $br = Get-SFProp $Tweak 'breaks' ''
    if ($br) { $lines += ('May break: ' + $br) }
    $src = Get-SFProp $Tweak 'source' ''
    if ($src) { $lines += ('Source: ' + $src) }
    return ($lines -join "`n")
}

function ConvertTo-SFChecklistRows {
    param([Parameter(Mandatory)]$Selection)
    $out = foreach ($s in $Selection) {
        if (-not $s.Visible) { continue }
        [pscustomobject]@{
            Label = $s.Tweak.name; Detail = (Format-SFTweakDetail $s.Tweak); Selected = $s.Selected
            Locked = (-not $s.Applies); LockReason = $s.Reason; Section = $s.Category; Group = $s.Group
            Tag = ('[' + $s.Tier + ']'); Source = $s
        }
    }
    return @($out)
}

function ConvertTo-SFExternalRows {
    param([Parameter(Mandatory)]$Selection, [string]$Section)
    $out = foreach ($s in $Selection) {
        if (-not $s.Visible) { continue }
        $detail = 'Option: ' + $s.Id
        $br = Get-SFProp $s.Item 'breaks' ''
        if ($br) { $detail += "`nMay break: " + $br }
        [pscustomobject]@{
            Label = $s.Item.name; Detail = $detail; Selected = $s.Selected; Locked = (-not $s.Applies); LockReason = $s.Reason
            Section = $Section; Group = $null; Tag = $(if ($s.Advanced) { '[adv]' } else { '' }); Source = $s
        }
    }
    return @($out)
}

function Get-SFBannerLines {
    param([Parameter(Mandatory)]$Context)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(@())
    [void]$lines.Add(@((New-SFSeg '  SteadyFrame ' 'White'), (New-SFSeg ('v{0}  -  Windows tune-up for gaming PCs' -f (Get-SFVersion)) 'DarkGray')))
    [void]$lines.Add(@((New-SFSeg ('  {0}  |  Windows {1} {2} {3} (build {4})  |  {5}' -f $Context.Computer, $Context.OsMajor, $Context.Edition, $Context.DisplayVersion, $Context.Build, $Context.FormFactor) 'Gray')))
    $gpu = (@($Context.Gpus) -join ' + ')
    [void]$lines.Add(@((New-SFSeg ('  {0}  |  {1} GB {2}-{3} x{4}  |  {5}  |  {6}' -f $Context.CpuName, $Context.Ram.TotalGB, $Context.Ram.Type, $Context.Ram.SpeedMTs, $Context.Ram.Sticks, $gpu, $Context.Disk.SystemDisk) 'Gray')))
    $games = @(Get-SFProp $Context 'Games' @())
    if ($games.Count -gt 0) { [void]$lines.Add(@((New-SFSeg ('  Games found: ' + (($games | ForEach-Object { $_.Name }) -join ', ')) 'Gray'))) }
    if ($Context.IsDualCcdX3D) { [void]$lines.Add(@((New-SFSeg '  Dual-CCD X3D detected: keeping Balanced plan + Xbox Game Bar (AMD V-Cache driver needs them).' 'Yellow'))) }
    if ($Context.IsIntelRaptor) { [void]$lines.Add(@((New-SFSeg '  Intel 13th/14th gen detected: the health check verifies the Vmin-shift microcode fix.' 'Yellow'))) }
    return , $lines.ToArray()
}

function Show-SFBanner {
    param([Parameter(Mandatory)]$Context)
    Clear-Host
    foreach ($l in (Get-SFBannerLines $Context)) { Write-SFLine $l }
}

function Show-SFUpdate {
    param([Parameter(Mandatory)]$Release)
    Write-SFHeader ('SteadyFrame ' + $Release.Version)
    foreach ($line in (Format-SFReleaseNotes $Release.Notes)) { Write-Host ('  ' + $line) -ForegroundColor Gray }
    Write-Host ''
    Write-Host ('  Full notes: ' + $Release.Url) -ForegroundColor DarkGray
    Write-Host ('  It goes in a new folder: ' + (Join-Path (Split-Path -Parent (Get-SFRoot)) ('SteadyFrame-' + $Release.Version)))
    Write-Host '  This folder stays as it is, and the undo history works from both.' -ForegroundColor DarkGray
    if (-not (Confirm-SF '  Download it?' -DefaultYes)) { return }
    try { $r = Install-SFUpdate -Release $Release }
    catch { Write-SFStatus 'FAIL' $_.Exception.Message; return }
    $how = if ($r.Checked) { 'checksum matches the one on GitHub' } else { 'GitHub listed no checksum, SHA256 ' + $r.Sha256 }
    Write-SFStatus 'OK' ('Downloaded to {0} ({1})' -f $r.Path, $how)
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $r.Path) } catch { }
    Write-Host '  Close this window and open Run.bat in the new folder. You can delete this old folder afterwards.' -ForegroundColor White
}

function Show-SFShareOffer {
    param([Parameter(Mandatory)]$Findings, $Context, [string]$Title = 'health check')
    $ans = Read-SFInput '  c = copy a short summary for Discord, Enter = back: '
    if ($ans -notmatch '^(?i)c$') { return }
    try {
        Set-Clipboard -Value (Format-SFShareText -Findings $Findings -Context $Context -Title $Title)
        Write-SFStatus 'OK' 'Copied. Paste it in Discord with Ctrl+V.'
    } catch {
        Write-SFStatus 'FAIL' ('Could not copy: ' + $_.Exception.Message)
    }
    [void](Read-SFInput '  Enter to go back...')
}

function Show-SFBenchmarkMenu {
    param($Context)
    Write-SFHeader 'Measure FPS'
    Write-Host '  Records your game''s frame times for a minute and shows average FPS and 1% / 0.1% lows.'
    Write-Host '  Measure once before a change and once after, in the same place in the game.'
    $pins = Read-SFJson (Get-SFExternalPaths).Pins
    $pin = $pins.presentmon
    if (-not (Test-Path -LiteralPath (Join-Path (Get-SFExternalPaths).Cache $pin.file))) {
        Write-Host ''
        Write-Host ('  This uses PresentMon {0}, Intel''s free frame-time tool. It is downloaded once from GitHub' -f $pin.tag)
        Write-Host '  (about 1 MB) and checked against its SHA256 before it runs. It doesn''t touch the game itself.'
        if (-not (Confirm-SF '  Download it?' -DefaultYes)) { return }
    }
    Write-Host ''
    Write-Host '  Looking for a running game (have it open)...' -ForegroundColor DarkGray
    $game = Find-SFRunningGame -Context $Context
    if ($game -and -not (Confirm-SF ('  Measure {0}?' -f $game) -DefaultYes)) { $game = $null }
    if (-not $game) {
        $game = Read-SFInput '  Game .exe name (for example RustClient.exe), empty = cancel: '
        if (-not $game) { return }
    }
    $label = Read-SFInput '  Name this run (for example: before, after, overlay off): '
    if ($null -eq $label) { return }
    try {
        $runs = Invoke-SFBenchmark -Game $game -Label $label
        Write-SFBenchmarkTable $runs
    } catch {
        Write-SFStatus 'FAIL' $_.Exception.Message
    }
}
