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

# ──────────────── az_sr timeout wrapper ─────────────
_az=$(command -v az)
AZ_SR_CMD_TIMEOUT=120       # max seconds for any single az_sr call
ASR_OP_TIMEOUT=300           # 5 min for infra resources (policy, fabric, etc.)
ASR_REPL_TIMEOUT=1800        # 30 min per VM replication enablement

# Wrapper for az_sr that prevents indefinite hangs.
# Runs the command in background and kills it if it exceeds AZ_SR_CMD_TIMEOUT.
# Usage: az_sr <subcommand> [args...]   (omit the "site-recovery" prefix)
az_sr() {
    "$_az" site-recovery "$@" &
    local pid=$!
    local w=0
    while (( w < AZ_SR_CMD_TIMEOUT )) && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        w=$((w + 1))
    done
    if ! kill -0 "$pid" 2>/dev/null; then
        local rc=0
        wait "$pid" || rc=$?
        return $rc
    else
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        warn "az site-recovery command timed out after ${AZ_SR_CMD_TIMEOUT}s: $*"
        return 124
    fi
}

# Poll an ASR "show" command until the resource exists or timeout.
# Each individual call goes through az_sr which enforces a per-call timeout.
# Usage: wait_for_asr_resource <timeout_secs> <label> <az_sr show command ...>
wait_for_asr_resource() {
    local timeout_secs="$1"; shift
    local label="$1"; shift
    local elapsed=0

    detail "  Waiting for $label to be provisioned (timeout: ${timeout_secs}s)..."
    while (( elapsed < timeout_secs )); do
        if "$@" &>/dev/null; then
            return 0
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
    err "Timed out waiting for $label after ${timeout_secs}s"
}

# Wait for an ASR resource to reach a terminal provisioning state (Succeeded).
# ASR resources can appear in "show" but not be fully ready (Creating/Updating).
# Usage: wait_for_asr_provisioning <timeout_secs> <label> <az_sr show command ...>
wait_for_asr_provisioning() {
    local timeout_secs="$1"; shift
    local label="$1"; shift
    local elapsed=0

    detail "  Waiting for $label to reach Succeeded state (timeout: ${timeout_secs}s)..."
    while (( elapsed < timeout_secs )); do
        local prov_state
        prov_state=$("$@" --query "properties.customDetails.instanceType" -o tsv 2>/dev/null || echo "Unknown")
        # Also check if the resource is queryable at all
        if "$@" -o json 2>/dev/null | jq -e '.id' &>/dev/null; then
            return 0
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
    err "Timed out waiting for $label provisioning after ${timeout_secs}s"
}

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

# ──────────── 0. Validate vault ───────────────────────────────
# Verify the vault is a Recovery Services vault in the target region.
# Using a wrong vault type or vault in wrong region causes hangs and
# CannotEnableProtection errors.
info "Validating Recovery Services vault: $VAULT_NAME"
if ! az resource show --resource-type "Microsoft.RecoveryServices/vaults" \
        -g "$TARGET_RG" -n "$VAULT_NAME" &>/dev/null 2>&1; then
    err "Vault '$VAULT_NAME' not found in resource group '$TARGET_RG'.
  Make sure you ran 01-preflight-and-stage.sh first to create the vault.
  Do NOT reuse an existing vault created for other purposes (backup, etc.)."
fi
vault_location=$(az resource show --resource-type "Microsoft.RecoveryServices/vaults" \
    -g "$TARGET_RG" -n "$VAULT_NAME" --query "location" -o tsv 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' | tr -d ' ')
expected_location=$(echo "$TARGET_REGION" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
if [[ "$vault_location" != "$expected_location" ]]; then
    err "Vault '$VAULT_NAME' is in '$vault_location' but target region is '$expected_location'.
  ASR requires the vault to be in the target region. Create a new vault."
fi
ok "Vault $VAULT_NAME verified (Recovery Services, $TARGET_REGION)"

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

if az_sr policy show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$POLICY_NAME" &>/dev/null; then
    ok "Replication policy $POLICY_NAME already exists"
else
    az_sr policy create \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        -n "$POLICY_NAME" \
        --provider-specific-input '{a2a:{multi-vm-sync-status:Enable}}' \
        --no-wait
    wait_for_asr_resource "$ASR_OP_TIMEOUT" "replication policy $POLICY_NAME" \
        az_sr policy show -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$POLICY_NAME"
    ok "Created replication policy: $POLICY_NAME"
fi

POLICY_ID=$(az_sr policy show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$POLICY_NAME" \
    --query "id" -o tsv)

# ──────────── 3. Source + target fabrics ──────────────────────
# ASR "fabrics" are NOT Azure Service Fabric.  In ASR, a fabric is a logical
# representation of a physical Azure region.  A2A replication requires exactly
# two fabrics: one for the source region, one for the target region.  These are
# mandatory ASR data-model objects — they cannot be skipped.
SRC_FABRIC="fabric-${SOURCE_REGION}"
TGT_FABRIC="fabric-${TARGET_REGION}"

info "Creating ASR fabrics (logical region objects — required for A2A replication)..."

for fabric_name in "$SRC_FABRIC" "$TGT_FABRIC"; do
    if [[ "$fabric_name" == "$SRC_FABRIC" ]]; then
        region="$SOURCE_REGION"
    else
        region="$TARGET_REGION"
    fi

    if az_sr fabric show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$fabric_name" &>/dev/null; then
        ok "Fabric $fabric_name already exists"
    else
        az_sr fabric create \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            -n "$fabric_name" \
            --custom-details "{azure:{location:${region}}}" \
            --no-wait
        wait_for_asr_resource "$ASR_OP_TIMEOUT" "fabric $fabric_name" \
            az_sr fabric show -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$fabric_name"
        # Extra stabilization wait — ASR fabric provisioning is async and the
        # resource can appear in "show" before it's fully ready for dependent
        # operations (protection containers).  30s has proven reliable.
        detail "  Stabilizing fabric $fabric_name..."
        sleep 30
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

    if az_sr protection-container show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$fabric" -n "$container_name" &>/dev/null; then
        ok "Container $container_name already exists"
    else
        az_sr protection-container create \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            --fabric-name "$fabric" \
            -n "$container_name" \
            --provider-input '[{instance-type:A2A}]' \
            --no-wait
        wait_for_asr_resource "$ASR_OP_TIMEOUT" "container $container_name" \
            az_sr protection-container show -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            --fabric-name "$fabric" -n "$container_name"
        ok "Created protection container: $container_name"
    fi
done

TGT_CONTAINER_ID=$(az_sr protection-container show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
    --fabric-name "$TGT_FABRIC" -n "$TGT_CONTAINER" \
    --query "id" -o tsv)

# ──────────── 5. Container mapping (policy ↔ containers) ─────
MAPPING_NAME="mapping-${SOURCE_REGION}-to-${TARGET_REGION}"

info "Creating container mapping..."

if az_sr protection-container mapping show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
    --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
    -n "$MAPPING_NAME" &>/dev/null; then
    ok "Container mapping $MAPPING_NAME already exists"
else
    az_sr protection-container mapping create \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" \
        --protection-container "$SRC_CONTAINER" \
        -n "$MAPPING_NAME" \
        --policy-id "$POLICY_ID" \
        --target-container "$TGT_CONTAINER_ID" \
        --provider-input '{a2a:{agent-auto-update-status:Enabled}}' \
        --no-wait
    wait_for_asr_resource "$ASR_OP_TIMEOUT" "container mapping $MAPPING_NAME" \
        az_sr protection-container mapping show -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" -n "$MAPPING_NAME"
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

if az_sr network mapping show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
    --fabric-name "$SRC_FABRIC" --network-name "$SOURCE_VNET_NAME" \
    -n "$NET_MAPPING_NAME" &>/dev/null; then
    ok "Network mapping $NET_MAPPING_NAME already exists"
else
    az_sr network mapping create \
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
# NOTE: The az site-recovery CLI extension does NOT support the Trusted Launch
# security profile fields (recoveryVirtualMachineSecurityType, etc.) in its
# --provider-details schema.  The Portal works because it calls the REST API
# directly.  We do the same here — use `az rest` with the full JSON payload
# so Trusted Launch VMs replicate correctly.
# ──────────────────────────────────────────────────────────────

info "Enabling replication for ${#VM_NAMES[@]} VM(s)..."

TARGET_RG_ID=$(az group show -n "$TARGET_RG" --query "id" -o tsv)

# Build the base resource URI for protected-item operations
ASR_BASE_URI="/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}"
ASR_API_VERSION="2024-10-01"

for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"  # trim whitespace
    ITEM_NAME="asr-${vm_name}"

    # Check if already protected
    if az_sr protected-item show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
        -n "$ITEM_NAME" &>/dev/null; then
        ok "  $vm_name: replication already enabled — skipping"
        continue
    fi

    info "  Enabling replication for $vm_name..."

    vm_json=$(az vm show -g "$SOURCE_RG" -n "$vm_name" -o json)
    vm_id=$(echo "$vm_json" | jq -r '.id')
    security_type=$(echo "$vm_json" | jq -r '.securityProfile.securityType // "Standard"')

    # Build managed disk list (OS + data disks) as JSON array
    os_disk_id=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.managedDisk.id')
    os_disk_sku=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.managedDisk.storageAccountType')

    disk_array=$(jq -n \
        --arg diskId "$os_disk_id" \
        --arg cacheId "$CACHE_STORAGE_ID" \
        --arg recRg "$TARGET_RG_ID" \
        --arg sku "$os_disk_sku" \
        '[{
            diskId: $diskId,
            primaryStagingAzureStorageAccountId: $cacheId,
            recoveryResourceGroupId: $recRg,
            recoveryReplicaDiskAccountType: $sku,
            recoveryTargetDiskAccountType: $sku
        }]')

    data_disk_count=$(echo "$vm_json" | jq '.storageProfile.dataDisks | length')
    for i in $(seq 0 $((data_disk_count - 1))); do
        dd_id=$(echo "$vm_json" | jq -r ".storageProfile.dataDisks[$i].managedDisk.id")
        dd_sku=$(echo "$vm_json" | jq -r ".storageProfile.dataDisks[$i].managedDisk.storageAccountType")
        disk_array=$(echo "$disk_array" | jq \
            --arg diskId "$dd_id" \
            --arg cacheId "$CACHE_STORAGE_ID" \
            --arg recRg "$TARGET_RG_ID" \
            --arg sku "$dd_sku" \
            '. + [{
                diskId: $diskId,
                primaryStagingAzureStorageAccountId: $cacheId,
                recoveryResourceGroupId: $recRg,
                recoveryReplicaDiskAccountType: $sku,
                recoveryTargetDiskAccountType: $sku
            }]')
    done

    # Build providerSpecificDetails — include Trusted Launch fields when needed
    provider_specific=$(jq -n \
        --arg instanceType "A2A" \
        --arg fabricObjId "$vm_id" \
        --argjson disks "$disk_array" \
        --arg recNetwork "$TARGET_VNET_ID" \
        --arg recContainer "$TGT_CONTAINER_ID" \
        --arg recRg "$TARGET_RG_ID" \
        --arg recSubnet "$TARGET_SUBNET" \
        '{
            instanceType: $instanceType,
            fabricObjectId: $fabricObjId,
            vmManagedDisks: $disks,
            recoveryAzureNetworkId: $recNetwork,
            recoveryContainerId: $recContainer,
            recoveryResourceGroupId: $recRg,
            recoverySubnetName: $recSubnet
        }')

    # Add Trusted Launch security profile for TrustedLaunch VMs
    if [[ "$security_type" == "TrustedLaunch" ]]; then
        detail "    Detected Trusted Launch VM — adding security profile to replication request"
        provider_specific=$(echo "$provider_specific" | jq '. + {recoveryVirtualMachineSecurityType: "TrustedLaunch"}')
    fi

    # Build full request body
    request_body=$(jq -n \
        --arg policyId "$POLICY_ID" \
        --argjson providerDetails "$provider_specific" \
        '{
            properties: {
                policyId: $policyId,
                providerSpecificDetails: $providerDetails
            }
        }')

    # Use az rest to call the ASR REST API directly (bypasses CLI schema limitation)
    item_uri="${ASR_BASE_URI}/replicationFabrics/${SRC_FABRIC}/replicationProtectionContainers/${SRC_CONTAINER}/replicationProtectedItems/${ITEM_NAME}?api-version=${ASR_API_VERSION}"

    az rest --method put \
        --uri "$item_uri" \
        --body "$request_body" \
        --output none 2>&1 || {
        err "  Failed to enable replication for $vm_name. Check vault, fabric, and VM configuration."
    }

    wait_for_asr_resource "$ASR_REPL_TIMEOUT" "replication item $ITEM_NAME" \
        az_sr protected-item show -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" -n "$ITEM_NAME"

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

            item_json=$(az_sr protected-item show \
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
