# 🖥️ Proxmox Manager

PowerShell toolkit + MCP server for managing Proxmox VE clusters via REST API — built for Cognyte InfraOps.

## Features

- 🔗 **Multi-cluster support** — connect to multiple PVE clusters from a single config
- 🔐 **Secure token storage** — AES-256 encrypted API tokens (no plaintext secrets)
- 📋 **VM inventory** — list VMs, LXC containers, disks, config, status, snapshots
- 💾 **Storage mapping** — correlate VMs to their underlying NFS/LVM datastores
- 🤖 **MCP server** — 25 read-only tools exposable to AI agents (Claude, Hermes, Copilot)
- 🧩 **Modular design** — mirrors `VMware_Manager` architecture for consistency

---

## Structure

```
proxmox-manager/
├── proxmox-manager.ps1        # Entry point — loads modules, shows quick start
├── New-PVEConfig.ps1          # First-time setup wizard — builds nodes.json + saves token
├── New-PVECredential.ps1      # Renew/replace API token only (AES encrypted)
├── Run-AllTests.ps1           # Run all 27 functions and save output to out/
├── Modules/
│   ├── PVE-Connection.psm1    # Connect-PVECluster, internal HTTP invoker
│   └── PVE-VMs.psm1           # All 27 read-only functions
├── mcp/
│   └── pve-mcp-server.py      # MCP stdio server — 25 tools for AI agents
├── Config/
│   └── nodes.json             # Cluster definitions (gitignored — no secrets)
├── credentials/
│   └── *.cred                 # AES-encrypted tokens (gitignored)
└── out/                       # Output from Run-AllTests.ps1 (gitignored)
    └── *.txt                  # One file per function
```

---

## Quick Start

```powershell
# 1. First-time setup — interactive wizard (auto-discovers nodes from API)
.\New-PVEConfig.ps1

# OR — write a generic template and fill in manually
.\New-PVEConfig.ps1 -Skip

# 2. Load the modules directly (PSM1 — avoids emoji parse errors in PS 5.1)
Import-Module .\Modules\PVE-Connection.psm1 -Force
Import-Module .\Modules\PVE-VMs.psm1 -Force

# 3. Connect to a cluster
Connect-PVECluster -Name THC

# 4. List all VMs
Get-PVEVMs -ClusterName THC

# 5. Filter by name pattern
Get-PVEVMs -ClusterName THC -Name 'THC*'

# 6. Top VMs by RAM
Get-PVEClusterResources -ClusterName THC -Type vm | Sort-Object maxmem -Descending | Select-Object -First 10

# 7. Run all tests and save to out/
.\Run-AllTests.ps1
```

> ⚠️ **Do NOT** use `. .\proxmox-manager.ps1` (dot-source) — the file contains emoji comments that
> cause parse errors in PowerShell 5.1. Always `Import-Module` the PSM1 files directly.

---

## Config: nodes.json

```json
{
  "Clusters": [
    {
      "Name": "THC",
      "APINode": "pve-node.domain.local",
      "Port": 8006,
      "CredentialFile": "credentials/user@realm!tokenid.cred"
    }
  ]
}
```

> ⚠️ `Config/nodes.json` is gitignored — copy from your secure store or run `New-PVEConfig.ps1`.

---

## Authentication

API tokens are stored AES-256 encrypted using a per-machine key:

```powershell
.\New-PVECredential.ps1 -ClusterName THC -TokenId "<TokenUser>!<TokenName>" -Secret "<token>"
```

The token is saved to `credentials/<TokenId>.cred` and loaded automatically on `Connect-PVECluster`.

**SSL:** PVE uses self-signed certificates. In PowerShell 5.1, `-SkipCertificateCheck` is not available
on `Invoke-RestMethod`. The `PVE-Connection.psm1` module patches the `ServicePointManager` using a
`TrustAllCerts` class (added via `Add-Type`) to bypass certificate validation at the .NET layer.

---

## Requirements

- PowerShell **5.1+** (tested on 5.1.26100.x and 7.x)
- Proxmox VE **7+** (tested on PVE 9.1.1)
- API token with at least `PVEAuditor` role
- Python 3.9+ and `mcp` package (for MCP server only)

---

## Available Commands — PowerShell (27 functions)

### Connection

| Command | Description |
|---|---|
| `Connect-PVECluster -Name <cluster>` | Authenticate and store session |
| `Get-PVEClusterList` | List configured clusters from nodes.json |

### Cluster & Nodes

| Command | Key Parameters | Description |
|---|---|---|
| `Get-PVENodes` | `-ClusterName` | List all PVE nodes with status/memory/uptime |
| `Get-PVENodeStatus` | `-ClusterName`, `-Node` | CPU, memory, disk, uptime for a specific node |
| `Get-PVENodeNetwork` | `-ClusterName`, `-Node` | Network interfaces of a node |
| `Get-PVENodeDisks` | `-ClusterName`, `-Node` | Physical disks on a node |
| `Get-PVENodeServices` | `-ClusterName`, `-Node` | systemd services on a node |
| `Get-PVENodePCI` | `-ClusterName`, `-Node` | PCI devices on a node |
| `Get-PVENodeCertificates` | `-ClusterName`, `-Node` | SSL certificates on a node |
| `Get-PVENodeRRDData` | `-ClusterName`, `-Node` | Historical RRD stats for a node |
| `Get-PVEClusterResources` | `-ClusterName`, `-Type` | All resources: vm / storage / node / sdn |
| `Get-PVEClusterTasks` | `-ClusterName`, `-Limit` | Recent cluster task log |

### VMs & LXC

| Command | Key Parameters | Description |
|---|---|---|
| `Get-PVEVMs` | `-ClusterName`, `-Name`, `-Node`, `-Status` | List QEMU VMs (filter by name/node/status) |
| `Get-PVELXCList` | `-ClusterName`, `-Node` | List LXC containers |
| `Get-PVEVMStatus` | `-ClusterName`, `-VMIDorName` | Live status of a VM (CPU %, RAM, uptime) |
| `Get-PVEVMPowerState` | `-ClusterName`, `-VMIDorName` | Power state: running / stopped / paused |
| `Get-PVEVMConfig` | `-ClusterName`, `-VMIDorName` | Full VM config (CPU, memory, network, etc.) |
| `Get-PVEVMPending` | `-ClusterName`, `-VMIDorName` | Pending config changes (not yet applied) |
| `Get-PVEVMDisk` | `-ClusterName`, `-VMIDorName` | Disk layout: storage pool, path, size |
| `Get-PVEVMAgent` | `-ClusterName`, `-VMIDorName` | QEMU guest agent info (requires agent installed) |
| `Get-PVEVMRRDData` | `-ClusterName`, `-VMIDorName` | Historical RRD stats for a VM |
| `Get-PVESnapshots` | `-ClusterName`, `-VMIDorName` | Snapshot list for a VM |
| `Get-PVEVMsByStorage` | `-ClusterName` | Group VMs by storage backend |

### Storage, Backup & HA

| Command | Key Parameters | Description |
|---|---|---|
| `Get-PVEStorage` | `-ClusterName` | List all storage resources (capacity, type) |
| `Get-PVEStorageContent` | `-ClusterName`, `-Node`, `-StorageName` | List content of a storage pool |
| `Get-PVEBackupJobs` | `-ClusterName` | Configured vzdump backup jobs |
| `Get-PVEHAStatus` | `-ClusterName` | HA manager state and resource list |
| `Get-PVEReplicationJobs` | `-ClusterName` | ZFS/storage replication jobs |
| `Get-PVEFirewallRules` | `-ClusterName` | Cluster-level firewall rules |

---

## MCP Server (25 tools)

The MCP server exposes 25 read-only tools to AI agents via stdio transport.

### Setup

```bash
# Install dependency
pip install mcp

# Register in Hermes config (one-time)
hermes config set mcp_servers.proxmox.command python
hermes config set mcp_servers.proxmox.args '["C:/path/to/proxmox-manager/mcp/pve-mcp-server.py"]'

# Test
hermes mcp test proxmox
# → ✓ Connected — 25 tools
```

### Tool List

| Tool | Description |
|---|---|
| `pve_list_vms` | List all QEMU VMs |
| `pve_list_lxc` | List all LXC containers |
| `pve_get_vm_status` | Live status for a VM |
| `pve_get_vm_config` | Full VM config |
| `pve_get_vm_disks` | Disk layout for a VM |
| `pve_get_vm_snapshots` | Snapshots for a VM |
| `pve_get_vm_pending` | Pending config changes |
| `pve_get_vm_rrd` | Historical RRD data for a VM |
| `pve_get_vm_agent` | Guest agent info |
| `pve_get_nodes` | List all PVE nodes |
| `pve_get_node_status` | Status of a specific node |
| `pve_get_node_network` | Node network interfaces |
| `pve_get_node_disks` | Node physical disks |
| `pve_get_node_services` | Node systemd services |
| `pve_get_node_pci` | Node PCI devices |
| `pve_get_node_certificates` | Node SSL certificates |
| `pve_get_node_rrd` | Historical RRD data for a node |
| `pve_get_cluster_resources` | All cluster resources |
| `pve_get_cluster_tasks` | Recent task log |
| `pve_get_storage` | List all storage pools |
| `pve_get_storage_content` | Content of a storage pool |
| `pve_get_backup_jobs` | Backup job definitions |
| `pve_get_ha_status` | HA manager state |
| `pve_get_replication_jobs` | Replication job list |
| `pve_get_firewall_rules` | Cluster firewall rules |

---

## Known Issues

| # | Issue | Workaround |
|---|---|---|
| 1 | **`-SkipCertificateCheck` not available in PS 5.1** — parameter doesn't exist on `Invoke-RestMethod` in Windows PowerShell 5.1 | `PVE-Connection.psm1` patches `ServicePointManager.ServerCertificateValidationCallback` via `Add-Type` with a `TrustAllCerts` class |
| 2 | **`??` null-coalescing operator not available in PS 5.1** — causes parse error | Replaced with `if ($x) { $x } else { 'default' }` pattern throughout `PVE-VMs.psm1` |
| 3 | **`/cluster/tasks?limit=N` rejected by PVE 9.x** — API returns 400/500 when query param is passed | Fetch full task list, then apply `Select-Object -First $Limit` on the client side |
| 4 | **`Get-PVEVMAgent` returns empty for most VMs** — QEMU guest agent must be installed and running inside the VM | Install `qemu-guest-agent` in the VM OS and enable it in VM config (`agent: 1`) |
| 5 | **Some `out/*.txt` files are 0 KB** — e.g., `Get-PVEHAStatus`, `Get-PVEReplicationJobs`, `Get-PVEFirewallRules` | Not an error — those endpoints return empty arrays when no HA/replication/firewall is configured |
| 6 | **Dot-sourcing `proxmox-manager.ps1` fails in PS 5.1** — emoji in comments cause parser error | Always `Import-Module` the PSM1 files directly (see Quick Start above) |
| 7 | **MCP server requires `NotificationOptions()` object** — passing `None` throws `TypeError` in recent `mcp` package versions | Import and pass `NotificationOptions()` explicitly in `server.run()` |
---

## Roadmap

- [ ] **WRITE operations** — `Set-PVEVMPower`, `New-PVESnapshot`, `Remove-PVESnapshot`, `Start-PVEBackup`
- [ ] **Multi-cluster MCP** — allow MCP tools to target any cluster (not just default)
- [ ] **LXC full parity** — same function coverage for LXC as for QEMU VMs

---

## Related Projects

- [`VMware_Manager`](../VMware_Manager) — same architecture for vCenter management
- [`netapp-element-api`](../NetApp) — SolidFire/HCI Element API toolkit
