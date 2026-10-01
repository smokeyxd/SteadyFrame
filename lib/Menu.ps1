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

# Row fields: Label, Detail, Selected, Locked, LockReason, Section, Group, Tag. Returns $null on cancel.
function Show-SFChecklist {
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
        if ($cmd -match '^(?i)a$') { foreach ($r in $rows) { if (-not (Get-SFProp $r 'Locked' $false) -and -not (Get-SFProp $r 'Group')) { $r.Selected = $true } }; continue }
        if ($cmd -match '^(?i)n$') { foreach ($r in $rows) { if (-not (Get-SFProp $r 'Group')) { $r.Selected = $false } }; continue }
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
        foreach ($n in $nums) {
            $r = $rows[$n - 1]
            if (Get-SFProp $r 'Locked' $false) { continue }
            $g = Get-SFProp $r 'Group'
            if ($g) {
                # radio group. updatePolicy always needs one picked, so it can't be cleared
                if (-not $r.Selected) { foreach ($o in $rows) { if ((Get-SFProp $o 'Group') -eq $g) { $o.Selected = $false } }; $r.Selected = $true }
                elseif ($g -ne 'updatePolicy') { $r.Selected = $false }
            } else {
                $r.Selected = -not $r.Selected
            }
        }
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

function Show-SFBanner {
    param([Parameter(Mandatory)]$Context)
    Clear-Host
    Write-Host ''
    Write-Host '  SteadyFrame ' -ForegroundColor White -NoNewline
    Write-Host ('v{0}  -  Windows tune-up for gaming PCs' -f (Get-SFVersion)) -ForegroundColor DarkGray
    Write-Host ('  {0}  |  Windows {1} {2} {3} (build {4})  |  {5}' -f $Context.Computer, $Context.OsMajor, $Context.Edition, $Context.DisplayVersion, $Context.Build, $Context.FormFactor) -ForegroundColor Gray
    $gpu = (@($Context.Gpus) -join ' + ')
    Write-Host ('  {0}  |  {1} GB {2}-{3} x{4}  |  {5}  |  {6}' -f $Context.CpuName, $Context.Ram.TotalGB, $Context.Ram.Type, $Context.Ram.SpeedMTs, $Context.Ram.Sticks, $gpu, $Context.Disk.SystemDisk) -ForegroundColor Gray
    $games = @(Get-SFProp $Context 'Games' @())
    if ($games.Count -gt 0) { Write-Host ('  Games found: ' + (($games | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Gray }
    if ($Context.IsDualCcdX3D) { Write-Host '  Dual-CCD X3D detected: keeping Balanced plan + Xbox Game Bar (AMD V-Cache driver needs them).' -ForegroundColor Yellow }
    if ($Context.IsIntelRaptor) { Write-Host '  Intel 13th/14th gen detected: the health check verifies the Vmin-shift microcode fix.' -ForegroundColor Yellow }
}
