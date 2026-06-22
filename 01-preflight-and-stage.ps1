<#
  01-preflight-and-stage.ps1
  Cross-region ASR migration — captures source inventory and stamps the target-region fabric
  (VNet, subnets, NSGs, Load Balancer, public IP, Recovery Services vault).

  This script is idempotent-ish: it checks existence before creating. Review every -Force / create
  before running against production. Run in a non-prod sub first.

  Requires: Az.Accounts, Az.Network, Az.Compute, Az.RecoveryServices, Az.Resources
#>

param(
    [Parameter(Mandatory)] [string] $SourceResourceGroup,
    [Parameter(Mandatory)] [string] $SourceRegion,          # e.g. "southeastasia"
    [Parameter(Mandatory)] [string] $TargetResourceGroup,
    [Parameter(Mandatory)] [string] $TargetRegion,          # e.g. "eastasia"
    [Parameter(Mandatory)] [string] $VaultName,
    [Parameter(Mandatory)] [string[]] $VmNames,
    [string] $TargetVnetName   = "vnet-target",
    [string] $TargetVnetCidr   = "10.1.0.0/16",   # match source CIDR to retain private IPs
    [string] $TargetSubnetName = "snet-workload",
    [string] $TargetSubnetCidr = "10.1.1.0/24",
    [string] $InventoryOutPath = "./source-inventory.json"
)

$ErrorActionPreference = "Stop"
Write-Host "== Phase 0/1: Pre-flight inventory + target staging ==" -ForegroundColor Cyan

# ---------- 1. Capture source inventory (for parity validation + rebuild fallback) ----------
$inventory = @()
foreach ($vmName in $VmNames) {
    $vm  = Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $vmName -Status
    $cfg = Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $vmName

    # Trusted Launch / Gen2 / controller checks
    $securityType   = $cfg.SecurityProfile.SecurityType          # expect "TrustedLaunch"
    $secureBoot     = $cfg.SecurityProfile.UefiSettings.SecureBootEnabled
    $vTpm           = $cfg.SecurityProfile.UefiSettings.VTpmEnabled
    $diskController  = $cfg.StorageProfile.DiskControllerType      # "SCSI" or "NVMe"

    $dataDisks = $cfg.StorageProfile.DataDisks | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Lun = $_.Lun; SizeGB = $_.DiskSizeGB; Sku = $_.ManagedDisk.StorageAccountType }
    }

    $nicInfos = foreach ($nicRef in $cfg.NetworkProfile.NetworkInterfaces) {
        $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
        foreach ($ipc in $nic.IpConfigurations) {
            [pscustomobject]@{
                Nic           = $nic.Name
                PrivateIp     = $ipc.PrivateIpAddress
                Allocation    = $ipc.PrivateIpAllocationMethod
                HasPublicIp   = [bool]$ipc.PublicIpAddress
                Subnet        = ($ipc.Subnet.Id -split '/')[-1]
                NsgOnNic      = if ($nic.NetworkSecurityGroup) { ($nic.NetworkSecurityGroup.Id -split '/')[-1] } else { $null }
                LbBackends    = $ipc.LoadBalancerBackendAddressPools.Id
            }
        }
    }

    $record = [pscustomobject]@{
        Vm              = $vmName
        Size            = $cfg.HardwareProfile.VmSize
        HyperVGen       = $cfg.StorageProfile.ImageReference.Sku  # informational
        SecurityType    = $securityType
        SecureBoot      = $secureBoot
        vTPM            = $vTpm
        DiskController  = $diskController
        OsDiskSku       = $cfg.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
        DataDisks       = $dataDisks
        Nics            = $nicInfos
    }
    $inventory += $record

    Write-Host ("VM {0}: size={1} security={2} controller={3} dataDisks={4}" -f `
        $vmName, $cfg.HardwareProfile.VmSize, $securityType, $diskController, $dataDisks.Count) -ForegroundColor Yellow

    if ($securityType -ne "TrustedLaunch") {
        Write-Warning "  $vmName is not TrustedLaunch — confirm this is expected."
    }
}
$inventory | ConvertTo-Json -Depth 8 | Out-File -Encoding utf8 $InventoryOutPath
Write-Host "Inventory written to $InventoryOutPath" -ForegroundColor Green

# ---------- 2. Target region capacity check (controller-compatible size) ----------
Write-Host "Checking target region SKU availability..." -ForegroundColor Cyan
$neededSizes = $inventory.Size | Sort-Object -Unique
$available   = (Get-AzComputeResourceSku -Location $TargetRegion |
                Where-Object { $_.ResourceType -eq "virtualMachines" }).Name
foreach ($s in $neededSizes) {
    if ($available -contains $s) { Write-Host "  $s available in $TargetRegion" -ForegroundColor Green }
    else { Write-Warning "  $s NOT available in $TargetRegion — choose an alternate size or region." }
}

# ---------- 3. Target resource group ----------
if (-not (Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $TargetResourceGroup -Location $TargetRegion | Out-Null
    Write-Host "Created target RG $TargetResourceGroup" -ForegroundColor Green
}

# ---------- 4. Target VNet + subnet (match CIDR to retain private IPs) ----------
$vnet = Get-AzVirtualNetwork -Name $TargetVnetName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue
if (-not $vnet) {
    $subnet = New-AzVirtualNetworkSubnetConfig -Name $TargetSubnetName -AddressPrefix $TargetSubnetCidr
    $vnet   = New-AzVirtualNetwork -Name $TargetVnetName -ResourceGroupName $TargetResourceGroup `
                -Location $TargetRegion -AddressPrefix $TargetVnetCidr -Subnet $subnet
    Write-Host "Created target VNet $TargetVnetName ($TargetVnetCidr)" -ForegroundColor Green
}

# ---------- 5. Target NSGs (ASR does NOT replicate NSGs — must pre-create) ----------
# Replicate source NSG rules into target. Adjust naming as needed.
$sourceNsgs = Get-AzNetworkSecurityGroup -ResourceGroupName $SourceResourceGroup
foreach ($snsg in $sourceNsgs) {
    $tName = "$($snsg.Name)-target"
    if (-not (Get-AzNetworkSecurityGroup -Name $tName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue)) {
        $tnsg = New-AzNetworkSecurityGroup -Name $tName -ResourceGroupName $TargetResourceGroup -Location $TargetRegion
        foreach ($rule in $snsg.SecurityRules) {
            $tnsg | Add-AzNetworkSecurityRuleConfig -Name $rule.Name -Description $rule.Description `
                -Access $rule.Access -Protocol $rule.Protocol -Direction $rule.Direction `
                -Priority $rule.Priority -SourceAddressPrefix $rule.SourceAddressPrefix `
                -SourcePortRange $rule.SourcePortRange -DestinationAddressPrefix $rule.DestinationAddressPrefix `
                -DestinationPortRange $rule.DestinationPortRange | Out-Null
        }
        $tnsg | Set-AzNetworkSecurityGroup | Out-Null
        Write-Host "Created target NSG $tName with $($snsg.SecurityRules.Count) rules" -ForegroundColor Green
    }
}

# ---------- 6. Target public IP (new address — source PIP cannot move) ----------
$pipName = "pip-target-lb"
if (-not (Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzPublicIpAddress -Name $pipName -ResourceGroupName $TargetResourceGroup -Location $TargetRegion `
        -AllocationMethod Static -Sku Standard | Out-Null
    Write-Host "Created target public IP $pipName (NEW address — update DNS at cutover)" -ForegroundColor Green
}

# ---------- 7. Target Load Balancer (frontend + backend pool + probe + rule) ----------
$lbName = "lb-target"
if (-not (Get-AzLoadBalancer -Name $lbName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue)) {
    $pip   = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $TargetResourceGroup
    $fe    = New-AzLoadBalancerFrontendIpConfig -Name "fe" -PublicIpAddress $pip
    $bepool= New-AzLoadBalancerBackendAddressPoolConfig -Name "bepool"
    $probe = New-AzLoadBalancerProbeConfig -Name "tcp-probe" -Protocol Tcp -Port 80 -IntervalInSeconds 5 -ProbeCount 2
    $rule  = New-AzLoadBalancerRuleConfig -Name "rule-80" -FrontendIpConfiguration $fe `
                -BackendAddressPool $bepool -Probe $probe -Protocol Tcp -FrontendPort 80 -BackendPort 80
    New-AzLoadBalancer -Name $lbName -ResourceGroupName $TargetResourceGroup -Location $TargetRegion `
        -Sku Standard -FrontendIpConfiguration $fe -BackendAddressPool $bepool -Probe $probe -LoadBalancingRule $rule | Out-Null
    Write-Host "Created target Load Balancer $lbName" -ForegroundColor Green
}

# ---------- 8. Recovery Services vault (target region) ----------
if (-not (Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $TargetResourceGroup -Location $TargetRegion | Out-Null
    Write-Host "Created Recovery Services vault $VaultName" -ForegroundColor Green
}

Write-Host "`n== Pre-flight + staging complete. Review source-inventory.json, then enable replication. ==" -ForegroundColor Cyan
Write-Host "Next: enable replication per VM (network mapping -> target VNet/subnet, retain private IP, set target disk SKUs)." -ForegroundColor Cyan
