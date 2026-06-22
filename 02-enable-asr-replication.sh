#!/usr/bin/env bash
#
# 02-enable-asr-replication.sh
# Cross-region ASR migration — Phase 2: Enable replication.
#
# Sets vault context, creates replication policy (A2A), source + target fabrics,
# protection containers, container mapping, network mapping, then enables
# replication per VM and polls until initial sync completes.
#
# Prerequisite: Run 01-preflight-and-stage.sh first (target fabric must exist).
# Next step:    Run 03-test-failover.sh to validate the Trusted Launch boot path.
#
# Requires: az cli (with site-recovery extension), jq
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

Enable ASR replication for Trusted Launch VMs (A2A, cross-region).

Required:
  --source-rg NAME              Source resource group
  --source-region REGION        Source region (e.g. eastus)
  --target-rg NAME              Target resource group
  --target-region REGION        Target region (e.g. centralus)
  --vault-name NAME             Recovery Services vault name (in target RG)
  --vm-names VM1,VM2,...        Comma-separated list of VM names

Optional:
  --target-vnet NAME            Target VNet name              (default: vnet-target)
  --target-subnet NAME          Target subnet name            (default: snet-workload)
  --policy-name NAME            Replication policy name       (default: policy-a2a-24h)
  --cache-storage-acct NAME     Cache storage account name    (default: auto-created)
  --no-wait                     Don't poll for initial sync completion
  -h, --help                    Show this help

Example:
  $(basename "$0") \\
    --source-rg rg-prod-eastus --source-region eastus \\
    --target-rg rg-prod-centralus --target-region centralus \\
    --vault-name vault-asr-centralus \\
    --vm-names "vm-app01,vm-app02" \\
    --target-vnet vnet-target --target-subnet snet-workload
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
TARGET_SUBNET="snet-workload"
POLICY_NAME="policy-a2a-24h"
CACHE_STORAGE_ACCT=""
NO_WAIT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-rg)          SOURCE_RG="$2";           shift 2;;
        --source-region)      SOURCE_REGION="$2";       shift 2;;
        --target-rg)          TARGET_RG="$2";           shift 2;;
        --target-region)      TARGET_REGION="$2";       shift 2;;
        --vault-name)         VAULT_NAME="$2";          shift 2;;
        --vm-names)           VM_NAMES_CSV="$2";        shift 2;;
        --target-vnet)        TARGET_VNET="$2";         shift 2;;
        --target-subnet)      TARGET_SUBNET="$2";       shift 2;;
        --policy-name)        POLICY_NAME="$2";         shift 2;;
        --cache-storage-acct) CACHE_STORAGE_ACCT="$2";  shift 2;;
        --no-wait)            NO_WAIT=true;             shift;;
        -h|--help)            usage;;
        *) err "Unknown argument: $1";;
    esac
done

[[ -z "$SOURCE_RG" ]]     && err "--source-rg is required"
[[ -z "$SOURCE_REGION" ]] && err "--source-region is required"
[[ -z "$TARGET_RG" ]]     && err "--target-rg is required"
[[ -z "$TARGET_REGION" ]] && err "--target-region is required"
[[ -z "$VAULT_NAME" ]]    && err "--vault-name is required"
[[ -z "$VM_NAMES_CSV" ]]  && err "--vm-names is required"

IFS=',' read -ra VM_NAMES <<< "$VM_NAMES_CSV"

SUB_ID=$(az account show --query "id" -o tsv)

info "== Phase 2: Enable ASR Replication =="

# ──────────── 1. Cache storage account (required for A2A) ─────
if [[ -z "$CACHE_STORAGE_ACCT" ]]; then
    # Auto-generate a cache storage account name in the SOURCE region
    CACHE_STORAGE_ACCT="asrcache${SOURCE_REGION}$(echo "$SUB_ID" | cut -c1-8)"
    # Storage account names: lowercase alphanumeric, 3-24 chars
    CACHE_STORAGE_ACCT=$(echo "$CACHE_STORAGE_ACCT" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]' | cut -c1-24)
fi

if ! az storage account show -g "$SOURCE_RG" -n "$CACHE_STORAGE_ACCT" &>/dev/null; then
    info "Creating cache storage account $CACHE_STORAGE_ACCT in $SOURCE_REGION..."
    az storage account create \
        -g "$SOURCE_RG" -n "$CACHE_STORAGE_ACCT" -l "$SOURCE_REGION" \
        --sku Standard_LRS --kind StorageV2 \
        -o none
    ok "Created cache storage account: $CACHE_STORAGE_ACCT"
else
    ok "Cache storage account $CACHE_STORAGE_ACCT already exists"
fi

CACHE_STORAGE_ID=$(az storage account show -g "$SOURCE_RG" -n "$CACHE_STORAGE_ACCT" --query "id" -o tsv)

# ──────────── 2. Replication policy ───────────────────────────
info "Creating replication policy: $POLICY_NAME"

if az site-recovery policy show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$POLICY_NAME" &>/dev/null; then
    ok "Replication policy $POLICY_NAME already exists"
else
    az site-recovery policy create \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        -n "$POLICY_NAME" \
        --provider-specific-input '{a2a:{multi-vm-sync-status:Enable}}' \
        --no-wait false
    ok "Created replication policy: $POLICY_NAME"
fi

POLICY_ID=$(az site-recovery policy show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$POLICY_NAME" \
    --query "id" -o tsv)

# ──────────── 3. Source + target fabrics ──────────────────────
SRC_FABRIC="fabric-${SOURCE_REGION}"
TGT_FABRIC="fabric-${TARGET_REGION}"

info "Creating ASR fabrics..."

for fabric_name in "$SRC_FABRIC" "$TGT_FABRIC"; do
    if [[ "$fabric_name" == "$SRC_FABRIC" ]]; then
        region="$SOURCE_REGION"
    else
        region="$TARGET_REGION"
    fi

    if az site-recovery fabric show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$fabric_name" &>/dev/null; then
        ok "Fabric $fabric_name already exists"
    else
        az site-recovery fabric create \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            -n "$fabric_name" \
            --custom-details "{azure:{location:${region}}}" \
            --no-wait false
        ok "Created fabric: $fabric_name (region: $region)"
    fi
done

# ──────────── 4. Protection containers ────────────────────────
SRC_CONTAINER="container-${SOURCE_REGION}"
TGT_CONTAINER="container-${TARGET_REGION}"

info "Creating protection containers..."

for container_name in "$SRC_CONTAINER" "$TGT_CONTAINER"; do
    if [[ "$container_name" == "$SRC_CONTAINER" ]]; then
        fabric="$SRC_FABRIC"
    else
        fabric="$TGT_FABRIC"
    fi

    if az site-recovery protection-container show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$fabric" -n "$container_name" &>/dev/null; then
        ok "Container $container_name already exists"
    else
        az site-recovery protection-container create \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            --fabric-name "$fabric" \
            -n "$container_name" \
            --provider-input '[{instance-type:A2A}]' \
            --no-wait false
        ok "Created protection container: $container_name"
    fi
done

TGT_CONTAINER_ID=$(az site-recovery protection-container show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
    --fabric-name "$TGT_FABRIC" -n "$TGT_CONTAINER" \
    --query "id" -o tsv)

# ──────────── 5. Container mapping (policy ↔ containers) ─────
MAPPING_NAME="mapping-${SOURCE_REGION}-to-${TARGET_REGION}"

info "Creating container mapping..."

if az site-recovery protection-container mapping show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
    --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
    -n "$MAPPING_NAME" &>/dev/null; then
    ok "Container mapping $MAPPING_NAME already exists"
else
    az site-recovery protection-container mapping create \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" \
        --protection-container "$SRC_CONTAINER" \
        -n "$MAPPING_NAME" \
        --policy-id "$POLICY_ID" \
        --target-container "$TGT_CONTAINER_ID" \
        --provider-input '{a2a:{agent-auto-update-status:Enabled}}' \
        --no-wait false
    ok "Created container mapping: $MAPPING_NAME"
fi

# ──────────── 6. Network mapping (source VNet → target VNet) ─
info "Creating network mapping..."

# Discover source VNet (from first VM's NIC)
first_vm="${VM_NAMES[0]}"
first_vm_json=$(az vm show -g "$SOURCE_RG" -n "$first_vm" -o json)
first_nic_id=$(echo "$first_vm_json" | jq -r '.networkProfile.networkInterfaces[0].id')
first_nic_json=$(az network nic show --ids "$first_nic_id" -o json)
source_subnet_id=$(echo "$first_nic_json" | jq -r '.ipConfigurations[0].subnet.id')
# Extract VNet name from subnet ID: .../virtualNetworks/<vnet>/subnets/<subnet>
SOURCE_VNET_NAME=$(echo "$source_subnet_id" | awk -F'/virtualNetworks/' '{print $2}' | awk -F'/' '{print $1}')
SOURCE_VNET_ID=$(az network vnet show -g "$SOURCE_RG" -n "$SOURCE_VNET_NAME" --query "id" -o tsv)
TARGET_VNET_ID=$(az network vnet show -g "$TARGET_RG" -n "$TARGET_VNET" --query "id" -o tsv)

NET_MAPPING_NAME="netmap-${SOURCE_REGION}-to-${TARGET_REGION}"

if az site-recovery network mapping show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
    --fabric-name "$SRC_FABRIC" --network-name "$SOURCE_VNET_NAME" \
    -n "$NET_MAPPING_NAME" &>/dev/null; then
    ok "Network mapping $NET_MAPPING_NAME already exists"
else
    az site-recovery network mapping create \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" \
        --network-name "$SOURCE_VNET_NAME" \
        -n "$NET_MAPPING_NAME" \
        --recovery-network-id "$TARGET_VNET_ID" \
        --recovery-fabric-name "$TGT_FABRIC" \
        --fabric-details "{azure-to-azure:{primary-network-id:${SOURCE_VNET_ID}}}"
    ok "Created network mapping: $SOURCE_VNET_NAME -> $TARGET_VNET"
fi

# ──────────── 7. Enable replication per VM ────────────────────
info "Enabling replication for ${#VM_NAMES[@]} VM(s)..."

TARGET_RG_ID=$(az group show -n "$TARGET_RG" --query "id" -o tsv)

for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"  # trim whitespace
    ITEM_NAME="asr-${vm_name}"

    # Check if already protected
    if az site-recovery protected-item show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
        -n "$ITEM_NAME" &>/dev/null; then
        ok "  $vm_name: replication already enabled — skipping"
        continue
    fi

    info "  Enabling replication for $vm_name..."

    vm_json=$(az vm show -g "$SOURCE_RG" -n "$vm_name" -o json)
    vm_id=$(echo "$vm_json" | jq -r '.id')

    # Build managed disk list (OS + data disks)
    os_disk_id=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.managedDisk.id')
    os_disk_sku=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.managedDisk.storageAccountType')

    disk_entries="{disk-id:${os_disk_id},primary-staging-azure-storage-account-id:${CACHE_STORAGE_ID},recovery-resource-group-id:${TARGET_RG_ID},recovery-replica-disk-account-type:${os_disk_sku},recovery-target-disk-account-type:${os_disk_sku}}"

    data_disk_count=$(echo "$vm_json" | jq '.storageProfile.dataDisks | length')
    for i in $(seq 0 $((data_disk_count - 1))); do
        dd_id=$(echo "$vm_json" | jq -r ".storageProfile.dataDisks[$i].managedDisk.id")
        dd_sku=$(echo "$vm_json" | jq -r ".storageProfile.dataDisks[$i].managedDisk.storageAccountType")
        disk_entries="${disk_entries},{disk-id:${dd_id},primary-staging-azure-storage-account-id:${CACHE_STORAGE_ID},recovery-resource-group-id:${TARGET_RG_ID},recovery-replica-disk-account-type:${dd_sku},recovery-target-disk-account-type:${dd_sku}}"
    done

    provider_details="{a2a:{fabric-object-id:${vm_id},vm-managed-disks:[${disk_entries}],recovery-azure-network-id:${TARGET_VNET_ID},recovery-container-id:${TGT_CONTAINER_ID},recovery-resource-group-id:${TARGET_RG_ID},recovery-subnet-name:${TARGET_SUBNET}}}"

    az site-recovery protected-item create \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" \
        --protection-container "$SRC_CONTAINER" \
        -n "$ITEM_NAME" \
        --policy-id "$POLICY_ID" \
        --provider-details "$provider_details" \
        --no-wait false

    ok "  $vm_name: replication enabled (item: $ITEM_NAME)"
done

# ──────────── 8. Poll replication health ──────────────────────
if [[ "$NO_WAIT" == false ]]; then
    info "Polling replication health until initial sync completes..."
    info "(This can take 30-90 minutes depending on disk size. Ctrl+C is safe — replication continues.)"
    echo ""

    all_synced=false
    while [[ "$all_synced" == false ]]; do
        all_synced=true
        for vm_name in "${VM_NAMES[@]}"; do
            vm_name="$(echo "$vm_name" | xargs)"
            ITEM_NAME="asr-${vm_name}"

            item_json=$(az site-recovery protected-item show \
                -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
                --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
                -n "$ITEM_NAME" -o json 2>/dev/null || echo "{}")

            state=$(echo "$item_json" | jq -r '.properties.protectionState // "Unknown"')
            health=$(echo "$item_json" | jq -r '.properties.replicationHealth // "Unknown"')

            if [[ "$state" == "Protected" ]]; then
                ok "  $vm_name: Protected (health: $health)"
            else
                detail "  $vm_name: $state (health: $health) — syncing..."
                all_synced=false
            fi
        done

        if [[ "$all_synced" == false ]]; then
            echo "  Waiting 60s before next check..."
            sleep 60
        fi
    done

    ok "All VMs reached Protected state."
else
    warn "Skipping replication health polling (--no-wait). Check manually:"
    echo "  az site-recovery protected-item list -g $TARGET_RG --vault-name $VAULT_NAME \\"
    echo "    --fabric-name $SRC_FABRIC --protection-container $SRC_CONTAINER -o table"
fi

# ──────────── Done ──────────────────────────────────────────────
echo ""
info "== Replication enablement complete. =="
info ""
info "Next step:"
info "  Run 03-test-failover.sh to validate the Trusted Launch boot path"
info "  in an isolated test network before planned cutover."
info ""
info "  Example:"
echo "    ./03-test-failover.sh \\"
echo "      --target-rg \"$TARGET_RG\" --target-region \"$TARGET_REGION\" \\"
echo "      --vault-name \"$VAULT_NAME\" --vm-names \"$VM_NAMES_CSV\" \\"
echo "      --source-region \"$SOURCE_REGION\""
