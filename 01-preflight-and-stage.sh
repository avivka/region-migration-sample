#!/usr/bin/env bash
#
# 01-preflight-and-stage.sh
# Cross-region ASR migration — captures source inventory and stamps the target-region fabric
# (VNet, subnets, NSGs, Load Balancer, public IP, Recovery Services vault).
#
# Bash/Azure CLI equivalent of 01-preflight-and-stage.ps1
#
# This script is idempotent: it checks existence before creating. Review every create
# before running against production. Run in a non-prod sub first.
#
# Requires: az cli, jq
#
# ──────────────────────────────────────────────────────────────────
# HYBRID APPROACH: AZURE RESOURCE MOVER + ASR
#
#   Azure Resource Mover does NOT support Trusted Launch VMs.
#   However, it CAN move infrastructure resources: VNet, NSG, PIP.
#
#   With --use-resource-mover, this script uses Resource Mover for
#   VNet, NSG, and PIP, then falls back to az CLI for LB and vault.
#   VMs/disks are always handled by ASR (scripts 02-04).
#
#   Without --use-resource-mover, all resources are created directly
#   via az CLI (original behavior, still the default).
# ──────────────────────────────────────────────────────────────────
#

set -euo pipefail

# ──────────────────────────── Colors ────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}$*${NC}"; }
ok()      { echo -e "${GREEN}$*${NC}"; }
warn()    { echo -e "${YELLOW}WARNING: $*${NC}" >&2; }
detail()  { echo -e "${YELLOW}$*${NC}"; }
err()     { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

# ──────────────────────────── Usage ─────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --source-rg NAME              Source resource group
  --source-region REGION        Source region (e.g. eastus)
  --target-rg NAME              Target resource group
  --target-region REGION        Target region (e.g. centralus)
  --vault-name NAME             Recovery Services vault name
  --vm-names VM1,VM2,...        Comma-separated list of VM names

Optional:
  --target-vnet NAME            Target VNet name            (default: vnet-target)
  --target-vnet-cidr CIDR       Target VNet address space   (default: 10.1.0.0/16)
  --target-subnet NAME          Target subnet name          (default: snet-workload)
  --target-subnet-cidr CIDR     Target subnet prefix        (default: 10.1.1.0/24)
  --inventory-out PATH          Inventory JSON output path  (default: ./source-inventory.json)
  --use-resource-mover          Use Azure Resource Mover for VNet, NSG, PIP
  --move-collection-name NAME   Move collection name        (default: mc-region-migration)
  -h, --help                    Show this help

Example:
  $(basename "$0") \\
    --source-rg rg-prod-eastus --source-region eastus \\
    --target-rg rg-prod-centralus --target-region centralus \\
    --vault-name vault-asr-centralus \\
    --vm-names "vm-app01,vm-app02" \\
    --target-vnet-cidr "10.0.0.0/16" --target-subnet-cidr "10.0.1.0/24"
EOF
    exit 0
}

# ──────────────────────────── Parse args ────────────────────────
SOURCE_RG=""
SOURCE_REGION=""
TARGET_RG=""
TARGET_REGION=""
VAULT_NAME=""
VM_NAMES_CSV=""
TARGET_VNET="vnet-target"
TARGET_VNET_CIDR="10.1.0.0/16"
TARGET_SUBNET="snet-workload"
TARGET_SUBNET_CIDR="10.1.1.0/24"
INVENTORY_OUT="./source-inventory.json"
USE_RESOURCE_MOVER=false
MOVE_COLLECTION_NAME="mc-region-migration"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-rg)       SOURCE_RG="$2";        shift 2;;
        --source-region)   SOURCE_REGION="$2";     shift 2;;
        --target-rg)       TARGET_RG="$2";         shift 2;;
        --target-region)   TARGET_REGION="$2";     shift 2;;
        --vault-name)      VAULT_NAME="$2";        shift 2;;
        --vm-names)        VM_NAMES_CSV="$2";      shift 2;;
        --target-vnet)     TARGET_VNET="$2";       shift 2;;
        --target-vnet-cidr)    TARGET_VNET_CIDR="$2";    shift 2;;
        --target-subnet)       TARGET_SUBNET="$2";       shift 2;;
        --target-subnet-cidr)  TARGET_SUBNET_CIDR="$2";  shift 2;;
        --inventory-out)   INVENTORY_OUT="$2";     shift 2;;
        --use-resource-mover)  USE_RESOURCE_MOVER=true;   shift;;
        --move-collection-name) MOVE_COLLECTION_NAME="$2"; shift 2;;
        -h|--help)         usage;;
        *) err "Unknown argument: $1";;
    esac
done

# Validate required params
[[ -z "$SOURCE_RG" ]]     && err "--source-rg is required"
[[ -z "$SOURCE_REGION" ]] && err "--source-region is required"
[[ -z "$TARGET_RG" ]]     && err "--target-rg is required"
[[ -z "$TARGET_REGION" ]] && err "--target-region is required"
[[ -z "$VAULT_NAME" ]]    && err "--vault-name is required"
[[ -z "$VM_NAMES_CSV" ]]  && err "--vm-names is required"

# Split comma-separated VM names into array
IFS=',' read -ra VM_NAMES <<< "$VM_NAMES_CSV"

info "== Phase 0/1: Pre-flight inventory + target staging =="

# ──────────────────── 1. Capture source inventory ───────────────
inventory_json="[]"

for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"  # trim whitespace

    info "Capturing inventory for VM: $vm_name"

    # Full VM JSON — source of truth
    vm_json=$(az vm show -g "$SOURCE_RG" -n "$vm_name" -o json)

    # Extract key properties
    vm_size=$(echo "$vm_json" | jq -r '.hardwareProfile.vmSize')
    security_type=$(echo "$vm_json" | jq -r '.securityProfile.securityType // "Standard"')
    secure_boot=$(echo "$vm_json" | jq -r '.securityProfile.uefiSettings.secureBootEnabled // false')
    vtpm=$(echo "$vm_json" | jq -r '.securityProfile.uefiSettings.vTpmEnabled // false')
    disk_controller=$(echo "$vm_json" | jq -r '.storageProfile.diskControllerType // "SCSI"')
    os_disk_name=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.name')
    os_disk_sku=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.managedDisk.storageAccountType')
    image_sku=$(echo "$vm_json" | jq -r '.storageProfile.imageReference.sku // "N/A"')

    # Data disks
    data_disks=$(echo "$vm_json" | jq '[.storageProfile.dataDisks[] | {name: .name, lun: .lun, sizeGB: .diskSizeGB, sku: .managedDisk.storageAccountType}]')
    data_disk_count=$(echo "$data_disks" | jq 'length')

    # NIC info
    nic_ids=$(echo "$vm_json" | jq -r '.networkProfile.networkInterfaces[].id')
    nic_infos="[]"
    for nic_id in $nic_ids; do
        nic_json=$(az network nic show --ids "$nic_id" -o json)
        nic_name=$(echo "$nic_json" | jq -r '.name')
        nsg_on_nic=$(echo "$nic_json" | jq -r '.networkSecurityGroup.id // empty' | awk -F'/' '{print $NF}')
        [[ -z "$nsg_on_nic" ]] && nsg_on_nic="null"

        ip_configs=$(echo "$nic_json" | jq '[.ipConfigurations[] | {
            privateIp: .privateIpAddress,
            allocation: .privateIpAllocationMethod,
            hasPublicIp: (.publicIpAddress != null),
            subnet: (.subnet.id | split("/") | last),
            lbBackends: [.loadBalancerBackendAddressPools[]?.id]
        }]')

        nic_entry=$(jq -n \
            --arg name "$nic_name" \
            --arg nsg "$nsg_on_nic" \
            --argjson ipConfigs "$ip_configs" \
            '{nic: $name, nsgOnNic: (if $nsg == "null" then null else $nsg end), ipConfigurations: $ipConfigs}')

        nic_infos=$(echo "$nic_infos" | jq --argjson entry "$nic_entry" '. + [$entry]')
    done

    # Build inventory record
    record=$(jq -n \
        --arg vm "$vm_name" \
        --arg size "$vm_size" \
        --arg hyperVGen "$image_sku" \
        --arg secType "$security_type" \
        --argjson secureBoot "$secure_boot" \
        --argjson vTPM "$vtpm" \
        --arg diskCtrl "$disk_controller" \
        --arg osDiskSku "$os_disk_sku" \
        --argjson dataDisks "$data_disks" \
        --argjson nics "$nic_infos" \
        '{
            vm: $vm,
            size: $size,
            hyperVGen: $hyperVGen,
            securityType: $secType,
            secureBoot: $secureBoot,
            vTPM: $vTPM,
            diskController: $diskCtrl,
            osDiskSku: $osDiskSku,
            dataDisks: $dataDisks,
            nics: $nics
        }')

    inventory_json=$(echo "$inventory_json" | jq --argjson rec "$record" '. + [$rec]')

    detail "  VM $vm_name: size=$vm_size security=$security_type controller=$disk_controller dataDisks=$data_disk_count"

    if [[ "$security_type" != "TrustedLaunch" ]]; then
        warn "$vm_name is not TrustedLaunch — confirm this is expected."
    fi
done

echo "$inventory_json" | jq '.' > "$INVENTORY_OUT"
ok "Inventory written to $INVENTORY_OUT"

# Derive LB/PIP names from source inventory
SOURCE_LB_ID=$(echo "$inventory_json" | jq -r '.[0].nics[0].ipConfigurations[0].lbBackends[0] // empty')
if [[ -n "$SOURCE_LB_ID" ]]; then
    SOURCE_LB=$(echo "$SOURCE_LB_ID" | awk -F'/loadBalancers/' '{print $2}' | awk -F'/' '{print $1}')
    SOURCE_BEPOOL=$(echo "$SOURCE_LB_ID" | awk -F'/backendAddressPools/' '{print $2}')
    LB_NAME="${SOURCE_LB}-target"
    PIP_NAME="pip-${SOURCE_LB}-target"
    detail "Derived from source inventory: LB=$LB_NAME PIP=$PIP_NAME POOL=$SOURCE_BEPOOL"
else
    LB_NAME="lb-target"
    PIP_NAME="pip-target-lb"
    detail "No source LB found in inventory — using defaults: LB=$LB_NAME PIP=$PIP_NAME"
fi

# ──────────── 2. Target region capacity check ───────────────────
info "Checking target region SKU availability..."
needed_sizes=$(echo "$inventory_json" | jq -r '.[].size' | sort -u)
available_skus=$(az vm list-skus -l "$TARGET_REGION" --resource-type virtualMachines --query "[].name" -o tsv)

for size in $needed_sizes; do
    if echo "$available_skus" | grep -qx "$size"; then
        ok "  $size available in $TARGET_REGION"
    else
        warn "$size NOT available in $TARGET_REGION — choose an alternate size or region."
    fi
done

# ──────────── 3. Target resource group ──────────────────────────
if ! az group show -n "$TARGET_RG" &>/dev/null; then
    az group create -n "$TARGET_RG" -l "$TARGET_REGION" -o none
    ok "Created target RG $TARGET_RG"
else
    ok "Target RG $TARGET_RG already exists"
fi

# ──────────── 4-6. Target VNet, NSGs, PIP ─────────────────────────
# Two paths: Resource Mover (--use-resource-mover) or direct az CLI (default)

SUB_ID=$(az account show --query "id" -o tsv)
source_nsg_names=$(az network nsg list -g "$SOURCE_RG" --query "[].name" -o tsv)

if [[ "$USE_RESOURCE_MOVER" == true ]]; then
    info "Using Azure Resource Mover for VNet, NSG, PIP..."

    # ── 4a. Create Move Collection ──
    # Move Collections are only available in certain regions. Use eastus2 as default
    # (the collection location is independent of source/target regions).
    MC_LOCATION="eastus2"
    info "Creating Move Collection: $MOVE_COLLECTION_NAME (location: $MC_LOCATION)"
    if ! az resource-mover move-collection show \
            --name "$MOVE_COLLECTION_NAME" --resource-group "$TARGET_RG" &>/dev/null 2>&1; then
        az resource-mover move-collection create \
            --name "$MOVE_COLLECTION_NAME" \
            --resource-group "$TARGET_RG" \
            --location "$MC_LOCATION" \
            --source-region "$SOURCE_REGION" \
            --target-region "$TARGET_REGION" \
            --identity type=SystemAssigned \
            -o none
        ok "  Created Move Collection $MOVE_COLLECTION_NAME"
    else
        ok "  Move Collection $MOVE_COLLECTION_NAME already exists"
    fi

    # Grant MSI Contributor on source + target RGs
    MC_MSI=$(az resource-mover move-collection show \
        --name "$MOVE_COLLECTION_NAME" --resource-group "$TARGET_RG" \
        --query "identity.principalId" -o tsv 2>/dev/null || true)

    if [[ -n "$MC_MSI" ]]; then
        info "  Granting Move Collection MSI access..."
        az role assignment create --assignee-object-id "$MC_MSI" \
            --assignee-principal-type ServicePrincipal \
            --role "Contributor" \
            --scope "/subscriptions/$SUB_ID/resourceGroups/$SOURCE_RG" \
            -o none 2>/dev/null || true
        az role assignment create --assignee-object-id "$MC_MSI" \
            --assignee-principal-type ServicePrincipal \
            --role "Contributor" \
            --scope "/subscriptions/$SUB_ID/resourceGroups/$TARGET_RG" \
            -o none 2>/dev/null || true
        ok "  MSI granted Contributor on source + target RGs"
        info "  Waiting for RBAC propagation..."
        sleep 30
    fi

    # ── 4b. Add VNet as move resource ──
    SOURCE_VNET_NAME=$(az network vnet list -g "$SOURCE_RG" --query "[0].name" -o tsv)
    SOURCE_VNET_ID=$(az network vnet show -g "$SOURCE_RG" -n "$SOURCE_VNET_NAME" --query "id" -o tsv)

    info "  Adding VNet $SOURCE_VNET_NAME → $TARGET_VNET"
    az resource-mover move-resource add \
        --move-collection-name "$MOVE_COLLECTION_NAME" \
        --resource-group "$TARGET_RG" \
        --name "move-vnet-${SOURCE_VNET_NAME}" \
        --source-id "$SOURCE_VNET_ID" \
        --resource-settings "{
            \"resourceType\": \"Microsoft.Network/virtualNetworks\",
            \"targetResourceName\": \"$TARGET_VNET\",
            \"targetResourceGroupName\": \"$TARGET_RG\"
        }" -o none 2>/dev/null || ok "    (already added)"

    # ── 4c. Add NSGs as move resources ──
    for src_nsg_name in $source_nsg_names; do
        tgt_nsg_name="${src_nsg_name}-target"
        src_nsg_id=$(az network nsg show -g "$SOURCE_RG" -n "$src_nsg_name" --query "id" -o tsv)

        info "  Adding NSG $src_nsg_name → $tgt_nsg_name"
        az resource-mover move-resource add \
            --move-collection-name "$MOVE_COLLECTION_NAME" \
            --resource-group "$TARGET_RG" \
            --name "move-nsg-${src_nsg_name}" \
            --source-id "$src_nsg_id" \
            --resource-settings "{
                \"resourceType\": \"Microsoft.Network/networkSecurityGroups\",
                \"targetResourceName\": \"$tgt_nsg_name\",
                \"targetResourceGroupName\": \"$TARGET_RG\"
            }" -o none 2>/dev/null || ok "    (already added)"
    done

    # ── 4d. Add PIP as move resource ──
    # Find source PIP (from LB frontend or direct)
    SOURCE_PIP_NAME=""
    if [[ -n "${SOURCE_LB_ID:-}" ]]; then
        SOURCE_LB_NAME=$(echo "$SOURCE_LB_ID" | awk -F'/loadBalancers/' '{print $2}' | awk -F'/' '{print $1}')
        SOURCE_PIP_NAME=$(az network lb show -g "$SOURCE_RG" -n "$SOURCE_LB_NAME" \
            --query "frontendIpConfigurations[0].publicIpAddress.id" -o tsv 2>/dev/null \
            | awk -F'/' '{print $NF}' || true)
    fi
    if [[ -z "$SOURCE_PIP_NAME" ]]; then
        SOURCE_PIP_NAME=$(az network public-ip list -g "$SOURCE_RG" --query "[0].name" -o tsv 2>/dev/null || true)
    fi

    if [[ -n "$SOURCE_PIP_NAME" ]]; then
        SOURCE_PIP_ID=$(az network public-ip show -g "$SOURCE_RG" -n "$SOURCE_PIP_NAME" --query "id" -o tsv)
        info "  Adding PIP $SOURCE_PIP_NAME → $PIP_NAME"
        az resource-mover move-resource add \
            --move-collection-name "$MOVE_COLLECTION_NAME" \
            --resource-group "$TARGET_RG" \
            --name "move-pip-${SOURCE_PIP_NAME}" \
            --source-id "$SOURCE_PIP_ID" \
            --resource-settings "{
                \"resourceType\": \"Microsoft.Network/publicIPAddresses\",
                \"targetResourceName\": \"$PIP_NAME\",
                \"targetResourceGroupName\": \"$TARGET_RG\"
            }" -o none 2>/dev/null || ok "    (already added)"
    else
        warn "No source PIP found — will create target PIP directly"
    fi

    # ── 4e. Resolve dependencies ──
    info "  Resolving dependencies..."
    az resource-mover move-collection resolve-dependency \
        --move-collection-name "$MOVE_COLLECTION_NAME" \
        --resource-group "$TARGET_RG" -o none 2>/dev/null || true

    # ── 4f. Prepare resources ──
    info "  Preparing resources for move..."
    MOVE_RESOURCE_IDS=$(az resource-mover move-resource list \
        --move-collection-name "$MOVE_COLLECTION_NAME" --resource-group "$TARGET_RG" \
        --query "[].id" -o tsv 2>/dev/null || true)

    if [[ -n "$MOVE_RESOURCE_IDS" ]]; then
        # Convert to JSON array for the API
        mr_json="["
        first=true
        for mr_id in $MOVE_RESOURCE_IDS; do
            if [[ "$first" == true ]]; then first=false; else mr_json+=","; fi
            mr_json+="\"$mr_id\""
        done
        mr_json+="]"

        az resource-mover move-collection prepare \
            --move-collection-name "$MOVE_COLLECTION_NAME" \
            --resource-group "$TARGET_RG" \
            --move-resources "$mr_json" \
            -o none 2>/dev/null || true

        # Poll until all resources are MovePending
        info "  Waiting for prepare to complete..."
        for attempt in $(seq 1 30); do
            all_ready=true
            states=$(az resource-mover move-resource list \
                --move-collection-name "$MOVE_COLLECTION_NAME" --resource-group "$TARGET_RG" \
                --query "[].{name:name, state:properties.moveStatus.moveState}" -o json 2>/dev/null || echo "[]")

            while IFS= read -r state; do
                if [[ "$state" != "MovePending" ]] && [[ "$state" != "CommitPending" ]]; then
                    all_ready=false
                    break
                fi
            done < <(echo "$states" | jq -r '.[].state')

            if [[ "$all_ready" == true ]]; then
                ok "  All resources prepared"
                break
            fi
            sleep 30
        done

        # ── 4g. Initiate move ──
        info "  Initiating move..."
        az resource-mover move-collection initiate-move \
            --move-collection-name "$MOVE_COLLECTION_NAME" \
            --resource-group "$TARGET_RG" \
            --move-resources "$mr_json" \
            -o none 2>/dev/null || true

        # Poll until CommitPending
        info "  Waiting for move to complete..."
        for attempt in $(seq 1 60); do
            all_moved=true
            states=$(az resource-mover move-resource list \
                --move-collection-name "$MOVE_COLLECTION_NAME" --resource-group "$TARGET_RG" \
                --query "[].{name:name, state:properties.moveStatus.moveState}" -o json 2>/dev/null || echo "[]")

            while IFS= read -r state; do
                if [[ "$state" != "CommitPending" ]] && [[ "$state" != "DeleteSourcePending" ]]; then
                    all_moved=false
                    break
                fi
            done < <(echo "$states" | jq -r '.[].state')

            if [[ "$all_moved" == true ]]; then
                ok "  All resources moved to target region"
                break
            fi
            sleep 30
        done
    fi

    detail "  Move collection left in CommitPending (source resources untouched)"

    # Verify target resources exist and fix subnet-NSG association if needed
    info "  Verifying target resources..."
    if az network vnet show -g "$TARGET_RG" -n "$TARGET_VNET" &>/dev/null; then
        ok "  VNet $TARGET_VNET exists in target"
        # Ensure subnet exists
        if ! az network vnet subnet show -g "$TARGET_RG" --vnet-name "$TARGET_VNET" -n "$TARGET_SUBNET" &>/dev/null; then
            az network vnet subnet create \
                -g "$TARGET_RG" --vnet-name "$TARGET_VNET" \
                -n "$TARGET_SUBNET" --address-prefix "$TARGET_SUBNET_CIDR" \
                -o none
            ok "  Created subnet $TARGET_SUBNET"
        fi
    else
        warn "VNet $TARGET_VNET not found after move — creating directly"
        az network vnet create \
            -g "$TARGET_RG" -n "$TARGET_VNET" -l "$TARGET_REGION" \
            --address-prefix "$TARGET_VNET_CIDR" \
            --subnet-name "$TARGET_SUBNET" --subnet-prefix "$TARGET_SUBNET_CIDR" \
            -o none
    fi

    # Re-associate NSG with subnet (Resource Mover may not preserve this)
    first_tgt_nsg="${source_nsg_names%% *}-target"
    if [[ -n "$first_tgt_nsg" ]] && [[ "$first_tgt_nsg" != "-target" ]]; then
        az network vnet subnet update \
            -g "$TARGET_RG" --vnet-name "$TARGET_VNET" -n "$TARGET_SUBNET" \
            --network-security-group "$first_tgt_nsg" -o none 2>/dev/null || true
        ok "  Associated NSG $first_tgt_nsg with subnet $TARGET_SUBNET"
    fi

    # Create PIP directly if Resource Mover didn't handle it
    if ! az network public-ip show -g "$TARGET_RG" -n "$PIP_NAME" &>/dev/null; then
        az network public-ip create \
            -g "$TARGET_RG" -n "$PIP_NAME" -l "$TARGET_REGION" \
            --sku Standard --allocation-method Static -o none
        ok "  Created PIP $PIP_NAME directly (Resource Mover fallback)"
    else
        ok "  PIP $PIP_NAME exists in target"
    fi

else
    # ──── Original az CLI path (default) ────

    # ──────────── 4. Target VNet + subnet ───────────────────────────
    if ! az network vnet show -g "$TARGET_RG" -n "$TARGET_VNET" &>/dev/null; then
        az network vnet create \
            -g "$TARGET_RG" -n "$TARGET_VNET" -l "$TARGET_REGION" \
            --address-prefix "$TARGET_VNET_CIDR" \
            --subnet-name "$TARGET_SUBNET" --subnet-prefix "$TARGET_SUBNET_CIDR" \
            -o none
        ok "Created target VNet $TARGET_VNET ($TARGET_VNET_CIDR)"
    else
        ok "Target VNet $TARGET_VNET already exists"
        # Ensure subnet exists
        if ! az network vnet subnet show -g "$TARGET_RG" --vnet-name "$TARGET_VNET" -n "$TARGET_SUBNET" &>/dev/null; then
            az network vnet subnet create \
                -g "$TARGET_RG" --vnet-name "$TARGET_VNET" \
                -n "$TARGET_SUBNET" --address-prefix "$TARGET_SUBNET_CIDR" \
                -o none
            ok "Created subnet $TARGET_SUBNET in existing VNet"
        fi
    fi

    # ──────────── 5. Target NSGs (ASR does NOT replicate NSGs) ──────
    info "Replicating source NSGs to target..."

    for src_nsg_name in $source_nsg_names; do
        tgt_nsg_name="${src_nsg_name}-target"

        if az network nsg show -g "$TARGET_RG" -n "$tgt_nsg_name" &>/dev/null; then
            ok "  Target NSG $tgt_nsg_name already exists — skipping"
            continue
        fi

        az network nsg create -g "$TARGET_RG" -n "$tgt_nsg_name" -l "$TARGET_REGION" -o none

        # Copy each custom security rule from source NSG
        rules_json=$(az network nsg rule list -g "$SOURCE_RG" --nsg-name "$src_nsg_name" -o json)
        rule_count=$(echo "$rules_json" | jq 'length')

        for i in $(seq 0 $((rule_count - 1))); do
            rule=$(echo "$rules_json" | jq ".[$i]")
            r_name=$(echo "$rule" | jq -r '.name')
            r_priority=$(echo "$rule" | jq -r '.priority')
            r_access=$(echo "$rule" | jq -r '.access')
            r_protocol=$(echo "$rule" | jq -r '.protocol')
            r_direction=$(echo "$rule" | jq -r '.direction')
            r_src_addr=$(echo "$rule" | jq -r '[.sourceAddressPrefix // empty] + (.sourceAddressPrefixes // []) | join(" ")')
            r_src_port=$(echo "$rule" | jq -r '[.sourcePortRange // empty] + (.sourcePortRanges // []) | join(" ")')
            r_dst_addr=$(echo "$rule" | jq -r '[.destinationAddressPrefix // empty] + (.destinationAddressPrefixes // []) | join(" ")')
            r_dst_port=$(echo "$rule" | jq -r '[.destinationPortRange // empty] + (.destinationPortRanges // []) | join(" ")')
            r_desc=$(echo "$rule" | jq -r '.description // empty')

            # Disable globbing so that port/address wildcards ("*") aren't
            # expanded into filenames by bash.
            set -f
            cmd=(az network nsg rule create
                -g "$TARGET_RG" --nsg-name "$tgt_nsg_name"
                -n "$r_name" --priority "$r_priority"
                --access "$r_access" --protocol "$r_protocol" --direction "$r_direction"
                --source-address-prefixes $r_src_addr
                --source-port-ranges $r_src_port
                --destination-address-prefixes $r_dst_addr
                --destination-port-ranges $r_dst_port
                -o none)
            set +f

            if [[ -n "$r_desc" ]]; then
                cmd+=(--description "$r_desc")
            fi

            "${cmd[@]}"
        done

        ok "  Created target NSG $tgt_nsg_name with $rule_count rules"
    done

    # Associate first target NSG with subnet (if only one NSG — adjust if multiple)
    first_tgt_nsg="${source_nsg_names%% *}-target"
    if [[ -n "$first_tgt_nsg" ]] && [[ "$first_tgt_nsg" != "-target" ]]; then
        az network vnet subnet update \
            -g "$TARGET_RG" --vnet-name "$TARGET_VNET" -n "$TARGET_SUBNET" \
            --network-security-group "$first_tgt_nsg" -o none 2>/dev/null || true
        ok "Associated NSG $first_tgt_nsg with subnet $TARGET_SUBNET"
    fi

    # ──────────── 6. Target public IP (new address) ─────────────────
    if ! az network public-ip show -g "$TARGET_RG" -n "$PIP_NAME" &>/dev/null; then
        az network public-ip create \
            -g "$TARGET_RG" -n "$PIP_NAME" -l "$TARGET_REGION" \
            --sku Standard --allocation-method Static \
            -o none
        ok "Created target public IP $PIP_NAME (NEW address — update DNS at cutover)"
    else
        ok "Target public IP $PIP_NAME already exists"
    fi
fi

# ──────────── 7. Target Load Balancer ───────────────────────────
if ! az network lb show -g "$TARGET_RG" -n "$LB_NAME" &>/dev/null; then
    az network lb create \
        -g "$TARGET_RG" -n "$LB_NAME" -l "$TARGET_REGION" \
        --sku Standard \
        --public-ip-address "$PIP_NAME" \
        --frontend-ip-name "fe" \
        --backend-pool-name "bepool" \
        -o none

    az network lb probe create \
        -g "$TARGET_RG" --lb-name "$LB_NAME" \
        -n "tcp-probe" --protocol Tcp --port 80 \
        --interval 5 --threshold 2 \
        -o none

    az network lb rule create \
        -g "$TARGET_RG" --lb-name "$LB_NAME" \
        -n "rule-80" --protocol Tcp \
        --frontend-port 80 --backend-port 80 \
        --frontend-ip-name "fe" --backend-pool-name "bepool" \
        --probe-name "tcp-probe" \
        -o none

    ok "Created target Load Balancer $LB_NAME"
else
    ok "Target Load Balancer $LB_NAME already exists"
fi

# ──────────── 8. Recovery Services vault ────────────────────────
# ASR requires a Recovery Services vault (Microsoft.RecoveryServices/vaults),
# NOT a Backup vault (Microsoft.DataProtection/BackupVaults).
# Use a DEDICATED vault — do NOT reuse an existing vault created for other
# purposes (backup, different region, etc.) as it causes hangs and conflicts.
if ! az backup vault show -g "$TARGET_RG" -n "$VAULT_NAME" &>/dev/null 2>&1; then
    info "Creating Recovery Services vault $VAULT_NAME in $TARGET_REGION..."
    az backup vault create \
        -g "$TARGET_RG" -n "$VAULT_NAME" -l "$TARGET_REGION" \
        -o none
    ok "Created Recovery Services vault $VAULT_NAME"
else
    # Verify vault is in the correct region
    vault_location=$(az backup vault show -g "$TARGET_RG" -n "$VAULT_NAME" \
        --query "location" -o tsv 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    expected_location=$(echo "$TARGET_REGION" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    if [[ "$vault_location" != "$expected_location" ]]; then
        warn "Vault $VAULT_NAME is in '$vault_location' but target region is '$expected_location'."
        warn "ASR requires the vault to be in the target region. Create a new vault."
    fi
    ok "Recovery Services vault $VAULT_NAME already exists"
fi

# ──────────── Done ──────────────────────────────────────────────
echo ""
info "== Pre-flight + staging complete. Review $INVENTORY_OUT, then enable replication. =="
info ""
info "Target resource names (pass to 04-planned-failover.sh if not using defaults):"
echo "  LB:  $LB_NAME"
echo "  PIP: $PIP_NAME"
info ""
info "Next step:"
info "  Run 02-enable-asr-replication.sh to create the replication policy,"
info "  fabric/container mappings, network mapping, and enable replication per VM."
info ""
info "  Example:"
echo "    ./02-enable-asr-replication.sh \\"
echo "      --source-rg \"$SOURCE_RG\" --source-region \"$SOURCE_REGION\" \\"
echo "      --target-rg \"$TARGET_RG\" --target-region \"$TARGET_REGION\" \\"
echo "      --vault-name \"$VAULT_NAME\" --vm-names \"$VM_NAMES_CSV\" \\"
echo "      --target-vnet \"$TARGET_VNET\" --target-subnet \"$TARGET_SUBNET\""
