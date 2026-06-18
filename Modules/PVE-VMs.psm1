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
    $nameFilter = if ($Name) { $Name } else { '*' }
    Get-PVEVMs -ClusterName $ClusterName -Name $nameFilter |
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

# ═══════════════════════════════════════════════════════
# NEW FUNCTIONS — VM Details
# ═══════════════════════════════════════════════════════

function Get-PVEVMConfig {
    <#
    .SYNOPSIS Full configuration of a VM: CPU type, BIOS, boot, NICs, disks, tags, description.
    .EXAMPLE
        Get-PVEVMConfig -ClusterName THC -VMIDorName 'thcwpexch01'
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][Alias('VMID','Name')][string]$VMIDorName,
        [string]$Node
    )
    if ($VMIDorName -match '^\d+$') {
        $vmid = [int]$VMIDorName
        if (-not $Node) { throw "Pass -Node when using VMID directly." }
    } else {
        $vm   = Get-PVEVMs -ClusterName $ClusterName -Name $VMIDorName | Select-Object -First 1
        if (-not $vm) { throw "VM '$VMIDorName' not found." }
        $vmid = $vm.VMID; if (-not $Node) { $Node = $vm.Node }
    }
    $cfg = _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/config"
    $cfg | Add-Member -NotePropertyName _VMName -NotePropertyValue $VMIDorName -PassThru |
           Add-Member -NotePropertyName _Node   -NotePropertyValue $Node       -PassThru
}

function Get-PVEVMStatus {
    <#
    .SYNOPSIS Live CPU%, RAM used, PID, uptime, lock for a running VM.
    .EXAMPLE
        Get-PVEVMStatus -ClusterName THC -VMIDorName 'thcwpexch01'
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][Alias('VMID','Name')][string]$VMIDorName,
        [string]$Node
    )
    if ($VMIDorName -match '^\d+$') {
        $vmid = [int]$VMIDorName
        if (-not $Node) { throw "Pass -Node when using VMID directly." }
    } else {
        $vm   = Get-PVEVMs -ClusterName $ClusterName -Name $VMIDorName | Select-Object -First 1
        if (-not $vm) { throw "VM '$VMIDorName' not found." }
        $vmid = $vm.VMID; if (-not $Node) { $Node = $vm.Node }
    }
    $s = _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/status/current"
    [PSCustomObject]@{
        Name      = $s.name
        VMID      = $vmid
        Node      = $Node
        Status    = $s.status
        CpuPct    = [math]::Round($s.cpu * 100, 2)
        MemUsedGB = [math]::Round($s.mem / 1GB, 2)
        MemMaxGB  = [math]::Round($s.maxmem / 1GB, 1)
        MemPct    = if ($s.maxmem) { [math]::Round(($s.mem / $s.maxmem) * 100, 1) } else { 0 }
        UptimeH   = [math]::Round($s.uptime / 3600, 1)
        PID       = $s.pid
        Lock      = $s.lock
        QmpStatus = $s.qmpstatus
        Tags      = $s.tags
    }
}

function Get-PVEClusterResources {
    <#
    .SYNOPSIS All cluster resources in one call: VMs, nodes, storage, LXC.
    .PARAMETER Type  Filter: vm | node | storage | sdn | all (default: all)
    .EXAMPLE
        Get-PVEClusterResources -ClusterName THC
        Get-PVEClusterResources -ClusterName THC -Type vm
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [ValidateSet('vm','node','storage','sdn','all')][string]$Type = 'all'
    )
    $path = '/cluster/resources'
    if ($Type -ne 'all') { $path += "?type=$Type" }
    _PVE-Invoke -ClusterName $ClusterName -Path $path
}

function Get-PVELXCList {
    <#
    .SYNOPSIS List LXC containers across all nodes.
    .EXAMPLE
        Get-PVELXCList -ClusterName THC
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [string]$Node,
        [ValidateSet('running','stopped','all')][string]$Status = 'all'
    )
    $nodes = if ($Node) { @([PSCustomObject]@{node=$Node}) } else { _PVE-Invoke -ClusterName $ClusterName -Path '/nodes' }
    $results = foreach ($n in $nodes) {
        try {
            $ctrs = _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$($n.node)/lxc"
            foreach ($c in $ctrs) {
                [PSCustomObject]@{
                    ClusterName = $ClusterName
                    Node     = $n.node
                    CTID     = $c.vmid
                    Name     = $c.name
                    Status   = $c.status
                    MemGB    = [math]::Round($c.maxmem/1GB, 1)
                    CPUs     = $c.cpus
                    DiskGB   = [math]::Round($c.maxdisk/1GB, 1)
                    UptimeH  = if ($c.uptime) { [math]::Round($c.uptime/3600,1) } else { 0 }
                }
            }
        } catch { }
    }
    $results = $results | Where-Object { $_ -ne $null }
    if ($Status -ne 'all') { $results = $results | Where-Object { $_.Status -eq $Status } }
    $results | Sort-Object Node, Name
}

function Get-PVENodeStatus {
    <#
    .SYNOPSIS Detailed CPU/RAM/swap/load/disk for a specific node.
    .EXAMPLE
        Get-PVENodeStatus -ClusterName THC -Node thclprhevh01
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node
    )
    $s = _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/status"
    [PSCustomObject]@{
        Node        = $Node
        CpuPct      = [math]::Round($s.cpu * 100, 2)
        CPUs        = $s.cpuinfo.cpus
        CpuModel    = $s.cpuinfo.model
        MemUsedGB   = [math]::Round($s.memory.used/1GB,1)
        MemTotalGB  = [math]::Round($s.memory.total/1GB,1)
        SwapUsedGB  = [math]::Round($s.swap.used/1GB,1)
        SwapTotalGB = [math]::Round($s.swap.total/1GB,1)
        RootUsedGB  = [math]::Round($s.rootfs.used/1GB,1)
        RootTotalGB = [math]::Round($s.rootfs.total/1GB,1)
        Load1m      = $s.loadavg[0]
        Load5m      = $s.loadavg[1]
        Load15m     = $s.loadavg[2]
        KernelVer   = $s.kversion
        PVEVersion  = $s.pveversion
        UptimeH     = [math]::Round($s.uptime/3600,1)
    }
}

function Get-PVENodeNetwork {
    <#
    .SYNOPSIS All NICs and bridges on a node (name, type, IP, MAC, bridge members).
    .EXAMPLE
        Get-PVENodeNetwork -ClusterName THC -Node thclprhevh01
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node
    )
    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/network" |
        Select-Object iface, type, active, autostart,
            @{N='IP';E={$_.address}},
            @{N='Netmask';E={$_.netmask}},
            @{N='Gateway';E={$_.gateway}},
            @{N='MAC';E={$_.'hardware-address'}},
            @{N='BridgePorts';E={$_.'bridge-ports'}},
            @{N='BridgeSTP';E={$_.'bridge-stp'}},
            comments |
        Sort-Object type, iface
}

function Get-PVENodeDisks {
    <#
    .SYNOPSIS Physical disks on a node (model, serial, size, type, health).
    .EXAMPLE
        Get-PVENodeDisks -ClusterName THC -Node thclprhevh01
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node
    )
    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/disks/list" |
        Select-Object devpath, model, serial, vendor, size,
            @{N='SizeGB';E={[math]::Round($_.size/1GB,0)}},
            type, health, rpm, wearout |
        Sort-Object devpath
}

function Get-PVEStorageContent {
    <#
    .SYNOPSIS List content of a storage pool: ISOs, VM images, backups, templates.
    .PARAMETER ContentType  Filter: images | iso | backup | vztmpl | all (default: all)
    .EXAMPLE
        Get-PVEStorageContent -ClusterName THC -Node thclprhevh01 -StorageName local
        Get-PVEStorageContent -ClusterName THC -Node thclprhevh01 -StorageName nfs_proxmox_hrz01 -ContentType backup
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$StorageName,
        [ValidateSet('images','iso','backup','vztmpl','all')][string]$ContentType = 'all'
    )
    $path = "/nodes/$Node/storage/$StorageName/content"
    if ($ContentType -ne 'all') { $path += "?content=$ContentType" }
    _PVE-Invoke -ClusterName $ClusterName -Path $path |
        Select-Object volid, content, format,
            @{N='SizeGB';E={[math]::Round($_.size/1GB,2)}},
            vmid, notes, ctime |
        Sort-Object content, volid
}

function Get-PVEClusterTasks {
    <#
    .SYNOPSIS Cluster task history: migrations, backups, clone, snapshots, etc.
    .PARAMETER Limit  Max tasks to return (default: 50)
    .EXAMPLE
        Get-PVEClusterTasks -ClusterName THC -Limit 20
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [int]$Limit = 50
    )
    _PVE-Invoke -ClusterName $ClusterName -Path "/cluster/tasks" |
        Select-Object -First $Limit |
        Select-Object upid, type, user, node, status,
            @{N='StartTime';E={ [DateTimeOffset]::FromUnixTimeSeconds($_.starttime).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') }},
            @{N='EndTime';E={ if ($_.endtime) { [DateTimeOffset]::FromUnixTimeSeconds($_.endtime).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' } }},
            id |
        Sort-Object StartTime -Descending |
        Select-Object -First $Limit
}

function Get-PVEBackupJobs {
    <#
    .SYNOPSIS List configured backup jobs (vzdump schedules).
    .EXAMPLE
        Get-PVEBackupJobs -ClusterName THC
    #>
    param([Parameter(Mandatory)][string]$ClusterName)
    _PVE-Invoke -ClusterName $ClusterName -Path '/cluster/backup' |
        Select-Object id, enabled, schedule, storage, node, vmid,
            compress, mode, mailto, maxfiles, notes-template |
        Sort-Object id
}

function Get-PVEHAStatus {
    <#
    .SYNOPSIS HA cluster status and HA-managed resources.
    .EXAMPLE
        Get-PVEHAStatus -ClusterName THC
    #>
    param([Parameter(Mandatory)][string]$ClusterName)
    $status    = _PVE-Invoke -ClusterName $ClusterName -Path '/cluster/ha/status/current'
    $resources = try { _PVE-Invoke -ClusterName $ClusterName -Path '/cluster/ha/resources' } catch { @() }
    [PSCustomObject]@{
        Status    = $status
        Resources = $resources
    }
}

function Get-PVEReplicationJobs {
    <#
    .SYNOPSIS List replication jobs (cross-node VM replication schedule).
    .EXAMPLE
        Get-PVEReplicationJobs -ClusterName THC
    #>
    param([Parameter(Mandatory)][string]$ClusterName)
    _PVE-Invoke -ClusterName $ClusterName -Path '/cluster/replication' |
        Select-Object id, type, source, target, vmid, schedule,
            enabled, rate, remove_job, comment |
        Sort-Object id
}

function Get-PVEFirewallRules {
    <#
    .SYNOPSIS Firewall rules for a node or a specific VM.
    .PARAMETER VMIDorName  If provided, get VM-level rules. Otherwise node-level rules.
    .EXAMPLE
        Get-PVEFirewallRules -ClusterName THC -Node thclprhevh01
        Get-PVEFirewallRules -ClusterName THC -Node thclprhevh01 -VMIDorName 'thcwpexch01'
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node,
        [string]$VMIDorName
    )
    if ($VMIDorName) {
        if ($VMIDorName -match '^\d+$') { $vmid = [int]$VMIDorName }
        else {
            $vm = Get-PVEVMs -ClusterName $ClusterName -Name $VMIDorName | Select-Object -First 1
            $vmid = $vm.VMID
        }
        _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/firewall/rules"
    } else {
        _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/firewall/rules"
    }
}

function Get-PVEVMAgent {
    <#
    .SYNOPSIS QEMU guest agent info: IPs, OS info, hostname (requires guest agent installed).
    .EXAMPLE
        Get-PVEVMAgent -ClusterName THC -VMIDorName 'thcwpexch01'
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][Alias('VMID','Name')][string]$VMIDorName,
        [string]$Node
    )
    if ($VMIDorName -match '^\d+$') {
        $vmid = [int]$VMIDorName
        if (-not $Node) { throw "Pass -Node when using VMID directly." }
    } else {
        $vm   = Get-PVEVMs -ClusterName $ClusterName -Name $VMIDorName | Select-Object -First 1
        if (-not $vm) { throw "VM '$VMIDorName' not found." }
        $vmid = $vm.VMID; if (-not $Node) { $Node = $vm.Node }
    }

    $nics = try { _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/agent/network-get-interfaces" } catch { $null }
    $os   = try { _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/agent/get-osinfo" }             catch { $null }
    $host = try { _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/agent/get-host-name" }         catch { $null }

    [PSCustomObject]@{
        VMName    = $VMIDorName
        VMID      = $vmid
        Node      = $Node
        Hostname  = $host.result.'host-name'
        OS        = $os.result
        NICs      = $nics.result.'return'
    }
}

function Get-PVEVMRRDData {
    <#
    .SYNOPSIS Historical metrics graph data: CPU, RAM, Net I/O, Disk I/O.
    .PARAMETER Timeframe  hour | day | week | month | year (default: hour)
    .EXAMPLE
        Get-PVEVMRRDData -ClusterName THC -VMIDorName 'thcwpexch01' -Timeframe day
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][Alias('VMID','Name')][string]$VMIDorName,
        [string]$Node,
        [ValidateSet('hour','day','week','month','year')][string]$Timeframe = 'hour'
    )
    if ($VMIDorName -match '^\d+$') {
        $vmid = [int]$VMIDorName
        if (-not $Node) { throw "Pass -Node when using VMID directly." }
    } else {
        $vm   = Get-PVEVMs -ClusterName $ClusterName -Name $VMIDorName | Select-Object -First 1
        if (-not $vm) { throw "VM '$VMIDorName' not found." }
        $vmid = $vm.VMID; if (-not $Node) { $Node = $vm.Node }
    }
    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/rrddata?timeframe=$Timeframe&cf=AVERAGE"
}

function Get-PVENodeRRDData {
    <#
    .SYNOPSIS Historical metrics for a node (CPU, RAM, Net, Disk over time).
    .PARAMETER Timeframe  hour | day | week | month | year (default: hour)
    .EXAMPLE
        Get-PVENodeRRDData -ClusterName THC -Node thclprhevh01 -Timeframe day
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node,
        [ValidateSet('hour','day','week','month','year')][string]$Timeframe = 'hour'
    )
    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/rrddata?timeframe=$Timeframe&cf=AVERAGE"
}

function Get-PVENodeServices {
    <#
    .SYNOPSIS systemd services on a node (pveproxy, pvedaemon, pve-ha-*, etc.).
    .EXAMPLE
        Get-PVENodeServices -ClusterName THC -Node thclprhevh01
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node
    )
    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/services" |
        Select-Object name, desc, state, 'active-state' |
        Sort-Object state, name
}

function Get-PVENodePCI {
    <#
    .SYNOPSIS PCI devices available for passthrough on a node.
    .EXAMPLE
        Get-PVENodePCI -ClusterName THC -Node thclprhevh01
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node
    )
    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/hardware/pci" |
        Select-Object id, class, vendor, device, iommugroup, subsystem_vendor, subsystem_device |
        Sort-Object iommugroup, id
}

function Get-PVEVMPending {
    <#
    .SYNOPSIS Config changes pending reboot for a VM (live config vs stored config diff).
    .EXAMPLE
        Get-PVEVMPending -ClusterName THC -VMIDorName 'thcwpexch01'
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][Alias('VMID','Name')][string]$VMIDorName,
        [string]$Node
    )
    if ($VMIDorName -match '^\d+$') {
        $vmid = [int]$VMIDorName
        if (-not $Node) { throw "Pass -Node when using VMID directly." }
    } else {
        $vm   = Get-PVEVMs -ClusterName $ClusterName -Name $VMIDorName | Select-Object -First 1
        if (-not $vm) { throw "VM '$VMIDorName' not found." }
        $vmid = $vm.VMID; if (-not $Node) { $Node = $vm.Node }
    }
    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/qemu/$vmid/pending"
}

function Get-PVENodeCertificates {
    <#
    .SYNOPSIS TLS certificates on a node (expiry, fingerprint, issuer).
    .EXAMPLE
        Get-PVENodeCertificates -ClusterName THC -Node thclprhevh01
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Node
    )
    _PVE-Invoke -ClusterName $ClusterName -Path "/nodes/$Node/certificates/info" |
        Select-Object filename, subject, issuer, fingerprint,
            @{N='NotBefore';E={ [DateTimeOffset]::FromUnixTimeSeconds($_.notbefore).LocalDateTime.ToString('yyyy-MM-dd') }},
            @{N='NotAfter'; E={ [DateTimeOffset]::FromUnixTimeSeconds($_.notafter).LocalDateTime.ToString('yyyy-MM-dd') }} |
        Sort-Object filename
}

Export-ModuleMember -Function `
    Get-PVENodes, Get-PVEVMs, Get-PVEVMDisk, Get-PVEVMsByStorage, Get-PVEStorage,
    Get-PVEVMPowerState, Get-PVESnapshots,
    Get-PVEVMConfig, Get-PVEVMStatus, Get-PVEClusterResources,
    Get-PVELXCList, Get-PVENodeStatus, Get-PVENodeNetwork, Get-PVENodeDisks,
    Get-PVEStorageContent, Get-PVEClusterTasks, Get-PVEBackupJobs,
    Get-PVEHAStatus, Get-PVEReplicationJobs, Get-PVEFirewallRules,
    Get-PVEVMAgent, Get-PVEVMRRDData, Get-PVENodeRRDData,
    Get-PVENodeServices, Get-PVENodePCI, Get-PVEVMPending, Get-PVENodeCertificates
