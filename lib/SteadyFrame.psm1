# Dot-sourced so everything shares one module scope.
# Keep every file ASCII-only: PS 5.1 reads BOM-less UTF-8 as ANSI and mangles it.

$script:SFLibRoot = $PSScriptRoot
$script:SFRoot = Split-Path -Parent $PSScriptRoot
$script:SFVersion = '0.1.2'

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
. (Join-Path $PSScriptRoot 'Update.ps1')
. (Join-Path $PSScriptRoot 'Engine.ps1')
. (Join-Path $PSScriptRoot 'Revert.ps1')
. (Join-Path $PSScriptRoot 'Menu.ps1')

Export-ModuleMember -Function *-SF*
