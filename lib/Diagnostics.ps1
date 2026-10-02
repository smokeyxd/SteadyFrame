# Read-only. Nothing in here may change the system.

$script:SFDisplayCs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SFDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
        public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    public class Info { public string Device; public string Adapter; public int Width; public int Height; public int Current; public int Max; }
    public static List<Info> Get() {
        var list = new List<Info>();
        for (uint i = 0; i < 32; i++) {
            var d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            if ((d.StateFlags & 0x1) == 0 || (d.StateFlags & 0x8) != 0) continue;
            var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(d.DeviceName, -1, ref cur)) continue;
            int max = cur.dmDisplayFrequency;
            var m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            for (int k = 0; EnumDisplaySettings(d.DeviceName, k, ref m); k++) {
                if (m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight && m.dmDisplayFrequency > max) max = m.dmDisplayFrequency;
            }
            var info = new Info();
            info.Device = d.DeviceName; info.Adapter = d.DeviceString; info.Width = cur.dmPelsWidth;
            info.Height = cur.dmPelsHeight; info.Current = cur.dmDisplayFrequency; info.Max = max;
            list.Add(info);
        }
        return list;
    }
}
'@

function Get-SFDisplays {
    try {
        if (-not ('SFDisplay' -as [type])) { Add-Type -TypeDefinition $script:SFDisplayCs -Language CSharp -ErrorAction Stop }
        return @([SFDisplay]::Get())
    } catch { return @() }
}

function New-SFFinding {
    param([string]$Area, [string]$Item, [string]$Value, [ValidateSet('OK', 'INFO', 'WARN', 'BAD')][string]$Status, [string]$Advice = '', [string]$Bios = '')
    [pscustomobject]@{ Area = $Area; Item = $Item; Value = $Value; Status = $Status; Advice = $Advice; Bios = $Bios }
}

function Get-SFSecurityBaseline {
    $b = [ordered]@{}
    $mp = Get-SFSafe { Get-MpComputerStatus -ErrorAction Stop }
    $b.DefenderRealtime = if ($mp) { [bool]$mp.RealTimeProtectionEnabled } else { 'unknown' }
    $b.DefenderEngine = if ($mp) { [bool]$mp.AMServiceEnabled } else { 'unknown' }
    $b.TamperProtection = if ($mp) { [bool]$mp.IsTamperProtected } else { 'unknown' }
    $av = @(Get-SFSafe { Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop } @())
    $b.AntivirusProducts = (@($av | ForEach-Object { $_.displayName }) -join ', ')
    $dg = Get-SFSafe { Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop }
    $b.VbsRunning = if ($dg) { ([int]$dg.VirtualizationBasedSecurityStatus -eq 2) } else { 'unknown' }
    $b.HvciRunning = if ($dg) { (@($dg.SecurityServicesRunning) -contains 2) } else { 'unknown' }
    $b.SecureBoot = Get-SFSafe { [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } 'unknown'
    # Get-Tpm without admin can return a half-empty object (TpmReady = False), so only trust it elevated.
    $tpm = if (Test-SFAdmin) { Get-SFSafe { Get-Tpm -ErrorAction Stop } } else { $null }
    $b.TpmReady = if ($tpm) { [bool]$tpm.TpmReady } else { 'unknown' }
    $lua = Get-SFRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
    $b.UacEnabled = if ($lua.Exists) { ([int64]$lua.Value -eq 1) } else { $true }
    $fw = @(Get-SFSafe { Get-NetFirewallProfile -ErrorAction Stop } @())
    $b.FirewallAllProfilesOn = if ($fw.Count -gt 0) { (@($fw | Where-Object { -not $_.Enabled }).Count -eq 0) } else { 'unknown' }
    $fso = Get-SFRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'FeatureSettingsOverride'
    $b.CpuMitigationsDefault = (-not $fso.Exists -or ([int64]$fso.Value -band 3) -eq 0)
    return [pscustomobject]$b
}

# 'unknown' on either side is ignored, so a non-admin run can't cause a false alarm
function Compare-SFSecurityBaseline {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $changes = @()
    foreach ($p in $Before.PSObject.Properties) {
        if ($p.Name -eq 'AntivirusProducts') { continue }
        $a = Get-SFProp $After $p.Name
        if ("$($p.Value)" -eq 'unknown' -or "$a" -eq 'unknown') { continue }
        if ("$($p.Value)" -ne "$a") { $changes += [pscustomobject]@{ Setting = $p.Name; Before = $p.Value; After = $a } }
    }
    return $changes
}

function Get-SFNvidiaBar1MiB {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (-not (Test-Path -LiteralPath $smi)) { return $null }
    $out = (Get-SFSafe { & $smi -q -d MEMORY 2>$null } @()) -join "`n"
    $m = [regex]::Match($out, 'BAR1[^\n]*\n\s*Total\s*:\s*(\d+)\s*MiB')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

$script:SFStutterSoftware = @(
    @{ Pattern = '^ArmouryCrate|^ArmourySocketServer|^LightingService$|^AuraWallpaperService'; Name = 'ASUS Armoury Crate / Aura'; Advice = 'Known for DPC latency spikes and background CPU use. Uninstall it (Armoury Crate Uninstall Tool) or at least disable its startup services; set RGB once and remove it.' }
    @{ Pattern = '^iCUE$|^Corsair\.Service|^CorsairService'; Name = 'Corsair iCUE'; Advice = 'Heavy background polling. Close it while gaming, or save lighting to device memory and remove it from startup.' }
    @{ Pattern = '^NahimicService|^Nahimic|^A-Volute'; Name = 'Nahimic / A-Volute audio'; Advice = 'Well known for stutters and crashes in games. Disable the Nahimic service or uninstall it.' }
    @{ Pattern = '^MSI\.CentralServer|^MSI_Center|^Dragon Center'; Name = 'MSI Center / Dragon Center'; Advice = 'Background services poll sensors constantly. Remove what you do not use.' }
    @{ Pattern = '^CAM$|^NZXT CAM'; Name = 'NZXT CAM'; Advice = 'Known to cause frame-time spikes from sensor polling. Close it while gaming.' }
    @{ Pattern = '^wallpaper(32|64)$'; Name = 'Wallpaper Engine'; Advice = 'Uses GPU in the background. Set it to pause when a game is fullscreen.' }
    @{ Pattern = '^Overwolf'; Name = 'Overwolf'; Advice = 'Injects overlays into games. Disable it unless you really use an app on it.' }
    @{ Pattern = '^RzSDKService|^Razer Synapse|^RazerCentralService'; Name = 'Razer Synapse'; Advice = 'Heavy background services. Save profiles to on-board memory and close it if possible.' }
    @{ Pattern = '^SonicStudio|^SS3Svc'; Name = 'ASUS Sonic Studio'; Advice = 'Audio effects layer that can add latency/crackle. Disable if you do not need it.' }
)

function Get-SFDiagnostics {
    param([Parameter(Mandatory)]$Context)
    $f = New-Object System.Collections.ArrayList
    $add = { param($x) [void]$f.Add($x) }

    & $add (New-SFFinding 'Windows' 'Version' ("Windows {0} {1} {2} (build {3}.{4})" -f $Context.OsMajor, $Context.Edition, $Context.DisplayVersion, $Context.Build, $Context.UBR) 'INFO')
    $days = Get-SFSupportDaysLeft (Get-SFProp $Context 'EndOfService')
    if ($null -ne $days) {
        $eos = '{0:yyyy-MM-dd}' -f $Context.EndOfService
        if ($days -lt 0) {
            $advice = if ($Context.OsMajor -eq 10) { 'Windows 10 no longer gets security updates. Extended Security Updates (if you enrolled) only last until 2026-10-13. Upgrade to Windows 11 if this PC supports it.' }
            else { 'This Windows version no longer gets security updates. Install the newest version in Settings > Windows Update.' }
            & $add (New-SFFinding 'Windows' 'Security updates' ('ended ' + $eos) 'BAD' $advice)
        } elseif ($days -lt $script:SFMinSupportDays) {
            & $add (New-SFFinding 'Windows' 'Security updates' ('until {0} ({1} days left)' -f $eos, $days) 'WARN' 'Install the newest Windows version soon (Settings > Windows Update). SteadyFrame will not lock this version.')
        } else {
            & $add (New-SFFinding 'Windows' 'Security updates' ('until ' + $eos) 'OK')
        }
    }
    & $add (New-SFFinding 'Windows' 'Form factor' $Context.FormFactor 'INFO')
    if (-not $Context.IsAdmin) { & $add (New-SFFinding 'Windows' 'Admin' 'not elevated' 'WARN' 'Run as administrator for the full check (TPM, BitLocker, boot settings).') }
    $elevUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $console = Get-SFSafe { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName }
    if ($console -and $console -ne $elevUser) {
        & $add (New-SFFinding 'Windows' 'Signed-in user' "$console (running as $elevUser)" 'WARN' 'Per-user tweaks (HKCU) will apply to the admin account, not the gamer account. Sign in as the gamer and elevate with "Run as administrator" on that account.')
    }

    & $add (New-SFFinding 'CPU' 'Processor' ("{0} ({1} cores / {2} threads)" -f $Context.CpuName, $Context.CpuCores, $Context.CpuThreads) 'INFO')
    if ($Context.IsIntelRaptor) {
        $mc = $Context.Microcode
        if ($null -eq $mc) {
            & $add (New-SFFinding 'CPU' 'Intel 13th/14th gen microcode' 'unknown' 'WARN' 'Could not read the microcode revision. Make sure the BIOS includes microcode 0x12F or newer.' 'Update BIOS to a version with Intel microcode 0x12F or newer, then load the "Intel Default Settings" profile.')
        } elseif ($mc -lt 0x100) {
            & $add (New-SFFinding 'CPU' 'Intel 13th/14th gen microcode' ('0x{0:X}' -f $mc) 'INFO' 'Looks like an Alder Lake-based die (not affected by the Vmin shift issue). Keep the BIOS updated anyway.')
        } elseif ($mc -lt 0x12F) {
            & $add (New-SFFinding 'CPU' 'Intel 13th/14th gen microcode' ('0x{0:X}' -f $mc) 'BAD' 'This CPU family can degrade from excess voltage (Vmin shift). Update the BIOS NOW to one with microcode 0x12F or newer and use "Intel Default Settings". No CPU overclocking.' 'Update BIOS to a version with Intel microcode 0x12F or newer, then load the "Intel Default Settings" profile.')
        } else {
            & $add (New-SFFinding 'CPU' 'Intel 13th/14th gen microcode' ('0x{0:X}' -f $mc) 'OK' 'Has the Vmin shift fix. Keep "Intel Default Settings" in the BIOS.')
        }
    }
    if ($Context.IsDualCcdX3D) {
        $vc = @(Get-SFSafe { Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%V-Cache%'" -ErrorAction Stop } @())
        if ($vc.Count -gt 0) { & $add (New-SFFinding 'CPU' 'AMD 3D V-Cache driver' 'installed' 'OK') }
        else { & $add (New-SFFinding 'CPU' 'AMD 3D V-Cache driver' 'not found' 'BAD' 'Install the latest AMD chipset driver; without it games can land on the wrong CCD.' 'Install the latest AMD chipset driver from amd.com (needed for dual-CCD X3D core parking).') }
        $gb = @(Get-SFSafe { Get-AppxPackage -Name 'Microsoft.XboxGamingOverlay' -ErrorAction Stop } @())
        if ($gb.Count -eq 0) { & $add (New-SFFinding 'CPU' 'Xbox Game Bar (needed by X3D driver)' 'missing' 'BAD' 'Reinstall Xbox Game Bar from the Microsoft Store; the V-Cache driver uses it to detect games.') }
    }

    $ram = $Context.Ram
    $ramText = '{0} GB {1}-{2} ({3} stick(s))' -f $ram.TotalGB, $ram.Type, $ram.SpeedMTs, $ram.Sticks
    & $add (New-SFFinding 'Memory' 'Installed' $ramText 'INFO')
    $xmpOff = (($ram.Type -eq 'DDR4' -and $ram.SpeedMTs -gt 0 -and $ram.SpeedMTs -le 2666) -or ($ram.Type -eq 'DDR5' -and $ram.SpeedMTs -gt 0 -and $ram.SpeedMTs -le 4800))
    if ($xmpOff) {
        & $add (New-SFFinding 'Memory' 'XMP / EXPO' ('running at {0} MT/s (JEDEC default)' -f $ram.SpeedMTs) 'BAD' 'RAM is almost certainly running at stock speed. Enabling XMP/EXPO is one of the biggest 1% low improvements there is. It is a memory profile, not a CPU overclock.' 'Enable XMP (Intel) / EXPO (AMD) and pick the kit''s rated profile. If it becomes unstable, use the next lower speed.')
    } elseif ($ram.SpeedMTs -gt 0) {
        & $add (New-SFFinding 'Memory' 'XMP / EXPO' ('{0} MT/s' -f $ram.SpeedMTs) 'OK')
    }
    if ($ram.Sticks -eq 1) {
        & $add (New-SFFinding 'Memory' 'Channels' 'single stick = single channel' 'BAD' 'Single-channel RAM halves memory bandwidth and hurts 1% lows a lot. Add a matching second stick.' 'Install RAM as a matched pair in the slots the motherboard manual marks for dual channel (usually A2 + B2).')
    } elseif ($ram.Sticks -eq 3) {
        & $add (New-SFFinding 'Memory' 'Channels' '3 sticks' 'WARN' 'Odd stick count runs partly single-channel. Use 2 or 4 matched sticks.')
    }
    if ($ram.MixedSizes) { & $add (New-SFFinding 'Memory' 'Mixed stick sizes' 'yes' 'WARN' 'Mixed kits often run at lower speed or flex mode. Matched kits are best.') }
    if ($ram.TotalGB -lt 16) { & $add (New-SFFinding 'Memory' 'Capacity' ('{0} GB' -f $ram.TotalGB) 'WARN' 'Modern games want 16 GB; with less, Windows pages to disk mid-game (stutter).') }

    $disk = $Context.Disk
    $st = if ($disk.SystemDisk -eq 'HDD') { 'BAD' } else { 'OK' }
    $adv = if ($st -eq 'BAD') { 'Windows on a hard drive is the biggest stutter source of all. Move Windows and games to an SSD.' } else { '' }
    & $add (New-SFFinding 'Storage' 'Windows drive' $disk.SystemDisk $st $adv)
    if ($disk.SizeGB -gt 0) {
        $pct = [math]::Round(100 * $disk.FreeGB / $disk.SizeGB)
        $fs = if ($pct -lt 15) { 'WARN' } else { 'OK' }
        & $add (New-SFFinding 'Storage' 'Free space on Windows drive' ('{0} GB free ({1}%)' -f $disk.FreeGB, $pct) $fs $(if ($fs -eq 'WARN') { 'Keep at least 15% free; SSDs slow down when nearly full and Windows needs room for the page file and updates.' } else { '' }))
    }

    $vcs = @(Get-SFSafe { Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { "$($_.PNPDeviceID)" -like 'PCI\*' } } @())
    foreach ($g in $vcs) {
        if ($g.Name -match 'Basic Display') {
            & $add (New-SFFinding 'GPU' 'Driver' 'Microsoft Basic Display Adapter' 'BAD' 'No real GPU driver installed. Install the NVIDIA/AMD/Intel driver.')
            continue
        }
        $age = $null
        if ($g.DriverDate) { $age = [int]((Get-Date) - [datetime]$g.DriverDate).TotalDays }
        $gs = if ($age -ne $null -and $age -gt 180) { 'WARN' } else { 'OK' }
        $gtext = '{0} - driver {1}' -f $g.Name, $g.DriverVersion
        if ($age -ne $null) { $gtext += (' ({0} days old)' -f $age) }
        & $add (New-SFFinding 'GPU' 'Graphics card' $gtext $gs $(if ($gs -eq 'WARN') { 'Driver is over 6 months old. New drivers often fix stutter in recent games. For a clean install use DDU in Safe Mode, then the newest driver.' } else { '' }))
        $msi = Get-SFRegistryValue (Get-SFMsiKey $g.PNPDeviceID) 'MSISupported'
        if ($msi.Exists -and [int64]$msi.Value -eq 1) {
            & $add (New-SFFinding 'GPU' 'Interrupt mode' 'MSI' 'OK')
        } else {
            & $add (New-SFFinding 'GPU' 'Interrupt mode' 'line-based (MSI off)' 'WARN' 'Advanced > "Graphics card: use MSI interrupts" can switch it (undo-able).')
        }
    }
    $hags = Get-SFRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    $hagsText = if (-not $hags.Exists) { 'default' } elseif ([int64]$hags.Value -eq 2) { 'on' } else { 'off' }
    & $add (New-SFFinding 'GPU' 'Hardware-accelerated GPU scheduling' $hagsText 'INFO' 'Needed for DLSS Frame Generation (RTX 40/50). Otherwise benchmark on vs off.')
    if ($Context.HasNvidia) {
        $bar = Get-SFNvidiaBar1MiB
        if ($bar -ne $null) {
            if ($bar -gt 256) { & $add (New-SFFinding 'GPU' 'Resizable BAR' ('on (BAR1 {0} MiB)' -f $bar) 'OK') }
            else { & $add (New-SFFinding 'GPU' 'Resizable BAR' 'off (BAR1 256 MiB)' 'WARN' 'Resizable BAR is off. Supported games get smoother with it.' 'Enable "Above 4G Decoding" and "Resizable BAR" (needs UEFI mode, CSM off).') }
        }
    }

    foreach ($d in (Get-SFDisplays)) {
        $txt = '{0}x{1} @ {2} Hz (max {3} Hz at this resolution) on {4}' -f $d.Width, $d.Height, $d.Current, $d.Max, $d.Adapter
        if ($d.Max -gt $d.Current + 1) {
            & $add (New-SFFinding 'Display' $d.Device $txt 'BAD' ('Monitor is running below its max refresh rate. Settings > System > Display > Advanced display > choose {0} Hz. Also check the cable (DisplayPort / HDMI 2.0+).' -f $d.Max))
        } else {
            & $add (New-SFFinding 'Display' $d.Device $txt 'OK')
        }
    }

    $active = Get-SFActivePowerScheme
    $planName = ($(Get-SFPowerSchemes) | Where-Object { $_.Guid -eq $active } | Select-Object -First 1).Name
    $ps = 'INFO'
    $padv = ''
    if ($Context.IsDualCcdX3D -and $active -ne $script:SFPowerGuids.Balanced) { $ps = 'BAD'; $padv = 'Dual-CCD X3D needs the Balanced plan for core parking.' }
    & $add (New-SFFinding 'Power' 'Active plan' ("{0} ({1})" -f $planName, $active) $ps $padv)

    $gm = Get-SFRegistryValue 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    $gmOn = (-not $gm.Exists -or [int64]$gm.Value -eq 1)
    & $add (New-SFFinding 'Gaming' 'Game Mode' $(if ($gmOn) { 'on' } else { 'off' }) $(if ($gmOn) { 'OK' } else { 'WARN' }) $(if ($gmOn) { '' } else { 'Turn it back on: it blocks update installs and restart prompts while gaming.' }))
    $dvr = Get-SFRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'
    $dvrOn = ($dvr.Exists -and [int64]$dvr.Value -eq 1)
    & $add (New-SFFinding 'Gaming' 'Game DVR background capture' $(if ($dvrOn) { 'on' } else { 'off' }) $(if ($dvrOn) { 'WARN' } else { 'OK' }) $(if ($dvrOn) { 'Background recording costs performance.' } else { '' }))

    foreach ($a in (Get-SFPhysicalAdapters | Where-Object { $_.Status -eq 'Up' })) {
        $isWifi = ($a.PhysicalMediaType -match '802\.11' -or $a.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11')
        if ($isWifi) {
            & $add (New-SFFinding 'Network' $a.InterfaceDescription ('Wi-Fi, {0}' -f $a.LinkSpeed) 'INFO' 'Ethernet gives more stable ping than Wi-Fi for competitive games.')
        } else {
            $slow = ("$($a.LinkSpeed)" -match '^(10|100) Mbps')
            & $add (New-SFFinding 'Network' $a.InterfaceDescription ('Ethernet, {0}' -f $a.LinkSpeed) $(if ($slow) { 'WARN' } else { 'OK' }) $(if ($slow) { 'Link is only 100 Mbps: usually a damaged cable or bad port (gigabit needs all 8 wires). Try another cable.' } else { '' }))
        }
    }

    foreach ($g in @(Get-SFProp $Context 'Games' @())) {
        & $add (New-SFFinding 'Games' $g.Name $g.Dir 'INFO' 'Main menu option 7 shows the settings card for this game.')
    }

    $startup = @(Get-SFSafe { Get-SFStartupItems } @() | Where-Object { $_.Enabled })
    $sus = if ($startup.Count -gt 12) { 'WARN' } else { 'INFO' }
    & $add (New-SFFinding 'Background' 'Startup apps enabled' "$($startup.Count)" $sus 'Review them in the optimizer (or Task Manager > Startup apps).')
    $procs = @(Get-SFSafe { Get-Process -ErrorAction Stop | ForEach-Object { $_.ProcessName } } @())
    $svcs = @(Get-SFSafe { Get-Service -ErrorAction Stop | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name } } @())
    $names = @($procs + $svcs | Sort-Object -Unique)
    foreach ($sw in $script:SFStutterSoftware) {
        if (@($names | Where-Object { $_ -match $sw.Pattern }).Count -gt 0) {
            & $add (New-SFFinding 'Background' $sw.Name 'running' 'WARN' $sw.Advice)
        }
    }

    $l = $Context.Leftovers
    if ($l.UsePlatformClock) { & $add (New-SFFinding 'Leftovers' 'Forced HPET (useplatformclock)' 'set' 'WARN' 'Old FPS tweak that adds timer overhead. The optimizer can remove it.') }
    if ($l.PagefileDisabled) { & $add (New-SFFinding 'Leftovers' 'Page file' 'disabled' 'BAD' 'Causes crashes/stutter when memory fills. The optimizer re-enables it.') }
    if ($l.SpectreMitigationsDisabled) { & $add (New-SFFinding 'Leftovers' 'CPU security mitigations' 'disabled' 'BAD' 'Security hole; the optimizer restores Windows defaults.') }
    if ($l.LargeSystemCache) { & $add (New-SFFinding 'Leftovers' 'LargeSystemCache' '1 (server mode)' 'WARN' 'The optimizer resets it to the desktop default.') }
    if ($l.UpdateServicesDisabled) { & $add (New-SFFinding 'Leftovers' 'Windows Update / BITS' 'disabled' 'BAD' 'No security updates; anti-cheats may refuse old builds. The optimizer re-enables them.') }
    if ($l.VersionLockExpiring) { & $add (New-SFFinding 'Leftovers' 'Windows version lock' ("locked to $($l.VersionLockTarget)") 'BAD' 'This version stops getting security updates soon (or already has). The optimizer removes the lock.') }
    elseif ($l.VersionLocked) { & $add (New-SFFinding 'Leftovers' 'Windows version lock' ("locked to $($l.VersionLockTarget)") 'INFO' 'Fine while this version is supported. Run SteadyFrame again a few months before support ends; it will offer to unlock it.') }
    if ($l.PrioritySeparationOdd) { & $add (New-SFFinding 'Leftovers' 'Win32PrioritySeparation' ('0x{0:X}' -f $l.PrioritySeparationValue) 'WARN' 'Non-default value from a tweak tool. The optimizer can reset it.') }
    if ($l.DefenderDisabledByPolicy) { & $add (New-SFFinding 'Leftovers' 'Defender disabled by policy' 'yes' 'BAD' 'A policy disables Microsoft Defender. SteadyFrame never touches Defender; remove that policy yourself (or with the tool that set it) unless another antivirus is installed.') }

    $sec = Get-SFSecurityBaseline
    $secOk = { param($v) if ("$v" -eq 'unknown') { 'INFO' } elseif ($v) { 'OK' } else { 'WARN' } }
    & $add (New-SFFinding 'Security' 'Antivirus' $(if ($sec.AntivirusProducts) { $sec.AntivirusProducts } else { 'unknown' }) 'INFO')
    & $add (New-SFFinding 'Security' 'Defender real-time protection' "$($sec.DefenderRealtime)" (& $secOk $sec.DefenderRealtime) $(if ($sec.DefenderRealtime -eq $false -and -not $sec.AntivirusProducts) { 'No real-time protection detected.' } else { '' }))
    & $add (New-SFFinding 'Security' 'Secure Boot' "$($sec.SecureBoot)" (& $secOk $sec.SecureBoot) $(if ($sec.SecureBoot -eq $false) { 'Valorant (Vanguard) and FACEIT on Windows 11 require Secure Boot.' } else { '' }) $(if ($sec.SecureBoot -eq $false) { 'Enable Secure Boot (UEFI mode, CSM off) - required by Vanguard/FACEIT on Windows 11.' } else { '' }))
    & $add (New-SFFinding 'Security' 'TPM ready' "$($sec.TpmReady)" (& $secOk $sec.TpmReady) $(if ($sec.TpmReady -eq $false) { 'Anti-cheats need TPM 2.0.' } else { '' }) $(if ($sec.TpmReady -eq $false) { 'Enable fTPM (AMD) / PTT (Intel).' } else { '' }))
    & $add (New-SFFinding 'Security' 'VBS / Memory integrity (HVCI)' ("VBS {0}, HVCI {1}" -f $sec.VbsRunning, $sec.HvciRunning) 'INFO' 'Left exactly as it is: some games/anti-cheats require it.')
    & $add (New-SFFinding 'Security' 'UAC' "$($sec.UacEnabled)" (& $secOk $sec.UacEnabled))
    & $add (New-SFFinding 'Security' 'Firewall (all profiles)' "$($sec.FirewallAllProfilesOn)" (& $secOk $sec.FirewallAllProfilesOn))
    if ($Context.BitLockerOn -eq $true) { & $add (New-SFFinding 'Security' 'BitLocker on C:' 'on' 'INFO' 'Boot-setting tweaks are skipped while BitLocker is on. Save your recovery key (aka.ms/myrecoverykey).') }

    $bios = Get-SFSafe { Get-CimInstance Win32_BIOS -ErrorAction Stop }
    if ($bios -and $bios.ReleaseDate) {
        $bage = [int]((Get-Date) - [datetime]$bios.ReleaseDate).TotalDays
        $bs = if ($bage -gt 730) { 'WARN' } else { 'INFO' }
        & $add (New-SFFinding 'Firmware' 'BIOS' ('{0} ({1:yyyy-MM-dd}, {2} days old)' -f $bios.SMBIOSBIOSVersion, [datetime]$bios.ReleaseDate, $bage) $bs $(if ($bs -eq 'WARN') { 'BIOS is over 2 years old; updates often fix memory stability and add CPU fixes.' } else { '' }) $(if ($bs -eq 'WARN') { 'Update the BIOS from the motherboard maker''s site (read their instructions, do not power off during the update).' } else { '' }))
    }
    return $f.ToArray()
}

function Write-SFDiagnostics {
    param([Parameter(Mandatory)]$Findings)
    $area = ''
    foreach ($x in $Findings) {
        if ($x.Area -ne $area) { $area = $x.Area; Write-SFHeader $area }
        Write-SFStatus $x.Status ('{0}: {1}' -f $x.Item, $x.Value)
        if ($x.Advice -and $x.Status -ne 'OK') { Write-Host ('            ' + $x.Advice) -ForegroundColor DarkGray }
    }
    $bios = @($Findings | Where-Object { $_.Bios })
    Write-SFHeader 'Do this outside Windows (BIOS / hardware) - read it out on Discord'
    if ($bios.Count -eq 0) { Write-SFStatus 'OK' 'Nothing urgent found. Still worth checking XMP/EXPO and Resizable BAR are on.' }
    $i = 1
    foreach ($b in $bios) { Write-Host ('  {0}. {1}' -f $i, $b.Bios) -ForegroundColor Yellow; $i++ }
}

function Save-SFDiagnostics {
    param([Parameter(Mandatory)]$Findings, [Parameter(Mandatory)][string]$Path, $Context)
    Save-SFJson -Object ([ordered]@{ Time = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME; Findings = @($Findings) }) -Path ($Path + '.json')
    $lines = @("SteadyFrame health check - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '')
    foreach ($x in $Findings) {
        $lines += ('[{0,-4}] {1} / {2}: {3}' -f $x.Status, $x.Area, $x.Item, $x.Value)
        if ($x.Advice -and $x.Status -ne 'OK') { $lines += ('       ' + $x.Advice) }
    }
    $bios = @($Findings | Where-Object { $_.Bios })
    if ($bios.Count -gt 0) { $lines += ''; $lines += 'Outside Windows (BIOS / hardware):'; foreach ($b in $bios) { $lines += (' - ' + $b.Bios) } }
    [System.IO.File]::WriteAllLines($Path + '.txt', $lines, (New-Object System.Text.UTF8Encoding $false))
}
