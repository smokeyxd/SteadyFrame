# Hard safety rails. Every write the engine makes is checked here first, and a
# blocked write is refused even if someone adds it to the catalog by mistake.
# Goal: anti-cheat (Vanguard, FACEIT, EAC, BattlEye) and core Windows security
# keep working. Defender *telemetry* (sample submission) is allowed; Defender
# *protection* is not.

# Registry subtrees SteadyFrame never writes to (prefix match, any value).
$script:SFGuardBlockedKeys = @(
    'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender'
    'HKLM\SOFTWARE\Microsoft\Windows Defender'
    'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center'
    'HKLM\SOFTWARE\Microsoft\Windows Defender Security Center'
    'HKLM\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
    'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard'
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'
    'HKLM\SYSTEM\CurrentControlSet\Control\CI'
    'HKLM\SYSTEM\CurrentControlSet\Control\Lsa'
    'HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot'
    'HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
    'HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall'
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
)

# Value names blocked wherever they appear.
#   Block      = never write or delete
#   DeleteOnly = may only be removed (resetting a leftover back to Windows default)
#   Allow      = only the listed values may be written (delete also allowed)
$script:SFGuardValueRules = @(
    @{ Name = 'EnableLUA'; Mode = 'Block' }
    @{ Name = 'ConsentPromptBehaviorAdmin'; Mode = 'Block' }
    @{ Name = 'PromptOnSecureDesktop'; Mode = 'Block' }
    @{ Name = 'EnableSmartScreen'; Mode = 'Block' }
    @{ Name = 'SmartScreenEnabled'; Mode = 'Block' }
    @{ Name = 'DisableAntiSpyware'; Mode = 'Block' }
    @{ Name = 'DisableAntiVirus'; Mode = 'Block' }
    @{ Name = 'DisableRealtimeMonitoring'; Mode = 'Block' }
    @{ Name = 'EnableVirtualizationBasedSecurity'; Mode = 'Block' }
    @{ Name = 'HypervisorEnforcedCodeIntegrity'; Mode = 'Block' }
    @{ Name = 'MitigationOptions'; Mode = 'Block' }
    @{ Name = 'MitigationAuditOptions'; Mode = 'Block' }
    @{ Name = 'MoveImages'; Mode = 'Block' }
    @{ Name = 'DisableExceptionChainValidation'; Mode = 'Block' }
    @{ Name = 'Debugger'; Mode = 'Block' }
    @{ Name = 'GlobalFlag'; Mode = 'Block' }
    @{ Name = 'PagingFiles'; Mode = 'Block' }
    @{ Name = 'ExistingPageFiles'; Mode = 'Block' }
    @{ Name = 'DisableWindowsUpdateAccess'; Mode = 'Block' }
    @{ Name = 'SetDisableUXWUAccess'; Mode = 'Block' }
    @{ Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Mode = 'Block' }
    @{ Name = 'WUServer'; Mode = 'Block' }
    @{ Name = 'WUStatusServer'; Mode = 'Block' }
    @{ Name = 'UseWUServer'; Mode = 'Block' }
    @{ Name = 'FeatureSettingsOverride'; Mode = 'DeleteOnly' }
    @{ Name = 'FeatureSettingsOverrideMask'; Mode = 'DeleteOnly' }
    @{ Name = 'NoAutoUpdate'; Mode = 'Allow'; Values = @(0) }
    @{ Name = 'LargeSystemCache'; Mode = 'Allow'; Values = @(0) }
)

# Security and anti-cheat services: no start-type change at all.
$script:SFGuardUntouchableServices = @(
    'WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'Sense', 'SecurityHealthService',
    'wscsvc', 'mpssvc', 'mpsdrv', 'BFE', 'KeyIso', 'SamSs', 'CryptSvc', 'TrustedInstaller',
    'WaaSMedicSvc', 'tbs', 'vgc', 'vgk', 'EasyAntiCheat', 'EasyAntiCheat_EOS', 'BEService',
    'FACEIT', 'FACEITService', 'EAAntiCheatService', 'PnkBstrA', 'PnkBstrB', 'ESEADriver2'
)

# Core services: may be set to Manual/Automatic, never Disabled.
$script:SFGuardNeverDisableServices = @(
    'wuauserv', 'UsoSvc', 'BITS', 'Winmgmt', 'EventLog', 'Schedule', 'RpcSs', 'RpcEptMapper',
    'DcomLaunch', 'Appinfo', 'gpsvc', 'ProfSvc', 'AudioSrv', 'AudioEndpointBuilder', 'Dhcp',
    'Dnscache', 'NlaSvc', 'nsi', 'netprofm', 'LSM', 'Power', 'PlugPlay', 'AppXSvc', 'ClipSVC',
    'StateRepository', 'LicenseManager', 'TokenBroker', 'WlanSvc', 'GamingServices', 'GamingServicesNet'
)

# bcdedit is allow-listed: only these settings, only these operations.
$script:SFGuardBcdAllow = @{
    'disabledynamictick' = @('yes', 'no', '<delete>')
    'useplatformclock'   = @('<delete>')
    'useplatformtick'    = @('<delete>')
    'tscsyncpolicy'      = @('<delete>')
}

# External tool options that are never passed through.
$script:SFGuardBlockedExternal = @{
    winutil      = @(
        'WPFTweaksDisableBitLocker', 'WPFTweaksDisableIPv6', 'WPFTweaksTeredo', 'WPFTweaksIPv46',
        'WPFTweaksUTC', 'WPFTweaksDisableWarningForUnsignedRdp', 'WPFTweaksRazerBlock',
        'WPFTweaksDisableStoreSearch', 'WPFOOSUbutton', 'WPFchangedns'
    )
    win11debloat = @(
        'DisableBitlockerAutoEncryption', 'Sysprep', 'User', 'Config', 'RunDefaults', 'RunDefaultsLite',
        'RunSavedSettings', 'CLI', 'ReplaceStart', 'ReplaceStartAllUsers', 'EnableWindowsSandbox',
        'EnableWindowsSubsystemForLinux', 'Apps', 'AppRemovalTarget', 'LogPath', 'Silent'
    )
}

function Get-SFGuardServiceKeys {
    $all = @($script:SFGuardUntouchableServices) + @($script:SFGuardNeverDisableServices)
    return ($all | ForEach-Object { 'HKLM\SYSTEM\CurrentControlSet\Services\' + $_ })
}

# Returns $null when the registry write is allowed, otherwise the reason.
function Test-SFRegistryWrite {
    param([Parameter(Mandatory)][string]$Path, [string]$Name = '', $Value = $null, [switch]$Delete)
    $norm = (ConvertTo-SFRegistryKeyName $Path).ToUpperInvariant().TrimEnd('\')
    foreach ($prefix in $script:SFGuardBlockedKeys) {
        $p = $prefix.ToUpperInvariant()
        if ($norm -eq $p -or $norm.StartsWith($p + '\')) {
            return "protected security key ($prefix)"
        }
    }
    foreach ($prefix in (Get-SFGuardServiceKeys)) {
        $p = $prefix.ToUpperInvariant()
        if ($norm -eq $p -or $norm.StartsWith($p + '\')) {
            return "protected service key ($prefix)"
        }
    }
    foreach ($rule in $script:SFGuardValueRules) {
        if ($Name -ne $rule.Name) { continue }
        switch ($rule.Mode) {
            'Block' { return "protected value '$Name'" }
            'DeleteOnly' { if (-not $Delete) { return "'$Name' may only be reset (deleted), not set" } }
            'Allow' {
                if (-not $Delete) {
                    $ok = $false
                    foreach ($v in $rule.Values) { if ("$v" -eq "$Value") { $ok = $true } }
                    if (-not $ok) { return "'$Name' may only be set to $($rule.Values -join '/')" }
                }
            }
        }
    }
    # Image File Execution Options: only the PerfOptions subkey (CPU priority) is allowed.
    $ifeo = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS NT\CURRENTVERSION\IMAGE FILE EXECUTION OPTIONS\'
    if ($norm.StartsWith($ifeo)) {
        $rest = $norm.Substring($ifeo.Length)
        $parts = $rest.Split('\')
        if ($parts.Count -ne 2 -or $parts[1] -ne 'PERFOPTIONS') { return 'only IFEO <exe>\PerfOptions may be written' }
        if ($Name -notin @('CpuPriorityClass', 'IoPriority', 'PagePriority')) { return "IFEO value '$Name' not allowed" }
    }
    return $null
}

function Test-SFServiceWrite {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$StartType)
    foreach ($s in $script:SFGuardUntouchableServices) {
        if ($s -eq $Name) { return "service '$Name' is security/anti-cheat critical" }
    }
    if ($StartType -eq 'Disabled') {
        foreach ($s in $script:SFGuardNeverDisableServices) {
            if ($s -eq $Name) { return "service '$Name' must never be disabled" }
        }
    }
    return $null
}

function Test-SFBcdWrite {
    param([Parameter(Mandatory)][string]$Setting, [string]$Value = '', [switch]$Delete)
    $key = $Setting.ToLowerInvariant()
    if (-not $script:SFGuardBcdAllow.ContainsKey($key)) { return "bcdedit setting '$Setting' is not on the allow-list" }
    $op = if ($Delete) { '<delete>' } else { $Value.ToLowerInvariant() }
    if ($script:SFGuardBcdAllow[$key] -notcontains $op) { return "bcdedit '$Setting' operation '$op' not allowed" }
    return $null
}

# Files are allow-listed: the only file SteadyFrame writes is a CS2 autoexec.cfg.
function Test-SFFileWrite {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '\.\.' -or -not [IO.Path]::IsPathRooted($Path)) { return "file path '$Path' is not a plain absolute path" }
    if ($Path -notmatch '(?i)\\game\\csgo\\cfg\\autoexec\.cfg$') { return "SteadyFrame only writes CS2's autoexec.cfg ('$Path' refused)" }
    return $null
}

function Test-SFExternalOption {
    param([Parameter(Mandatory)][ValidateSet('winutil', 'win11debloat')][string]$Tool, [Parameter(Mandatory)][string]$Id)
    if ($script:SFGuardBlockedExternal[$Tool] -contains $Id) { return "$Tool option '$Id' is blocked" }
    if ($Tool -eq 'winutil' -and $Id -notmatch '^WPF(Tweaks|Toggle)[A-Za-z0-9]+$') { return "only WinUtil tweak/toggle IDs are supported ('$Id')" }
    if ($Tool -eq 'win11debloat' -and $Id -notmatch '^[A-Za-z0-9]+$') { return "invalid Win11Debloat flag '$Id'" }
    return $null
}
