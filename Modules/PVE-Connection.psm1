#Requires -Version 5.1
<#
.SYNOPSIS
    Proxmox VE API connection and credential management.
.DESCRIPTION
    Mirrors the pattern of VMW-Connection.psm1 — AES-encrypted API token,
    per-cluster config from Config/nodes.json, non-interactive for AI/skill use.

    Auth: PVE API Token — loaded from Config/nodes.json + credentials/<name>.cred
    Header: Authorization: PVEAPIToken=<user>@<realm>!<tokenID>=<uuid>
#>

$script:PVEConnections = @{}          # [ClusterName] -> @{BaseUrl; Headers; Node}
$script:PVEConfigPath  = Join-Path $PSScriptRoot '..\Config\nodes.json'
$script:PVECredPath    = Join-Path $PSScriptRoot '..\credentials'
$script:PVEAesKeyPath  = Join-Path $PSScriptRoot '..\credentials\aes.key'

# PS 5.1 does not support -SkipCertificateCheck — bypass via callback instead
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
    Add-Type -TypeDefinition @'
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int e) { return true; }
}
'@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
}

# ──────────────────────────────────────────────
# Internal helpers
# ──────────────────────────────────────────────


function _PVE-GetConfig {
    if (-not (Test-Path $script:PVEConfigPath)) {
        throw "Config not found: $script:PVEConfigPath"
    }
    Get-Content $script:PVEConfigPath -Raw | ConvertFrom-Json
}

function _PVE-DecryptCred ([string]$CredentialName) {
    $credFile = Join-Path $script:PVECredPath "$CredentialName.cred"
    if (-not (Test-Path $script:PVEAesKeyPath)) { throw "AES key not found: $script:PVEAesKeyPath" }
    if (-not (Test-Path $credFile))             { throw "Cred file not found: $credFile" }

    $aesKey = Get-Content $script:PVEAesKeyPath
    $secure = Get-Content $credFile | ConvertTo-SecureString -Key $aesKey
    $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function _PVE-Invoke {
    param(
        [string]$ClusterName,
        [string]$Path,
        [string]$Method = 'GET',
        [hashtable]$Body
    )
    $conn = $script:PVEConnections[$ClusterName]
    if (-not $conn) { throw "Not connected to cluster '$ClusterName'. Run Connect-PVECluster first." }

    $uri    = "$($conn.BaseUrl)$Path"
    $params = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $conn.Headers
        ContentType = 'application/json'
    }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 5) }

    try {
        $r = Invoke-RestMethod @params
        return $r.data
    } catch {
        $msg = $_.ErrorDetails.Message
        try { $msg = ($msg | ConvertFrom-Json).errors | ConvertTo-Json } catch {}
        throw "PVE API error [$Method $Path]: $msg"
    }
}

# ──────────────────────────────────────────────
# Public functions
# ──────────────────────────────────────────────

function Get-PVEClusterList {
    <# Returns cluster list from Config/nodes.json #>
    (_PVE-GetConfig).Clusters
}

function Connect-PVECluster {
    <#
    .SYNOPSIS Connect to a Proxmox cluster by name using API token auth.
    .PARAMETER Name   Cluster name from nodes.json (e.g. THC)
    .PARAMETER Node   Override API node hostname/IP (optional — uses first node in config)
    .PARAMETER Token  Raw API token UUID (optional — reads from AES cred file by default)
    .EXAMPLE
        Connect-PVECluster -Name THC
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Node,
        [string]$Token
    )

    $cfg     = _PVE-GetConfig
    $cluster = $cfg.Clusters | Where-Object Name -eq $Name
    if (-not $cluster) { throw "Cluster '$Name' not found in nodes.json" }

    # Resolve node — use APINode if defined, else first in Nodes array
    if (-not $Node) {
        if ($cluster.APINode) {
            $Node = $cluster.APINode
        } elseif ($cluster.Nodes -and $cluster.Nodes.Count -gt 0) {
            $Node = $cluster.Nodes[0]
        } else {
            throw "No nodes defined for cluster '$Name'. Pass -Node <ip/hostname>."
        }
    }

    # Resolve token
    if (-not $Token) {
        $Token = _PVE-DecryptCred $cluster.CredentialName
    }

    $tokenUser = $cfg.PVE_TokenUser
    $tokenId   = $cfg.PVE_TokenName
    $baseUrl   = "https://${Node}:8006/api2/json"

    $headers = @{ Authorization = "PVEAPIToken=${tokenUser}!${tokenId}=${Token}" }

    # Test connection
    $test = Invoke-RestMethod -Uri "$baseUrl/version" -Headers $headers -Method GET
    if (-not $test.data.version) { throw "Connection test failed for $baseUrl" }

    $script:PVEConnections[$Name] = @{
        BaseUrl = $baseUrl
        Headers = $headers
        Node    = $Node
        Version = $test.data.version
    }

    Write-Host "✓ Connected to PVE cluster [$Name] node $Node — PVE $($test.data.version)" -ForegroundColor Green
}

function Disconnect-PVECluster {
    param([string]$Name)
    if ($Name) { $script:PVEConnections.Remove($Name) }
    else       { $script:PVEConnections.Clear() }
    Write-Host "Disconnected." -ForegroundColor Yellow
}

function Get-PVEConnectionStatus {
    if ($script:PVEConnections.Count -eq 0) {
        Write-Host "No active PVE connections." -ForegroundColor Yellow
        return
    }
    $script:PVEConnections.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            Cluster = $_.Key
            Node    = $_.Value.Node
            BaseUrl = $_.Value.BaseUrl
            Version = $_.Value.Version
        }
    }
}

function Assert-PVEConnection {
    param([Parameter(Mandatory)][string]$ClusterName)
    if (-not $script:PVEConnections[$ClusterName]) {
        throw "Not connected to PVE cluster '$ClusterName'. Run Connect-PVECluster -Name $ClusterName first."
    }
    return $true
}

Export-ModuleMember -Function Get-PVEClusterList, Connect-PVECluster, Disconnect-PVECluster, Get-PVEConnectionStatus, Assert-PVEConnection, _PVE-Invoke
