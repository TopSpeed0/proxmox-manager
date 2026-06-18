#!/usr/bin/env python3
"""
Proxmox VE MCP Server
Exposes PVE REST API as MCP tools for Hermes Agent (and any MCP client).

Phase 1: stdio transport (local)
    python pve-mcp-server.py

Phase 2: HTTP/SSE transport (server deployment)
    python pve-mcp-server.py --transport sse --port 8080 --api-key <secret>

Config is loaded automatically from:
    ../Config/nodes.json   (cluster, API node, token ID)
    ../credentials/<id>.cred + aes.key  (encrypted token secret)

No environment variables or plaintext secrets required.
Phase 2 override: set PVE_TOKEN_SECRET env var to skip .cred decryption.
"""

import os
import sys
import json
import argparse
import ssl
import subprocess
import urllib.request
import urllib.error
from typing import Any

import mcp.server.stdio
import mcp.types as types
from mcp.server import Server, NotificationOptions
from mcp.server.models import InitializationOptions

# ─────────────────────────────────────────────
# Load config from nodes.json (gitignored)
# ─────────────────────────────────────────────

_SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
_ROOT_DIR    = os.path.dirname(_SCRIPT_DIR)
_NODES_FILE  = os.path.join(_ROOT_DIR, "Config", "nodes.json")
_CRED_DIR    = os.path.join(_ROOT_DIR, "credentials")


def _load_config() -> dict:
    if not os.path.exists(_NODES_FILE):
        raise RuntimeError(
            f"nodes.json not found: {_NODES_FILE}\n"
            "Run New-PVEConfig.ps1 to create it."
        )
    with open(_NODES_FILE, encoding="utf-8") as f:
        return json.load(f)


def _load_token_secret(cred_name: str) -> str:
    """Decrypt token secret from AES-encrypted .cred file via PowerShell.
    Falls back to PVE_TOKEN_SECRET env var (Phase 2 server deployment)."""
    if os.environ.get("PVE_TOKEN_SECRET"):
        return os.environ["PVE_TOKEN_SECRET"]
    cred_file = os.path.join(_CRED_DIR, f"{cred_name}.cred")
    key_file  = os.path.join(_CRED_DIR, "aes.key")
    if not os.path.exists(cred_file):
        raise RuntimeError(f"Credential file not found: {cred_file}\nRun New-PVECredential.ps1")
    if not os.path.exists(key_file):
        raise RuntimeError(f"AES key file not found: {key_file}")
    ps = (
        f"$s = Get-Content '{cred_file}' | ConvertTo-SecureString -Key (Get-Content '{key_file}');"
        "$b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);"
        "[System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)"
    )
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-Command", ps],
        capture_output=True, text=True, timeout=15
    )
    secret = result.stdout.strip().splitlines()[-1].strip()
    if not secret or result.returncode != 0:
        raise RuntimeError(f"Failed to decrypt credential: {result.stderr.strip()}")
    return secret


# Load at startup
_cfg         = _load_config()
_cluster     = _cfg["Clusters"][0]           # default: first cluster
CLUSTER_NAME = _cluster["Name"]
API_NODE     = _cluster["APINode"]
TOKEN_USER   = _cfg["PVE_TokenUser"]
TOKEN_NAME   = _cfg["PVE_TokenName"]
TOKEN_ID     = f"{TOKEN_USER}!{TOKEN_NAME}"
CRED_NAME    = _cluster.get("CredentialName", TOKEN_ID)
PORT         = int(os.environ.get("PVE_PORT", "8006"))
TOKEN_SECRET = _load_token_secret(CRED_NAME)




BASE_URL = f"https://{API_NODE}:{PORT}/api2/json"

# TLS context — skip verify (self-signed PVE cert)
_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode    = ssl.CERT_NONE


# ─────────────────────────────────────────────
# PVE API client
# ─────────────────────────────────────────────

def _pve_request(path: str) -> Any:
    """Make a GET request to the PVE API. Returns .data field."""
    if not API_NODE or not TOKEN_ID or not TOKEN_SECRET:
        raise RuntimeError(
            "Missing PVE credentials. Set PVE_API_NODE, PVE_TOKEN_ID, PVE_TOKEN_SECRET."
        )
    url     = f"{BASE_URL}{path}"
    headers = {
        "Authorization": f"PVEAPIToken={TOKEN_ID}={TOKEN_SECRET}",
    }
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, context=_SSL_CTX, timeout=30) as resp:
            body = json.loads(resp.read())
            return body.get("data", body)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"PVE API HTTP {e.code}: {e.reason} [{path}]")
    except Exception as e:
        raise RuntimeError(f"PVE API error [{path}]: {e}")


def _get_nodes() -> list[dict]:
    return _pve_request("/nodes") or []


def _get_vms(node: str) -> list[dict]:
    try:
        return _pve_request(f"/nodes/{node}/qemu") or []
    except Exception:
        return []


def _get_vm_config(node: str, vmid: int) -> dict:
    return _pve_request(f"/nodes/{node}/qemu/{vmid}/config") or {}


def _get_node_storage(node: str) -> list[dict]:
    try:
        return _pve_request(f"/nodes/{node}/storage") or []
    except Exception:
        return []


def _get_vm_snapshots(node: str, vmid: int) -> list[dict]:
    try:
        return _pve_request(f"/nodes/{node}/qemu/{vmid}/snapshot") or []
    except Exception:
        return []


def _get_lxc(node: str) -> list[dict]:
    try: return _pve_request(f"/nodes/{node}/lxc") or []
    except Exception: return []

def _get_vm_status_live(node: str, vmid: int) -> dict:
    return _pve_request(f"/nodes/{node}/qemu/{vmid}/status/current") or {}

def _get_node_status(node: str) -> dict:
    return _pve_request(f"/nodes/{node}/status") or {}

def _get_node_network(node: str) -> list[dict]:
    try: return _pve_request(f"/nodes/{node}/network") or []
    except Exception: return []

def _get_node_disks(node: str) -> list[dict]:
    try: return _pve_request(f"/nodes/{node}/disks/list") or []
    except Exception: return []

def _get_storage_content(node: str, storage: str, ctype: str = "") -> list[dict]:
    path = f"/nodes/{node}/storage/{storage}/content"
    if ctype: path += f"?content={ctype}"
    try: return _pve_request(path) or []
    except Exception: return []

def _get_cluster_resources(rtype: str = "") -> list[dict]:
    path = "/cluster/resources"
    if rtype: path += f"?type={rtype}"
    try: return _pve_request(path) or []
    except Exception: return []

def _get_cluster_tasks(limit: int = 50) -> list[dict]:
    try: return _pve_request(f"/cluster/tasks?limit={limit}") or []
    except Exception: return []

def _get_backup_jobs() -> list[dict]:
    try: return _pve_request("/cluster/backup") or []
    except Exception: return []

def _get_ha_info() -> dict:
    try:
        return {"status": _pve_request("/cluster/ha/status/current") or {},
                "resources": _pve_request("/cluster/ha/resources") or []}
    except Exception as e:
        return {"error": str(e)}

def _get_replication_jobs() -> list[dict]:
    try: return _pve_request("/cluster/replication") or []
    except Exception: return []

def _get_firewall_rules(node: str, vmid: int = 0) -> list[dict]:
    try:
        path = f"/nodes/{node}/qemu/{vmid}/firewall/rules" if vmid else f"/nodes/{node}/firewall/rules"
        return _pve_request(path) or []
    except Exception: return []

def _get_agent_info(node: str, vmid: int) -> dict:
    out = {}
    for ep, k in [("network-get-interfaces","nics"),("get-osinfo","os"),("get-host-name","hostname")]:
        try: out[k] = _pve_request(f"/nodes/{node}/qemu/{vmid}/agent/{ep}")
        except Exception: out[k] = None
    return out

def _get_rrddata(path: str, timeframe: str = "hour") -> list[dict]:
    try: return _pve_request(f"{path}?timeframe={timeframe}&cf=AVERAGE") or []
    except Exception: return []

def _get_node_services(node: str) -> list[dict]:
    try: return _pve_request(f"/nodes/{node}/services") or []
    except Exception: return []

def _get_node_pci(node: str) -> list[dict]:
    try: return _pve_request(f"/nodes/{node}/hardware/pci") or []
    except Exception: return []

def _get_vm_pending(node: str, vmid: int) -> list[dict]:
    try: return _pve_request(f"/nodes/{node}/qemu/{vmid}/pending") or []
    except Exception: return []

def _get_node_certs(node: str) -> list[dict]:
    try: return _pve_request(f"/nodes/{node}/certificates/info") or []
    except Exception: return []


# ─────────────────────────────────────────────
# MCP Server
# ─────────────────────────────────────────────

server = Server("proxmox-manager")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="pve_list_vms",
            description=(
                "List QEMU VMs in the Proxmox cluster. "
                "Optionally filter by name (supports * wildcard) or status (running/stopped)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "name_filter": {
                        "type": "string",
                        "description": "VM name filter (wildcard * supported). E.g. 'hrz*', 'hrzwpsystools01'."
                    },
                    "status_filter": {
                        "type": "string",
                        "enum": ["running", "stopped", "all"],
                        "description": "Filter by VM status. Default: all.",
                        "default": "all"
                    }
                }
            }
        ),
        types.Tool(
            name="pve_get_vm_disks",
            description=(
                "Get disk/storage layout for a specific VM. "
                "Returns storage pool name, disk path, and size for each disk."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "vm_name": {
                        "type": "string",
                        "description": "VM name (exact) or VMID (numeric)."
                    }
                },
                "required": ["vm_name"]
            }
        ),
        types.Tool(
            name="pve_get_storage",
            description=(
                "List storage pools in the Proxmox cluster with capacity info "
                "(type, total GB, free GB, used %)."
            ),
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        types.Tool(
            name="pve_get_snapshots",
            description=(
                "List Proxmox-level snapshots for a VM (or all VMs if no name given). "
                "Note: these are PVE snapshots, NOT NetApp ONTAP volume snapshots."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "vm_name": {
                        "type": "string",
                        "description": "VM name or VMID. Leave empty to list snapshots for all VMs (slow)."
                    }
                }
            }
        ),
        types.Tool(
            name="pve_get_nodes",
            description="List all nodes in the Proxmox cluster with status, memory, and uptime.",
            inputSchema={"type": "object", "properties": {}}
        ),
        # ── NEW TOOLS ──────────────────────────────────────────────────
        types.Tool(
            name="pve_get_vm_config",
            description="Full VM config: CPU type, BIOS, boot order, NIC list, disk config, tags, description.",
            inputSchema={"type":"object","properties":{"vm_name":{"type":"string","description":"VM name or VMID."}},"required":["vm_name"]}
        ),
        types.Tool(
            name="pve_get_vm_status",
            description="Live VM metrics: CPU%, RAM used/max, PID, uptime, QMP status, lock, tags.",
            inputSchema={"type":"object","properties":{"vm_name":{"type":"string","description":"VM name or VMID."}},"required":["vm_name"]}
        ),
        types.Tool(
            name="pve_get_cluster_resources",
            description="All cluster resources in one bulk call: VMs, nodes, storage, LXC. Fast overview.",
            inputSchema={"type":"object","properties":{"type":{"type":"string","enum":["vm","node","storage","sdn","all"],"default":"all","description":"Resource type filter."}}}
        ),
        types.Tool(
            name="pve_list_lxc",
            description="List LXC containers across all nodes (name, status, RAM, CPU, disk).",
            inputSchema={"type":"object","properties":{"node":{"type":"string","description":"Filter to specific node (optional)."},"status_filter":{"type":"string","enum":["running","stopped","all"],"default":"all"}}}
        ),
        types.Tool(
            name="pve_get_node_status",
            description="Detailed node metrics: CPU%, RAM, swap, load averages, disk, kernel, PVE version.",
            inputSchema={"type":"object","properties":{"node":{"type":"string","description":"Node name, e.g. thclprhevh01."}},"required":["node"]}
        ),
        types.Tool(
            name="pve_get_node_network",
            description="All NICs and bridges on a node: IP, netmask, gateway, MAC, bridge ports.",
            inputSchema={"type":"object","properties":{"node":{"type":"string","description":"Node name."}},"required":["node"]}
        ),
        types.Tool(
            name="pve_get_node_disks",
            description="Physical disks on a node: model, serial, size, type, S.M.A.R.T. health, wear.",
            inputSchema={"type":"object","properties":{"node":{"type":"string","description":"Node name."}},"required":["node"]}
        ),
        types.Tool(
            name="pve_get_storage_content",
            description="List content of a storage pool: VM images, ISOs, backups, templates.",
            inputSchema={"type":"object","properties":{"node":{"type":"string"},"storage":{"type":"string"},"content_type":{"type":"string","enum":["images","iso","backup","vztmpl","all"],"default":"all"}},"required":["node","storage"]}
        ),
        types.Tool(
            name="pve_get_cluster_tasks",
            description="Cluster task history: migrations, backups, clones, snapshot operations.",
            inputSchema={"type":"object","properties":{"limit":{"type":"integer","default":50,"description":"Max tasks to return."}}}
        ),
        types.Tool(
            name="pve_get_backup_jobs",
            description="List configured vzdump backup jobs: schedule, storage, VMs, compression, mode.",
            inputSchema={"type":"object","properties":{}}
        ),
        types.Tool(
            name="pve_get_ha_status",
            description="HA cluster status and list of HA-managed resources.",
            inputSchema={"type":"object","properties":{}}
        ),
        types.Tool(
            name="pve_get_replication_jobs",
            description="List VM replication jobs: source, target, schedule, rate, status.",
            inputSchema={"type":"object","properties":{}}
        ),
        types.Tool(
            name="pve_get_firewall_rules",
            description="Firewall rules for a node or a specific VM.",
            inputSchema={"type":"object","properties":{"node":{"type":"string","description":"Node name."},"vm_name":{"type":"string","description":"VM name/VMID for VM-level rules. Omit for node-level."}},"required":["node"]}
        ),
        types.Tool(
            name="pve_get_vm_agent",
            description="QEMU guest agent data: IP addresses, OS info, hostname. Requires agent installed inside VM.",
            inputSchema={"type":"object","properties":{"vm_name":{"type":"string","description":"VM name or VMID."}},"required":["vm_name"]}
        ),
        types.Tool(
            name="pve_get_vm_rrddata",
            description="Historical metrics for a VM: CPU, RAM, net I/O, disk I/O over time.",
            inputSchema={"type":"object","properties":{"vm_name":{"type":"string"},"timeframe":{"type":"string","enum":["hour","day","week","month","year"],"default":"hour"}},"required":["vm_name"]}
        ),
        types.Tool(
            name="pve_get_node_rrddata",
            description="Historical metrics for a node: CPU, RAM, net, disk over time.",
            inputSchema={"type":"object","properties":{"node":{"type":"string"},"timeframe":{"type":"string","enum":["hour","day","week","month","year"],"default":"hour"}},"required":["node"]}
        ),
        types.Tool(
            name="pve_get_node_services",
            description="systemd services on a node: pveproxy, pvedaemon, pve-ha-*, corosync, etc.",
            inputSchema={"type":"object","properties":{"node":{"type":"string","description":"Node name."}},"required":["node"]}
        ),
        types.Tool(
            name="pve_get_node_pci",
            description="PCI devices available for passthrough on a node (IOMMU groups, vendor, class).",
            inputSchema={"type":"object","properties":{"node":{"type":"string","description":"Node name."}},"required":["node"]}
        ),
        types.Tool(
            name="pve_get_vm_pending",
            description="Config changes pending reboot for a VM (diff between live and stored config).",
            inputSchema={"type":"object","properties":{"vm_name":{"type":"string","description":"VM name or VMID."}},"required":["vm_name"]}
        ),
        types.Tool(
            name="pve_get_node_certificates",
            description="TLS certificates on a node: subject, issuer, fingerprint, expiry dates.",
            inputSchema={"type":"object","properties":{"node":{"type":"string","description":"Node name."}},"required":["node"]}
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    try:
        result = await _dispatch(name, arguments)
        return [types.TextContent(type="text", text=json.dumps(result, indent=2, default=str))]
    except Exception as e:
        return [types.TextContent(type="text", text=f"Error: {e}")]


async def _dispatch(name: str, args: dict) -> Any:
    if name == "pve_get_nodes":
        return _tool_get_nodes()
    elif name == "pve_list_vms":
        return _tool_list_vms(
            name_filter=args.get("name_filter", ""),
            status_filter=args.get("status_filter", "all")
        )
    elif name == "pve_get_vm_disks":
        return _tool_get_vm_disks(args["vm_name"])
    elif name == "pve_get_storage":
        return _tool_get_storage()
    elif name == "pve_get_snapshots":
        return _tool_get_snapshots(args.get("vm_name", ""))
    elif name == "pve_get_vm_config":
        return _tool_get_vm_config(args["vm_name"])
    elif name == "pve_get_vm_status":
        return _tool_get_vm_status(args["vm_name"])
    elif name == "pve_get_cluster_resources":
        return _get_cluster_resources(args.get("type", ""))
    elif name == "pve_list_lxc":
        return _tool_list_lxc(args.get("node", ""), args.get("status_filter", "all"))
    elif name == "pve_get_node_status":
        return _get_node_status(args["node"])
    elif name == "pve_get_node_network":
        return _get_node_network(args["node"])
    elif name == "pve_get_node_disks":
        return _get_node_disks(args["node"])
    elif name == "pve_get_storage_content":
        return _get_storage_content(args["node"], args["storage"], args.get("content_type", ""))
    elif name == "pve_get_cluster_tasks":
        return _get_cluster_tasks(args.get("limit", 50))
    elif name == "pve_get_backup_jobs":
        return _get_backup_jobs()
    elif name == "pve_get_ha_status":
        return _get_ha_info()
    elif name == "pve_get_replication_jobs":
        return _get_replication_jobs()
    elif name == "pve_get_firewall_rules":
        return _tool_get_firewall_rules(args["node"], args.get("vm_name", ""))
    elif name == "pve_get_vm_agent":
        return _tool_get_vm_agent(args["vm_name"])
    elif name == "pve_get_vm_rrddata":
        node, vmid, _ = _resolve_vm(args["vm_name"])
        return _get_rrddata(f"/nodes/{node}/qemu/{vmid}/rrddata", args.get("timeframe", "hour"))
    elif name == "pve_get_node_rrddata":
        return _get_rrddata(f"/nodes/{args['node']}/rrddata", args.get("timeframe", "hour"))
    elif name == "pve_get_node_services":
        return _get_node_services(args["node"])
    elif name == "pve_get_node_pci":
        return _get_node_pci(args["node"])
    elif name == "pve_get_vm_pending":
        node, vmid, _ = _resolve_vm(args["vm_name"])
        return _get_vm_pending(node, vmid)
    elif name == "pve_get_node_certificates":
        return _get_node_certs(args["node"])
    else:
        raise ValueError(f"Unknown tool: {name}")


# ─────────────────────────────────────────────
# Tool implementations
# ─────────────────────────────────────────────

def _tool_get_nodes() -> list[dict]:
    nodes = _get_nodes()
    return [
        {
            "node":    n.get("node"),
            "status":  n.get("status"),
            "mem_gb":  round(n.get("maxmem", 0) / 1e9, 1),
            "disk_gb": round(n.get("maxdisk", 0) / 1e9, 1),
            "uptime_h": round(n.get("uptime", 0) / 3600, 1),
        }
        for n in nodes
    ]


def _tool_list_vms(name_filter: str = "", status_filter: str = "all") -> list[dict]:
    import fnmatch
    nodes   = _get_nodes()
    results = []
    for n in nodes:
        node_name = n.get("node", "")
        for vm in _get_vms(node_name):
            vm_name   = vm.get("name", "")
            vm_status = vm.get("status", "")
            if name_filter and not fnmatch.fnmatch(vm_name.lower(), name_filter.lower()):
                continue
            if status_filter != "all" and vm_status != status_filter:
                continue
            results.append({
                "cluster":  CLUSTER_NAME,
                "node":     node_name,
                "vmid":     vm.get("vmid"),
                "name":     vm_name,
                "status":   vm_status,
                "mem_gb":   round(vm.get("maxmem", 0) / 1e9, 1),
                "cpus":     vm.get("cpus"),
                "uptime_h": round(vm.get("uptime", 0) / 3600, 1),
            })
    return sorted(results, key=lambda x: (x["node"], x["name"]))


def _resolve_vm(vm_name: str) -> tuple[str, int, str]:
    """Returns (node, vmid, name). Raises if not found."""
    nodes = _get_nodes()
    for n in nodes:
        node_name = n.get("node", "")
        for vm in _get_vms(node_name):
            name = vm.get("name", "")
            vmid = vm.get("vmid")
            if name == vm_name or str(vmid) == str(vm_name):
                return node_name, vmid, name
    raise ValueError(f"VM '{vm_name}' not found in cluster {CLUSTER_NAME}")


def _tool_get_vm_disks(vm_name: str) -> list[dict]:
    node, vmid, name = _resolve_vm(vm_name)
    config = _get_vm_config(node, vmid)
    disk_keys = [k for k in config if
                 any(k.startswith(p) for p in ("scsi", "virtio", "ide", "sata", "efidisk", "tpmstate"))
                 and "cdrom" not in str(config[k]) and "none" not in str(config[k])]
    disks = []
    for key in sorted(disk_keys):
        val   = config[key]
        parts = val.split(",", 1)
        loc   = parts[0]
        opts  = parts[1] if len(parts) > 1 else ""
        size  = next((o.split("=")[1] for o in opts.split(",") if o.startswith("size=")), "?")
        stor, path = (loc.split(":", 1) + [""])[:2]
        disks.append({
            "vm":      name,
            "vmid":    vmid,
            "node":    node,
            "disk":    key,
            "storage": stor,
            "path":    path,
            "size":    size,
        })
    return disks


def _tool_get_storage() -> list[dict]:
    nodes = _get_nodes()
    if not nodes:
        return []
    node_name = nodes[0].get("node", "")
    storages  = _get_node_storage(node_name)
    return sorted([
        {
            "storage":  s.get("storage"),
            "type":     s.get("type"),
            "shared":   bool(s.get("shared")),
            "total_gb": round(s.get("total", 0) / 1e9, 1),
            "free_gb":  round(s.get("avail", 0) / 1e9, 1),
            "used_pct": round(((s.get("total", 0) - s.get("avail", 0)) / s.get("total", 1)) * 100, 1)
                        if s.get("total") else 0,
        }
        for s in storages
    ], key=lambda x: x["storage"])


def _tool_get_snapshots(vm_name: str = "") -> list[dict]:
    from datetime import datetime, timezone
    results = []
    if vm_name:
        vms_to_check = [_resolve_vm(vm_name)]
    else:
        nodes = _get_nodes()
        vms_to_check = []
        for n in nodes:
            for vm in _get_vms(n.get("node", "")):
                vms_to_check.append((n.get("node", ""), vm.get("vmid"), vm.get("name", "")))

    for node, vmid, name in vms_to_check:
        for snap in _get_vm_snapshots(node, vmid):
            if snap.get("name") == "current":
                continue
            snaptime = snap.get("snaptime")
            results.append({
                "vm":          name,
                "vmid":        vmid,
                "node":        node,
                "snapshot":    snap.get("name"),
                "description": snap.get("description", ""),
                "created":     datetime.fromtimestamp(snaptime, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")
                               if snaptime else "-",
                "has_ram":     bool(snap.get("vmstate")),
            })
    return sorted(results, key=lambda x: (x["vm"], x["created"]))


def _tool_get_vm_config(vm_name: str) -> dict:
    node, vmid, name = _resolve_vm(vm_name)
    cfg = _get_vm_config(node, vmid)
    cfg["_vm_name"] = name
    cfg["_node"]    = node
    cfg["_vmid"]    = vmid
    return cfg


def _tool_get_vm_status(vm_name: str) -> dict:
    node, vmid, name = _resolve_vm(vm_name)
    s = _get_vm_status_live(node, vmid)
    maxmem = s.get("maxmem", 1) or 1
    return {
        "name":       name,
        "vmid":       vmid,
        "node":       node,
        "status":     s.get("status"),
        "cpu_pct":    round(s.get("cpu", 0) * 100, 2),
        "mem_used_gb":round(s.get("mem", 0) / 1e9, 2),
        "mem_max_gb": round(s.get("maxmem", 0) / 1e9, 1),
        "mem_pct":    round(s.get("mem", 0) / maxmem * 100, 1),
        "uptime_h":   round(s.get("uptime", 0) / 3600, 1),
        "pid":        s.get("pid"),
        "lock":       s.get("lock"),
        "qmpstatus":  s.get("qmpstatus"),
        "tags":       s.get("tags"),
    }


def _tool_list_lxc(node_filter: str = "", status_filter: str = "all") -> list[dict]:
    import fnmatch
    nodes = _get_nodes()
    results = []
    for n in nodes:
        nname = n.get("node", "")
        if node_filter and not fnmatch.fnmatch(nname, node_filter):
            continue
        for c in _get_lxc(nname):
            st = c.get("status", "")
            if status_filter != "all" and st != status_filter:
                continue
            results.append({
                "node":     nname,
                "ctid":     c.get("vmid"),
                "name":     c.get("name"),
                "status":   st,
                "mem_gb":   round(c.get("maxmem", 0) / 1e9, 1),
                "cpus":     c.get("cpus"),
                "disk_gb":  round(c.get("maxdisk", 0) / 1e9, 1),
                "uptime_h": round(c.get("uptime", 0) / 3600, 1),
            })
    return sorted(results, key=lambda x: (x["node"], x["name"] or ""))


def _tool_get_firewall_rules(node: str, vm_name: str = "") -> list[dict]:
    vmid = 0
    if vm_name:
        _, vmid, _ = _resolve_vm(vm_name)
    return _get_firewall_rules(node, vmid)


def _tool_get_vm_agent(vm_name: str) -> dict:
    node, vmid, name = _resolve_vm(vm_name)
    info = _get_agent_info(node, vmid)
    return {"vm": name, "vmid": vmid, "node": node, **info}


# ─────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────

async def _run_stdio():
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="proxmox-manager",
                server_version="1.0.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={}
                ),
            ),
        )


async def _run_sse(port: int, api_key: str):
    """Phase 2: HTTP/SSE transport with Bearer token auth."""
    try:
        from mcp.server.sse import SseServerTransport
        from starlette.applications import Starlette
        from starlette.routing import Route, Mount
        from starlette.responses import JSONResponse
        from starlette.middleware.base import BaseHTTPMiddleware
        import uvicorn

        class BearerAuthMiddleware(BaseHTTPMiddleware):
            async def dispatch(self, request, call_next):
                if api_key:
                    auth = request.headers.get("Authorization", "")
                    if auth != f"Bearer {api_key}":
                        return JSONResponse({"error": "Unauthorized"}, status_code=401)
                return await call_next(request)

        sse = SseServerTransport("/messages")

        async def handle_sse(request):
            async with sse.connect_sse(request.scope, request.receive, request._send) as streams:
                await server.run(
                    streams[0], streams[1],
                    InitializationOptions(
                        server_name="proxmox-manager",
                        server_version="1.0.0",
                        capabilities=server.get_capabilities(
                            notification_options=None,
                            experimental_capabilities={}
                        ),
                    ),
                )

        app = Starlette(
            routes=[
                Route("/sse", endpoint=handle_sse),
                Mount("/messages", app=sse.handle_post_message),
                Route("/health", endpoint=lambda r: JSONResponse({"status": "ok", "cluster": CLUSTER_NAME})),
            ]
        )
        app.add_middleware(BearerAuthMiddleware)

        print(f"[pve-mcp] Starting SSE server on port {port}", file=sys.stderr)
        print(f"[pve-mcp] Cluster: {CLUSTER_NAME} @ {API_NODE}", file=sys.stderr)
        print(f"[pve-mcp] Auth: {'enabled' if api_key else 'DISABLED'}", file=sys.stderr)
        await uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=port)).serve()

    except ImportError as e:
        print(f"[pve-mcp] SSE transport requires extra deps: pip install starlette uvicorn", file=sys.stderr)
        raise


if __name__ == "__main__":
    import asyncio

    parser = argparse.ArgumentParser(description="Proxmox VE MCP Server")
    parser.add_argument("--transport", choices=["stdio", "sse"], default="stdio")
    parser.add_argument("--port",      type=int, default=8080)
    parser.add_argument("--api-key",   default=os.environ.get("PVE_MCP_API_KEY", ""))
    args = parser.parse_args()

    if args.transport == "sse":
        asyncio.run(_run_sse(args.port, args.api_key))
    else:
        asyncio.run(_run_stdio())
