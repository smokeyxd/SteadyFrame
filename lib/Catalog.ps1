# Tweak catalog: load, validate, check applicability, resolve a selection.
# Tiers: A = proven / vendor-documented, B = situational, C = weak evidence,
# placebo or cosmetic (Advanced only, never in a preset).

$script:SFKnownActions = @('Registry', 'RegistryToken', 'Service', 'PowerScheme', 'PowerSetting', 'Hibernate', 'Bcd',
    'ScheduledTask', 'NetAdapterProperty', 'MMAgent', 'Pagefile', 'StartupReview', 'Cs2Autoexec')
$script:SFPresets = @('HighEnd', 'MidRange', 'Minimal')
$script:SFUpdatePolicyMap = @{ Leave = 'updates.leave'; DeferFeature = 'updates.defer-feature'; SecurityOnly = 'updates.security-only' }

function Import-SFCatalog {
    param([string]$Dir = (Join-Path (Get-SFRoot) 'catalog'))
    $tweaks = @()
    $index = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Dir -Filter '*.json' | Sort-Object Name)) {
        $doc = Read-SFJson $f.FullName
        $catOrder = [int](Get-SFProp $doc 'order' 100)
        foreach ($t in @($doc.tweaks)) {
            $t | Add-Member -NotePropertyName category -NotePropertyValue $doc.category -Force
            $t | Add-Member -NotePropertyName categoryOrder -NotePropertyValue $catOrder -Force
            $t | Add-Member -NotePropertyName sourceFile -NotePropertyValue $f.Name -Force
            $t | Add-Member -NotePropertyName fileIndex -NotePropertyValue ($index++) -Force
            $tweaks += $t
        }
    }
    # Sort-Object is not stable in PS 5.1, so file order is the final tie-breaker.
    return @($tweaks | Sort-Object categoryOrder, @{ Expression = { [int](Get-SFProp $_ 'order' 100) } }, fileIndex)
}

# Returns a list of problems (empty = valid).
function Test-SFCatalog {
    param([Parameter(Mandatory)]$Catalog)
    $errors = @()
    $ids = @{}
    foreach ($t in $Catalog) {
        $id = Get-SFProp $t 'id'
        if (-not $id) { $errors += "tweak without id in $($t.sourceFile)"; continue }
        if ($ids.ContainsKey($id)) { $errors += "duplicate id $id" }
        $ids[$id] = $true
        foreach ($field in @('name', 'why', 'tier')) { if (-not (Get-SFProp $t $field)) { $errors += "$id missing '$field'" } }
        $tier = Get-SFProp $t 'tier'
        if ($tier -notin @('A', 'B', 'C')) { $errors += "$id has invalid tier '$tier'" }
        foreach ($p in @(Get-SFProp $t 'presets' @())) { if ($p -notin $script:SFPresets) { $errors += "$id unknown preset '$p'" } }
        if ($tier -eq 'C' -and @(Get-SFProp $t 'presets' @()).Count -gt 0) { $errors += "$id is tier C but sits in a preset (C is Advanced-only)" }
        $actions = @(Get-SFProp $t 'actions' @())
        if ($actions.Count -eq 0 -and (Get-SFProp $t 'group') -ne 'updatePolicy') { $errors += "$id has no actions" }
        foreach ($a in $actions) {
            $type = Get-SFProp $a 'type'
            if ($type -notin $script:SFKnownActions) { $errors += "$id unknown action type '$type'" }
            if ($type -in @('Registry', 'RegistryToken')) {
                $path = "$(Get-SFProp $a 'path')"
                if ($path -notmatch '\{') {
                    $why = Test-SFRegistryWrite -Path $path -Name (Get-SFProp $a 'name' '') -Value (Get-SFProp $a 'value') -Delete:([bool](Get-SFProp $a 'delete' $false))
                    if ($why) { $errors += "$id blocked by Guard: $why" }
                }
            }
            if ($type -eq 'Service') {
                $why = Test-SFServiceWrite -Name (Get-SFProp $a 'name') -StartType (Get-SFProp $a 'startType')
                if ($why) { $errors += "$id blocked by Guard: $why" }
            }
            if ($type -eq 'Bcd') {
                $why = Test-SFBcdWrite -Setting (Get-SFProp $a 'setting') -Value "$(Get-SFProp $a 'value' '')" -Delete:([bool](Get-SFProp $a 'delete' $false))
                if ($why) { $errors += "$id blocked by Guard: $why" }
            }
            foreach ($r in @(Get-SFProp $a 'requires' @())) { $errors += (Test-SFRequirementName $id $r) }
        }
        foreach ($r in @(Get-SFProp $t 'requires' @())) { $errors += (Test-SFRequirementName $id $r) }
    }
    return @($errors | Where-Object { $_ })
}

function Test-SFRequirementName {
    param([string]$Id, [string]$Name)
    $n = $Name.TrimStart('!')
    $known = '^(Win10|Win11|MinBuild:\d+|Desktop|Laptop|DualCcdX3D|HomeEdition|SsdOnly|Printer|GamePass|Ram16Plus|BitLocker|GameExe|GameDetected|Game:[\w-]+|Nvidia|Leftover:\w+)$'
    if ($n -notmatch $known) { return "$Id unknown requirement '$Name'" }
    return $null
}

# Applies = all tweak-level requirements pass. Reason explains why not.
function Get-SFApplicability {
    param([Parameter(Mandatory)]$Tweak, [Parameter(Mandatory)]$Context)
    foreach ($r in @(Get-SFProp $Tweak 'requires' @())) {
        if (-not (Test-SFRequirement $r $Context)) {
            return [pscustomobject]@{ Applies = $false; Reason = (Get-SFRequirementText $r) }
        }
    }
    return [pscustomobject]@{ Applies = $true; Reason = '' }
}

# Builds the working list: every tweak with Applies/Reason/Selected/Visible.
function Resolve-SFSelection {
    param(
        [Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$Context,
        [ValidateSet('HighEnd', 'MidRange', 'Minimal', 'Custom')][string]$Preset = 'HighEnd',
        [string[]]$Include = @(), [string[]]$Exclude = @(),
        [ValidateSet('Leave', 'DeferFeature', 'SecurityOnly')][string]$UpdatePolicy = 'DeferFeature',
        [switch]$ShowAll
    )
    $basePreset = if ($Preset -eq 'Custom') { $Context.SuggestedPreset } else { $Preset }
    $policyId = $script:SFUpdatePolicyMap[$UpdatePolicy]
    $rows = foreach ($t in $Catalog) {
        $app = Get-SFApplicability $t $Context
        $id = $t.id
        $group = Get-SFProp $t 'group'
        $sel = ($basePreset -in @(Get-SFProp $t 'presets' @()))
        if ($group -eq 'updatePolicy') { $sel = ($id -eq $policyId) }
        if ($Include -contains $id) { $sel = $true }
        if ($Exclude -contains $id) { $sel = $false }
        if (-not $app.Applies) { $sel = $false }
        # Leftover fixes only matter when the leftover exists; otherwise they are just clutter.
        $isFix = (@(Get-SFProp $t 'requires' @()) | Where-Object { $_ -like 'Leftover:*' }).Count -gt 0
        [pscustomobject]@{
            Id = $id; Tweak = $t; Tier = $t.tier; Category = $t.category; Group = $group
            Applies = $app.Applies; Reason = $app.Reason; Selected = $sel
            Visible = (($ShowAll -or ($t.tier -ne 'C' -and -not [bool](Get-SFProp $t 'advanced' $false)) -or $sel) -and -not ($isFix -and -not $app.Applies))
        }
    }
    return @($rows)
}

function Invoke-SFTweak {
    param([Parameter(Mandatory)]$Tweak, [Parameter(Mandatory)]$Context, $Journal, [switch]$DryRun, [switch]$Interactive)
    $results = @()
    foreach ($a in @(Get-SFProp $Tweak 'actions' @())) {
        $results += @(Invoke-SFAction -Action $a -TweakId $Tweak.id -Context $Context -Journal $Journal -DryRun:$DryRun -Interactive:$Interactive)
    }
    return $results
}

function Export-SFCatalogJson {
    param([Parameter(Mandatory)]$Catalog, $Context)
    $out = foreach ($t in $Catalog) {
        $app = if ($Context) { Get-SFApplicability $t $Context } else { $null }
        [ordered]@{
            id = $t.id; name = $t.name; category = $t.category; tier = $t.tier; why = $t.why
            breaks = (Get-SFProp $t 'breaks' ''); source = (Get-SFProp $t 'source' '')
            presets = @(Get-SFProp $t 'presets' @()); group = (Get-SFProp $t 'group')
            requires = @(Get-SFProp $t 'requires' @())
            appliesHere = $(if ($app) { $app.Applies } else { $null }); reason = $(if ($app) { $app.Reason } else { $null })
        }
    }
    return (ConvertTo-Json -InputObject @($out) -Depth 6)
}
