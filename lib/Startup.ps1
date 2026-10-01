# Same switch Task Manager uses: the StartupApproved value, first byte 03 = disabled.
# Nothing is deleted, so Task Manager can turn any of these back on.

$script:SFStartupApprovedHKCU = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:SFStartupApprovedHKLM = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

# never offered
$script:SFStartupProtected = 'SecurityHealth|Windows Security|Vanguard|vgtray|EasyAntiCheat|BattlEye|FACEIT|Windows Defender'
# drivers and peripheral software: shown, but not pre-ticked
$script:SFStartupKeep = 'Realtek|RtkAud|NVIDIA|NvBackend|Radeon|AMD|igfx|Intel|Synaptics|Elan|ETD|Logitech G HUB|lghub|Razer|SteelSeries|Wooting|ctfmon'
# pre-ticked for disabling: launchers, chat apps, updaters, browsers
$script:SFStartupSuggestOff = 'EdgeAutoLaunch|Teams|Spotify|Steam|Epic|EADM|EA Desktop|EADesktop|Origin|Ubisoft|Uplay|Battle\.net|Riot Client|Discord|Skype|OneDrive|Cortana|Opera|Brave|Chrome|Firefox|Adobe|CCleaner|iTunes|Overwolf|uTorrent|qBittorrent|BitTorrent|Zoom|Slack|WhatsApp|Telegram|Dropbox|Google Drive|GoogleDrive|Wallpaper|Medal|Outplayed|CurseForge|GOG Galaxy|Copilot|Phone Link|YourPhone'

function Get-SFStartupItems {
    $sources = @(
        @{ Scope = 'User'; Run = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = $script:SFStartupApprovedHKCU + '\Run' }
        @{ Scope = 'All users'; Run = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = $script:SFStartupApprovedHKLM + '\Run' }
        @{ Scope = 'All users (32-bit)'; Run = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = $script:SFStartupApprovedHKLM + '\Run32' }
        @{ Scope = 'User folder'; Folder = [Environment]::GetFolderPath('Startup'); Approved = $script:SFStartupApprovedHKCU + '\StartupFolder' }
        @{ Scope = 'All users folder'; Folder = [Environment]::GetFolderPath('CommonStartup'); Approved = $script:SFStartupApprovedHKLM + '\StartupFolder' }
    )
    $items = @()
    foreach ($src in $sources) {
        $entries = @()
        if ($src.Run) {
            $s = Split-SFRegistryPath $src.Run
            $base = Get-SFBaseKey $s.Hive
            try {
                $k = $base.OpenSubKey($s.SubKey, $false)
                if ($k) {
                    foreach ($n in $k.GetValueNames()) {
                        if ($n -eq '') { continue }
                        $entries += [pscustomobject]@{ Name = $n; Command = "$($k.GetValue($n, ''))" }
                    }
                    $k.Close()
                }
            } finally { $base.Close() }
        } elseif ($src.Folder -and (Test-Path -LiteralPath $src.Folder)) {
            foreach ($f in (Get-ChildItem -LiteralPath $src.Folder -File -ErrorAction SilentlyContinue)) {
                if ($f.Name -eq 'desktop.ini') { continue }
                $entries += [pscustomobject]@{ Name = $f.Name; Command = $f.FullName }
            }
        }
        foreach ($e in $entries) {
            $approved = Get-SFRegistryValue $src.Approved $e.Name
            $enabled = $true
            if ($approved.Exists -and $approved.Kind -eq 'Binary') {
                $bytes = ConvertFrom-SFHex $approved.Value
                if ($bytes.Length -gt 0 -and ($bytes[0] % 2) -eq 1) { $enabled = $false }
            }
            $hay = $e.Name + ' ' + $e.Command
            $suggest = ''
            if ($hay -match $script:SFStartupProtected) { $suggest = 'protected' }
            elseif ($hay -match $script:SFStartupKeep) { $suggest = 'keep' }
            elseif ($hay -match $script:SFStartupSuggestOff) { $suggest = 'disable' }
            $items += [pscustomobject]@{
                Name = $e.Name; Command = $e.Command; Scope = $src.Scope
                ApprovedKey = $src.Approved; Enabled = $enabled; Suggest = $suggest
            }
        }
    }
    return $items
}

function New-SFStartupDisabledBlob {
    $bytes = New-Object byte[] 12
    $bytes[0] = 3
    $ft = [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc())
    [Array]::Copy($ft, 0, $bytes, 4, 8)
    return (ConvertTo-SFHex $bytes)
}

function Invoke-SFStartupReview {
    param([string]$TweakId = 'bg.startup-review', $Journal, [switch]$DryRun, [switch]$Interactive)
    $items = @(Get-SFStartupItems | Where-Object { $_.Enabled -and $_.Suggest -ne 'protected' })
    if ($items.Count -eq 0) { return (New-SFResult $TweakId 'Startup' 'startup apps' 'AlreadySet' 'no enabled startup apps to review') }
    if (-not $Interactive) {
        return (New-SFResult $TweakId 'Startup' 'startup apps' 'Skipped' ("{0} enabled startup apps; review them in interactive mode or Task Manager > Startup apps" -f $items.Count))
    }
    $rows = foreach ($i in $items) {
        $tag = switch ($i.Suggest) { 'keep' { '(driver/peripheral - suggest keep)' } 'disable' { '(suggest disable)' } default { '' } }
        [pscustomobject]@{ Label = ('{0}  [{1}] {2}' -f $i.Name, $i.Scope, $tag); Detail = $i.Command; Selected = ($i.Suggest -eq 'disable'); Item = $i }
    }
    $picked = Show-SFChecklist -Title 'Startup apps: CHECKED = will be DISABLED at login (Task Manager can re-enable any of them)' -Rows @($rows)
    $results = @()
    foreach ($r in @($picked | Where-Object { $_.Selected })) {
        $blob = New-SFStartupDisabledBlob
        $results += Invoke-SFRegistryChange -TweakId $TweakId -Path $r.Item.ApprovedKey -Name $r.Item.Name -Kind 'Binary' -Value $blob -Journal $Journal -DryRun:$DryRun -Label 'Startup'
    }
    if ($results.Count -eq 0) { return (New-SFResult $TweakId 'Startup' 'startup apps' 'Skipped' 'nothing selected') }
    return $results
}
