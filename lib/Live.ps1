# Read-only. Uses per-process CPU time and raw WMI counters instead of Get-Counter: counter paths
# are translated on non-English Windows, WMI class and property names are not.

$script:SFNotAGame = @(
    'dwm', 'explorer', 'System', 'Idle', 'csrss', 'audiodg', 'ShellExperienceHost', 'StartMenuExperienceHost',
    'SearchHost', 'TextInputHost', 'Widgets', 'Taskmgr', 'powershell', 'pwsh', 'WindowsTerminal', 'conhost',
    'msedgewebview2', 'chrome', 'msedge', 'firefox', 'librewolf', 'brave', 'opera', 'Discord', 'DiscordCanary',
    'DiscordPTB', 'obs64', 'obs32', 'NVIDIA Overlay', 'NVIDIA app', 'steamwebhelper', 'Spotify', 'claude', 'Code',
    'wallpaper32', 'wallpaper64', 'Lively', 'Rainmeter', 'GameBar', 'XboxGameBar', 'Overwolf'
)

$script:SFKnownBackground = @(
    @{ Pattern = '^NVIDIA (Overlay|Share)$|^nvcontainer$'; Advice = 'NVIDIA overlay: turn off Instant Replay and the statistics overlay (Alt+Z > Settings), or the whole overlay.' }
    @{ Pattern = '^Discord'; Advice = 'Discord: a stream or video call costs CPU. Stream at 720p / 30 FPS and turn off its in-game overlay.' }
    @{ Pattern = '^obs(32|64)$'; Advice = 'OBS: record with the GPU encoder (NVENC / AMF / QSV), not x264.' }
    @{ Pattern = '^(chrome|msedge|firefox|librewolf|brave|opera)$'; Advice = 'A browser is busy in the background (a video or many tabs). Close it while playing.' }
    @{ Pattern = '^wallpaper(32|64)$'; Advice = 'Wallpaper Engine: set it to pause while a game is in focus.' }
    @{ Pattern = '^steamwebhelper$'; Advice = 'Steam''s web pages (store, friends, overlay). Close the Steam window while playing.' }
    @{ Pattern = '^MsMpEng$'; Advice = 'Windows Security is scanning. Let it finish; it only does this now and then.' }
    @{ Pattern = '^(TiWorker|TrustedInstaller|MoUsoCoreWorker|wuauclt)$'; Advice = 'Windows Update is installing something. Let it finish before judging FPS.' }
    @{ Pattern = '^SearchIndexer$'; Advice = 'Windows Search is indexing files.' }
    @{ Pattern = '^Spotify$'; Advice = 'Spotify: turn off hardware acceleration in its settings if it stays busy.' }
)


function Get-SFGpuEngineRaw {
    $map = @{}
    foreach ($r in @(Get-SFSafe { Get-CimInstance Win32_PerfRawData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop } @())) {
        if ("$($r.Name)" -match '^pid_(\d+)_.*engtype_3D') {
            $map[$r.Name] = [pscustomobject]@{ Pid = [int]$Matches[1]; Value = [double]$r.UtilizationPercentage; Time = [double]$r.Timestamp_Sys100NS }
        }
    }
    return $map
}

function Get-SFGpuUsageByName {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After, [Parameter(Mandatory)]$PidNames)
    $byName = @{}
    foreach ($k in @($After.Keys)) {
        if (-not $Before.ContainsKey($k)) { continue }
        $a = $Before[$k]; $b = $After[$k]
        $dt = $b.Time - $a.Time
        if ($dt -le 0) { continue }
        $name = $PidNames[$b.Pid]
        if (-not $name) { continue }
        $byName[$name] = [double]$byName[$name] + [math]::Max(0, ($b.Value - $a.Value) / $dt * 100)
    }
    return $byName
}

function Get-SFLiveSample {
    param([int]$Seconds = 20)
    $cpuBefore = @{}
    foreach ($p in Get-Process) { if ($null -ne $p.CPU) { $cpuBefore[$p.Id] = [double]$p.CPU } }
    $gpuBefore = Get-SFGpuEngineRaw
    Start-Sleep -Seconds $Seconds
    $gpuAfter = Get-SFGpuEngineRaw

    $pidNames = @{}
    $rows = foreach ($p in Get-Process) {
        $pidNames[$p.Id] = $p.ProcessName
        if ($null -eq $p.CPU -or -not $cpuBefore.ContainsKey($p.Id)) { continue }
        [pscustomobject]@{ Name = $p.ProcessName; Cores = ([double]$p.CPU - $cpuBefore[$p.Id]) / $Seconds; MemoryMB = $p.PrivateMemorySize64 / 1MB }
    }
    $processes = @($rows | Group-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Cores = ($_.Group | Measure-Object Cores -Sum).Sum; MemoryMB = ($_.Group | Measure-Object MemoryMB -Sum).Sum }
        })

    $os = Get-CimInstance Win32_OperatingSystem
    $mem = Get-SFSafe { Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop }
    $dg = Get-SFSafe { Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop }
    $features = @(Get-SFSafe { Get-CimInstance Win32_OptionalFeature -Filter 'InstallState=1' -ErrorAction Stop } @() |
        Where-Object { $_.Name -in 'Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Containers-DisposableClientVM', 'Microsoft-Windows-Subsystem-Linux' } |
        ForEach-Object { $_.Name })

    return [pscustomobject]@{
        Seconds     = $Seconds
        Processes   = $processes
        GpuByName   = (Get-SFGpuUsageByName -Before $gpuBefore -After $gpuAfter -PidNames $pidNames)
        Memory      = [pscustomobject]@{
            TotalMB       = [double]$os.TotalVisibleMemorySize / 1KB
            AvailableMB   = [double]$os.FreePhysicalMemory / 1KB
            CommitMB      = $(if ($mem) { [double]$mem.CommittedBytes / 1MB } else { $null })
            CommitLimitMB = $(if ($mem) { [double]$mem.CommitLimit / 1MB } else { $null })
        }
        Compression = $(if (Get-Service SysMain -ErrorAction SilentlyContinue) { (Get-Service SysMain).StartType -ne 'Disabled' } else { $null })
        Hypervisor  = [pscustomobject]@{
            Present  = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent
            Hvci     = $(if ($dg) { @($dg.SecurityServicesRunning) -contains 2 } else { $null })
            Features = $features
        }
    }
}

function Find-SFGameInSample {
    param([Parameter(Mandatory)]$Sample, [string[]]$KnownGames = @())
    $known = @($KnownGames | ForEach-Object { $_ -replace '\.exe$', '' })
    $candidates = @($Sample.GpuByName.Keys | Where-Object { $_ -notin $script:SFNotAGame -and $_ -notlike 'vmmem*' -and $Sample.GpuByName[$_] -ge 5 })
    $pick = @($candidates | Where-Object { $_ -in $known }) + @($candidates | Sort-Object { $Sample.GpuByName[$_] } -Descending)
    return ($pick | Select-Object -First 1)
}

function Get-SFLiveFindings {
    param([Parameter(Mandatory)]$Sample, [string]$Game = '', [string[]]$KnownGames = @())
    $f = New-Object System.Collections.ArrayList
    $add = { param($x) [void]$f.Add($x) }
    if (-not $Game) { $Game = Find-SFGameInSample -Sample $Sample -KnownGames $KnownGames }
    $gpuTotal = [math]::Min(100, (@($Sample.GpuByName.Values) | Measure-Object -Sum).Sum)

    if (-not $Game) {
        & $add (New-SFFinding 'Game' 'Game' 'none found' 'WARN' 'No program was using the graphics card much while this ran. Start the check, then switch to your game and play until it beeps.')
    } else {
        $g = $Sample.Processes | Where-Object Name -eq $Game | Select-Object -First 1
        $gCores = if ($g) { $g.Cores } else { 0 }
        & $add (New-SFFinding 'Game' 'Game' ('{0} ({1:N1} CPU cores, {2:N0}% of the graphics card)' -f $Game, $gCores, [double]$Sample.GpuByName[$Game]) 'INFO')
        if ($gpuTotal -lt 85) {
            & $add (New-SFFinding 'Game' 'Graphics card busy' ('{0:N0}%' -f $gpuTotal) 'INFO' 'The graphics card had time to spare, so FPS is held back by the CPU or by an FPS cap (V-Sync, frame limiter). Background CPU use below matters here.')
        } else {
            & $add (New-SFFinding 'Game' 'Graphics card busy' ('{0:N0}%' -f $gpuTotal) 'OK' 'The graphics card is the limit; lower graphics settings or resolution raise FPS.')
        }
    }

    $background = @($Sample.Processes | Where-Object { $_.Name -ne $Game -and $_.Name -notin 'Idle', 'System' -and $_.Cores -ge 0.5 } | Sort-Object Cores -Descending | Select-Object -First 6)
    foreach ($p in $background) {
        $hint = $script:SFKnownBackground | Where-Object { $p.Name -match $_.Pattern } | Select-Object -First 1
        $advice = if ($hint) { $hint.Advice } else { 'Close it while playing if you don''t need it.' }
        & $add (New-SFFinding 'Background' $p.Name ('{0:N1} CPU cores' -f $p.Cores) 'WARN' $advice)
    }
    if ($background.Count -eq 0) { & $add (New-SFFinding 'Background' 'Other programs' 'quiet' 'OK') }

    $dwm = [double]$Sample.GpuByName['dwm']
    if ($Game -and $dwm -ge 15) {
        & $add (New-SFFinding 'Display' 'Windows desktop compositor' ('{0:N0}% of the graphics card' -f $dwm) 'WARN' 'The game is probably in borderless or windowed mode with overlays on top. Exclusive fullscreen skips this step.')
    }

    $m = $Sample.Memory
    $freeGB = $m.AvailableMB / 1024
    $status = if ($m.AvailableMB -lt 2048) { 'BAD' } elseif ($m.AvailableMB -lt 4096) { 'WARN' } else { 'OK' }
    $advice = if ($status -ne 'OK') { 'Windows is moving memory to the page file, which causes hitches. Close big programs while playing.' } else { '' }
    & $add (New-SFFinding 'Memory' 'Free RAM' ('{0:N1} GB of {1:N0} GB' -f $freeGB, ($m.TotalMB / 1024)) $status $advice)
    if ($m.CommitLimitMB -gt 0 -and $m.CommitMB / $m.CommitLimitMB -ge 0.9) {
        & $add (New-SFFinding 'Memory' 'Committed memory' ('{0:N1} of {1:N1} GB' -f ($m.CommitMB / 1024), ($m.CommitLimitMB / 1024)) 'BAD' 'Programs have reserved almost all memory Windows can hand out. Close programs, or let Windows manage the page file size.')
    }
    if ($status -ne 'OK' -and $Sample.Compression -eq $false) {
        & $add (New-SFFinding 'Memory' 'Memory compression' 'off (SysMain is disabled)' 'WARN' 'With RAM this tight, compression would keep more in memory instead of the page file. Set the SysMain service back to Automatic and compare.')
    }
    foreach ($p in @($Sample.Processes | Where-Object { $_.Name -ne $Game -and $_.MemoryMB -ge 1024 } | Sort-Object MemoryMB -Descending | Select-Object -First 4)) {
        & $add (New-SFFinding 'Memory' $p.Name ('{0:N1} GB' -f ($p.MemoryMB / 1024)) 'INFO')
    }

    $h = $Sample.Hypervisor
    if (@($h.Features).Count -gt 0) {
        & $add (New-SFFinding 'Windows' 'Virtualization features' (@($h.Features) -join ', ') 'WARN' 'These keep Windows running on top of the hypervisor. If you don''t use virtual machines, WSL or Windows Sandbox, turn them off in "Turn Windows features on or off".')
    }
    if ($h.Hvci) {
        & $add (New-SFFinding 'Windows' 'Memory integrity' 'on' 'INFO' 'Left on by SteadyFrame on purpose: some anti-cheats need it, and it protects the PC. It costs a few percent in CPU-heavy games.')
    }
    foreach ($p in @($Sample.Processes | Where-Object { $_.Name -like 'vmmem*' -and $_.MemoryMB -ge 500 })) {
        & $add (New-SFFinding 'Windows' $p.Name ('{0:N1} GB' -f ($p.MemoryMB / 1024)) 'WARN' 'A virtual machine (WSL, Docker, Sandbox or an emulator) is running and holding memory.')
    }
    return $f.ToArray()
}

function Invoke-SFLiveCheck {
    param($Context, [int]$Seconds = 20, [int]$Countdown = 10, [string]$Game = '')
    Write-SFHeader 'What''s slowing my game?'
    Write-Host '  Have your game open. When the countdown ends, switch to it and play normally.'
    Write-Host ('  It measures for {0} seconds and beeps when it''s done.' -f $Seconds)
    Write-Host ''
    for ($i = $Countdown; $i -gt 0; $i--) {
        Write-Host ("`r  Starting in {0,2} s " -f $i) -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host "`r  Measuring...        "
    try { [console]::Beep(660, 150) } catch { }
    $sample = Get-SFLiveSample -Seconds $Seconds
    try { [console]::Beep(880, 400) } catch { }
    $known = @(Get-SFProp $Context 'GameExes' @())
    $findings = Get-SFLiveFindings -Sample $sample -Game $Game -KnownGames $known
    Write-SFDiagnostics $findings -NoBios
    return $findings
}

function Find-SFRunningGame {
    param($Context, [int]$Seconds = 3)
    $before = Get-SFGpuEngineRaw
    Start-Sleep -Seconds $Seconds
    $after = Get-SFGpuEngineRaw
    $names = @{}
    foreach ($p in Get-Process) { $names[$p.Id] = $p.ProcessName }
    $sample = [pscustomobject]@{ GpuByName = (Get-SFGpuUsageByName -Before $before -After $after -PidNames $names) }
    return (Find-SFGameInSample -Sample $sample -KnownGames @(Get-SFProp $Context 'GameExes' @()))
}
