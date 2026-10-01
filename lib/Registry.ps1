# Registry access through the .NET API (64-bit view) so values like
# 0xFFFFFFFF DWORDs, binary blobs and REG_EXPAND_SZ round-trip exactly.

$script:SFHiveMap = @{
    'HKLM' = 'LocalMachine'; 'HKEY_LOCAL_MACHINE' = 'LocalMachine'
    'HKCU' = 'CurrentUser'; 'HKEY_CURRENT_USER' = 'CurrentUser'
    'HKCR' = 'ClassesRoot'; 'HKEY_CLASSES_ROOT' = 'ClassesRoot'
    'HKU' = 'Users'; 'HKEY_USERS' = 'Users'
}
$script:SFHiveShort = @{ LocalMachine = 'HKLM'; CurrentUser = 'HKCU'; ClassesRoot = 'HKCR'; Users = 'HKU' }

# Accepts HKLM:\x, HKLM\x, HKEY_LOCAL_MACHINE\x, Registry::HKEY_LOCAL_MACHINE\x
function Split-SFRegistryPath {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path -replace '^(?i)Registry::', ''
    $p = $p -replace '/', '\'
    $m = [regex]::Match($p, '^(?<hive>[A-Za-z_]+):?\\?(?<sub>.*)$')
    if (-not $m.Success) { throw "Invalid registry path: $Path" }
    $hive = $script:SFHiveMap[$m.Groups['hive'].Value.ToUpperInvariant()]
    if (-not $hive) { throw "Unknown registry hive in path: $Path" }
    return [pscustomobject]@{ Hive = $hive; SubKey = $m.Groups['sub'].Value.Trim('\') }
}

function ConvertTo-SFRegistryKeyName {
    param([Parameter(Mandatory)][string]$Path)
    $s = Split-SFRegistryPath $Path
    return ($script:SFHiveShort[$s.Hive] + '\' + $s.SubKey)
}

function Get-SFBaseKey {
    param([Parameter(Mandatory)][string]$Hive)
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Test-SFRegistryKey {
    param([Parameter(Mandatory)][string]$Path)
    $s = Split-SFRegistryPath $Path
    $base = Get-SFBaseKey $s.Hive
    try {
        $k = $base.OpenSubKey($s.SubKey, $false)
        if ($k) { $k.Close(); return $true }
        return $false
    } catch { return $false }
    finally { $base.Close() }
}

# Serialized form used in the journal and for comparisons:
#   DWord -> unsigned number, QWord -> string, Binary -> hex string,
#   MultiString -> string array, String/ExpandString -> string
function ConvertTo-SFSerializedValue {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'DWord' { return [int64][BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Value), 0) }
        'QWord' { return ([int64]$Value).ToString() }
        'Binary' { return (ConvertTo-SFHex ([byte[]]$Value)) }
        'MultiString' { return ,([string[]]@($Value)) }
        default { return [string]$Value }
    }
}

function ConvertFrom-SFSerializedValue {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'DWord' {
            $u = [uint32]([int64]$Value)
            return [BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0)
        }
        'QWord' { return [int64]::Parse("$Value") }
        'Binary' { return ,([byte[]](ConvertFrom-SFHex ([string]$Value))) }
        'MultiString' { return ,([string[]]@($Value)) }
        default { return [string]$Value }
    }
}

function Get-SFRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [string]$Name = '')
    $s = Split-SFRegistryPath $Path
    $base = Get-SFBaseKey $s.Hive
    try {
        $k = $base.OpenSubKey($s.SubKey, $false)
        if (-not $k) { return [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = $null; Value = $null } }
        try {
            $exists = $false
            foreach ($n in $k.GetValueNames()) { if ($n -eq $Name) { $exists = $true; break } }
            if (-not $exists) { return [pscustomobject]@{ KeyExists = $true; Exists = $false; Kind = $null; Value = $null } }
            $kind = $k.GetValueKind($Name).ToString()
            $raw = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ KeyExists = $true; Exists = $true; Kind = $kind; Value = (ConvertTo-SFSerializedValue $raw $kind) }
        } finally { $k.Close() }
    } finally { $base.Close() }
}

# Returns the top-most key that had to be created ('' when the key already existed).
function Set-SFRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [string]$Name = '', [Parameter(Mandatory)][string]$Kind, $Value)
    $s = Split-SFRegistryPath $Path
    $base = Get-SFBaseKey $s.Hive
    try {
        $created = ''
        $parts = $s.SubKey.Split('\')
        $walk = ''
        foreach ($part in $parts) {
            $walk = if ($walk) { $walk + '\' + $part } else { $part }
            $probe = $base.OpenSubKey($walk, $false)
            if ($probe) { $probe.Close() }
            else { $created = $script:SFHiveShort[$s.Hive] + '\' + $walk; break }
        }
        $k = $base.CreateSubKey($s.SubKey, $true)
        try {
            $native = ConvertFrom-SFSerializedValue $Value $Kind
            if ($Kind -eq 'Binary') { $native = [byte[]]$native }
            elseif ($Kind -eq 'MultiString') { $native = [string[]]@($native) }
            $k.SetValue($Name, $native, [Microsoft.Win32.RegistryValueKind]$Kind)
        } finally { $k.Close() }
        return $created
    } finally { $base.Close() }
}

function Remove-SFRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [string]$Name = '')
    $s = Split-SFRegistryPath $Path
    $base = Get-SFBaseKey $s.Hive
    try {
        $k = $base.OpenSubKey($s.SubKey, $true)
        if ($k) { try { $k.DeleteValue($Name, $false) } finally { $k.Close() } }
    } finally { $base.Close() }
}

# Delete $Path and its parents up to and including $StopAt, but only while each is empty.
function Remove-SFEmptyRegistryKeys {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$StopAt)
    $s = Split-SFRegistryPath $Path
    $stop = (Split-SFRegistryPath $StopAt).SubKey
    if (-not $s.SubKey.StartsWith($stop, [StringComparison]::OrdinalIgnoreCase)) { return }
    $base = Get-SFBaseKey $s.Hive
    try {
        $current = $s.SubKey
        while ($current.Length -ge $stop.Length) {
            $k = $base.OpenSubKey($current, $false)
            if (-not $k) { break }
            $empty = ($k.SubKeyCount -eq 0 -and $k.ValueCount -eq 0)
            $k.Close()
            if (-not $empty) { break }
            $base.DeleteSubKey($current, $false)
            if ($current.Length -eq $stop.Length) { break }
            $idx = $current.LastIndexOf('\')
            if ($idx -lt 0) { break }
            $current = $current.Substring(0, $idx)
        }
    } finally { $base.Close() }
}

function Test-SFSerializedEqual {
    param($A, $B, [string]$Kind)
    if ($Kind -eq 'MultiString') { return ((@($A) -join "`n") -ceq (@($B) -join "`n")) }
    if ($Kind -eq 'DWord') { return ([int64]$A -eq [int64]$B) }
    if ($Kind -eq 'Binary') { return (("$A").ToLowerInvariant() -eq ("$B").ToLowerInvariant()) }
    return ("$A" -ceq "$B")
}
