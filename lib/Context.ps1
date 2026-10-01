# PC detection. The context object drives which tweaks apply (requirements),
# which preset is suggested, and what the health check reports.

$script:SFLaptopChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)

function Get-SFSafe {
    param([scriptblock]$Script, $Default = $null)
    try { $r = & $Script; if ($null -eq $r) { return $Default } return $r } catch { return $Default }
}

function Get-SFMicrocodeRevision {
    $v = Get-SFSafe { Get-SFRegistryValue 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0' 'Update Revision' }
    if (-not $v -or -not $v.Exists -or $v.Kind -ne 'Binary') { return $null }
    $bytes = ConvertFrom-SFHex $v.Value
    # Intel stores 8 bytes with the revision in the high DWORD; AMD stores 4 bytes.
    if ($bytes.Length -ge 8) {
        $rev = [BitConverter]::ToUInt32($bytes, 4)
        if ($rev -eq 0) { $rev = [BitConverter]::ToUInt32($bytes, 0) }
        return [int64]$rev
    }
    if ($bytes.Length -ge 4) { return [int64][BitConverter]::ToUInt32($bytes, 0) }
    return $null
}

function Get-SFRamInfo {
    $sticks = @(Get-SFSafe { Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop } @())
    $totalBytes = [int64]0
    foreach ($s in $sticks) { $totalBytes += [int64]$s.Capacity }
    $type = 'Unknown'
    $speed = 0
    if ($sticks.Count -gt 0) {
        $t = [int](Get-SFProp $sticks[0] 'SMBIOSMemoryType' 0)
        if ($t -eq 26) { $type = 'DDR4' } elseif ($t -eq 34) { $type = 'DDR5' } elseif ($t -eq 24) { $type = 'DDR3' }
        $speed = [int](Get-SFProp $sticks[0] 'ConfiguredClockSpeed' 0)
        if ($speed -le 0) { $speed = [int](Get-SFProp $sticks[0] 'Speed' 0) }
        # Some firmware reports the memory clock (MHz) instead of the data rate (MT/s).
        if ($type -eq 'DDR4' -and $speed -gt 0 -and $speed -le 1600) { $speed = $speed * 2 }
        if ($type -eq 'DDR5' -and $speed -gt 0 -and $speed -le 3000) { $speed = $speed * 2 }
    }
    $sizes = @($sticks | ForEach-Object { [math]::Round($_.Capacity / 1GB) } | Sort-Object -Unique)
    return [pscustomobject]@{
        TotalGB     = [math]::Round($totalBytes / 1GB)
        TotalKB     = [int64]($totalBytes / 1KB)
        Sticks      = $sticks.Count
        Type        = $type
        SpeedMTs    = $speed
        MixedSizes  = ($sizes.Count -gt 1)
        Slots       = @($sticks | ForEach-Object { $_.DeviceLocator })
    }
}

function Get-SFDiskInfo {
    $sysType = 'Unknown'
    $allSsd = $true
    $any = $false
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        foreach ($d in $disks) {
            $any = $true
            if ("$($d.MediaType)" -ne 'SSD' -and "$($d.BusType)" -ne 'NVMe') { if ("$($d.BusType)" -notin @('USB', 'SD', 'MMC')) { $allSsd = $false } }
        }
        $part = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $num = $part.DiskNumber
        $pd = $disks | Where-Object { "$($_.DeviceId)" -eq "$num" } | Select-Object -First 1
        if ($pd) {
            if ("$($pd.BusType)" -eq 'NVMe') { $sysType = 'NVMe SSD' }
            elseif ("$($pd.MediaType)" -eq 'SSD') { $sysType = 'SATA SSD' }
            elseif ("$($pd.MediaType)" -eq 'HDD') { $sysType = 'HDD' }
            else { $sysType = "$($pd.MediaType) ($($pd.BusType))" }
        }
    } catch { $allSsd = $false }
    $free = Get-SFSafe {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        [pscustomobject]@{ FreeGB = [math]::Round($ld.FreeSpace / 1GB); SizeGB = [math]::Round($ld.Size / 1GB) }
    }
    return [pscustomobject]@{
        SystemDisk = $sysType
        SsdOnly    = ($any -and $allSsd)
        FreeGB     = (Get-SFProp $free 'FreeGB' 0)
        SizeGB     = (Get-SFProp $free 'SizeGB' 0)
    }
}

function Test-SFPhysicalPrinter {
    $printers = @(Get-SFSafe { Get-CimInstance Win32_Printer -ErrorAction Stop } @())
    $virtual = 'PDF|XPS|OneNote|Fax|Send To|AnyDesk|Snagit|Root Print|Remote Desktop|Redirected'
    $real = @($printers | Where-Object { $_.Name -notmatch $virtual -and "$($_.PortName)" -notmatch '^(PORTPROMPT:|nul:|SHRFAX:|FILE:)' })
    return ($real.Count -gt 0)
}

function Get-SFBitLockerOn {
    $v = Get-SFSafe {
        Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) -ErrorAction Stop
    }
    if ($null -eq $v) { return $null }   # unknown (not admin, or no BitLocker support)
    return ([int]$v.ProtectionStatus -eq 1)
}

function Get-SFActiveInterfaces {
    $root = 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $result = @()
    $s = Split-SFRegistryPath $root
    $base = Get-SFBaseKey $s.Hive
    try {
        $k = $base.OpenSubKey($s.SubKey, $false)
        if (-not $k) { return @() }
        foreach ($name in $k.GetSubKeyNames()) {
            $sub = $k.OpenSubKey($name, $false)
            if (-not $sub) { continue }
            $dhcp = "$($sub.GetValue('DhcpIPAddress', ''))"
            $static = @($sub.GetValue('IPAddress', @())) -join ''
            $sub.Close()
            if (($dhcp -and $dhcp -ne '0.0.0.0') -or ($static -and $static -ne '0.0.0.0')) { $result += $name }
        }
        $k.Close()
    } finally { $base.Close() }
    return $result
}

function Get-SFBcdValue {
    param([Parameter(Mandatory)][string]$Setting)
    # Returns: $null = could not read (needs admin), '' = not set, otherwise the raw value
    $out = Get-SFSafe { & bcdedit.exe /enum '{current}' 2>&1 }
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    foreach ($line in @($out)) {
        $m = [regex]::Match("$line", '^\s*' + [regex]::Escape($Setting) + '\s+(\S+)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

function ConvertTo-SFBcdBool {
    param([string]$Raw)
    if ($Raw -match '^(?i)(yes|on|true|1|s.|si|oui|ja|sim)$') { return 'yes' }
    return 'no'
}

function Get-SFLeftovers {
    $l = [ordered]@{}
    $bcd = Get-SFBcdValue 'useplatformclock'
    $l.UsePlatformClock = ($bcd -and (ConvertTo-SFBcdBool $bcd) -eq 'yes')
    $cs = Get-SFSafe { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
    $pfUsage = @(Get-SFSafe { Get-CimInstance Win32_PageFileUsage -ErrorAction Stop } @())
    $l.PagefileDisabled = ($cs -and -not $cs.AutomaticManagedPagefile -and $pfUsage.Count -eq 0)
    $mm = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $fso = Get-SFRegistryValue $mm 'FeatureSettingsOverride'
    $l.SpectreMitigationsDisabled = ($fso.Exists -and ([int64]$fso.Value -band 3) -ne 0)
    $lsc = Get-SFRegistryValue $mm 'LargeSystemCache'
    $l.LargeSystemCache = ($lsc.Exists -and [int64]$lsc.Value -ne 0)
    $wu = Get-SFServiceStartType 'wuauserv'
    $bits = Get-SFServiceStartType 'BITS'
    $l.WuauservDisabled = ($wu -eq 'Disabled')
    $l.BitsDisabled = ($bits -eq 'Disabled')
    $l.UpdateServicesDisabled = ($wu -eq 'Disabled' -or $bits -eq 'Disabled')
    $ps = Get-SFRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation'
    $l.PrioritySeparationValue = if ($ps.Exists) { [int64]$ps.Value } else { $null }
    $l.PrioritySeparationOdd = ($ps.Exists -and [int64]$ps.Value -notin @(2, 0x26))
    $dpol = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender'
    $a = Get-SFRegistryValue $dpol 'DisableAntiSpyware'
    $r = Get-SFRegistryValue ($dpol + '\Real-Time Protection') 'DisableRealtimeMonitoring'
    $l.DefenderDisabledByPolicy = (($a.Exists -and [int64]$a.Value -eq 1) -or ($r.Exists -and [int64]$r.Value -eq 1))
    return [pscustomobject]$l
}

function Get-SFContext {
    param([string[]]$GameExe = @(), [switch]$NoGamePass)
    $cv = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int](Get-SFRegistryValue $cv 'CurrentBuild').Value
    $ubr = (Get-SFRegistryValue $cv 'UBR').Value
    $display = (Get-SFRegistryValue $cv 'DisplayVersion').Value
    $edition = (Get-SFRegistryValue $cv 'EditionID').Value
    $osMajor = if ($build -ge 22000) { 11 } else { 10 }

    $chassis = @(Get-SFSafe { (Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes } @())
    $battery = @(Get-SFSafe { Get-CimInstance Win32_Battery -ErrorAction Stop } @())
    $isLaptop = ($battery.Count -gt 0)
    foreach ($c in $chassis) { if ($script:SFLaptopChassis -contains [int]$c) { $isLaptop = $true } }

    $cpu = Get-SFSafe { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 }
    $cpuName = if ($cpu) { ($cpu.Name -replace '\s+', ' ').Trim() } else { 'Unknown CPU' }
    $isAmd = ($cpuName -match 'AMD')
    $isIntel = ($cpuName -match 'Intel')
    $dualX3D = ($cpuName -match 'Ryzen 9 (7900|7950|9900|9950)X3D')
    $raptor = ($isIntel -and $cpuName -match 'i[579]-1[34]\d{3}(K|KF|KS|F|T)?(\s|$)')

    $gpus = @(Get-SFSafe {
            Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { "$($_.PNPDeviceID)" -like 'PCI\*' }
        } @())

    $ram = Get-SFRamInfo
    $disk = Get-SFDiskInfo
    $cores = if ($cpu) { [int]$cpu.NumberOfCores } else { 0 }
    $threads = if ($cpu) { [int]$cpu.NumberOfLogicalProcessors } else { 0 }

    $games = @(Get-SFSafe { Get-SFInstalledGames } @())
    $exeNames = @(@($GameExe) + @($games | ForEach-Object { $_.ExeName }) | Where-Object { $_ } |
        ForEach-Object { if ($_ -notmatch '\.exe$') { "$_.exe" } else { $_ } } | Sort-Object -Unique)

    $suggest = 'HighEnd'
    if ($ram.TotalGB -lt 16 -or $threads -le 8 -or $disk.SystemDisk -eq 'HDD') { $suggest = 'MidRange' }

    return [pscustomobject]@{
        Computer        = $env:COMPUTERNAME
        IsAdmin         = (Test-SFAdmin)
        OsMajor         = $osMajor
        Build           = $build
        UBR             = $ubr
        DisplayVersion  = $display
        ProductVersion  = ('Windows {0}' -f $osMajor)
        Edition         = $edition
        IsHome          = ($edition -match '^Core')
        FormFactor      = if ($isLaptop) { 'Laptop' } else { 'Desktop' }
        CpuName         = $cpuName
        CpuCores        = $cores
        CpuThreads      = $threads
        IsAmd           = $isAmd
        IsIntel         = $isIntel
        IsDualCcdX3D    = $dualX3D
        IsX3D           = ($cpuName -match 'X3D')
        IsIntelRaptor   = $raptor
        Microcode       = (Get-SFMicrocodeRevision)
        Gpus            = @($gpus | ForEach-Object { $_.Name })
        HasNvidia       = (@($gpus | Where-Object { $_.Name -match 'NVIDIA' }).Count -gt 0)
        Ram             = $ram
        Disk            = $disk
        HasPrinter      = (Test-SFPhysicalPrinter)
        BitLockerOn     = (Get-SFBitLockerOn)
        ActiveInterfaces = @(Get-SFActiveInterfaces)
        Games           = $games
        GameExes        = $exeNames
        NoGamePass      = [bool]$NoGamePass
        Leftovers       = (Get-SFLeftovers)
        SuggestedPreset = $suggest
    }
}

# Named requirement predicates used by the catalog ("requires": [...]).
function Test-SFRequirement {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Context)
    $neg = $false
    $n = $Name
    if ($n.StartsWith('!')) { $neg = $true; $n = $n.Substring(1) }
    $ok = switch -Regex ($n) {
        '^Win10$' { $Context.OsMajor -eq 10; break }
        '^Win11$' { $Context.OsMajor -eq 11; break }
        '^MinBuild:(\d+)$' { $Context.Build -ge [int]$Matches[1]; break }
        '^Desktop$' { $Context.FormFactor -eq 'Desktop'; break }
        '^Laptop$' { $Context.FormFactor -eq 'Laptop'; break }
        '^DualCcdX3D$' { [bool]$Context.IsDualCcdX3D; break }
        '^HomeEdition$' { [bool]$Context.IsHome; break }
        '^SsdOnly$' { [bool]$Context.Disk.SsdOnly; break }
        '^Printer$' { [bool]$Context.HasPrinter; break }
        '^GamePass$' { -not [bool]$Context.NoGamePass; break }
        '^Ram16Plus$' { $Context.Ram.TotalGB -ge 15; break }
        '^BitLocker$' { $Context.BitLockerOn -ne $false; break }   # unknown counts as "maybe on" (safe side)
        '^GameExe$' { @($Context.GameExes).Count -gt 0; break }
        '^GameDetected$' { @(Get-SFProp $Context 'Games' @()).Count -gt 0; break }
        '^Game:([\w-]+)$' { $gid = $Matches[1]; @(Get-SFProp $Context 'Games' @() | Where-Object { $_.Id -eq $gid }).Count -gt 0; break }
        '^Nvidia$' { [bool]$Context.HasNvidia; break }
        '^Leftover:(\w+)$' { [bool](Get-SFProp $Context.Leftovers $Matches[1] $false); break }
        default { throw "Unknown requirement '$Name'" }
    }
    if ($neg) { return (-not $ok) }
    return [bool]$ok
}

$script:SFRequirementHelp = @{
    'Desktop' = 'desktop PCs only'; '!Laptop' = 'not on laptops'; 'Laptop' = 'laptops only'
    'Win11' = 'Windows 11 only'; 'Win10' = 'Windows 10 only'
    '!DualCcdX3D' = 'skipped on dual-CCD X3D CPUs (AMD V-Cache driver needs Balanced plan + Game Bar)'
    'DualCcdX3D' = 'dual-CCD X3D CPUs only'
    'HomeEdition' = 'Windows Home only'; '!HomeEdition' = 'Windows Pro/Education/Enterprise only'
    'SsdOnly' = 'only when every drive is an SSD'; '!Printer' = 'only when no physical printer is installed'
    '!GamePass' = 'only if you said this PC does not use Game Pass / Xbox app'
    'Ram16Plus' = 'needs 16 GB RAM or more'; '!BitLocker' = 'needs BitLocker off/suspended (boot setting change)'
    'GameExe' = 'needs at least one game .exe (Advanced > game list)'; 'Nvidia' = 'NVIDIA GPUs only'
}

function Get-SFRequirementText {
    param([string]$Name)
    $t = $script:SFRequirementHelp[$Name]
    if ($t) { return $t }
    if ($Name -match '^MinBuild:(\d+)$') { return "needs Windows build $($Matches[1]) or newer" }
    if ($Name -match '^Leftover:(\w+)$') { return "only when the leftover '$($Matches[1])' is detected" }
    if ($Name -eq 'GameDetected') { return 'no supported game found (Tekken 8, VALORANT, CS2)' }
    if ($Name -match '^Game:([\w-]+)$') { return "$($Matches[1]) is not installed on this PC" }
    return $Name
}
