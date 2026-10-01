# Don't parse command output text in here: it's translated on non-English Windows.
# Stick to GUIDs, registry keywords and numbers.

$script:SFPowerGuids = @{
    Balanced         = '381b4222-f694-41f0-9685-ff5bb260df2e'
    High             = '8c5e7fda-e8bf-4a96-9a85-cf4f6e9b8dcb'
    UltimateTemplate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    SteadyFrame      = 'b1e5f7a0-5f00-4d3e-9a1e-57ead7f4a3e1'
}
$script:SFNicClassKey = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$script:SFGuidRegex = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'


function Get-SFServiceStartType {
    param([Parameter(Mandatory)][string]$Name)
    $key = 'HKLM\SYSTEM\CurrentControlSet\Services\' + $Name
    $start = Get-SFRegistryValue $key 'Start'
    if (-not $start.KeyExists -or -not $start.Exists) { return $null }
    $delayed = Get-SFRegistryValue $key 'DelayedAutostart'
    switch ([int64]$start.Value) {
        0 { return 'Boot' }
        1 { return 'System' }
        2 { if ($delayed.Exists -and [int64]$delayed.Value -eq 1) { return 'AutomaticDelayed' } return 'Automatic' }
        3 { return 'Manual' }
        4 { return 'Disabled' }
    }
    return $null
}

function Set-SFServiceStartType {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$StartType)
    $map = @{ Automatic = 'auto'; AutomaticDelayed = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled'; Boot = 'boot'; System = 'system' }
    $out = & sc.exe config $Name start= $map[$StartType] 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("sc.exe config failed ({0}): {1}" -f $LASTEXITCODE, (($out | Out-String).Trim())) }
}

function Get-SFActivePowerScheme {
    $out = (& powercfg.exe /getactivescheme 2>$null) -join ' '
    $m = [regex]::Match($out, $script:SFGuidRegex)
    if ($m.Success) { return $m.Value.ToLowerInvariant() }
    return $null
}

function Get-SFPowerSchemes {
    $out = & powercfg.exe /list 2>$null
    $list = foreach ($line in @($out)) {
        $m = [regex]::Match("$line", '(' + $script:SFGuidRegex + ')\s+\((.*)\)')
        if ($m.Success) { [pscustomobject]@{ Guid = $m.Groups[1].Value.ToLowerInvariant(); Name = $m.Groups[2].Value } }
    }
    return @($list)
}

function Get-SFPowerSettingValue {
    param([string]$Scheme, [string]$Subgroup, [string]$Setting)
    $out = & powercfg.exe /query $Scheme $Subgroup $Setting 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $vals = @()
    foreach ($line in @($out)) {
        $m = [regex]::Match("$line", ':\s*0x([0-9a-fA-F]+)\s*$')
        if ($m.Success) { $vals += [Convert]::ToInt64($m.Groups[1].Value, 16) }
    }
    if ($vals.Count -lt 2) { return $null }
    # The last two hex lines of a setting block are the current AC and DC indexes.
    return [pscustomobject]@{ AC = $vals[$vals.Count - 2]; DC = $vals[$vals.Count - 1] }
}

function Get-SFPhysicalAdapters {
    $skip = 'Virtual|Hyper-V|VPN|TAP-|WireGuard|Loopback|Bluetooth|WAN Miniport|Npcap|ZeroTier|Tailscale|Radmin|Hamachi'
    return @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -notmatch $skip })
}

# PnPCapabilities lives in the adapter's Control\Class\{net}\NNNN key, not under Services.
function Get-SFNicClassKeys {
    $guids = @(Get-SFPhysicalAdapters | ForEach-Object { "$($_.InterfaceGuid)".ToLowerInvariant() })
    $keys = @()
    $s = Split-SFRegistryPath $script:SFNicClassKey
    $base = Get-SFBaseKey $s.Hive
    try {
        $root = $base.OpenSubKey($s.SubKey, $false)
        if (-not $root) { return @() }
        foreach ($n in $root.GetSubKeyNames()) {
            if ($n -notmatch '^\d{4}$') { continue }
            try {
                $sub = $root.OpenSubKey($n, $false)
                if (-not $sub) { continue }
                $id = "$($sub.GetValue('NetCfgInstanceId', ''))".ToLowerInvariant()
                $sub.Close()
                if ($id -and $guids -contains $id) { $keys += ($script:SFNicClassKey + '\' + $n) }
            } catch { }
        }
        $root.Close()
    } finally { $base.Close() }
    return $keys
}


function Expand-SFTemplate {
    param([string]$Text, $Context)
    $results = @($Text)
    if ($Text -match '\{GameExe\}') {
        $results = @(foreach ($r in $results) { foreach ($g in @($Context.GameExes)) { $r.Replace('{GameExe}', $g) } })
    }
    if ($Text -match '\{GameExePath\}') {
        $paths = @(Get-SFProp $Context 'Games' @() | ForEach-Object { $_.Exe })
        $results = @(foreach ($r in $results) { foreach ($p in $paths) { $r.Replace('{GameExePath}', $p) } })
    }
    if ($Text -match '\{ActiveInterfaces\}') {
        $results = @(foreach ($r in $results) { foreach ($i in @($Context.ActiveInterfaces)) { $r.Replace('{ActiveInterfaces}', $i) } })
    }
    if ($Text -match '\{NicClassKeys\}') {
        $nk = @(Get-SFNicClassKeys)
        $results = @(foreach ($r in $results) { foreach ($k in $nk) { $r.Replace('{NicClassKeys}', $k) } })
    }
    $results = @(foreach ($r in $results) {
            $r.Replace('{RamKB}', "$($Context.Ram.TotalKB)").Replace('{DisplayVersion}', "$($Context.DisplayVersion)").Replace('{ProductVersion}', "$($Context.ProductVersion)")
        })
    return $results
}


function Invoke-SFRegistryChange {
    param(
        [string]$TweakId, [string]$Path, [string]$Name = '', [string]$Kind = 'DWord', $Value,
        [switch]$Delete, $Journal, [switch]$DryRun, [string]$Label = 'Registry'
    )
    $target = '{0} : {1}' -f (ConvertTo-SFRegistryKeyName $Path), $(if ($Name) { $Name } else { '(Default)' })
    $why = Test-SFRegistryWrite -Path $Path -Name $Name -Value $Value -Delete:$Delete
    if ($why) { return (New-SFResult $TweakId $Label $target 'Blocked' $why) }

    $cur = Get-SFRegistryValue $Path $Name
    $beforeText = if ($cur.Exists) { Format-SFValue $cur.Value } else { $null }
    if ($Delete) {
        if (-not $cur.Exists) { return (New-SFResult $TweakId $Label $target 'AlreadySet' 'already absent') }
        if ($DryRun) { return (New-SFResult $TweakId $Label $target 'DryRun' 'would delete' $beforeText '(deleted)') }
        Remove-SFRegistryValue $Path $Name
        if ($Journal) {
            Add-SFJournalEntry $Journal $TweakId 'Registry' ([ordered]@{ Path = (ConvertTo-SFRegistryKeyName $Path); Name = $Name }) $cur ([ordered]@{ Deleted = $true; CreatedKey = '' })
        }
        return (New-SFResult $TweakId $Label $target 'Applied' 'deleted' $beforeText '(deleted)')
    }

    $newSer = ConvertTo-SFSerializedValue (ConvertFrom-SFSerializedValue $Value $Kind) $Kind
    if ($cur.Exists -and $cur.Kind -eq $Kind -and (Test-SFSerializedEqual $cur.Value $newSer $Kind)) {
        return (New-SFResult $TweakId $Label $target 'AlreadySet' '' $beforeText (Format-SFValue $newSer))
    }
    if ($DryRun) { return (New-SFResult $TweakId $Label $target 'DryRun' '' $beforeText (Format-SFValue $newSer)) }
    $created = Set-SFRegistryValue -Path $Path -Name $Name -Kind $Kind -Value $newSer
    if ($Journal) {
        Add-SFJournalEntry $Journal $TweakId 'Registry' ([ordered]@{ Path = (ConvertTo-SFRegistryKeyName $Path); Name = $Name }) $cur ([ordered]@{ Kind = $Kind; Value = $newSer; Deleted = $false; CreatedKey = $created })
    }
    return (New-SFResult $TweakId $Label $target 'Applied' '' $beforeText (Format-SFValue $newSer))
}

function Set-SFStringToken {
    param([string]$Text, [string]$Token, [string]$Value)
    $parts = @(("$Text").Split(';') | Where-Object { $_ -ne '' })
    $found = $false
    $out = foreach ($p in $parts) {
        $kv = $p.Split('=', 2)
        if ($kv[0] -eq $Token) { $found = $true; "$Token=$Value" } else { $p }
    }
    $out = @($out)
    if (-not $found) { $out += "$Token=$Value" }
    return (($out -join ';') + ';')
}


function Invoke-SFAction {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)][string]$TweakId, [Parameter(Mandatory)]$Context, $Journal, [switch]$DryRun, [switch]$Interactive)
    $type = Get-SFProp $Action 'type'
    foreach ($req in @(Get-SFProp $Action 'requires' @())) {
        if (-not (Test-SFRequirement $req $Context)) {
            return (New-SFResult $TweakId $type '' 'Skipped' ('n/a: ' + (Get-SFRequirementText $req)) -Quiet)
        }
    }
    try {
        switch ($type) {
            'Registry' { return (Invoke-SFRegistryAction $Action $TweakId $Context $Journal -DryRun:$DryRun) }
            'RegistryToken' { return (Invoke-SFRegistryTokenAction $Action $TweakId $Context $Journal -DryRun:$DryRun) }
            'Service' { return (Invoke-SFServiceAction $Action $TweakId $Journal -DryRun:$DryRun) }
            'PowerScheme' { return (Invoke-SFPowerSchemeAction $Action $TweakId $Journal -DryRun:$DryRun) }
            'PowerSetting' { return (Invoke-SFPowerSettingAction $Action $TweakId $Journal -DryRun:$DryRun) }
            'Hibernate' { return (Invoke-SFHibernateAction $Action $TweakId $Journal -DryRun:$DryRun) }
            'Bcd' { return (Invoke-SFBcdAction $Action $TweakId $Context $Journal -DryRun:$DryRun) }
            'ScheduledTask' { return (Invoke-SFScheduledTaskAction $Action $TweakId $Journal -DryRun:$DryRun) }
            'NetAdapterProperty' { return (Invoke-SFNetAdapterPropertyAction $Action $TweakId $Journal -DryRun:$DryRun) }
            'MMAgent' { return (Invoke-SFMMAgentAction $Action $TweakId $Journal -DryRun:$DryRun) }
            'Pagefile' { return (Invoke-SFPagefileAction $Action $TweakId $Journal -DryRun:$DryRun) }
            'StartupReview' { return (Invoke-SFStartupReview -TweakId $TweakId -Journal $Journal -DryRun:$DryRun -Interactive:$Interactive) }
            'Cs2Autoexec' { return (Invoke-SFCs2AutoexecAction $Action $TweakId $Context $Journal -DryRun:$DryRun -Interactive:$Interactive) }
            default { return (New-SFResult $TweakId "$type" '' 'Failed' "unknown action type '$type'") }
        }
    } catch {
        return (New-SFResult $TweakId "$type" '' 'Failed' $_.Exception.Message)
    }
}

function Invoke-SFRegistryAction {
    param($Action, $TweakId, $Context, $Journal, [switch]$DryRun)
    $paths = @(Expand-SFTemplate (Get-SFProp $Action 'path') $Context)
    if ($paths.Count -eq 0) { return (New-SFResult $TweakId 'Registry' (Get-SFProp $Action 'path') 'Skipped' 'nothing to apply on this PC' -Quiet) }
    $kind = Get-SFProp $Action 'kind' 'DWord'
    $value = Get-SFProp $Action 'value'
    if ($value -is [string]) { $value = @(Expand-SFTemplate $value $Context)[0] }
    $results = foreach ($p in $paths) {
        Invoke-SFRegistryChange -TweakId $TweakId -Path $p -Name (Get-SFProp $Action 'name' '') -Kind $kind -Value $value `
            -Delete:([bool](Get-SFProp $Action 'delete' $false)) -Journal $Journal -DryRun:$DryRun
    }
    return @($results)
}

function Invoke-SFRegistryTokenAction {
    param($Action, $TweakId, $Context, $Journal, [switch]$DryRun)
    $path = Get-SFProp $Action 'path'
    # name can be a template too: the per-game GPU preference is keyed by exe path
    $names = @(Expand-SFTemplate (Get-SFProp $Action 'name') $Context)
    if ($names.Count -eq 0) { return (New-SFResult $TweakId 'RegistryToken' $path 'Skipped' 'nothing to apply on this PC' -Quiet) }
    $results = foreach ($name in $names) {
        $cur = Get-SFRegistryValue $path $name
        $text = if ($cur.Exists) { "$($cur.Value)" } else { '' }
        $new = Set-SFStringToken $text (Get-SFProp $Action 'token') ("$(Get-SFProp $Action 'value')")
        Invoke-SFRegistryChange -TweakId $TweakId -Path $path -Name $name -Kind 'String' -Value $new -Journal $Journal -DryRun:$DryRun -Label 'RegistryToken'
    }
    return @($results)
}

function Invoke-SFServiceAction {
    param($Action, $TweakId, $Journal, [switch]$DryRun)
    $name = Get-SFProp $Action 'name'
    $want = Get-SFProp $Action 'startType'
    $why = Test-SFServiceWrite -Name $name -StartType $want
    if ($why) { return (New-SFResult $TweakId 'Service' $name 'Blocked' $why) }
    $cur = Get-SFServiceStartType $name
    if ($null -eq $cur) { return (New-SFResult $TweakId 'Service' $name 'Skipped' 'service not present on this PC') }
    if ($cur -eq $want) { return (New-SFResult $TweakId 'Service' $name 'AlreadySet' '' $cur $want) }
    if ($DryRun) { return (New-SFResult $TweakId 'Service' $name 'DryRun' '' $cur $want) }
    Set-SFServiceStartType $name $want
    if ($Journal) { Add-SFJournalEntry $Journal $TweakId 'Service' ([ordered]@{ Name = $name }) ([ordered]@{ StartType = $cur }) ([ordered]@{ StartType = $want }) }
    return (New-SFResult $TweakId 'Service' $name 'Applied' 'takes effect after reboot' $cur $want)
}

function Invoke-SFPowerSchemeAction {
    param($Action, $TweakId, $Journal, [switch]$DryRun)
    $wantName = Get-SFProp $Action 'scheme'
    $active = Get-SFActivePowerScheme
    $schemes = @(Get-SFPowerSchemes | ForEach-Object { $_.Guid })
    $created = $false
    $target = $null
    if ($wantName -eq 'Balanced') { $target = $script:SFPowerGuids.Balanced }
    elseif ($wantName -eq 'High') { $target = $script:SFPowerGuids.High }
    elseif ($wantName -eq 'Ultimate') {
        $target = $script:SFPowerGuids.SteadyFrame
        if ($schemes -notcontains $target) {
            if ($DryRun) { return (New-SFResult $TweakId 'PowerScheme' 'Ultimate Performance' 'DryRun' 'would create and activate' $active $target) }
            & powercfg.exe /duplicatescheme $script:SFPowerGuids.UltimateTemplate $target 2>&1 | Out-Null
            $schemes = @(Get-SFPowerSchemes | ForEach-Object { $_.Guid })
            if ($schemes -contains $target) {
                $created = $true
                & powercfg.exe /changename $target 'SteadyFrame Ultimate Performance' 'Ultimate Performance plan created by SteadyFrame' 2>&1 | Out-Null
            } else {
                $target = $script:SFPowerGuids.High
            }
        }
    }
    if ($schemes -notcontains $target) { return (New-SFResult $TweakId 'PowerScheme' $wantName 'Skipped' 'plan not available on this PC (Modern Standby systems only offer Balanced)') }
    if ($active -eq $target) { return (New-SFResult $TweakId 'PowerScheme' $wantName 'AlreadySet' '' $active $target) }
    if ($DryRun) { return (New-SFResult $TweakId 'PowerScheme' $wantName 'DryRun' '' $active $target) }
    & powercfg.exe /setactive $target 2>&1 | Out-Null
    if ((Get-SFActivePowerScheme) -ne $target) { throw "powercfg could not activate $target" }
    if ($Journal) { Add-SFJournalEntry $Journal $TweakId 'PowerScheme' ([ordered]@{ Scheme = $wantName }) ([ordered]@{ Scheme = $active }) ([ordered]@{ Scheme = $target; Created = $created }) }
    return (New-SFResult $TweakId 'PowerScheme' $wantName 'Applied' '' $active $target)
}

function Invoke-SFPowerSettingAction {
    param($Action, $TweakId, $Journal, [switch]$DryRun)
    $scheme = Get-SFActivePowerScheme
    $sub = Get-SFProp $Action 'subgroup'
    $set = Get-SFProp $Action 'setting'
    $label = Get-SFProp $Action 'label' $set
    $ac = [int64](Get-SFProp $Action 'ac')
    $dc = [int64](Get-SFProp $Action 'dc' $ac)
    $cur = Get-SFPowerSettingValue $scheme $sub $set
    if ($null -eq $cur) { return (New-SFResult $TweakId 'PowerSetting' $label 'Skipped' 'setting not available on this PC') }
    $beforeText = 'AC={0} DC={1}' -f $cur.AC, $cur.DC
    $afterText = 'AC={0} DC={1}' -f $ac, $dc
    if ($cur.AC -eq $ac -and $cur.DC -eq $dc) { return (New-SFResult $TweakId 'PowerSetting' $label 'AlreadySet' '' $beforeText $afterText) }
    if ($DryRun) { return (New-SFResult $TweakId 'PowerSetting' $label 'DryRun' '' $beforeText $afterText) }
    & powercfg.exe /setacvalueindex $scheme $sub $set $ac 2>&1 | Out-Null
    & powercfg.exe /setdcvalueindex $scheme $sub $set $dc 2>&1 | Out-Null
    & powercfg.exe /setactive $scheme 2>&1 | Out-Null
    if ($Journal) {
        Add-SFJournalEntry $Journal $TweakId 'PowerSetting' ([ordered]@{ Scheme = $scheme; Subgroup = $sub; Setting = $set; Label = $label }) ([ordered]@{ AC = $cur.AC; DC = $cur.DC }) ([ordered]@{ AC = $ac; DC = $dc })
    }
    return (New-SFResult $TweakId 'PowerSetting' $label 'Applied' '' $beforeText $afterText)
}

function Get-SFHibernateEnabled {
    $v = Get-SFRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    if ($v.Exists) { return ([int64]$v.Value -ne 0) }
    return $true
}

function Invoke-SFHibernateAction {
    param($Action, $TweakId, $Journal, [switch]$DryRun)
    $want = [bool](Get-SFProp $Action 'enabled')
    $cur = Get-SFHibernateEnabled
    if ($cur -eq $want) { return (New-SFResult $TweakId 'Hibernate' 'hibernation / Fast Startup' 'AlreadySet' '' $cur $want) }
    if ($DryRun) { return (New-SFResult $TweakId 'Hibernate' 'hibernation / Fast Startup' 'DryRun' '' $cur $want) }
    $arg = if ($want) { 'on' } else { 'off' }
    & powercfg.exe /hibernate $arg 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg /hibernate $arg failed" }
    if ($Journal) { Add-SFJournalEntry $Journal $TweakId 'Hibernate' ([ordered]@{ Item = 'Hibernate' }) ([ordered]@{ Enabled = $cur }) ([ordered]@{ Enabled = $want }) }
    return (New-SFResult $TweakId 'Hibernate' 'hibernation / Fast Startup' 'Applied' '' $cur $want)
}

function Invoke-SFBcdAction {
    param($Action, $TweakId, $Context, $Journal, [switch]$DryRun)
    $setting = Get-SFProp $Action 'setting'
    $delete = [bool](Get-SFProp $Action 'delete' $false)
    $value = "$(Get-SFProp $Action 'value' '')"
    $why = Test-SFBcdWrite -Setting $setting -Value $value -Delete:$delete
    if ($why) { return (New-SFResult $TweakId 'Bcd' $setting 'Blocked' $why) }
    if ($Context.BitLockerOn -ne $false) {
        return (New-SFResult $TweakId 'Bcd' $setting 'Skipped' 'BitLocker is on (or unknown): boot-setting changes can trigger BitLocker recovery. Suspend BitLocker first.')
    }
    $raw = Get-SFBcdValue $setting
    if ($null -eq $raw) { return (New-SFResult $TweakId 'Bcd' $setting 'Skipped' 'could not read boot configuration (run as admin)') }
    $cur = if ($raw -eq '') { '' } else { ConvertTo-SFBcdBool $raw }
    $curText = if ($cur -eq '') { '(not set)' } else { $cur }
    if ($delete -and $cur -eq '') { return (New-SFResult $TweakId 'Bcd' $setting 'AlreadySet' 'already absent') }
    if (-not $delete -and $cur -eq $value) { return (New-SFResult $TweakId 'Bcd' $setting 'AlreadySet' '' $curText $value) }
    $afterText = if ($delete) { '(deleted)' } else { $value }
    if ($DryRun) { return (New-SFResult $TweakId 'Bcd' $setting 'DryRun' '' $curText $afterText) }
    if ($delete) { & bcdedit.exe /deletevalue '{current}' $setting 2>&1 | Out-Null }
    else { & bcdedit.exe /set '{current}' $setting $value 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "bcdedit failed for $setting" }
    if ($Journal) { Add-SFJournalEntry $Journal $TweakId 'Bcd' ([ordered]@{ Setting = $setting }) ([ordered]@{ Value = $cur }) ([ordered]@{ Value = $(if ($delete) { '' } else { $value }) }) }
    return (New-SFResult $TweakId 'Bcd' $setting 'Applied' 'takes effect after reboot' $curText $afterText)
}

function Invoke-SFScheduledTaskAction {
    param($Action, $TweakId, $Journal, [switch]$DryRun)
    $path = Get-SFProp $Action 'path'
    $name = Get-SFProp $Action 'name'
    $want = [bool](Get-SFProp $Action 'enabled')
    $label = $path + $name
    $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
    if (-not $task) { return (New-SFResult $TweakId 'ScheduledTask' $label 'Skipped' 'task not present on this build' -Quiet) }
    $cur = ("$($task.State)" -ne 'Disabled')
    if ($cur -eq $want) { return (New-SFResult $TweakId 'ScheduledTask' $label 'AlreadySet' '' $cur $want) }
    if ($DryRun) { return (New-SFResult $TweakId 'ScheduledTask' $label 'DryRun' '' $cur $want) }
    if ($want) { Enable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null }
    if ($Journal) { Add-SFJournalEntry $Journal $TweakId 'ScheduledTask' ([ordered]@{ Path = $path; Name = $name }) ([ordered]@{ Enabled = $cur }) ([ordered]@{ Enabled = $want }) }
    return (New-SFResult $TweakId 'ScheduledTask' $label 'Applied' '' $cur $want)
}

function Invoke-SFNetAdapterPropertyAction {
    param($Action, $TweakId, $Journal, [switch]$DryRun)
    $kw = Get-SFProp $Action 'keyword'
    $want = "$(Get-SFProp $Action 'value')"
    $results = @()
    foreach ($a in (Get-SFPhysicalAdapters)) {
        $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $cur = "$(@($p.RegistryValue)[0])"
        $label = '{0} : {1}' -f $a.InterfaceDescription, $kw
        if ($cur -eq $want) { $results += (New-SFResult $TweakId 'NetAdapter' $label 'AlreadySet' '' $cur $want); continue }
        if ($DryRun) { $results += (New-SFResult $TweakId 'NetAdapter' $label 'DryRun' '' $cur $want); continue }
        Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -RegistryValue $want -NoRestart -ErrorAction Stop
        if ($Journal) { Add-SFJournalEntry $Journal $TweakId 'NetAdapterProperty' ([ordered]@{ InterfaceDescription = $a.InterfaceDescription; Keyword = $kw }) ([ordered]@{ Value = $cur }) ([ordered]@{ Value = $want }) }
        $results += (New-SFResult $TweakId 'NetAdapter' $label 'Applied' 'applies after adapter restart / reboot' $cur $want)
    }
    if ($results.Count -eq 0) { return (New-SFResult $TweakId 'NetAdapter' $kw 'Skipped' 'no adapter exposes this setting' -Quiet) }
    return $results
}

function Invoke-SFMMAgentAction {
    param($Action, $TweakId, $Journal, [switch]$DryRun)
    $want = [bool](Get-SFProp $Action 'memoryCompression')
    $cur = [bool](Get-MMAgent -ErrorAction Stop).MemoryCompression
    if ($cur -eq $want) { return (New-SFResult $TweakId 'MMAgent' 'memory compression' 'AlreadySet' '' $cur $want) }
    if ($DryRun) { return (New-SFResult $TweakId 'MMAgent' 'memory compression' 'DryRun' '' $cur $want) }
    if ($want) { Enable-MMAgent -MemoryCompression -ErrorAction Stop } else { Disable-MMAgent -MemoryCompression -ErrorAction Stop }
    if ($Journal) { Add-SFJournalEntry $Journal $TweakId 'MMAgent' ([ordered]@{ Feature = 'MemoryCompression' }) ([ordered]@{ Enabled = $cur }) ([ordered]@{ Enabled = $want }) }
    return (New-SFResult $TweakId 'MMAgent' 'memory compression' 'Applied' 'takes effect after reboot' $cur $want)
}

function Invoke-SFPagefileAction {
    param($Action, $TweakId, $Journal, [switch]$DryRun)
    $want = [bool](Get-SFProp $Action 'automatic')
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $cur = [bool]$cs.AutomaticManagedPagefile
    if ($cur -eq $want) { return (New-SFResult $TweakId 'Pagefile' 'system-managed page file' 'AlreadySet' '' $cur $want) }
    if ($DryRun) { return (New-SFResult $TweakId 'Pagefile' 'system-managed page file' 'DryRun' '' $cur $want) }
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $want } -ErrorAction Stop
    if ($Journal) { Add-SFJournalEntry $Journal $TweakId 'Pagefile' ([ordered]@{ Item = 'AutomaticManagedPagefile' }) ([ordered]@{ Automatic = $cur }) ([ordered]@{ Automatic = $want }) }
    return (New-SFResult $TweakId 'Pagefile' 'system-managed page file' 'Applied' 'takes effect after reboot' $cur $want)
}


function Undo-SFJournalEntry {
    param([Parameter(Mandatory)]$Entry, [switch]$DryRun)
    $type = Get-SFProp $Entry 'Type'
    $id = Get-SFProp $Entry 'TweakId'
    $t = Get-SFProp $Entry 'Target'
    $b = Get-SFProp $Entry 'Before'
    $a = Get-SFProp $Entry 'After'
    try {
        switch ($type) {
            'Registry' {
                $path = Get-SFProp $t 'Path'
                $name = Get-SFProp $t 'Name' ''
                $label = '{0} : {1}' -f $path, $name
                if ([bool](Get-SFProp $b 'Exists' $false)) {
                    $why = Test-SFRegistryWrite -Path $path -Name $name -Value (Get-SFProp $b 'Value')
                    if ($why) { return (New-SFResult $id 'Registry' $label 'Blocked' "kept the safer value ($why)") }
                    if ($DryRun) { return (New-SFResult $id 'Registry' $label 'DryRun' 'would restore' $null (Format-SFValue (Get-SFProp $b 'Value'))) }
                    Set-SFRegistryValue -Path $path -Name $name -Kind (Get-SFProp $b 'Kind') -Value (Get-SFProp $b 'Value') | Out-Null
                } else {
                    if ($DryRun) { return (New-SFResult $id 'Registry' $label 'DryRun' 'would remove (was not set before)') }
                    Remove-SFRegistryValue $path $name
                }
                $createdKey = Get-SFProp $a 'CreatedKey' ''
                if ($createdKey) { Remove-SFEmptyRegistryKeys -Path $path -StopAt $createdKey }
                return (New-SFResult $id 'Registry' $label 'Applied' 'restored')
            }
            'Service' {
                $name = Get-SFProp $t 'Name'
                $st = Get-SFProp $b 'StartType'
                $why = Test-SFServiceWrite -Name $name -StartType $st
                if ($why) { return (New-SFResult $id 'Service' $name 'Blocked' "kept the safer value ($why)") }
                if ($DryRun) { return (New-SFResult $id 'Service' $name 'DryRun' "would set $st") }
                Set-SFServiceStartType $name $st
                return (New-SFResult $id 'Service' $name 'Applied' "restored $st")
            }
            'PowerScheme' {
                $prev = Get-SFProp $b 'Scheme'
                if ($DryRun) { return (New-SFResult $id 'PowerScheme' $prev 'DryRun' 'would reactivate previous plan') }
                if ($prev) { & powercfg.exe /setactive $prev 2>&1 | Out-Null }
                if ([bool](Get-SFProp $a 'Created' $false)) { & powercfg.exe /delete (Get-SFProp $a 'Scheme') 2>&1 | Out-Null }
                return (New-SFResult $id 'PowerScheme' $prev 'Applied' 'previous plan reactivated')
            }
            'PowerSetting' {
                $scheme = Get-SFProp $t 'Scheme'
                $label = Get-SFProp $t 'Label'
                if ($DryRun) { return (New-SFResult $id 'PowerSetting' $label 'DryRun' 'would restore') }
                & powercfg.exe /setacvalueindex $scheme (Get-SFProp $t 'Subgroup') (Get-SFProp $t 'Setting') ([int64](Get-SFProp $b 'AC')) 2>&1 | Out-Null
                & powercfg.exe /setdcvalueindex $scheme (Get-SFProp $t 'Subgroup') (Get-SFProp $t 'Setting') ([int64](Get-SFProp $b 'DC')) 2>&1 | Out-Null
                if ((Get-SFActivePowerScheme) -eq $scheme) { & powercfg.exe /setactive $scheme 2>&1 | Out-Null }
                return (New-SFResult $id 'PowerSetting' $label 'Applied' 'restored')
            }
            'Hibernate' {
                $en = [bool](Get-SFProp $b 'Enabled')
                if ($DryRun) { return (New-SFResult $id 'Hibernate' 'hibernation' 'DryRun' "would set $en") }
                & powercfg.exe /hibernate $(if ($en) { 'on' } else { 'off' }) 2>&1 | Out-Null
                return (New-SFResult $id 'Hibernate' 'hibernation' 'Applied' 'restored')
            }
            'Bcd' {
                $setting = Get-SFProp $t 'Setting'
                $prev = "$(Get-SFProp $b 'Value' '')"
                $why = if ($prev -eq '') { Test-SFBcdWrite -Setting $setting -Delete } else { Test-SFBcdWrite -Setting $setting -Value $prev }
                if ($why) { return (New-SFResult $id 'Bcd' $setting 'Blocked' "kept the safer value ($why)") }
                if ($DryRun) { return (New-SFResult $id 'Bcd' $setting 'DryRun' 'would restore') }
                if ($prev -eq '') { & bcdedit.exe /deletevalue '{current}' $setting 2>&1 | Out-Null }
                else { & bcdedit.exe /set '{current}' $setting $prev 2>&1 | Out-Null }
                return (New-SFResult $id 'Bcd' $setting 'Applied' 'restored')
            }
            'ScheduledTask' {
                $label = (Get-SFProp $t 'Path') + (Get-SFProp $t 'Name')
                if ($DryRun) { return (New-SFResult $id 'ScheduledTask' $label 'DryRun' 'would restore') }
                if ([bool](Get-SFProp $b 'Enabled')) { Enable-ScheduledTask -TaskPath (Get-SFProp $t 'Path') -TaskName (Get-SFProp $t 'Name') -ErrorAction Stop | Out-Null }
                else { Disable-ScheduledTask -TaskPath (Get-SFProp $t 'Path') -TaskName (Get-SFProp $t 'Name') -ErrorAction Stop | Out-Null }
                return (New-SFResult $id 'ScheduledTask' $label 'Applied' 'restored')
            }
            'NetAdapterProperty' {
                $desc = Get-SFProp $t 'InterfaceDescription'
                $kw = Get-SFProp $t 'Keyword'
                $label = '{0} : {1}' -f $desc, $kw
                $ad = Get-NetAdapter -InterfaceDescription $desc -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $ad) { return (New-SFResult $id 'NetAdapter' $label 'Skipped' 'adapter no longer present') }
                if ($DryRun) { return (New-SFResult $id 'NetAdapter' $label 'DryRun' 'would restore') }
                Set-NetAdapterAdvancedProperty -Name $ad.Name -RegistryKeyword $kw -RegistryValue ("$(Get-SFProp $b 'Value')") -NoRestart -ErrorAction Stop
                return (New-SFResult $id 'NetAdapter' $label 'Applied' 'restored')
            }
            'MMAgent' {
                if ($DryRun) { return (New-SFResult $id 'MMAgent' 'memory compression' 'DryRun' 'would restore') }
                if ([bool](Get-SFProp $b 'Enabled')) { Enable-MMAgent -MemoryCompression -ErrorAction Stop } else { Disable-MMAgent -MemoryCompression -ErrorAction Stop }
                return (New-SFResult $id 'MMAgent' 'memory compression' 'Applied' 'restored')
            }
            'File' { return (Undo-SFFileEntry -Entry $Entry -DryRun:$DryRun) }
            'Pagefile' {
                if ($DryRun) { return (New-SFResult $id 'Pagefile' 'page file' 'DryRun' 'would restore') }
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = [bool](Get-SFProp $b 'Automatic') } -ErrorAction Stop
                return (New-SFResult $id 'Pagefile' 'page file' 'Applied' 'restored')
            }
            default { return (New-SFResult $id "$type" '' 'Failed' "cannot revert unknown entry type '$type'") }
        }
    } catch {
        return (New-SFResult $id "$type" '' 'Failed' $_.Exception.Message)
    }
}
