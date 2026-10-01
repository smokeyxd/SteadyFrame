# The apply pipeline, UI-agnostic: restore point -> WinUtil -> Win11Debloat ->
# SteadyFrame catalog (last, so its values win and are journaled) -> health
# check + security baseline diff. A GUI can call Invoke-SFOptimize directly.

function New-SFRunDir {
    param([string]$Suffix = '')
    $dir = Join-Path (Join-Path (Get-SFRoot) 'runs') ('{0}_{1}{2}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'), $Suffix)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-SFRestorePoint {
    param([string]$Description)
    $key = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $prev = Get-SFRegistryValue $key 'SystemRestorePointCreationFrequency'
    try {
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
        # Windows silently skips a restore point if one was made in the last 24h; lift that for this one call.
        Set-SFRegistryValue -Path $key -Name 'SystemRestorePointCreationFrequency' -Kind 'DWord' -Value 0 | Out-Null
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        return $true
    } catch {
        Write-SFStatus 'WARN' ('Restore point failed: ' + $_.Exception.Message)
        return $false
    } finally {
        if ($prev.Exists) { Set-SFRegistryValue -Path $key -Name 'SystemRestorePointCreationFrequency' -Kind $prev.Kind -Value $prev.Value | Out-Null }
        else { Remove-SFRegistryValue $key 'SystemRestorePointCreationFrequency' }
    }
}

function Write-SFResult {
    param([Parameter(Mandatory)]$Result)
    $map = @{ Applied = 'APPLIED'; DryRun = 'DRYRUN'; AlreadySet = 'SAME'; Skipped = 'SKIP'; Blocked = 'BLOCKED'; Failed = 'FAIL' }
    $text = $Result.Target
    if ($Result.Status -in @('Applied', 'DryRun', 'AlreadySet') -and ($null -ne $Result.Before -or $null -ne $Result.After)) {
        $text += (': {0} -> {1}' -f (Format-SFValue $Result.Before), (Format-SFValue $Result.After))
    }
    if ($Result.Message) { $text += ('  (' + $Result.Message + ')') }
    Write-SFStatus $map[$Result.Status] $text
}

function Invoke-SFOptimize {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Tweaks,              # selected catalog tweak objects, in order
        [string[]]$WinUtilIds = @(),
        [string[]]$W11DFlags = @(),
        [ValidateSet('Pinned', 'Latest', 'None')][string]$ExternalSource = 'Pinned',
        [string]$Preset = '',
        [switch]$DryRun, [switch]$Interactive, [switch]$NoRestorePoint
    )
    $runDir = if ($DryRun) { New-SFRunDir '-dryrun' } else { $null }
    $journal = $null
    if (-not $DryRun) {
        $journal = New-SFJournal -Root (Join-Path (Get-SFRoot) 'runs') -Meta @{ Preset = $Preset; ExternalSource = $ExternalSource; WinUtil = @($WinUtilIds); Win11Debloat = @($W11DFlags); Tweaks = @($Tweaks | ForEach-Object { $_.id }) }
        $runDir = $journal.Dir
    }
    $transcript = $false
    try { Start-Transcript -Path (Join-Path $runDir 'transcript.log') -Append | Out-Null; $transcript = $true } catch { }
    try {
        return (Invoke-SFOptimizeCore -Context $Context -Tweaks $Tweaks -WinUtilIds $WinUtilIds -W11DFlags $W11DFlags `
                -ExternalSource $ExternalSource -Preset $Preset -RunDir $runDir -Journal $journal -DryRun:$DryRun -Interactive:$Interactive -NoRestorePoint:$NoRestorePoint)
    } finally {
        if ($transcript) { try { Stop-Transcript | Out-Null } catch { } }
    }
}

function Invoke-SFOptimizeCore {
    param($Context, $Tweaks, [string[]]$WinUtilIds, [string[]]$W11DFlags, [string]$ExternalSource, [string]$Preset,
        [string]$RunDir, $Journal, [switch]$DryRun, [switch]$Interactive, [switch]$NoRestorePoint)
    $summary = [ordered]@{ RunDir = $runDir; RestorePoint = $null; WinUtilExit = $null; W11DExit = $null; Results = @(); SecurityChanges = @() }
    $secBefore = Get-SFSecurityBaseline

    if (-not $DryRun -and -not $NoRestorePoint) {
        Write-SFHeader 'Restore point'
        $ok = New-SFRestorePoint -Description ('SteadyFrame ' + (Split-Path -Leaf $runDir))
        $summary.RestorePoint = $ok
        if ($ok) { Write-SFStatus 'OK' 'Restore point created (undoes everything, including the debloat tools).' }
        elseif ($Interactive) {
            if (-not (Confirm-SF 'Continue WITHOUT a restore point? (SteadyFrame changes can still be undone with Revert)')) { throw 'Stopped: no restore point.' }
        } else { throw 'Stopped: restore point could not be created (use -NoRestorePoint to override).' }
    }

    $toolSource = if ($ExternalSource -eq 'None') { $null } else { $ExternalSource }
    if ($toolSource -and $WinUtilIds.Count -gt 0) {
        Write-SFHeader 'Chris Titus WinUtil'
        try {
            $summary.WinUtilExit = Invoke-SFWinUtil -Ids $WinUtilIds -Source $toolSource -LogDir $runDir -DryRun:$DryRun
        } catch { Write-SFStatus 'FAIL' $_.Exception.Message; $summary.WinUtilExit = 'error: ' + $_.Exception.Message }
    }
    if ($toolSource -and $W11DFlags.Count -gt 0) {
        Write-SFHeader 'Raphire Win11Debloat'
        try {
            $summary.W11DExit = Invoke-SFWin11Debloat -Flags $W11DFlags -Source $toolSource -LogDir (Join-Path $runDir 'win11debloat') -DryRun:$DryRun
        } catch { Write-SFStatus 'FAIL' $_.Exception.Message; $summary.W11DExit = 'error: ' + $_.Exception.Message }
    }

    Write-SFHeader 'SteadyFrame tweaks'
    $all = @()
    foreach ($t in $Tweaks) {
        Write-Host ('  ' + $t.name) -ForegroundColor White
        $res = @(Invoke-SFTweak -Tweak $t -Context $Context -Journal $Journal -DryRun:$DryRun -Interactive:$Interactive)
        foreach ($r in $res) { if (-not $r.Quiet) { Write-SFResult $r } }
        $all += $res
    }
    $summary.Results = $all

    $secAfter = Get-SFSecurityBaseline
    $summary.SecurityChanges = @(Compare-SFSecurityBaseline -Before $secBefore -After $secAfter)
    Write-SFHeader 'Security baseline check'
    if ($summary.SecurityChanges.Count -eq 0) { Write-SFStatus 'OK' 'Defender, VBS/HVCI, Secure Boot, TPM, UAC, firewall and CPU mitigations unchanged.' }
    else {
        foreach ($c in $summary.SecurityChanges) { Write-SFStatus 'BAD' ('{0} changed: {1} -> {2}' -f $c.Setting, $c.Before, $c.After) }
        Write-Host '  Something changed a security setting. Check the logs in the run folder; the restore point can undo it.' -ForegroundColor Red
    }

    $cards = Save-SFGameCards -Context $Context -Path (Join-Path $RunDir 'game-settings.txt')
    if ($cards) {
        Write-SFHeader 'Games'
        Write-SFStatus 'INFO' ('In-game settings for your games: ' + $cards + '  (main menu option 7 shows them)')
    }

    $counts = @{}
    foreach ($r in $all) { if (-not $r.Quiet) { $counts[$r.Status] = 1 + [int]$counts[$r.Status] } }
    Save-SFJson -Object ([ordered]@{
            Time = (Get-Date).ToString('o'); DryRun = [bool]$DryRun; Preset = $Preset; Counts = $counts
            RestorePoint = $summary.RestorePoint; WinUtilExit = $summary.WinUtilExit; W11DExit = $summary.W11DExit
            SecurityChanges = $summary.SecurityChanges; Results = $all
        }) -Path (Join-Path $runDir 'summary.json')
    $summary.Counts = $counts
    return [pscustomobject]$summary
}
