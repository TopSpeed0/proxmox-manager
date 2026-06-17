<#
.SYNOPSIS  Proxmox VE Manager — interactive console (mirrors VMware_Manager.ps1 structure)
.DESCRIPTION
    Load all PVE modules and provide quick access functions.
    For non-interactive / AI use: dot-source this file then call functions directly.

.EXAMPLE
    # Non-interactive (AI/skill pattern)
    . .\proxmox-manager.ps1
    Connect-PVECluster -Name THC
    Get-PVEVMs -ClusterName THC -Name 'THC*'
    Get-PVEVMsByStorage -ClusterName THC | Format-Table -AutoSize
#>

$ErrorActionPreference = 'Stop'
$ScriptDir  = $PSScriptRoot
$ModulePath = Join-Path $ScriptDir 'Modules'

# Load all PVE modules
Get-ChildItem -Path $ModulePath -Filter '*.psm1' | ForEach-Object {
    Import-Module $_.FullName -Force -DisableNameChecking -Global
}

# Suppress TLS cert warnings globally
[System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12

Write-Host ""
Write-Host "  ██████╗ ██╗   ██╗███████╗" -ForegroundColor Cyan
Write-Host "  ██╔══██╗██║   ██║██╔════╝" -ForegroundColor Cyan
Write-Host "  ██████╔╝██║   ██║█████╗  " -ForegroundColor Cyan
Write-Host "  ██╔═══╝ ╚██╗ ██╔╝██╔══╝  " -ForegroundColor Cyan
Write-Host "  ██║      ╚████╔╝ ███████╗ Manager" -ForegroundColor Cyan
Write-Host "  ╚═╝       ╚═══╝  ╚══════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Modules loaded: $(Get-ChildItem $ModulePath -Filter '*.psm1' | Measure-Object | Select-Object -Expand Count)" -ForegroundColor Gray
Write-Host "  Clusters: $((Get-PVEClusterList | Select-Object -Expand Name) -join ', ')" -ForegroundColor Gray
Write-Host ""
$firstCluster = (Get-PVEClusterList | Select-Object -First 1).Name
# First-time setup hint
if (-not (Test-Path (Join-Path $PSScriptRoot "Config\nodes.json"))) {
    Write-Host "  ⚠️  No Config/nodes.json found — run the setup wizard:" -ForegroundColor Yellow
    Write-Host "    . .\New-PVEConfig.ps1           # interactive wizard" -ForegroundColor White
    Write-Host "    . .\New-PVEConfig.ps1 -Skip     # write generic template" -ForegroundColor White
    Write-Host ""
}

# Auto-connect all clusters from nodes.json
Write-Host "  Connecting to clusters..." -ForegroundColor DarkGray
$allClusters = Get-PVEClusterList
foreach ($cl in $allClusters) {
    try {
        Connect-PVECluster -Name $cl.Name
    } catch {
        Write-Host "  ⚠️  Could not connect to $($cl.Name): $_" -ForegroundColor Yellow
    }
}
Write-Host ""

Write-Host "  Quick start:" -ForegroundColor Yellow
Write-Host "    Connect-PVECluster -Name $firstCluster" -ForegroundColor White
Write-Host "    Get-PVEVMs -ClusterName $firstCluster -Name 'THC*'" -ForegroundColor White
Write-Host "    Get-PVEStorage -ClusterName $firstCluster" -ForegroundColor White
Write-Host "    Get-PVEVMsByStorage -ClusterName $firstCluster | Format-Table -AutoSize" -ForegroundColor White
Write-Host ""
