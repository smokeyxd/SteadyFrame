function Get-SFVersion { $script:SFVersion }

function Get-SFRoot { $script:SFRoot }

# Most catalog/journal fields are optional; this works on JSON objects and hashtables alike.
function Get-SFProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Read-SFJson {
    param([Parameter(Mandatory)][string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

# no BOM: most JSON readers outside PowerShell trip over it
function Save-SFJson {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Test-SFAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-SFHeader {
    param([string]$Text)
    Write-Host ''
    Write-Host ('== ' + $Text + ' ') -ForegroundColor White
}

function Write-SFStatus {
    param([string]$Status, [string]$Text)
    $colors = @{
        OK = 'Green'; APPLIED = 'Green'; DRYRUN = 'White'; INFO = 'Gray'; SAME = 'DarkGray'
        WARN = 'Yellow'; SKIP = 'DarkGray'; BAD = 'Red'; FAIL = 'Red'; BLOCKED = 'Red'
    }
    $c = $colors[$Status]
    if (-not $c) { $c = 'Gray' }
    Write-Host ('  [{0,-7}] ' -f $Status) -ForegroundColor $c -NoNewline
    Write-Host $Text
}

function ConvertTo-SFHex {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { return '' }
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertFrom-SFHex {
    param([string]$Hex)
    if ([string]::IsNullOrEmpty($Hex)) { return ,([byte[]]@()) }
    $clean = $Hex -replace '[^0-9a-fA-F]', ''
    $bytes = New-Object byte[] ($clean.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($clean.Substring($i * 2, 2), 16)
    }
    return ,$bytes
}

function New-SFResult {
    param(
        [string]$TweakId, [string]$Action, [string]$Target,
        [ValidateSet('Applied', 'DryRun', 'AlreadySet', 'Skipped', 'Blocked', 'Failed')][string]$Status,
        [string]$Message = '', $Before = $null, $After = $null, [switch]$Quiet
    )
    # Quiet: "not on this PC" noise, like an adapter without that setting. Still in summary.json,
    # just not printed or counted.
    [pscustomobject]@{
        TweakId = $TweakId; Action = $Action; Target = $Target; Status = $Status
        Message = $Message; Before = $Before; After = $After; Quiet = [bool]$Quiet
    }
}

function Format-SFValue {
    param($Value)
    if ($null -eq $Value) { return '(not set)' }
    if ($Value -is [System.Array]) { return ('[' + (($Value | ForEach-Object { "$_" }) -join ', ') + ']') }
    return "$Value"
}
