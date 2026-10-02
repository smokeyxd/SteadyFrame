# Saved after every single entry, so a run that crashes halfway can still be undone.

function New-SFJournal {
    param([Parameter(Mandatory)][string]$Root, [hashtable]$Meta = @{})
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $Root ('{0}_{1}' -f $env:COMPUTERNAME, $stamp)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # not $meta: variable names are case-insensitive, that would overwrite the $Meta parameter
    $header = [ordered]@{
        Computer = $env:COMPUTERNAME
        User     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Started  = (Get-Date).ToString('o')
        Version  = (Get-SFVersion)
    }
    foreach ($k in @($Meta.Keys)) { $header[$k] = $Meta[$k] }
    $journal = [pscustomobject]@{
        Path    = (Join-Path $dir 'journal.json')
        Dir     = $dir
        Meta    = $header
        Entries = New-Object System.Collections.ArrayList
    }
    Save-SFJournal $journal
    return $journal
}

function Save-SFJournal {
    param([Parameter(Mandatory)]$Journal)
    $doc = [ordered]@{ Format = 1; Meta = $Journal.Meta; Entries = @($Journal.Entries) }
    Save-SFJson -Object $doc -Path $Journal.Path
}

function Add-SFJournalEntry {
    param(
        [Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)]$Target, $Before, $After
    )
    $entry = [pscustomobject][ordered]@{
        Seq     = $Journal.Entries.Count + 1
        Time    = (Get-Date).ToString('o')
        TweakId = $TweakId
        Type    = $Type
        Target  = $Target
        Before  = $Before
        After   = $After
    }
    [void]$Journal.Entries.Add($entry)
    Save-SFJournal $Journal
}

function Read-SFJournal {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Read-SFJson $Path
    return [pscustomobject]@{
        Path    = $Path
        Dir     = (Split-Path -Parent $Path)
        Meta    = $doc.Meta
        Entries = @($doc.Entries)
    }
}

# Newest first across all roots. 0.1.0 kept journals in the script folder's runs\, so that one is read too.
function Get-SFJournals {
    param([Parameter(Mandatory)][string[]]$Root)
    $seen = @{}
    $list = foreach ($r in $Root) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $r -Directory)) {
            $jp = Join-Path $d.FullName 'journal.json'
            if ($seen.ContainsKey($d.Name) -or -not (Test-Path -LiteralPath $jp)) { continue }
            try {
                $j = Read-SFJournal $jp
                $seen[$d.Name] = $true
                [pscustomobject]@{
                    Path     = $jp
                    Dir      = $d.FullName
                    Name     = $d.Name
                    Started  = (Get-SFProp $j.Meta 'Started' '')
                    Count    = @($j.Entries).Count
                    Reverted = (Test-Path -LiteralPath (Join-Path $d.FullName 'reverted.json'))
                }
            } catch { }
        }
    }
    return @($list | Sort-Object @{ Expression = { $_.Name -replace '^.*_(\d{8}-\d{6}).*$', '$1' } }, Name -Descending)
}

function Get-SFRunRoots {
    return @((Join-Path (Get-SFDataRoot) 'runs'), (Join-Path (Get-SFRoot) 'runs'))
}
