# Run-AllTests.ps1 — dot-source proxmox-manager, run every PVE function, save to out/
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutDir  = Join-Path $WorkDir "out"
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# Load modules directly (bypass proxmox-manager.ps1 which has parse issues with emoji)
$ModulePath = Join-Path $WorkDir "Modules"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
Get-ChildItem -Path $ModulePath -Filter '*.psm1' | ForEach-Object {
    Import-Module $_.FullName -Force -DisableNameChecking -Global
}
Connect-PVECluster -Name "THC"

$Cluster     = "THC"
$SampleVM    = $null
$SampleNode  = $null
$StorageName = $null
$StorageNode = $null

function Save-Output($Name, $Data) {
    $path = Join-Path $OutDir "$Name.txt"
    if ($Data -is [System.Array] -or $Data -is [System.Collections.IEnumerable]) {
        $text = $Data | Format-Table -AutoSize | Out-String
        if ($text.Trim().Length -eq 0) { $text = $Data | Format-List | Out-String }
    } else {
        $text = $Data | Format-List | Out-String
    }
    if ($text.Trim().Length -eq 0) { $text = "(empty result)" }
    $text | Out-File -FilePath $path -Encoding utf8 -Force
    $lines = ($text -split "`n").Count
    Write-Host "  [SAVED] $Name.txt  ($lines lines)"
}

function Run-Test($Name, [scriptblock]$Block) {
    Write-Host "`nRunning: $Name ..."
    try {
        $result = & $Block
        if ($null -eq $result -or ($result -is [string] -and $result.Trim().Length -eq 0)) {
            Save-Output $Name "(null / empty)"
        } else {
            Save-Output $Name $result
        }
    } catch {
        $errText = "ERROR: $_`n$($_.ScriptStackTrace)"
        $errText | Out-File -FilePath (Join-Path $OutDir "$Name.txt") -Encoding utf8 -Force
        Write-Host "  [ERROR] $_" -ForegroundColor Red
    }
}

# ─── 1. Nodes ────────────────────────────────
Run-Test "Get-PVENodes" {
    $nodes = Get-PVENodes -ClusterName $Cluster
    $script:SampleNode = ($nodes | Where-Object { $_.Status -eq 'online' } | Select-Object -First 1).Node
    Write-Host "  SampleNode: $script:SampleNode"
    $nodes
}

# ─── 2. VMs ──────────────────────────────────
Run-Test "Get-PVEVMs" {
    $vms = Get-PVEVMs -ClusterName $Cluster
    $script:SampleVM = ($vms | Where-Object { $_.Status -eq 'running' } | Sort-Object MemGB -Desc | Select-Object -First 1).Name
    Write-Host "  SampleVM: $script:SampleVM"
    $vms | Sort-Object MemGB -Descending
}

# ─── 3. VMDisk ───────────────────────────────
Run-Test "Get-PVEVMDisk" {
    if ($script:SampleVM) { Get-PVEVMDisk -ClusterName $Cluster -VMIDorName $script:SampleVM }
    else { "No running VM found" }
}

# ─── 4. VMsByStorage ─────────────────────────
Run-Test "Get-PVEVMsByStorage" {
    Get-PVEVMsByStorage -ClusterName $Cluster
}

# ─── 5. Storage ──────────────────────────────
Run-Test "Get-PVEStorage" {
    $st = Get-PVEStorage -ClusterName $Cluster
    $sample = $st | Where-Object { $_.Node } | Select-Object -First 1
    if ($sample) {
        $script:StorageName = $sample.Storage
        $script:StorageNode = $sample.Node
        Write-Host "  StorageSample: $script:StorageNode / $script:StorageName"
    }
    $st
}

# ─── 6. VMPowerState ─────────────────────────
Run-Test "Get-PVEVMPowerState" {
    if ($script:SampleVM) { Get-PVEVMPowerState -ClusterName $Cluster -Name $script:SampleVM }
    else { "No running VM found" }
}

# ─── 7. Snapshots ────────────────────────────
Run-Test "Get-PVESnapshots" {
    Get-PVESnapshots -ClusterName $Cluster -VMIDorName $script:SampleVM
}

# ─── 8. VMConfig ─────────────────────────────
Run-Test "Get-PVEVMConfig" {
    if ($script:SampleVM) { Get-PVEVMConfig -ClusterName $Cluster -VMIDorName $script:SampleVM }
    else { "No running VM found" }
}

# ─── 9. VMStatus ─────────────────────────────
Run-Test "Get-PVEVMStatus" {
    if ($script:SampleVM) { Get-PVEVMStatus -ClusterName $Cluster -VMIDorName $script:SampleVM }
    else { "No running VM found" }
}

# ─── 10. ClusterResources ────────────────────
Run-Test "Get-PVEClusterResources" {
    Get-PVEClusterResources -ClusterName $Cluster
}

# ─── 11. LXCList ─────────────────────────────
Run-Test "Get-PVELXCList" {
    Get-PVELXCList -ClusterName $Cluster
}

# ─── 12. NodeStatus ──────────────────────────
Run-Test "Get-PVENodeStatus" {
    if ($script:SampleNode) { Get-PVENodeStatus -ClusterName $Cluster -Node $script:SampleNode }
    else { "No online node found" }
}

# ─── 13. NodeNetwork ─────────────────────────
Run-Test "Get-PVENodeNetwork" {
    if ($script:SampleNode) { Get-PVENodeNetwork -ClusterName $Cluster -Node $script:SampleNode }
    else { "No online node found" }
}

# ─── 14. NodeDisks ───────────────────────────
Run-Test "Get-PVENodeDisks" {
    if ($script:SampleNode) { Get-PVENodeDisks -ClusterName $Cluster -Node $script:SampleNode }
    else { "No online node found" }
}

# ─── 15. StorageContent ──────────────────────
Run-Test "Get-PVEStorageContent" {
    if ($script:StorageNode -and $script:StorageName) {
        Get-PVEStorageContent -ClusterName $Cluster -Node $script:StorageNode -StorageName $script:StorageName |
            Select-Object -First 30
    } else { "No storage sample found" }
}

# ─── 16. ClusterTasks ────────────────────────
Run-Test "Get-PVEClusterTasks" {
    Get-PVEClusterTasks -ClusterName $Cluster
}

# ─── 17. BackupJobs ──────────────────────────
Run-Test "Get-PVEBackupJobs" {
    Get-PVEBackupJobs -ClusterName $Cluster
}

# ─── 18. HAStatus ────────────────────────────
Run-Test "Get-PVEHAStatus" {
    Get-PVEHAStatus -ClusterName $Cluster
}

# ─── 19. ReplicationJobs ─────────────────────
Run-Test "Get-PVEReplicationJobs" {
    Get-PVEReplicationJobs -ClusterName $Cluster
}

# ─── 20. FirewallRules ───────────────────────
Run-Test "Get-PVEFirewallRules" {
    if ($script:SampleNode) { Get-PVEFirewallRules -ClusterName $Cluster -Node $script:SampleNode }
    else { "No online node found" }
}

# ─── 21. VMAgent ─────────────────────────────
Run-Test "Get-PVEVMAgent" {
    if ($script:SampleVM) { Get-PVEVMAgent -ClusterName $Cluster -VMIDorName $script:SampleVM }
    else { "No running VM found" }
}

# ─── 22. VMRRDData ───────────────────────────
Run-Test "Get-PVEVMRRDData" {
    if ($script:SampleVM) {
        Get-PVEVMRRDData -ClusterName $Cluster -VMIDorName $script:SampleVM -Timeframe hour |
            Select-Object -Last 10
    } else { "No running VM found" }
}

# ─── 23. NodeRRDData ─────────────────────────
Run-Test "Get-PVENodeRRDData" {
    if ($script:SampleNode) {
        Get-PVENodeRRDData -ClusterName $Cluster -Node $script:SampleNode -Timeframe hour |
            Select-Object -Last 10
    } else { "No online node found" }
}

# ─── 24. NodeServices ────────────────────────
Run-Test "Get-PVENodeServices" {
    if ($script:SampleNode) { Get-PVENodeServices -ClusterName $Cluster -Node $script:SampleNode }
    else { "No online node found" }
}

# ─── 25. NodePCI ─────────────────────────────
Run-Test "Get-PVENodePCI" {
    if ($script:SampleNode) { Get-PVENodePCI -ClusterName $Cluster -Node $script:SampleNode }
    else { "No online node found" }
}

# ─── 26. VMPending ───────────────────────────
Run-Test "Get-PVEVMPending" {
    if ($script:SampleVM) { Get-PVEVMPending -ClusterName $Cluster -VMIDorName $script:SampleVM }
    else { "No running VM found" }
}

# ─── 27. NodeCertificates ────────────────────
Run-Test "Get-PVENodeCertificates" {
    if ($script:SampleNode) { Get-PVENodeCertificates -ClusterName $Cluster -Node $script:SampleNode }
    else { "No online node found" }
}

Write-Host "`n============================================"
Write-Host "=== DONE === output saved in: $OutDir"
$files = Get-ChildItem $OutDir -Filter "*.txt"
Write-Host "Files: $($files.Count) / 27"
$files | Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
