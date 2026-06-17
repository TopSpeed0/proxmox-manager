<#
.SYNOPSIS
    Save the Proxmox API token to an AES-encrypted .cred file.
    Mirrors New-VCCredential.ps1 from VMware_Manager.

.DESCRIPTION
    Reads cluster/token info from Config/nodes.json.
    Copies the AES key from the NetApp workspace (shared key)
    and encrypts the token UUID into credentials/<TokenUser>!<TokenName>.cred

.PARAMETER TokenUUID
    The raw UUID of the API token.
    If omitted, reads from the existing NetApp credential store.

.PARAMETER CredentialName
    Override the output filename (default: read from nodes.json → Clusters[0].CredentialName)

.EXAMPLE
    .\New-PVECredential.ps1
    .\New-PVECredential.ps1 -TokenUUID "<uuid>"
#>
param(
    [string]$TokenUUID,
    [string]$CredentialName
)

$ErrorActionPreference = 'Stop'
$ScriptDir   = $PSScriptRoot
$credDir     = Join-Path $ScriptDir 'credentials'
$aesKeyPath  = Join-Path $credDir 'aes.key'

# Load CredentialName from nodes.json if not passed
if (-not $CredentialName) {
    $nodesJson = Join-Path $ScriptDir 'Config\nodes.json'
    if (Test-Path $nodesJson) {
        $cfg           = Get-Content $nodesJson -Raw | ConvertFrom-Json
        $CredentialName = $cfg.Clusters[0].CredentialName
    } else {
        throw "nodes.json not found and -CredentialName not provided. Run New-PVEConfig.ps1 first."
    }
}

# Derive NetApp workspace credentials dir from USERPROFILE (no hardcoded username)
$netappCredDir = Join-Path $env:USERPROFILE 'OneDrive - COGNYTE\Documents\code\Netapp-Code-WorkSpace\credentials'
$srcCredDir    = $netappCredDir
$credOutPath   = Join-Path $credDir "$CredentialName.cred"

# 1. Ensure credentials dir exists
if (-not (Test-Path $credDir)) { New-Item -ItemType Directory -Path $credDir | Out-Null }

# 2. Copy AES key from NetApp workspace (shared key)
$srcKey = Join-Path $srcCredDir 'aes.key'
if (-not (Test-Path $aesKeyPath)) {
    Write-Host "Copying AES key from NetApp workspace..." -ForegroundColor Cyan
    Copy-Item $srcKey $aesKeyPath
}

$aesKey = Get-Content $aesKeyPath

# 3. If no UUID given — try reading from existing NetApp cred
if (-not $TokenUUID) {
    $srcCred = Join-Path $srcCredDir "$CredentialName.cred"
    if (Test-Path $srcCred) {
        Write-Host "Reading token from existing NetApp cred: $CredentialName" -ForegroundColor Cyan
        $secure    = Get-Content $srcCred | ConvertTo-SecureString -Key $aesKey
        $bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $TokenUUID = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    } else {
        $TokenUUID = Read-Host "Enter API Token UUID"
    }
}

# 4. Encrypt and save
$securePwd = ConvertTo-SecureString $TokenUUID -AsPlainText -Force
$securePwd | ConvertFrom-SecureString -Key $aesKey | Set-Content $credOutPath

Write-Host "✓ Saved: $credOutPath" -ForegroundColor Green
Write-Host "  Token user: $CredentialName" -ForegroundColor Gray
