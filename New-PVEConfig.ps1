#Requires -Version 7
<#
.SYNOPSIS
    Interactive wizard to create Config/nodes.json for Proxmox Manager.
    Run this once on first setup.

.PARAMETER Skip
    Skip the wizard and write a generic template (fill in details manually).

.EXAMPLE
    .\New-PVEConfig.ps1
    .\New-PVEConfig.ps1 -Skip
#>
param(
    [switch]$Skip
)

$ConfigPath = Join-Path $PSScriptRoot "Config\nodes.json"
$CredPath   = Join-Path $PSScriptRoot "credentials"

# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────
function Write-Header {
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │   PVE Config Wizard — nodes.json     │" -ForegroundColor Cyan
    Write-Host "  └──────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
}

function Prompt-Input {
    param([string]$Label, [string]$Default)
    if ($Default) {
        $input = Read-Host "  $Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
        return $input.Trim()
    }
    do { $input = Read-Host "  $Label" } while ([string]::IsNullOrWhiteSpace($input))
    return $input.Trim()
}

function Prompt-Secret {
    param([string]$Label)
    do {
        $secure = Read-Host "  $Label" -AsSecureString
        $plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    } while ([string]::IsNullOrWhiteSpace($plain))
    return $plain
}

function Fetch-Nodes {
    param([string]$APINode, [int]$Port, [string]$TokenId, [string]$Secret)
    $uri     = "https://${APINode}:${Port}/api2/json/nodes"
    $headers = @{ Authorization = "PVEAPIToken=${TokenId}=${Secret}" }
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers `
                    -SkipCertificateCheck -SkipHeaderValidation -TimeoutSec 10
        return ($resp.data | Sort-Object node | Select-Object -ExpandProperty node)
    } catch {
        return $null
    }
}

function Save-Token {
    param([string]$TokenId, [string]$Secret)
    $credFile = Join-Path $CredPath "$TokenId.cred"
    if (-not (Test-Path $CredPath)) { New-Item -ItemType Directory -Path $CredPath -Force | Out-Null }

    $keyFile = Join-Path $CredPath "$TokenId.key"
    $key     = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($key)
    $key | Set-Content $keyFile -Encoding Byte

    $encrypted = ConvertTo-SecureString $Secret -AsPlainText -Force |
                 ConvertFrom-SecureString -Key $key
    $encrypted | Set-Content $credFile -Encoding UTF8
    Write-Host "  💾 Token saved → credentials/$TokenId.cred" -ForegroundColor DarkGray
}

function Write-Config {
    param([object]$Config)
    if (-not (Test-Path (Split-Path $ConfigPath))) {
        New-Item -ItemType Directory -Path (Split-Path $ConfigPath) -Force | Out-Null
    }
    $Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
}

# ─────────────────────────────────────────────
# SKIP MODE — generic template
# ─────────────────────────────────────────────
if ($Skip) {
    $template = [ordered]@{
        PVE_TokenUser = "user@realm"
        PVE_TokenName = "tokenname"
        Clusters      = @(
            [ordered]@{
                Name           = "CLUSTER1"
                Description    = "My Proxmox Cluster"
                APINode        = "pve-node.domain.local"
                Port           = 8006
                Nodes          = @("<fill-in-node1>", "<fill-in-node2>")
                CredentialName = "user@realm!tokenname"
            }
        )
    }
    Write-Config $template
    Write-Host ""
    Write-Host "  ✅ Template written → Config/nodes.json" -ForegroundColor Green
    Write-Host "  ✏️  Edit it and replace all <fill-in-*> placeholders." -ForegroundColor Yellow
    Write-Host "  💡 Then run: .\New-PVECredential.ps1 to save your token." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ─────────────────────────────────────────────
# WIZARD
# ─────────────────────────────────────────────
Write-Header

# Check if config exists already
if (Test-Path $ConfigPath) {
    Write-Host "  ⚠️  Config/nodes.json already exists." -ForegroundColor Yellow
    $overwrite = Read-Host "  Overwrite? (y/N)"
    if ($overwrite -notmatch '^[Yy]') {
        Write-Host "  Aborted." -ForegroundColor DarkGray
        exit 0
    }
    Write-Host ""
}

# Token user (shared across clusters)
Write-Host "  Step 1/4 — Token Identity" -ForegroundColor Yellow
$tokenUser = Prompt-Input "Token user (e.g. JDoe@DOMAIN)"
$tokenName = Prompt-Input "Token name (e.g. jdoe)"
$tokenId   = "${tokenUser}!${tokenName}"
Write-Host ""

# Secret
Write-Host "  Step 2/4 — API Secret" -ForegroundColor Yellow
$secret = Prompt-Secret "Token secret (hidden)"
Write-Host ""

# Cluster details
Write-Host "  Step 3/4 — Cluster Details" -ForegroundColor Yellow
$clusterName = Prompt-Input "Cluster name (e.g. THC)"
$clusterDesc = Prompt-Input "Description" "Proxmox Cluster"
$apiNode     = Prompt-Input "API node hostname (e.g. pve01.domain.local)"
$port        = Prompt-Input "Port" "8006"
Write-Host ""

# Auto-fetch nodes
Write-Host "  Step 4/4 — Discovering Nodes..." -ForegroundColor Yellow
Write-Host "  Connecting to https://${apiNode}:${port} ..." -ForegroundColor DarkGray

$nodes = Fetch-Nodes -APINode $apiNode -Port $port -TokenId $tokenId -Secret $secret

if ($nodes) {
    Write-Host "  ✅ Found $($nodes.Count) nodes:" -ForegroundColor Green
    $nodes | ForEach-Object { Write-Host "     • $_" -ForegroundColor DarkGray }
} else {
    Write-Host "  ⚠️  Could not reach API — nodes will be empty (fill in manually)." -ForegroundColor Yellow
    $nodes = @("<could-not-fetch-check-connectivity>")
}
Write-Host ""

# Save token
Save-Token -TokenId $tokenId -Secret $secret

# Write config
$config = [ordered]@{
    PVE_TokenUser = $tokenUser
    PVE_TokenName = $tokenName
    Clusters      = @(
        [ordered]@{
            Name           = $clusterName
            Description    = $clusterDesc
            APINode        = $apiNode
            Port           = [int]$port
            Nodes          = $nodes
            CredentialName = $tokenId
        }
    )
}
Write-Config $config

Write-Host "  ✅ Config saved → Config/nodes.json" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    . .\proxmox-manager.ps1" -ForegroundColor White
Write-Host "    Connect-PVECluster -Name $clusterName" -ForegroundColor White
Write-Host "    Get-PVEVMs -ClusterName $clusterName" -ForegroundColor White
Write-Host ""
