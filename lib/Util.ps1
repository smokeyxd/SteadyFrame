function Get-SFVersion { $script:SFVersion }

function Get-SFRoot { $script:SFRoot }

# Undo journals live here and not next to the script, so deleting the SteadyFrame folder or
# unzipping a newer version somewhere else doesn't lose the way back.
# Not $env:ProgramData: users can set their own environment variables, and elevated processes see them.
function Get-SFDataRoot {
    $common = [Environment]::GetFolderPath('CommonApplicationData')
    if (-not $common) { return (Get-SFRoot) }
    return (Join-Path $common 'SteadyFrame')
}

# Administrators, SYSTEM, TrustedInstaller
$script:SFTrustedOwners = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')

function Test-SFAdminOwned {
    param([Parameter(Mandatory)][string]$Path)
    try { $owner = (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value }
    catch { return $false }
    return ($script:SFTrustedOwners -contains $owner)
}

# Admins and SYSTEM can write, users can only read: Revert runs elevated and replays these
# files, so a normal process must not be able to slip entries into them.
# Normal users can create folders in ProgramData too. If one made this folder before SteadyFrame
# did, they own it and could have put journals in it, so it gets moved aside, never reused.
function Initialize-SFDataRoot {
    $dir = Get-SFDataRoot
    if ((Test-Path -LiteralPath $dir) -and -not (Test-SFAdminOwned $dir)) {
        $aside = '{0}.untrusted-{1}' -f (Split-Path -Leaf $dir), (Get-Date -Format 'yyyyMMdd-HHmmss')
        try { Rename-Item -LiteralPath $dir -NewName $aside -ErrorAction Stop }
        catch { throw "$dir wasn't created by SteadyFrame (Administrators don't own it) and can't be moved aside. Delete it and run SteadyFrame again." }
        Write-SFStatus 'WARN' "$dir wasn't created by SteadyFrame, moved it to $aside"
    }
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($ace in @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-18', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier $ace[0]
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule $sid, $ace[1], $inherit, 'None', 'Allow'))
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir, $sec)
        # already the default owner for elevated admins, unless a policy changed that
        try {
            $acl = Get-Acl -LiteralPath $dir
            $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
            Set-Acl -LiteralPath $dir -AclObject $acl
        } catch { }
    }
    else { try { [System.IO.Directory]::SetAccessControl($dir, $sec) } catch { } }
    return $dir
}

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
        OK = 'Green'; APPLIED = 'White'; DRYRUN = 'White'; INFO = 'Gray'; SAME = 'DarkGray'
        WARN = 'Yellow'; SKIP = 'DarkGray'; BAD = 'Red'; FAIL = 'Red'; BLOCKED = 'Red'
    }
    $c = $colors[$Status]
    if (-not $c) { $c = 'Gray' }
    # one Write-Host per line: with -NoNewline, the PS 5.1 transcript splits the line in two
    Write-Host (('  [{0,-7}] ' -f $Status) + $Text) -ForegroundColor $c
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
    if ($Value -is [bool]) { if ($Value) { return 'on' } return 'off' }
    if ($Value -is [System.Array]) { return ('[' + (($Value | ForEach-Object { "$_" }) -join ', ') + ']') }
    return "$Value"
}
