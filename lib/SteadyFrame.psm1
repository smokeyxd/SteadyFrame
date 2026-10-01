# SteadyFrame engine module.
# Every component lives in its own .ps1 file and is dot-sourced here so all
# functions share one module scope and can call each other freely.
# Windows PowerShell 5.1 compatible: keep these files ASCII-only.

$script:SFLibRoot = $PSScriptRoot
$script:SFRoot = Split-Path -Parent $PSScriptRoot
$script:SFVersion = '0.1.0'

. (Join-Path $PSScriptRoot 'Util.ps1')
. (Join-Path $PSScriptRoot 'Guard.ps1')
. (Join-Path $PSScriptRoot 'Journal.ps1')
. (Join-Path $PSScriptRoot 'Registry.ps1')
. (Join-Path $PSScriptRoot 'Context.ps1')
. (Join-Path $PSScriptRoot 'Actions.ps1')
. (Join-Path $PSScriptRoot 'Startup.ps1')
. (Join-Path $PSScriptRoot 'Games.ps1')
. (Join-Path $PSScriptRoot 'Catalog.ps1')
. (Join-Path $PSScriptRoot 'Diagnostics.ps1')
. (Join-Path $PSScriptRoot 'External.ps1')
. (Join-Path $PSScriptRoot 'Engine.ps1')
. (Join-Path $PSScriptRoot 'Revert.ps1')
. (Join-Path $PSScriptRoot 'Menu.ps1')

Export-ModuleMember -Function *-SF*
