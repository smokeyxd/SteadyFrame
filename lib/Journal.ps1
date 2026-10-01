# Undo journal: every change records its "before" state the moment it is made,
# and the file is flushed after each entry so a crash mid-run is still revertible.

function New-SFJournal {
    param([Parameter(Mandatory)][string]$Root, [hashtable]$Meta = @{})
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $Root ('{0}_{1}' -f $env:COMPUTERNAME, $stamp)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # PowerShell variable names are case-insensitive, so this must not be called $meta.
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

# Newest first. Each item: Path, Dir, Name, Started, Count, Reverted
function Get-SFJournals {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $list = foreach ($d in (Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name -Descending)) {
        $jp = Join-Path $d.FullName 'journal.json'
        if (-not (Test-Path -LiteralPath $jp)) { continue }
        try {
            $j = Read-SFJournal $jp
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
    return @($list)
}
