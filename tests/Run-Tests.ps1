<#
.SYNOPSIS
    Self-contained tests (no Pester needed, runs on stock Windows PowerShell 5.1).
    Only writes under HKCU:\Software\SteadyFrame-Test and %TEMP%; no admin required.
    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\SteadyFrame.psm1') -Force -DisableNameChecking

$script:Pass = 0
$script:Fail = 0
function It {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:Fail++; Write-Host "  FAIL  $Name :: $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal { param($Expected, $Actual, [string]$Msg = '') if ("$Expected" -cne "$Actual") { throw "expected '$Expected' but got '$Actual' $Msg" } }
function Assert-True { param($Cond, [string]$Msg = '') if (-not $Cond) { throw "assertion failed: $Msg" } }
function Assert-Null { param($Value, [string]$Msg = '') if ($null -ne $Value) { throw "expected null but got '$Value' $Msg" } }
function Assert-NotNull { param($Value, [string]$Msg = '') if ($null -eq $Value) { throw "expected a value $Msg" } }

$T = 'HKCU\Software\SteadyFrame-Test'
function Reset-Sandbox { Remove-Item -Path 'HKCU:\Software\SteadyFrame-Test' -Recurse -Force -ErrorAction SilentlyContinue }
function New-TempJournal { New-SFJournal -Root (Join-Path $env:TEMP ('sf-test-' + [guid]::NewGuid().ToString('N'))) }

function New-FakeContext {
    param([hashtable]$Over = @{})
    $c = [ordered]@{
        Computer = 'TEST'; IsAdmin = $true; OsMajor = 11; Build = 26100; UBR = 1; DisplayVersion = '24H2'; ProductVersion = 'Windows 11'
        Edition = 'Professional'; IsHome = $false; FormFactor = 'Desktop'; CpuName = 'AMD Ryzen 7 9800X3D'; CpuCores = 8; CpuThreads = 16
        IsAmd = $true; IsIntel = $false; IsDualCcdX3D = $false; IsX3D = $true; IsIntelRaptor = $false; Microcode = $null
        Gpus = @('NVIDIA GeForce RTX 5070 Ti'); HasNvidia = $true
        Ram = [pscustomobject]@{ TotalGB = 32; TotalKB = 33554432; Sticks = 2; Type = 'DDR5'; SpeedMTs = 6000; MixedSizes = $false }
        Disk = [pscustomobject]@{ SystemDisk = 'NVMe SSD'; SsdOnly = $true; FreeGB = 500; SizeGB = 1000 }
        HasPrinter = $false; BitLockerOn = $false; ActiveInterfaces = @('{11111111-2222-3333-4444-555555555555}')
        GameExes = @(); Games = @(); NoGamePass = $false
        Leftovers = [pscustomobject]@{ UsePlatformClock = $false; PagefileDisabled = $false; SpectreMitigationsDisabled = $false; LargeSystemCache = $false; WuauservDisabled = $false; BitsDisabled = $false; UpdateServicesDisabled = $false; PrioritySeparationOdd = $false; DefenderDisabledByPolicy = $false }
        SuggestedPreset = 'HighEnd'
    }
    foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }
    return [pscustomobject]$c
}

Write-Host 'Registry layer' -ForegroundColor Cyan
Reset-Sandbox

It 'normalizes every registry path form' {
    Assert-Equal 'HKLM\SOFTWARE\X' (ConvertTo-SFRegistryKeyName 'HKLM:\SOFTWARE\X')
    Assert-Equal 'HKLM\SOFTWARE\X' (ConvertTo-SFRegistryKeyName 'HKEY_LOCAL_MACHINE\SOFTWARE\X')
    Assert-Equal 'HKLM\SOFTWARE\X' (ConvertTo-SFRegistryKeyName 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\X')
    Assert-Equal 'HKCU\Software\Y' (ConvertTo-SFRegistryKeyName 'hkcu:\Software\Y\')
}

It 'round-trips DWord 0xFFFFFFFF, QWord, Binary, MultiString, ExpandString' {
    Set-SFRegistryValue "$T\Types" 'D' 'DWord' 4294967295 | Out-Null
    Assert-Equal 4294967295 (Get-SFRegistryValue "$T\Types" 'D').Value
    Set-SFRegistryValue "$T\Types" 'Q' 'QWord' '9007199254740993' | Out-Null
    Assert-Equal '9007199254740993' (Get-SFRegistryValue "$T\Types" 'Q').Value
    Set-SFRegistryValue "$T\Types" 'B' 'Binary' '9012038010000000' | Out-Null
    Assert-Equal '9012038010000000' (Get-SFRegistryValue "$T\Types" 'B').Value
    Set-SFRegistryValue "$T\Types" 'M1' 'MultiString' @('only') | Out-Null
    Assert-Equal 'only' (@((Get-SFRegistryValue "$T\Types" 'M1').Value) -join '|')
    Set-SFRegistryValue "$T\Types" 'M2' 'MultiString' @('a', 'b') | Out-Null
    Assert-Equal 'a|b' (@((Get-SFRegistryValue "$T\Types" 'M2').Value) -join '|')
    Set-SFRegistryValue "$T\Types" 'E' 'ExpandString' '%SystemRoot%\x' | Out-Null
    $e = Get-SFRegistryValue "$T\Types" 'E'
    Assert-Equal '%SystemRoot%\x' $e.Value 'ExpandString must not be expanded'
    Assert-Equal 'ExpandString' $e.Kind
}

It 'apply on a new key journals it, revert removes value AND the created key' {
    Reset-Sandbox
    $j = New-TempJournal
    $r = Invoke-SFRegistryChange -TweakId 't1' -Path "$T\New\Deep" -Name 'V' -Kind 'DWord' -Value 7 -Journal $j
    Assert-Equal 'Applied' $r.Status
    Assert-Equal 7 (Get-SFRegistryValue "$T\New\Deep" 'V').Value
    Assert-Equal 1 $j.Entries.Count
    Assert-Equal 'HKCU\Software\SteadyFrame-Test' $j.Entries[0].After.CreatedKey 'top-most created key'
    $u = Undo-SFJournalEntry -Entry $j.Entries[0]
    Assert-Equal 'Applied' $u.Status
    Assert-True (-not (Test-SFRegistryKey "$T")) 'sandbox key should be gone again'
}

It 'overwrite then revert restores the exact previous value and type' {
    Reset-Sandbox
    Set-SFRegistryValue "$T" 'S' 'String' 'old' | Out-Null
    $j = New-TempJournal
    $r = Invoke-SFRegistryChange -TweakId 't2' -Path $T -Name 'S' -Kind 'DWord' -Value 1 -Journal $j
    Assert-Equal 'Applied' $r.Status
    Assert-Equal 'DWord' (Get-SFRegistryValue $T 'S').Kind
    [void](Undo-SFJournalEntry -Entry $j.Entries[0])
    $v = Get-SFRegistryValue $T 'S'
    Assert-Equal 'String' $v.Kind
    Assert-Equal 'old' $v.Value
}

It 'reports AlreadySet and writes no journal entry when nothing changes' {
    Reset-Sandbox
    Set-SFRegistryValue $T 'Same' 'DWord' 5 | Out-Null
    $j = New-TempJournal
    $r = Invoke-SFRegistryChange -TweakId 't3' -Path $T -Name 'Same' -Kind 'DWord' -Value 5 -Journal $j
    Assert-Equal 'AlreadySet' $r.Status
    Assert-Equal 0 $j.Entries.Count
}

It 'dry run writes nothing' {
    Reset-Sandbox
    $j = New-TempJournal
    $r = Invoke-SFRegistryChange -TweakId 't4' -Path "$T\Dry" -Name 'X' -Kind 'DWord' -Value 1 -Journal $j -DryRun
    Assert-Equal 'DryRun' $r.Status
    Assert-True (-not (Test-SFRegistryKey "$T\Dry")) 'key must not exist'
    Assert-Equal 0 $j.Entries.Count
}

It 'delete action is journaled and revert brings the value back' {
    Reset-Sandbox
    Set-SFRegistryValue $T 'Gone' 'DWord' 3 | Out-Null
    $j = New-TempJournal
    $r = Invoke-SFRegistryChange -TweakId 't5' -Path $T -Name 'Gone' -Delete -Journal $j
    Assert-Equal 'Applied' $r.Status
    Assert-True (-not (Get-SFRegistryValue $T 'Gone').Exists) 'deleted'
    [void](Undo-SFJournalEntry -Entry $j.Entries[0])
    Assert-Equal 3 (Get-SFRegistryValue $T 'Gone').Value
}

It 'RegistryToken changes one token and keeps the others (Auto HDR stays)' {
    Reset-Sandbox
    Set-SFRegistryValue $T 'DX' 'String' 'AutoHDREnable=1;VRROptimizeEnable=0;' | Out-Null
    $j = New-TempJournal
    $a = [pscustomobject]@{ type = 'RegistryToken'; path = $T; name = 'DX'; token = 'SwapEffectUpgradeEnable'; value = '1' }
    $r = Invoke-SFAction -Action $a -TweakId 't6' -Context (New-FakeContext) -Journal $j
    Assert-Equal 'Applied' $r.Status
    Assert-Equal 'AutoHDREnable=1;VRROptimizeEnable=0;SwapEffectUpgradeEnable=1;' (Get-SFRegistryValue $T 'DX').Value
    $r2 = Invoke-SFAction -Action $a -TweakId 't6' -Context (New-FakeContext) -Journal $j
    Assert-Equal 'AlreadySet' $r2.Status
    [void](Undo-SFJournalEntry -Entry $j.Entries[0])
    Assert-Equal 'AutoHDREnable=1;VRROptimizeEnable=0;' (Get-SFRegistryValue $T 'DX').Value
}

It 'Set-SFStringToken replaces an existing token in place' {
    Assert-Equal 'A=1;B=2;' (Set-SFStringToken 'A=1;B=0;' 'B' '2')
    Assert-Equal 'B=2;' (Set-SFStringToken '' 'B' '2')
}

It 'template expansion: game exes, interfaces and RAM size' {
    $ctx = New-FakeContext @{ GameExes = @('cs2.exe', 'r5apex.exe') }
    $p = @(Expand-SFTemplate 'HKLM\X\{GameExe}\PerfOptions' $ctx)
    Assert-Equal 2 $p.Count
    Assert-Equal 'HKLM\X\r5apex.exe\PerfOptions' $p[1]
    Assert-Equal '33554432' (@(Expand-SFTemplate '{RamKB}' $ctx)[0])
    Assert-Equal 0 @(Expand-SFTemplate 'HKLM\X\{GameExe}' (New-FakeContext)).Count 'no games = no targets'
}

It 'journal survives a JSON round trip with all value types' {
    Reset-Sandbox
    Set-SFRegistryValue $T 'B' 'Binary' '0300000000000000' | Out-Null
    Set-SFRegistryValue $T 'M' 'MultiString' @('x', 'y') | Out-Null
    $j = New-TempJournal
    [void](Invoke-SFRegistryChange -TweakId 'rt' -Path $T -Name 'B' -Kind 'Binary' -Value '0200000000000000' -Journal $j)
    [void](Invoke-SFRegistryChange -TweakId 'rt' -Path $T -Name 'M' -Kind 'MultiString' -Value @('z') -Journal $j)
    $back = Read-SFJournal $j.Path
    Assert-Equal 2 $back.Entries.Count
    foreach ($e in ($back.Entries | Sort-Object { [int]$_.Seq } -Descending)) { [void](Undo-SFJournalEntry -Entry $e) }
    Assert-Equal '0300000000000000' (Get-SFRegistryValue $T 'B').Value
    Assert-Equal 'x|y' (@((Get-SFRegistryValue $T 'M').Value) -join '|')
}

Write-Host 'Guard' -ForegroundColor Cyan

It 'blocks Defender, VBS/HVCI, LSA, firewall and UAC keys in any path form' {
    Assert-NotNull (Test-SFRegistryWrite 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'X' 1)
    Assert-NotNull (Test-SFRegistryWrite 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0)
    Assert-NotNull (Test-SFRegistryWrite 'hklm:\system\currentcontrolset\control\lsa' 'RunAsPPL' 0)
    Assert-NotNull (Test-SFRegistryWrite 'HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' 'EnableFirewall' 0)
    Assert-NotNull (Test-SFRegistryWrite 'HKLM\SOFTWARE\Something\Else' 'EnableLUA' 0) 'EnableLUA anywhere'
    Assert-NotNull (Test-SFRegistryWrite 'HKLM\SYSTEM\CurrentControlSet\Services\WinDefend' 'Start' 4) 'service keys'
}

It 'Spectre override: delete allowed, set blocked; LargeSystemCache only 0' {
    $mm = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    Assert-NotNull (Test-SFRegistryWrite $mm 'FeatureSettingsOverride' 3)
    Assert-Null (Test-SFRegistryWrite $mm 'FeatureSettingsOverride' -Delete)
    Assert-NotNull (Test-SFRegistryWrite $mm 'LargeSystemCache' 1)
    Assert-Null (Test-SFRegistryWrite $mm 'LargeSystemCache' 0)
}

It 'IFEO: PerfOptions CpuPriorityClass allowed, Debugger hijack blocked' {
    $ifeo = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    Assert-Null (Test-SFRegistryWrite "$ifeo\cs2.exe\PerfOptions" 'CpuPriorityClass' 3)
    Assert-NotNull (Test-SFRegistryWrite "$ifeo\cs2.exe" 'Debugger' 'evil.exe')
    Assert-NotNull (Test-SFRegistryWrite "$ifeo\cs2.exe\Other" 'CpuPriorityClass' 3)
}

It 'Windows Update cannot be disabled or redirected' {
    $wu = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    Assert-NotNull (Test-SFRegistryWrite "$wu\AU" 'NoAutoUpdate' 1)
    Assert-NotNull (Test-SFRegistryWrite $wu 'WUServer' 'http://127.0.0.1')
    Assert-Null (Test-SFRegistryWrite $wu 'DeferFeatureUpdates' 1)
}

It 'services: security/anti-cheat untouchable, core never disabled' {
    Assert-NotNull (Test-SFServiceWrite 'WinDefend' 'Manual')
    Assert-NotNull (Test-SFServiceWrite 'vgc' 'Manual') 'Vanguard'
    Assert-NotNull (Test-SFServiceWrite 'EasyAntiCheat_EOS' 'Disabled')
    Assert-NotNull (Test-SFServiceWrite 'wuauserv' 'Disabled')
    Assert-Null (Test-SFServiceWrite 'wuauserv' 'Manual')
    Assert-Null (Test-SFServiceWrite 'DiagTrack' 'Disabled')
}

It 'bcdedit is allow-listed' {
    Assert-NotNull (Test-SFBcdWrite 'hypervisorlaunchtype' 'off')
    Assert-NotNull (Test-SFBcdWrite 'nx' 'AlwaysOff')
    Assert-NotNull (Test-SFBcdWrite 'useplatformclock' 'yes')
    Assert-Null (Test-SFBcdWrite 'useplatformclock' -Delete)
    Assert-Null (Test-SFBcdWrite 'disabledynamictick' 'yes')
}

It 'external tool options are filtered' {
    Assert-NotNull (Test-SFExternalOption 'winutil' 'WPFTweaksDisableBitLocker')
    Assert-NotNull (Test-SFExternalOption 'winutil' 'WPFInstallsteam') 'only tweaks/toggles'
    Assert-Null (Test-SFExternalOption 'winutil' 'WPFTweaksTelemetry') 'telemetry allowed (protection untouched)'
    Assert-NotNull (Test-SFExternalOption 'win11debloat' 'DisableBitlockerAutoEncryption')
    Assert-NotNull (Test-SFExternalOption 'win11debloat' 'Sysprep')
    Assert-Null (Test-SFExternalOption 'win11debloat' 'RemoveApps')
}

It 'engine refuses a blocked write and leaves the registry alone' {
    $r = Invoke-SFRegistryChange -TweakId 'evil' -Path 'HKCU\Software\SteadyFrame-Test' -Name 'DisableAntiSpyware' -Kind 'DWord' -Value 1
    Assert-Equal 'Blocked' $r.Status
    Assert-True (-not (Get-SFRegistryValue $T 'DisableAntiSpyware').Exists)
}

It 'revert never re-applies a blocked value' {
    $entry = [pscustomobject]@{
        Seq = 1; TweakId = 'fix.largesystemcache'; Type = 'Registry'
        Target = [pscustomobject]@{ Path = $T; Name = 'LargeSystemCache' }
        Before = [pscustomobject]@{ KeyExists = $true; Exists = $true; Kind = 'DWord'; Value = 1 }
        After = [pscustomobject]@{ Kind = 'DWord'; Value = 0; Deleted = $false; CreatedKey = '' }
    }
    $u = Undo-SFJournalEntry -Entry $entry
    Assert-Equal 'Blocked' $u.Status
}

Write-Host 'Catalog and selection' -ForegroundColor Cyan
$catalog = Import-SFCatalog

It 'catalog validates (ids, tiers, guard, requirements)' {
    $p = @(Test-SFCatalog $catalog)
    Assert-Equal 0 $p.Count ($p -join '; ')
}

It 'tier C never sits in a preset' {
    foreach ($t in $catalog) { if ($t.tier -eq 'C') { Assert-Equal 0 @(Get-SFProp $t 'presets' @()).Count $t.id } }
}

It 'dual-CCD X3D: keeps Balanced, no Ultimate plan, Game Bar kept' {
    $ctx = New-FakeContext @{ IsDualCcdX3D = $true; CpuName = 'AMD Ryzen 9 9950X3D' }
    $sel = Resolve-SFSelection -Catalog $catalog -Context $ctx -Preset 'HighEnd'
    Assert-True (-not ($sel | Where-Object Id -eq 'power.plan-ultimate').Selected) 'ultimate off'
    Assert-True (($sel | Where-Object Id -eq 'power.plan-balanced-x3d').Selected) 'balanced on'
    Assert-True (-not ($sel | Where-Object Id -eq 'bg.background-apps-off').Applies) 'background apps untouched'
    $ext = Resolve-SFExternalSelection -Tool 'win11debloat' -Context (New-FakeContext @{ IsDualCcdX3D = $true; NoGamePass = $true }) -Preset 'HighEnd' -Include @('RemoveGamingApps')
    Assert-True (-not ($ext | Where-Object Id -eq 'RemoveGamingApps').Selected) 'Game Bar removal refused on X3D even when included'
}

It 'single-CCD X3D (9800X3D) gets the Ultimate plan' {
    $sel = Resolve-SFSelection -Catalog $catalog -Context (New-FakeContext) -Preset 'HighEnd'
    Assert-True (($sel | Where-Object Id -eq 'power.plan-ultimate').Selected)
    Assert-True (-not ($sel | Where-Object Id -eq 'power.plan-balanced-x3d').Applies)
}

It 'laptops get no desktop-only power/NIC tweaks' {
    $sel = Resolve-SFSelection -Catalog $catalog -Context (New-FakeContext @{ FormFactor = 'Laptop' }) -Preset 'HighEnd'
    foreach ($id in @('power.plan-ultimate', 'power.usb-suspend-off', 'power.hibernate-off', 'net.nic-power-saving-off')) {
        Assert-True (-not ($sel | Where-Object Id -eq $id).Selected) $id
    }
}

It 'tier C hidden and unselected by default, visible with ShowAll, selectable with Include' {
    $sel = Resolve-SFSelection -Catalog $catalog -Context (New-FakeContext) -Preset 'HighEnd'
    $c = @($sel | Where-Object { $_.Tier -eq 'C' })
    Assert-True ($c.Count -gt 0)
    Assert-Equal 0 @($c | Where-Object { $_.Selected -or $_.Visible }).Count
    $all = Resolve-SFSelection -Catalog $catalog -Context (New-FakeContext) -Preset 'HighEnd' -ShowAll -Include @('mem.disable-paging-executive')
    Assert-True (($all | Where-Object Id -eq 'mem.disable-paging-executive').Selected)
    Assert-True (@($all | Where-Object { $_.Tier -eq 'C' -and -not $_.Visible }).Count -eq 0)
}

It 'update policy maps to exactly one radio item' {
    foreach ($p in @('Leave', 'DeferFeature', 'SecurityOnly')) {
        $sel = Resolve-SFSelection -Catalog $catalog -Context (New-FakeContext) -Preset 'HighEnd' -UpdatePolicy $p
        $on = @($sel | Where-Object { $_.Group -eq 'updatePolicy' -and $_.Selected })
        Assert-Equal 1 $on.Count $p
    }
}

It 'Home edition pins the version instead of using Pro-only deferral' {
    $t = $catalog | Where-Object id -eq 'updates.defer-feature'
    function Get-ActiveNames($ctx) {
        foreach ($a in $t.actions) {
            $ok = $true
            foreach ($r in @(Get-SFProp $a 'requires' @())) { if (-not (Test-SFRequirement $r $ctx)) { $ok = $false } }
            if ($ok) { $a.name }
        }
    }
    $homeNames = @(Get-ActiveNames (New-FakeContext @{ IsHome = $true; Edition = 'Core' }))
    $proNames = @(Get-ActiveNames (New-FakeContext))
    Assert-True ($homeNames -contains 'TargetReleaseVersionInfo') 'home pins version'
    Assert-True ($homeNames -notcontains 'DeferFeatureUpdates') 'home skips deferral'
    Assert-True ($proNames -contains 'DeferFeatureUpdates') 'pro defers'
    Assert-True ($proNames -notcontains 'TargetReleaseVersionInfo') 'pro does not pin'
}

It 'unknown BitLocker state blocks boot-setting tweaks (safe side)' {
    $ctx = New-FakeContext @{ BitLockerOn = $null }
    Assert-True (-not (Test-SFRequirement '!BitLocker' $ctx))
    $r = Invoke-SFAction -Action ([pscustomobject]@{ type = 'Bcd'; setting = 'disabledynamictick'; value = 'yes' }) -TweakId 'x' -Context $ctx -DryRun
    Assert-Equal 'Skipped' $r.Status
}

It 'leftover fixes only apply when the leftover is detected' {
    $sel = Resolve-SFSelection -Catalog $catalog -Context (New-FakeContext) -Preset 'HighEnd'
    Assert-True (-not ($sel | Where-Object Id -eq 'fix.largesystemcache').Applies)
    $lo = (New-FakeContext).Leftovers; $lo.LargeSystemCache = $true
    $sel2 = Resolve-SFSelection -Catalog $catalog -Context (New-FakeContext @{ Leftovers = $lo }) -Preset 'Minimal'
    Assert-True (($sel2 | Where-Object Id -eq 'fix.largesystemcache').Selected)
}

It 'catalog JSON export (GUI hook) is valid' {
    $json = Export-SFCatalogJson -Catalog $catalog -Context (New-FakeContext)
    $arr = $json | ConvertFrom-Json   # PS 5.1 returns a top-level JSON array as one object
    Assert-Equal $catalog.Count $arr.Count
    Assert-True (@($arr | Where-Object { $_.id -eq 'power.plan-ultimate' }).Count -eq 1)
}

Write-Host 'External tools' -ForegroundColor Cyan

It 'pinned download with a wrong hash is deleted and never returned' {
    $mod = Get-Module SteadyFrame
    $oldRoot = & $mod { $script:SFRoot }
    $tmp = Join-Path $env:TEMP ('sf-ext-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $tmp 'external') -Force | Out-Null
    $payload = Join-Path $tmp 'payload.ps1'
    Set-Content -LiteralPath $payload -Value 'Write-Host hi' -Encoding ASCII
    $good = (Get-FileHash $payload -Algorithm SHA256).Hash.ToLowerInvariant()
    $uri = ([Uri]$payload).AbsoluteUri
    try {
        & $mod { param($r) $script:SFRoot = $r } $tmp
        Save-SFJson -Object ([ordered]@{ winutil = [ordered]@{ tag = 't'; url = $uri; sha256 = ('0' * 64); file = 'w.ps1' } }) -Path (Join-Path $tmp 'external\pins.json')
        $threw = $false
        try { Get-SFExternalTool -Tool 'winutil' -Source 'Pinned' | Out-Null } catch { $threw = ($_.Exception.Message -match 'SHA256 mismatch') }
        Assert-True $threw 'must throw on mismatch'
        Assert-True (-not (Test-Path (Join-Path $tmp 'tools\cache\w.ps1'))) 'bad file deleted'
        Save-SFJson -Object ([ordered]@{ winutil = [ordered]@{ tag = 't'; url = $uri; sha256 = $good; file = 'w.ps1' } }) -Path (Join-Path $tmp 'external\pins.json')
        $ok = Get-SFExternalTool -Tool 'winutil' -Source 'Pinned'
        Assert-Equal $good $ok.Sha256
        $cached = Get-SFExternalTool -Tool 'winutil' -Source 'Pinned'
        Assert-Equal 'Pinned (cached)' $cached.Source
    } finally {
        & $mod { param($r) $script:SFRoot = $r } $oldRoot
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

It 'shipped external configs only contain allowed options' {
    foreach ($tool in @('winutil', 'win11debloat')) {
        foreach ($it in (Get-SFExternalItems $tool)) { Assert-Null (Test-SFExternalOption $tool $it.id) "$tool $($it.id)" }
    }
}

It 'pins look like real SHA256 hashes' {
    $pins = Read-SFJson (Join-Path $root 'external\pins.json')
    foreach ($t in @('winutil', 'win11debloat')) { Assert-True ($pins.$t.sha256 -match '^[0-9a-f]{64}$') $t }
}

Write-Host 'Games' -ForegroundColor Cyan

# A fake Steam library + Riot install under %TEMP% that mirrors the real layout.
$gameRoot = Join-Path $env:TEMP ('sf-games-' + [guid]::NewGuid().ToString('N'))
function New-FakeFile { param([string]$Path, [string]$Content = '') New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null; [IO.File]::WriteAllText($Path, $Content) }
$steamDir = Join-Path $gameRoot 'Steam'
$lib2 = Join-Path $gameRoot 'Lib2'
New-FakeFile (Join-Path $steamDir 'steamapps\libraryfolders.vdf') ("`"libraryfolders`"`n{`n `"0`" { `"path`" `"" + ($steamDir -replace '\\', '\\') + "`" }`n `"1`" { `"path`" `"" + ($lib2 -replace '\\', '\\') + "`" }`n}")
New-FakeFile (Join-Path $lib2 'steamapps\appmanifest_1778820.acf') '"AppState" { "appid" "1778820" "installdir" "TEKKEN 8" }'
New-FakeFile (Join-Path $lib2 'steamapps\common\TEKKEN 8\Polaris\Binaries\Win64\Polaris-Win64-Shipping.exe')
New-FakeFile (Join-Path $steamDir 'steamapps\appmanifest_730.acf') '"AppState" { "appid" "730" "installdir" "Counter-Strike Global Offensive" }'
New-FakeFile (Join-Path $steamDir 'steamapps\common\Counter-Strike Global Offensive\game\bin\win64\cs2.exe')
$valDir = Join-Path $gameRoot 'Riot Games\VALORANT\live'
New-FakeFile (Join-Path $valDir 'ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe')
$meta = Join-Path $gameRoot 'Metadata'
New-FakeFile (Join-Path $meta 'valorant.live\valorant.live.product_settings.yaml') ("product_install_full_path: `"" + ($valDir -replace '\\', '/') + "`"`n")

It 'reads every Steam library from libraryfolders.vdf' {
    $libs = @(Get-SFSteamLibraries -SteamPath ($steamDir -replace '\\', '/'))
    Assert-Equal 2 $libs.Count ($libs -join ' | ')
    Assert-True ($libs -contains $lib2)
}

It 'finds Tekken 8, CS2 and VALORANT with their real exe paths' {
    $libs = @(Get-SFSteamLibraries -SteamPath $steamDir)
    $games = @(Get-SFInstalledGames -SteamLibraries $libs -RiotMetadataRoot $meta -NoRiotDefaultPath)
    Assert-Equal 'cs2,tekken8,valorant' ((@($games | ForEach-Object { $_.Id }) | Sort-Object) -join ',')
    Assert-Equal 'Polaris-Win64-Shipping.exe' ($games | Where-Object Id -eq 'tekken8').ExeName
    Assert-Equal 'VALORANT-Win64-Shipping.exe' ($games | Where-Object Id -eq 'valorant').ExeName
}

It 'a game whose exe is missing is not reported' {
    $games = @(Get-SFInstalledGames -SteamLibraries @((Join-Path $gameRoot 'Nowhere')) -RiotMetadataRoot (Join-Path $gameRoot 'NoMeta') -NoRiotDefaultPath)
    Assert-Equal 0 $games.Count
}

$fakeGames = @(Get-SFInstalledGames -SteamLibraries @($steamDir, $lib2) -RiotMetadataRoot $meta -NoRiotDefaultPath)

It 'cards show NVIDIA-only lines only on NVIDIA PCs' {
    $tk = (Get-SFGameDefinitions | Where-Object id -eq 'tekken8')
    $nv = (Get-SFGameCardLines -Definition $tk -Context (New-FakeContext)) -join "`n"
    $amd = (Get-SFGameCardLines -Definition $tk -Context (New-FakeContext @{ HasNvidia = $false; Gpus = @('AMD Radeon RX 7800 XT') })) -join "`n"
    Assert-True ($nv -match 'Low Latency Mode') 'nvidia sees it'
    Assert-True ($amd -notmatch 'Low Latency Mode') 'amd does not'
    Assert-True ($amd -match 'Leverless') 'controller advice always shown'
}

It 'every card item has a setting and a reason' {
    foreach ($g in (Get-SFGameDefinitions)) {
        foreach ($s in $g.card) { foreach ($it in $s.items) { Assert-True ($it.do -and $it.why) "$($g.id) / $($s.section)" } }
    }
}

It 'GPU preference writes one value per detected game exe' {
    Reset-Sandbox
    $ctx = New-FakeContext @{ Games = $fakeGames }
    $a = [pscustomobject]@{ type = 'RegistryToken'; path = $T; name = '{GameExePath}'; token = 'GpuPreference'; value = '2' }
    $r = @(Invoke-SFAction -Action $a -TweakId 'g' -Context $ctx)
    Assert-Equal 3 $r.Count
    $tk = ($fakeGames | Where-Object Id -eq 'tekken8').Exe
    Assert-Equal 'GpuPreference=2;' (Get-SFRegistryValue $T $tk).Value
    $none = @(Invoke-SFAction -Action $a -TweakId 'g' -Context (New-FakeContext))
    Assert-True ($none[0].Quiet) 'no games = quiet skip'
}

It 'file guard only allows CS2 autoexec.cfg' {
    Assert-Null (Test-SFFileWrite 'D:\Steam\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg\autoexec.cfg')
    Assert-NotNull (Test-SFFileWrite 'C:\Windows\System32\drivers\etc\hosts')
    Assert-NotNull (Test-SFFileWrite 'D:\x\game\csgo\cfg\..\..\..\evil\game\csgo\cfg\autoexec.cfg')
    Assert-NotNull (Test-SFFileWrite 'game\csgo\cfg\autoexec.cfg') 'relative path'
}

It 'CS2 autoexec keeps your own lines, is idempotent, and undo removes only its block' {
    $ctx = New-FakeContext @{ Games = $fakeGames }
    $cs2 = $fakeGames | Where-Object Id -eq 'cs2'
    $cfg = Join-Path $cs2.Dir 'game\csgo\cfg\autoexec.cfg'
    New-FakeFile $cfg "bind mouse4 +voicerecord`r`nsensitivity 1.2"
    $j = New-TempJournal
    $r = Invoke-SFAction -Action ([pscustomobject]@{ type = 'Cs2Autoexec'; fpsMax = 300 }) -TweakId 'games.cs2-autoexec' -Context $ctx -Journal $j
    Assert-Equal 'Applied' $r.Status
    $txt = [IO.File]::ReadAllText($cfg)
    Assert-True ($txt -match 'bind mouse4 \+voicerecord') 'user line kept'
    Assert-True ($txt -match '(?m)^fps_max 300\r?$') 'fps cap written'
    Assert-True ($txt -match '(?m)^// engine_low_latency_sleep_after_client_tick true') 'unproven tweak stays commented out'
    $again = Invoke-SFAction -Action ([pscustomobject]@{ type = 'Cs2Autoexec'; fpsMax = 300 }) -TweakId 'games.cs2-autoexec' -Context $ctx -Journal $j
    Assert-Equal 'AlreadySet' $again.Status
    Add-Content -LiteralPath $cfg -Value 'echo added-later'
    [void](Undo-SFJournalEntry -Entry $j.Entries[0])
    $after = [IO.File]::ReadAllText($cfg)
    Assert-True ($after -notmatch 'SteadyFrame') 'block removed'
    Assert-True ($after -match 'sensitivity 1\.2' -and $after -match 'echo added-later') 'user lines (old and new) kept'
}

It 'CS2 autoexec created from scratch is deleted again on undo' {
    $ctx = New-FakeContext @{ Games = $fakeGames }
    $cfg = Join-Path ($fakeGames | Where-Object Id -eq 'cs2').Dir 'game\csgo\cfg\autoexec.cfg'
    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
    $j = New-TempJournal
    [void](Invoke-SFAction -Action ([pscustomobject]@{ type = 'Cs2Autoexec' }) -TweakId 'games.cs2-autoexec' -Context $ctx -Journal $j)
    Assert-True (Test-Path -LiteralPath $cfg) 'created'
    Assert-True ([IO.File]::ReadAllText($cfg) -match 'fps_max 400') 'default cap'
    [void](Undo-SFJournalEntry -Entry $j.Entries[0])
    Assert-True (-not (Test-Path -LiteralPath $cfg)) 'deleted on undo'
}

It 'CS2 autoexec is Advanced-only and needs CS2 installed' {
    $ctx = New-FakeContext @{ Games = $fakeGames }
    $row = (Resolve-SFSelection -Catalog $catalog -Context $ctx -Preset 'HighEnd') | Where-Object Id -eq 'games.cs2-autoexec'
    Assert-True (-not $row.Visible -and -not $row.Selected) 'hidden by default'
    $adv = (Resolve-SFSelection -Catalog $catalog -Context $ctx -Preset 'HighEnd' -ShowAll) | Where-Object Id -eq 'games.cs2-autoexec'
    Assert-True ($adv.Visible -and $adv.Applies -and -not $adv.Selected) 'visible in Advanced, still opt-in'
    $noCs = (Resolve-SFSelection -Catalog $catalog -Context (New-FakeContext) -Preset 'HighEnd' -ShowAll) | Where-Object Id -eq 'games.cs2-autoexec'
    Assert-True (-not $noCs.Applies)
}

Remove-Item -LiteralPath $gameRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'Misc' -ForegroundColor Cyan

It 'startup "disabled" blob is the Task Manager format (03 + FILETIME)' {
    $b = ConvertFrom-SFHex (New-SFStartupDisabledBlob)
    Assert-Equal 12 $b.Length
    Assert-Equal 3 $b[0]
}

It 'number list parser handles ranges, commas and junk' {
    Assert-Equal '1,2,3,5' ((ConvertFrom-SFNumberList '1-3, 5' 10) -join ',')
    Assert-Equal '2' ((ConvertFrom-SFNumberList '2 99' 10) -join ',')
    Assert-Null (ConvertFrom-SFNumberList 'abc' 10)
}

Reset-Sandbox
Write-Host ''
$color = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $color
exit $script:Fail
