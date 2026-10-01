# Runs WinUtil tweaks one at a time and waits for each one.
# WinUtil 26.08.19's own -Config mode hands the tweaks to a background runspace, waits
# 100 ms, and if the runspace hasn't flagged itself busy yet it prints "Done." and closes
# the pool. On a normal PC that means nothing gets applied, with exit code 0.
# This file is started as its own powershell.exe process by Invoke-SFWinUtil.
param(
    [Parameter(Mandatory)][string]$WinUtilPath,
    [Parameter(Mandatory)][string]$ConfigFile,
    [Parameter(Mandatory)][string]$TweakIds,
    [Parameter(Mandatory)][string]$ResultFile
)

# Dot-sourced so WinUtil's functions and $sync are still loaded after it returns. Its own
# -Config pass runs first; whatever it manages to do is simply done again below.
. $WinUtilPath -Config $ConfigFile

$sfResults = @()
foreach ($sfId in ($TweakIds -split ',' | Where-Object { $_ })) {
    if (-not $sync.configs.tweaks.$sfId) {
        $sfResults += [pscustomobject]@{ Id = $sfId; Ok = $false; Errors = 0; Message = 'not in this WinUtil version' }
        continue
    }
    $errorsBefore = $Error.Count
    try {
        Invoke-WinUtilTweaks $sfId
        $sfResults += [pscustomobject]@{ Id = $sfId; Ok = $true; Errors = ($Error.Count - $errorsBefore); Message = '' }
    } catch {
        $sfResults += [pscustomobject]@{ Id = $sfId; Ok = $false; Errors = ($Error.Count - $errorsBefore); Message = $_.Exception.Message }
    }
}

$json = ConvertTo-Json -InputObject ([ordered]@{ Results = @($sfResults) }) -Depth 4
[IO.File]::WriteAllText($ResultFile, $json, (New-Object System.Text.UTF8Encoding $false))
exit (@($sfResults | Where-Object { -not $_.Ok }).Count)
