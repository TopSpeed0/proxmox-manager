# 🖥️ Proxmox Manager

PowerShell toolkit for managing Proxmox VE clusters via REST API — built for Cognyte InfraOps.

## Features

- 🔗 **Multi-cluster support** — connect to multiple PVE clusters from a single config
- 🔐 **Secure token storage** — AES-encrypted API tokens (no plaintext secrets)
- 📋 **VM inventory** — list VMs by cluster, name, node, status, or storage
- 💾 **Storage mapping** — correlate VMs to their underlying NFS/LVM datastores
- 🧩 **Modular design** — mirrors `VMware_Manager` architecture for consistency

## Structure

```
proxmox-manager/
├── proxmox-manager.ps1        # Entry point — loads modules, shows quick start
├── New-PVEConfig.ps1          # 🆕 First-time setup wizard — builds nodes.json + saves token
├── New-PVECredential.ps1      # Renew/replace API token only (AES encrypted)
├── Modules/
│   ├── PVE-Connection.psm1    # Connect-PVECluster, internal HTTP invoker
│   └── PVE-VMs.psm1           # Get-PVEVMs, Get-PVEStorage, Get-PVEVMDisk, Get-PVEVMsByStorage
├── Config/
│   └── nodes.json             # Cluster definitions (gitignored — no secrets)
└── credentials/
    └── *.cred                 # AES-encrypted tokens (gitignored)
```

## Quick Start

```powershell
# 1. First-time setup — interactive wizard (auto-discovers nodes from API)
.\New-PVEConfig.ps1

# OR — write a generic template and fill in manually
.\New-PVEConfig.ps1 -Skip

# 2. Load the toolkit
. .\proxmox-manager.ps1

# 3. Connect to a cluster
Connect-PVECluster -Name THC

# 4. List all VMs
Get-PVEVMs -ClusterName THC

# 5. Filter by name pattern
Get-PVEVMs -ClusterName THC -Name 'THC*'

# 6. Group VMs by storage
Get-PVEVMsByStorage -ClusterName THC | Format-Table -AutoSize
```

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

> ⚠️ `Config/nodes.json` is gitignored — copy from your secure store or create manually.

## Authentication

API tokens are stored AES-256 encrypted using a per-machine key:

```powershell
.\New-PVECredential.ps1 -ClusterName THC -TokenId "<TokenUser>!<TokenName>" -Secret "<token>"
```

The token is saved to `credentials/<TokenId>.cred` and loaded automatically on `Connect-PVECluster`.

> **Note:** PVE API requires `-SkipCertificateCheck` (self-signed cert) and `-SkipHeaderValidation`  
> (the `!` character in token IDs fails standard header validation in PowerShell's `Invoke-RestMethod`).

## Requirements

- PowerShell 7+
- Proxmox VE 7+ (tested on PVE 9.1.1)
- API token with at least `PVEAuditor` role

## Available Commands

| Command | Description |
|---|---|
| `Connect-PVECluster -Name <cluster>` | Authenticate and store session |
| `Get-PVEClusterList` | List configured clusters |
| `Get-PVEVMs -ClusterName <cluster>` | List all VMs (optional: `-Name`, `-Node`, `-Status`) |
| `Get-PVEStorage -ClusterName <cluster>` | List all storage resources |
| `Get-PVEVMDisk -ClusterName <cluster> -VMID <id>` | Get disk config for a specific VM |
| `Get-PVEVMsByStorage -ClusterName <cluster>` | Group VMs by storage backend |

## Related Projects

- [`VMware_Manager`](../VMware_Manager) — same architecture for vCenter management
- [`netapp-element-api`](../NetApp) — SolidFire/HCI Element API toolkit
