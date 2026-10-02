# Deliberately not a real auto-updater: it never replaces or runs anything by itself. SteadyFrame
# runs as admin, so swapping its own code would hand whoever controls the GitHub account every PC.

$script:SFRepo = 'smokeyxd/SteadyFrame'

function Test-SFNewerVersion {
    param([string]$Latest, [string]$Current)
    $l = $null; $c = $null
    if (-not [version]::TryParse("$Latest".TrimStart('v'), [ref]$l)) { return $false }
    if (-not [version]::TryParse("$Current".TrimStart('v'), [ref]$c)) { return $false }
    return ($l -gt $c)
}

function Get-SFLatestRelease {
    param([int]$TimeoutSec = 4)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri ('https://api.github.com/repos/{0}/releases/latest' -f $script:SFRepo) -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch { return $null }
    $version = "$($rel.tag_name)".TrimStart('v')
    $parsed = $null
    if (-not [version]::TryParse($version, [ref]$parsed)) { return $null }
    $asset = @($rel.assets | Where-Object { $_.name -eq ('SteadyFrame-{0}.zip' -f $version) }) | Select-Object -First 1
    return [pscustomobject]@{ Version = $version; Url = "$($rel.html_url)"; Notes = "$($rel.body)"; Asset = $asset }
}

function Get-SFUpdate {
    $rel = Get-SFLatestRelease
    if ($rel -and (Test-SFNewerVersion $rel.Version (Get-SFVersion))) { return $rel }
    return $null
}

# text from the web: control characters go, so it can't send escape codes to the console
function Format-SFReleaseNotes {
    param([string]$Text, [int]$MaxLines = 14)
    $lines = @(("$Text" -replace "`r", '') -split "`n" | ForEach-Object {
            ($_ -replace '[\x00-\x08\x0B-\x1F\x7F]', '' -replace '\*\*|`', '' -replace '^#+\s*', '').TrimEnd()
        } | Where-Object { $_ -ne '' })
    if ($lines.Count -gt $MaxLines) { $lines = @($lines[0..($MaxLines - 1)]) + '...' }
    return $lines
}

# The checksum GitHub lists only catches a broken download, not a compromised account. That's
# the same trust as downloading the zip by hand.
function Install-SFUpdate {
    param([Parameter(Mandatory)]$Release, [string]$Parent = (Split-Path -Parent (Get-SFRoot)))
    if (-not $Release.Asset) { throw ('Release {0} has no SteadyFrame-{0}.zip. Download it from {1}' -f $Release.Version, $Release.Url) }
    $dest = Join-Path $Parent ('SteadyFrame-' + $Release.Version)
    if (Test-Path -LiteralPath $dest) { throw "$dest already exists. Use that folder, or delete it and try again." }
    $zip = Join-Path $env:TEMP ('SteadyFrame-update-{0}.zip' -f [guid]::NewGuid().ToString('N'))
    $work = $dest + '.part'
    try {
        Invoke-SFDownload -Url $Release.Asset.browser_download_url -OutFile $zip
        $hash = Get-SFFileSha256 $zip
        $expected = ("$(Get-SFProp $Release.Asset 'digest' '')" -replace '^sha256:', '').ToLowerInvariant()
        if ($expected -and $hash -ne $expected) { throw "Checksum mismatch: GitHub lists $expected, the download is $hash. Nothing was installed." }
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
        $inner = Join-Path $work 'SteadyFrame'
        if (-not (Test-Path -LiteralPath (Join-Path $inner 'SteadyFrame.ps1'))) { throw 'The downloaded zip does not look like a SteadyFrame release. Nothing was installed.' }
        Move-Item -LiteralPath $inner -Destination $dest
        # health reports and 0.1.0 undo lists still live in the old folder
        $oldRuns = Join-Path (Get-SFRoot) 'runs'
        if (Test-Path -LiteralPath $oldRuns) { Copy-Item -LiteralPath $oldRuns -Destination $dest -Recurse -Force }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Path = $dest; Sha256 = $hash; Checked = [bool]$expected }
}
