# Newest entry first, so a value that was changed twice ends up back at the original.

function Invoke-SFRevert {
    param([Parameter(Mandatory)][string]$JournalPath, [string[]]$TweakIds = @(), [switch]$DryRun)
    $j = Read-SFJournal $JournalPath
    $entries = @($j.Entries)
    if ($TweakIds.Count -gt 0) { $entries = @($entries | Where-Object { $TweakIds -contains $_.TweakId }) }
    $entries = @($entries | Sort-Object { [int]$_.Seq } -Descending)
    $results = @()
    foreach ($e in $entries) {
        $r = Undo-SFJournalEntry -Entry $e -DryRun:$DryRun
        Write-SFResult $r
        $results += $r
    }
    if (-not $DryRun) {
        Save-SFJson -Object ([ordered]@{ Time = (Get-Date).ToString('o'); TweakIds = $TweakIds; Results = $results }) -Path (Join-Path $j.Dir 'reverted.json')
    }
    return $results
}

function Show-SFRevertMenu {
    param([switch]$DryRun)
    $runs = @(Get-SFJournals (Join-Path (Get-SFRoot) 'runs') | Where-Object { $_.Count -gt 0 })
    if ($runs.Count -eq 0) { Write-SFStatus 'INFO' 'No SteadyFrame runs with changes found on this PC.'; return }
    Write-SFHeader 'Undo a previous run'
    for ($i = 0; $i -lt $runs.Count; $i++) {
        $r = $runs[$i]
        $flag = if ($r.Reverted) { '  (already reverted once)' } else { '' }
        Write-Host ('  {0}) {1}  -  {2} changes{3}' -f ($i + 1), $r.Name, $r.Count, $flag)
    }
    Write-Host '  0) Back'
    $pick = Read-SFInput '  Which run? '
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $runs.Count) { return }
    $run = $runs[[int]$pick - 1]
    $j = Read-SFJournal $run.Path
    $ids = @($j.Entries | ForEach-Object { $_.TweakId } | Select-Object -Unique)
    $rows = foreach ($id in $ids) {
        $n = @($j.Entries | Where-Object { $_.TweakId -eq $id }).Count
        [pscustomobject]@{ Label = ('{0}  ({1} change(s))' -f $id, $n); Detail = ''; Selected = $true; Id = $id }
    }
    $picked = Show-SFChecklist -Title 'CHECKED = will be undone' -Rows @($rows)
    if ($null -eq $picked) { return }
    $sel = @($picked | Where-Object { $_.Selected } | ForEach-Object { $_.Id })
    if ($sel.Count -eq 0) { return }
    Write-Host ''
    Write-Host '  Note: changes made by WinUtil / Win11Debloat and removed apps are not in this journal.' -ForegroundColor DarkGray
    Write-Host '  Use the restore point (rstrui.exe) for those, and reinstall apps from the Microsoft Store.' -ForegroundColor DarkGray
    if (-not (Confirm-SF ('Undo {0} tweak(s) from {1}?' -f $sel.Count, $run.Name) -DefaultYes)) { return }
    $all = ($sel.Count -eq $ids.Count)
    [void](Invoke-SFRevert -JournalPath $run.Path -TweakIds $(if ($all) { @() } else { $sel }) -DryRun:$DryRun)
    Write-SFStatus 'OK' 'Done. Reboot to make sure everything is back.'
}
