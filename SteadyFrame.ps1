<#
.SYNOPSIS
    SteadyFrame - interactive Windows 10/11 gaming optimizer focused on stable frame times.

.DESCRIPTION
    Health check -> pick a preset -> review every change -> restore point ->
    Chris Titus WinUtil + Raphire Win11Debloat (pinned, hash-verified) ->
    SteadyFrame's own evidence-tiered tweaks (journaled, revertible).
    Never touches Defender protection, VBS/HVCI, Secure Boot/TPM, UAC, firewall
    or CPU security mitigations (see lib\Guard.ps1).

.EXAMPLE
    .\Run.bat                                   # interactive (recommended)
.EXAMPLE
    .\SteadyFrame.ps1 -DiagnoseOnly             # health check only, changes nothing
.EXAMPLE
    .\SteadyFrame.ps1 -Preset HighEnd -DryRun   # show exactly what would change
.EXAMPLE
    .\SteadyFrame.ps1 -Preset MidRange -Unattended -UpdatePolicy SecurityOnly
.EXAMPLE
    .\SteadyFrame.ps1 -ListTweaks -Json         # catalog + applicability, for a GUI
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'HighEnd', 'MidRange', 'Minimal', 'Custom')][string]$Preset = 'Auto',
    [string[]]$Include = @(),
    [string[]]$Exclude = @(),
    [ValidateSet('Pinned', 'Latest', 'None')][string]$ExternalSource = 'Pinned',
    [ValidateSet('Leave', 'DeferFeature', 'SecurityOnly')][string]$UpdatePolicy = 'DeferFeature',
    [string[]]$GameExe = @(),
    [switch]$NoGamePass,
    [switch]$DryRun,
    [switch]$Unattended,
    [switch]$DiagnoseOnly,
    [switch]$ListTweaks,
    [switch]$Json,
    [switch]$ShowAll,
    [switch]$NoRestorePoint,
    [switch]$Prefetch,
    [switch]$Revert,
    [switch]$GameCards
)

Import-Module (Join-Path $PSScriptRoot 'lib\SteadyFrame.psm1') -Force -DisableNameChecking

# "-Include a,b" arrives as one string when launched through -File (Run.bat, elevation).
$Include = @($Include | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Exclude = @($Exclude | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$GameExe = @($GameExe | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($ListTweaks) {
    $catalog = Import-SFCatalog
    $ctx = Get-SFContext -GameExe $GameExe -NoGamePass:$NoGamePass
    if ($Json) { Export-SFCatalogJson -Catalog $catalog -Context $ctx; return }
    $catalog | ForEach-Object {
        $app = Get-SFApplicability $_ $ctx
        [pscustomobject]@{ Id = $_.id; Tier = $_.tier; Category = $_.category; Presets = (@(Get-SFProp $_ 'presets' @()) -join ','); AppliesHere = $app.Applies; Name = $_.name }
    } | Format-Table -AutoSize
    return
}

if ($GameCards) {
    $ctx = Get-SFContext -GameExe $GameExe -NoGamePass:$NoGamePass
    Write-SFGameCards -Context $ctx -All:$ShowAll
    return
}

$needsAdmin = -not ($DiagnoseOnly -or $DryRun)
if ($needsAdmin -and -not (Test-SFAdmin)) {
    Write-Host 'SteadyFrame needs administrator rights. Relaunching elevated...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value.IsPresent) { $argList += ('-' + $kv.Key) } }
        elseif ($kv.Value -is [System.Array]) { $argList += ('-' + $kv.Key); $argList += ('"{0}"' -f ($kv.Value -join ',')) }
        else { $argList += ('-' + $kv.Key); $argList += ('"{0}"' -f $kv.Value) }
    }
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs } catch { Write-Host 'Elevation was cancelled.' -ForegroundColor Red }
    return
}
if (-not (Test-SFAdmin)) { Write-Host 'Not running as administrator: some checks (TPM, BitLocker, boot settings) will show as unknown.' -ForegroundColor Yellow }

if ($Prefetch) { Invoke-SFPrefetch; return }

$catalog = Import-SFCatalog
$problems = @(Test-SFCatalog $catalog)
if ($problems.Count -gt 0) {
    Write-Host 'The tweak catalog has problems, refusing to run:' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Red }
    exit 1
}

$ctx = Get-SFContext -GameExe $GameExe -NoGamePass:$NoGamePass
$interactive = -not $Unattended
$opts = @{ ExternalSource = $ExternalSource; UpdatePolicy = $UpdatePolicy; ShowAll = [bool]$ShowAll; DryRun = [bool]$DryRun }

function Invoke-HealthCheck {
    param([switch]$Save)
    Write-Host ''
    Write-Host '  Running health check (read-only)...' -ForegroundColor DarkGray
    $findings = Get-SFDiagnostics -Context $ctx
    Write-SFDiagnostics $findings
    if ($Save) {
        $dir = New-SFRunDir '-health'
        Save-SFDiagnostics -Findings $findings -Path (Join-Path $dir 'health') -Context $ctx
        Write-Host ''
        Write-Host ('  Report saved: ' + $dir) -ForegroundColor DarkGray
    }
    return $findings
}

function Show-Advanced {
    while ($true) {
        Write-SFHeader 'Advanced options'
        Write-Host ('  1) Debloat tools source ........ {0}   (Pinned = reviewed + hash-checked | Latest | None)' -f $opts.ExternalSource)
        Write-Host ('  2) Windows Update policy ....... {0}   (DeferFeature | SecurityOnly | Leave)' -f $opts.UpdatePolicy)
        Write-Host ('  3) Show tier C tweaks .......... {0}   (weak-evidence / placebo / cosmetic, off by default)' -f $(if ($opts.ShowAll) { 'yes' } else { 'no' }))
        Write-Host ('  4) Games for High priority ..... {0}' -f $(if (@($ctx.GameExes).Count) { $ctx.GameExes -join ', ' } else { '(none)' }))
        Write-Host ('  5) Uses Game Pass / Xbox app ... {0}' -f $(if ($ctx.NoGamePass) { 'no' } else { 'yes' }))
        Write-Host ('  6) Dry run ..................... {0}   (show what would change, change nothing)' -f $(if ($opts.DryRun) { 'yes' } else { 'no' }))
        Write-Host '  0) Back'
        switch (Read-SFInput '  Choice: ') {
            '1' {
                Write-Host '    1) Pinned - the reviewed versions, checked before running (default)'
                Write-Host '    2) Latest - whatever was published today, NOT checked'
                Write-Host '    3) None   - never run WinUtil / Win11Debloat, only SteadyFrame''s own tweaks'
                switch (Read-SFInput '    Source: ') {
                    '1' { $opts.ExternalSource = 'Pinned' }
                    '2' { $opts.ExternalSource = 'Latest'; Write-Host '    Only use Latest if you know why: it runs code nobody has reviewed for this tool.' -ForegroundColor Yellow }
                    '3' { $opts.ExternalSource = 'None' }
                }
            }
            '2' { $opts.UpdatePolicy = @{ DeferFeature = 'SecurityOnly'; SecurityOnly = 'Leave'; Leave = 'DeferFeature' }[$opts.UpdatePolicy] }
            '3' { $opts.ShowAll = -not $opts.ShowAll }
            '4' {
                $txt = Read-SFInput '  Game .exe names, comma separated (e.g. cs2.exe, VALORANT-Win64-Shipping.exe), empty = none: '
                $ctx.GameExes = @($txt -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { if ($_ -notmatch '\.exe$') { "$_.exe" } else { $_ } })
            }
            '5' { $ctx.NoGamePass = -not $ctx.NoGamePass }
            '6' { $opts.DryRun = -not $opts.DryRun }
            default { return }
        }
    }
}

function Get-OtherTier { if ($ctx.SuggestedPreset -eq 'HighEnd') { 'MidRange' } else { 'HighEnd' } }

function Start-Optimize {
    param([string]$PresetName)
    $policy = $opts.UpdatePolicy
    $sel = @(Resolve-SFSelection -Catalog $catalog -Context $ctx -Preset $PresetName -Include $Include -Exclude $Exclude -UpdatePolicy $policy -ShowAll:$opts.ShowAll)
    # can be switched off for this run below, when the PC was already debloated
    $source = $opts.ExternalSource

    if ($interactive) {
        $findings = Invoke-HealthCheck -Save
        $bad = @($findings | Where-Object { $_.Status -eq 'BAD' }).Count
        if ($bad -gt 0) { Write-Host ('  {0} BAD item(s) above: fixing those matters more than any registry tweak.' -f $bad) -ForegroundColor Yellow }
        Write-Host ''
        Write-Host '  Tip: record a CapFrameX/PresentMon baseline in your main game NOW (same scene, 3 x 60-90 s)' -ForegroundColor DarkGray
        Write-Host '  so you can compare average / 1% / 0.1% lows after the reboot.' -ForegroundColor DarkGray

        if ($source -ne 'None' -and $PresetName -ne 'Minimal') {
            $traces = @(Get-SFPriorDebloatTraces)
            Write-SFHeader 'Debloat tools (WinUtil + Win11Debloat)'
            if ($traces.Count -gt 0) {
                Write-Host ('  This PC has traces of: {0}. If it was already debloated, skip them.' -f ($traces -join ', '))
            } else {
                Write-Host '  No traces of Talon, WinUtil or Win11Debloat found (temp folders get cleaned, so this is only a guess).'
            }
            $skipDefault = ($traces.Count -gt 0)
            Write-Host ('  1) Skip them - only SteadyFrame''s own tweaks{0}' -f $(if ($skipDefault) { '   (default)' } else { '' }))
            Write-Host ('  2) Run them too{0}' -f $(if (-not $skipDefault) { '   (default)' } else { '' }))
            $ans = Read-SFInput '  Choice (Enter = default): '
            if ($null -eq $ans) { return }
            if ($ans -eq '1' -or ($ans -eq '' -and $skipDefault)) { $source = 'None' }
        } else {
            [void](Read-SFInput '  Press Enter to review the changes...')
        }
    }

    $wu = @()
    $wd = @()
    if ($source -ne 'None') {
        $wu = @(Resolve-SFExternalSelection -Tool 'winutil' -Context $ctx -Preset $PresetName -Include $Include -Exclude $Exclude -ShowAll:$opts.ShowAll)
        $wd = @(Resolve-SFExternalSelection -Tool 'win11debloat' -Context $ctx -Preset $PresetName -Include $Include -Exclude $Exclude -ShowAll:$opts.ShowAll)
    }

    if ($interactive) {
        $rows = ConvertTo-SFChecklistRows $sel
        $picked = Show-SFChecklist -Title ("SteadyFrame tweaks - preset {0} (CHECKED = will be applied)" -f $PresetName) -Rows $rows
        if ($null -eq $picked) { return }
        foreach ($r in $picked) { $r.Source.Selected = $r.Selected }

        if ($source -ne 'None') {
            $erows = @(ConvertTo-SFExternalRows $wu 'Chris Titus WinUtil') + @(ConvertTo-SFExternalRows $wd 'Raphire Win11Debloat')
            $epicked = Show-SFChecklist -Title ('Debloat and privacy tools ({0} source) - CHECKED = will be applied' -f $source) -Rows $erows
            if ($null -eq $epicked) { return }
            foreach ($r in $epicked) { $r.Source.Selected = $r.Selected }
        }
    }

    $tweaks = @($sel | Where-Object { $_.Selected -and $_.Applies } | ForEach-Object { $_.Tweak })
    $wuIds = @($wu | Where-Object { $_.Selected -and $_.Applies } | ForEach-Object { $_.Id })
    $wdFlags = @($wd | Where-Object { $_.Selected -and $_.Applies } | ForEach-Object { $_.Id })
    if ($tweaks.Count + $wuIds.Count + $wdFlags.Count -eq 0) { Write-SFStatus 'INFO' 'Nothing selected.'; return }

    Write-SFHeader 'Summary'
    Write-Host ('  SteadyFrame tweaks: {0}   WinUtil: {1}   Win11Debloat: {2}   Update policy: {3}' -f $tweaks.Count, $wuIds.Count, $wdFlags.Count, $opts.UpdatePolicy)
    $breaks = @()
    foreach ($t in $tweaks) { $b = Get-SFProp $t 'breaks' ''; if ($b) { $breaks += ('{0}: {1}' -f $t.name, $b) } }
    foreach ($s in @($wu + $wd | Where-Object { $_.Selected -and $_.Applies })) { $b = Get-SFProp $s.Item 'breaks' ''; if ($b) { $breaks += ('{0}: {1}' -f $s.Item.name, $b) } }
    if ($breaks.Count -gt 0) {
        Write-Host ''
        Write-Host '  Things that may stop working:' -ForegroundColor Yellow
        foreach ($b in $breaks) { Write-Host ('   - ' + $b) -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host '  Never touched: Defender protection, VBS / Memory integrity, Secure Boot, TPM, UAC, firewall, CPU mitigations.' -ForegroundColor Green
    Write-Host '  Undo: Revert.bat undoes SteadyFrame tweaks; the restore point undoes everything (rstrui.exe).' -ForegroundColor Green
    if ($opts.DryRun) { Write-Host '  DRY RUN: nothing will be changed.' -ForegroundColor White }
    if ($interactive) {
        $ans = Read-SFInput '  Type YES to apply (anything else cancels): '
        if ($ans -notmatch '^(?i)(yes|sim|si)$') { Write-SFStatus 'INFO' 'Cancelled, nothing changed.'; return }
    }

    try {
        $summary = Invoke-SFOptimize -Context $ctx -Tweaks $tweaks -WinUtilIds $wuIds -W11DFlags $wdFlags -ExternalSource $source `
            -Preset $PresetName -DryRun:$opts.DryRun -Interactive:$interactive -NoRestorePoint:$NoRestorePoint
    } catch {
        Write-SFStatus 'FAIL' $_.Exception.Message
        return
    }

    Write-SFHeader 'Done'
    $c = $summary.Counts
    Write-Host ('  Applied {0} | already set {1} | skipped {2} | blocked {3} | failed {4}{5}' -f [int]$c['Applied'], [int]$c['AlreadySet'], [int]$c['Skipped'], [int]$c['Blocked'], [int]$c['Failed'], $(if ($opts.DryRun) { (' | dry-run ' + [int]$c['DryRun']) } else { '' }))
    Write-Host ('  Run folder (journal, logs, summary): ' + $summary.RunDir) -ForegroundColor DarkGray
    if (-not $opts.DryRun) {
        Write-Host '  Reboot, then re-run your benchmark and compare 1% / 0.1% lows.' -ForegroundColor White
        if ($interactive -and (Confirm-SF '  Reboot now?')) { Restart-Computer -Force }
    }
}

if ($Revert) { Show-SFRevertMenu -DryRun:$DryRun; return }

if ($DiagnoseOnly) {
    Show-SFBanner $ctx
    [void](Invoke-HealthCheck -Save)
    return
}

if (-not $interactive) {
    $p = if ($Preset -eq 'Auto') { $ctx.SuggestedPreset } else { $Preset }
    Show-SFBanner $ctx
    Write-Host ('  Unattended run, preset {0}' -f $p) -ForegroundColor White
    Start-Optimize $p
    return
}

if ($Preset -ne 'Auto') {
    Show-SFBanner $ctx
    Start-Optimize $Preset
    return
}

while ($true) {
    Show-SFBanner $ctx
    $other = Get-OtherTier
    Write-Host ''
    Write-Host '  1) Health check only (changes nothing)'
    Write-Host ('  2) Optimize - {0} preset ' -f $ctx.SuggestedPreset) -NoNewline; Write-Host '(recommended for this PC)' -ForegroundColor Green
    Write-Host ('  3) Optimize - {0} preset' -f $other)
    Write-Host '  4) Optimize - Minimal (safest, no debloat tools)'
    Write-Host '  5) Custom (start from the recommendation, pick everything yourself)'
    Write-Host '  6) Undo a previous run'
    Write-Host '  7) Game settings cards (TEKKEN 8, VALORANT, CS2)'
    Write-Host '  0) Exit'
    if ($opts.DryRun) { Write-Host '  [dry run is ON]' -ForegroundColor White }
    $choice = Read-SFInput '  Choice: '
    if ($null -eq $choice) { return }
    switch -Regex ($choice) {
        '^1$' { [void](Invoke-HealthCheck -Save); [void](Read-SFInput '  Enter to go back...') }
        '^2$' { Start-Optimize $ctx.SuggestedPreset; [void](Read-SFInput '  Enter to go back...') }
        '^3$' { Start-Optimize $other; [void](Read-SFInput '  Enter to go back...') }
        '^4$' { Start-Optimize 'Minimal'; [void](Read-SFInput '  Enter to go back...') }
        '^5$' { $opts.ShowAll = $true; Start-Optimize 'Custom'; [void](Read-SFInput '  Enter to go back...') }
        '^6$' { Show-SFRevertMenu -DryRun:$opts.DryRun; [void](Read-SFInput '  Enter to go back...') }
        '^7$' {
            Write-SFGameCards -Context $ctx
            $dir = New-SFRunDir '-games'
            $saved = Save-SFGameCards -Context $ctx -Path (Join-Path $dir 'game-settings.txt')
            if ($saved) { Write-Host ''; Write-Host ('  Saved: ' + $saved) -ForegroundColor DarkGray }
            [void](Read-SFInput '  Enter to go back...')
        }
        '^(?i)adv(anced)?$' { Show-Advanced }
        '^0$' { return }
        default { }
    }
}
