#Requires -Version 5.1
<#
.SYNOPSIS
    Proxmox VE VM / Container operations (read-only + safe writes).
.DESCRIPTION
    Mirrors VMW-VMs.psm1 pattern for PVE — list VMs, power state, disk info, storage paths.
    All write operations (start/stop/migrate) require -Force to prevent accidents.
#>

function Get-PVENodes {
    <# List all nodes in the cluster #>
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$ClusterName
    )
    _PVE-Invoke -ClusterName $ClusterName -Path '/nodes' |
        Select-Object node, status, @{N='MemGB';E={[math]::Round($_.maxmem/1GB,1)}},
                      @{N='DiskGB';E={[math]::Round($_.maxdisk/1GB,1)}}, uptime
}

function Get-PVEVMs {
    <#
    .SYNOPSIS List VMs (QEMU) across all nodes in a cluster.
    .PARAMETER ClusterName  Cluster name (from nodes.json)
    .PARAMETER Name         Filter by VM name (wildcard supported)
    .PARAMETER Node         Limit to specific node
    .PARAMETER Status       Filter by status: running | stopped | all (default: all)
    .EXAMPLE
        Get-PVEVMs -ClusterName THC -Name 'THC*'
    #>
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$ClusterName,
        [string]$Name,
        [string]$Node,
        [ValidateSet('running','stopped','all')][string]$Status = 'all'
    )

    # Get all nodes
    $nodes = if ($Node) { @([PSCustomObject]@{node=$Node}) } else { _PVE-Invoke -ClusterName $ClusterName -Path '/nodes' }

    $results = foreach ($n in $nodes) {
        $vms = _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$($n.node)/qemu"
        foreach ($vm in $vms) {
            [PSCustomObject]@{
                ClusterName = $ClusterName
                Node    = $n.node
                VMID    = $vm.vmid
                Name    = $vm.name
                Status  = $vm.status
                MemGB   = [math]::Round($vm.maxmem/1GB, 1)
                CPUs    = $vm.cpus
                UptimeH = if ($vm.uptime) { [math]::Round($vm.uptime/3600, 1) } else { 0 }
            }
        }
    }

    $results = $results | Where-Object { $_ -ne $null }
    if ($Name)                       { $results = $results | Where-Object { $_.Name -like $Name } }
    if ($Status -ne 'all')           { $results = $results | Where-Object { $_.Status -eq $Status } }

    $results | Sort-Object Node, Name
}

function Get-PVEVMDisk {
    <#
    .SYNOPSIS Get disk/storage info for a VM (QEMU) — shows storage pool and disk path.
    .PARAMETER ClusterName  Cluster name
    .PARAMETER VMIDorName   VMID (integer) or VM name (string — resolves automatically)
    .PARAMETER Node         Node hostname (optional — auto-resolved from VM list)
    .EXAMPLE
        Get-PVEVMDisk -ClusterName THC -VMIDorName 'THCwpsystools01'
    #>
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$ClusterName,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('VMID','Name')]
        [string]$VMIDorName,
        [Parameter(ValueFromPipelineByPropertyName)][string]$Node
    )

    # Resolve VMID + node if name provided
    if ($VMIDorName -match '^\d+$') {
        $vmid = [int]$VMIDorName
        if (-not $Node) { throw "Pass -Node when using VMID directly, or use VM name." }
    } else {
        $all = Get-PVEVMs -ClusterName $ClusterName -Name $VMIDorName
        if (-not $all) { throw "VM '$VMIDorName' not found in cluster $ClusterName" }
        $vm   = $all | Select-Object -First 1
        $vmid = $vm.VMID
        if (-not $Node) { $Node = $vm.Node }
    }

    $config = _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/config"

    # Parse disk entries: scsi0, virtio0, ide0, sata0 etc.
    $disks = $config.PSObject.Properties | Where-Object {
        $_.Name -match '^(scsi|virtio|ide|sata|efidisk|tpmstate)\d+$' -and
        $_.Value -notmatch 'none|cdrom'
    }

    $disks | ForEach-Object {
        $key = $_.Name
        $val = $_.Value
        # Format: <storage>:<path/size>[,options]
        $parts   = $val -split ',', 2
        $loc     = $parts[0]    # e.g. "local-lvm:vm-100-disk-0" or "VMware_Datastores_Maskit1:vm-100-disk-0"
        $options = $parts[1]
        $sizeMatch = ($options -split ',') | Where-Object { $_ -match '^size=' }
        $size = if ($sizeMatch) { ($sizeMatch -split '=')[1] } else { 'unknown' }

        [PSCustomObject]@{
            Disk    = $key
            Storage = ($loc -split ':')[0]
            Path    = ($loc -split ':')[1]
            Size    = $size
            Full    = $loc
        }
    }
}

function Get-PVEVMsByStorage {
    <#
    .SYNOPSIS List all VMs grouped by their storage pool (disk location).
    .PARAMETER ClusterName  Cluster name
    .PARAMETER StorageName  Filter by specific storage name (optional)
    .EXAMPLE
        Get-PVEVMsByStorage -ClusterName THC
        Get-PVEVMsByStorage -ClusterName THC -StorageName 'nfs_proxmox_THC01'
    #>
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$ClusterName,
        [string]$StorageName
    )

    $allVMs = Get-PVEVMs -ClusterName $ClusterName
    $results = foreach ($vm in $allVMs) {
        try {
            $disks = Get-PVEVMDisk -ClusterName $ClusterName -VMIDorName ([string]$vm.VMID) -Node $vm.Node
            foreach ($d in $disks) {
                [PSCustomObject]@{
                    Node    = $vm.Node
                    VMID    = $vm.VMID
                    VMName  = $vm.Name
                    Status  = $vm.Status
                    Disk    = $d.Disk
                    Storage = $d.Storage
                    Path    = $d.Path
                    Size    = $d.Size
                }
            }
        } catch {
            Write-Warning "Could not get disks for VM $($vm.Name): $_"
        }
    }

    if ($StorageName) { $results = $results | Where-Object { $_.Storage -like "*$StorageName*" } }
    $results | Sort-Object Storage, VMName
}

function Get-PVEStorage {
    <#
    .SYNOPSIS List storage pools on a cluster (type, path, capacity).
    .EXAMPLE
        Get-PVEStorage -ClusterName THC
    #>
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$ClusterName,
        [Parameter(ValueFromPipelineByPropertyName)][string]$Node
    )
    if (-not $Node) {
        $nodes = _PVE-Invoke -ClusterName $ClusterName -Path '/nodes'
        $Node  = $nodes[0].node
    }

    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/storage" |
        Select-Object storage, type, enabled, shared,
            @{N='TotalGB';E={[math]::Round($_.total/1GB,1)}},
            @{N='FreeGB'; E={[math]::Round($_.avail/1GB,1)}},
            @{N='UsedPct';E={if($_.total){[math]::Round((($_.total-$_.avail)/$_.total)*100,1)}else{0}}} |
        Sort-Object storage
}

function Get-PVEVMPowerState {
    <# Quick power state for all VMs (or filter by name) #>
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$ClusterName,
        [string]$Name
    )
    Get-PVEVMs -ClusterName $ClusterName -Name ($Name ?? '*') |
        Select-Object Node, VMID, Name, Status, UptimeH
}

function Get-PVESnapshots {
    <#
    .SYNOPSIS Get snapshots for one VM or all VMs on a storage.
    .PARAMETER ClusterName  Cluster name
    .PARAMETER VMIDorName   Specific VM name or VMID (optional — if omitted, use StorageName)
    .PARAMETER Node         Node hostname (optional — auto-resolved)
    .PARAMETER StorageName  Show snapshots for all VMs on this storage pool
    .EXAMPLE
        Get-PVESnapshots -ClusterName THC -VMIDorName 'hrzwpsystools01'
        Get-PVESnapshots -ClusterName THC -StorageName 'nfs_proxmox_hrz01'
        Get-PVEVMs -ClusterName THC -Name 'hrzwpsystools01' | Get-PVESnapshots
    #>
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$ClusterName,
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('VMID','Name')]
        [string]$VMIDorName,
        [Parameter(ValueFromPipelineByPropertyName)][string]$Node,
        [string]$StorageName
    )

    # Build list of VMs to query
    $vms = if ($StorageName) {
        Get-PVEVMsByStorage -ClusterName $ClusterName -StorageName $StorageName |
            Select-Object -Property ClusterName, @{N='VMIDorName';E={[string]$_.VMID}}, Node -Unique
    } elseif ($VMIDorName) {
        if (-not $Node) {
            $found = Get-PVEVMs -ClusterName $ClusterName -Name $VMIDorName | Select-Object -First 1
            $Node  = $found.Node
            $VMIDorName = [string]$found.VMID
        }
        @([PSCustomObject]@{ ClusterName=$ClusterName; VMIDorName=$VMIDorName; Node=$Node })
    } else {
        throw "Pass -VMIDorName or -StorageName"
    }

    $results = foreach ($vm in $vms) {
        $snaps = try {
            _PVE-Invoke -ClusterName $vm.ClusterName -Path "/nodes/$($vm.Node)/qemu/$($vm.VMIDorName)/snapshot"
        } catch { continue }

        foreach ($s in ($snaps | Where-Object { $_.name -ne 'current' })) {
            [PSCustomObject]@{
                VM          = (Get-PVEVMs -ClusterName $vm.ClusterName |
                                Where-Object { $_.VMID -eq [int]$vm.VMIDorName } |
                                Select-Object -ExpandProperty Name -First 1)
                VMID        = $vm.VMIDorName
                Node        = $vm.Node
                Snapshot    = $s.name
                Description = $s.description
                Created     = if ($s.snaptime) { [DateTimeOffset]::FromUnixTimeSeconds($s.snaptime).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
                HasRAM      = [bool]$s.vmstate
            }
        }
    }

    $results | Sort-Object VM, Created
}

Export-ModuleMember -Function Get-PVENodes, Get-PVEVMs, Get-PVEVMDisk, Get-PVEVMsByStorage, Get-PVEStorage, Get-PVEVMPowerState, Get-PVESnapshots
