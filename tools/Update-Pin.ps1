<#
.SYNOPSIS
    Pin WinUtil or Win11Debloat to a specific release: downloads it, prints the SHA256,
    and (with -Write) updates external\pins.json.

.DESCRIPTION
    Read the release notes / diff of the new version BEFORE pinning it; the pin is your
    statement that you reviewed what will run on your friends' PCs. Also re-check
    external\winutil.json and external\win11debloat.json: option names can change.

.EXAMPLE
    .\tools\Update-Pin.ps1 -Tool winutil -Tag 26.09.02
.EXAMPLE
    .\tools\Update-Pin.ps1 -Tool win11debloat -Tag 2026.09.10 -Write
#>
param(
    [Parameter(Mandatory)][ValidateSet('winutil', 'win11debloat')][string]$Tool,
    [Parameter(Mandatory)][string]$Tag,
    [switch]$Write
)
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\SteadyFrame.psm1') -Force -DisableNameChecking

if ($Tool -eq 'winutil') {
    $url = 'https://github.com/ChrisTitusTech/winutil/releases/download/{0}/winutil.ps1' -f $Tag
    $file = 'winutil-{0}.ps1' -f $Tag
    $api = 'https://api.github.com/repos/ChrisTitusTech/winutil/releases/tags/{0}' -f $Tag
} else {
    $url = 'https://github.com/Raphire/Win11Debloat/archive/refs/tags/{0}.zip' -f $Tag
    $file = 'win11debloat-{0}.zip' -f $Tag
    $api = $null
}

$tmp = Join-Path $env:TEMP ('steadyframe-pin-' + $file)
Invoke-SFDownload -Url $url -OutFile $tmp
$hash = Get-SFFileSha256 $tmp
Remove-Item -LiteralPath $tmp -Force
Write-Host ('{0} {1}' -f $Tool, $Tag)
Write-Host ('  url    {0}' -f $url)
Write-Host ('  sha256 {0}' -f $hash)

if ($api) {
    try {
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -ErrorAction Stop
        $asset = @($rel.assets | Where-Object { $_.name -eq 'winutil.ps1' })[0]
        $digest = "$($asset.digest)" -replace '^sha256:', ''
        if ($digest) {
            if ($digest -eq $hash) { Write-Host '  GitHub release digest matches.' -ForegroundColor Green }
            else { Write-Host ('  WARNING: GitHub digest is {0} - does NOT match!' -f $digest) -ForegroundColor Red; exit 1 }
        }
    } catch { Write-Host '  (could not read GitHub release digest)' -ForegroundColor DarkGray }
}

if ($Write) {
    $pinsPath = Join-Path $root 'external\pins.json'
    $pins = Read-SFJson $pinsPath
    $p = $pins.$Tool
    $p.tag = $Tag
    $p.url = $url
    $p.sha256 = $hash
    $p.file = $file
    $p.reviewed = (Get-Date -Format 'yyyy-MM-dd')
    Save-SFJson -Object $pins -Path $pinsPath
    Write-Host ('  pins.json updated. Re-check external\{0}.json option names against this release.' -f $Tool) -ForegroundColor Yellow
}
