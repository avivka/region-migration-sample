<#
  02-failover-automation.ps1
  Attach this as a POST-failover script in the ASR recovery plan (Azure Automation runbook).
  At failover it: associates the target NSG to each NIC, assigns the new public IP, and adds
  the NIC to the target Load Balancer backend pool. Also re-enables Boot integrity monitoring note.

  In a recovery plan, ASR passes context via $RecoveryPlanContext (JSON). This script reads the
  failed-over VM resource IDs from that context. For standalone testing, pass -VmResourceIds.
#>

param(
    [string[]] $VmResourceIds,                       # optional override for manual runs
    [Parameter(Mandatory)] [string] $TargetResourceGroup,
    [Parameter(Mandatory)] [string] $TargetRegion,
    [string] $TargetNsgName   = $null,               # if null, infer "<source>-target" per NIC
    [string] $PublicIpName    = "pip-target-lb",
    [string] $LbName          = "lb-target",
    [string] $LbBackendPool   = "bepool"
)

$ErrorActionPreference = "Stop"

# ---- Resolve failed-over VMs from recovery plan context, or from param ----
if (-not $VmResourceIds -and $RecoveryPlanContext) {
    $ctx = $RecoveryPlanContext | ConvertFrom-Json
    $VmResourceIds = $ctx.VmMap.PSObject.Properties.Value.ResourceId
}
if (-not $VmResourceIds) { throw "No VM resource IDs supplied or found in recovery plan context." }

$lb       = Get-AzLoadBalancer -Name $LbName -ResourceGroupName $TargetResourceGroup
$bepool   = $lb.BackendAddressPools | Where-Object Name -eq $LbBackendPool
$pip      = Get-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $TargetResourceGroup

foreach ($vmId in $VmResourceIds) {
    $vm = Get-AzVM -ResourceId $vmId
    Write-Host "Wiring network for $($vm.Name)" -ForegroundColor Cyan

    foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id

        # 1. Associate NSG
        $nsgName = if ($TargetNsgName) { $TargetNsgName } else { "$($nic.Name)-target" }
        $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue
        if ($nsg) {
            $nic.NetworkSecurityGroup = $nsg
            Write-Host "  NSG $nsgName associated" -ForegroundColor Green
        } else {
            Write-Warning "  NSG $nsgName not found — skipping NSG association"
        }

        # 2. Assign public IP + 3. add to LB backend pool (primary ipconfig)
        $primary = $nic.IpConfigurations | Where-Object Primary -eq $true
        if (-not $primary) { $primary = $nic.IpConfigurations[0] }
        $primary.PublicIpAddress = $pip
        if ($primary.LoadBalancerBackendAddressPools.Id -notcontains $bepool.Id) {
            $primary.LoadBalancerBackendAddressPools.Add($bepool)
        }

        Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
        Write-Host "  Public IP assigned + added to LB backend pool $LbBackendPool" -ForegroundColor Green
    }

    # 4. Reminder: re-enable Boot integrity monitoring (not replicated by ASR)
    Write-Host "  ACTION: re-enable Boot integrity monitoring on $($vm.Name) (Trusted Launch state not replicated)" -ForegroundColor Yellow
}

Write-Host "Failover network wiring complete. Verify LB probes, then cut DNS to $($pip.IpAddress)." -ForegroundColor Cyan
