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

# ──────────────────────────── Logging ───────────────────────────
# Timestamped console output, mirrored (color-stripped) to logs/<script>-<run>.log
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
exec > >(while IFS= read -r line; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "$ts" "$line"
    printf '[%s] %s\n' "$ts" "$(printf '%s' "$line" | sed $'s/\x1b\\[[0-9;]*m//g')" >> "$LOG_FILE"
done) 2>&1

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
ASR_MAPPING_TIMEOUT=900      # 15 min for container mappings (slowest infra resource)
ASR_REPL_TIMEOUT=1800        # 30 min per VM replication enablement

# ASR replica disks cannot be Premium SSD v2 or Ultra. If the source disk is
# one of those, the intermediate replica disk must be Premium SSD v1.
replica_sku_for() {
    case "$1" in
        PremiumV2_LRS|UltraSSD_LRS) echo "Premium_LRS" ;;
        *) echo "$1" ;;
    esac
}

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
    local start=$SECONDS
    local next_progress=300

    detail "  Waiting for $label to be provisioned (timeout: ${timeout_secs}s)..."
    while (( SECONDS - start < timeout_secs )); do
        if "$@" &>/dev/null; then
            return 0
        fi
        sleep 15
        local elapsed=$(( SECONDS - start ))
        if (( elapsed >= next_progress )); then
            detail "  Still waiting for $label (${elapsed}s / ${timeout_secs}s)..."
            next_progress=$((next_progress + 300))
        fi
    done
    local elapsed=$(( SECONDS - start ))
    warn "Timed out waiting for $label after ${elapsed}s — fetching last known state:"
    "$@" 2>&1 || true
    err "Timed out waiting for $label after ${elapsed}s"
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
  --fix-kernel                  Downgrade VM kernels to ASR-supported version if needed
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
FIX_KERNEL=false

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
        --fix-kernel)         FIX_KERNEL=true;           shift;;
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
if ! az backup vault show -g "$TARGET_RG" -n "$VAULT_NAME" &>/dev/null 2>&1; then
    err "Vault '$VAULT_NAME' not found in resource group '$TARGET_RG'.
  Make sure you ran 01-preflight-and-stage.sh first to create the vault.
  Do NOT reuse an existing vault created for other purposes."
fi
vault_location=$(az backup vault show -g "$TARGET_RG" -n "$VAULT_NAME" \
    --query "location" -o tsv 2>/dev/null \
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
        --sku Premium_LRS --kind BlockBlobStorage \
        --allow-shared-key-access true \
        --public-network-access Enabled --default-action Deny --bypass AzureServices \
        -o none
    ok "Created cache storage account: $CACHE_STORAGE_ACCT"
else
    ok "Cache storage account $CACHE_STORAGE_ACCT already exists"
fi

# Lock the cache account down: default-deny firewall, allow only trusted Microsoft
# services (the vault reaches it that way). Public endpoint stays Enabled-but-denied
# — fully Disabled would also block the trusted-service path and break ASR. Source
# VMs reach the cache over a private endpoint (configured below).
az storage account update -g "$SOURCE_RG" -n "$CACHE_STORAGE_ACCT" \
    --allow-shared-key-access true \
    --public-network-access Enabled --default-action Deny --bypass AzureServices \
    -o none 2>/dev/null || true

CACHE_STORAGE_ID=$(az storage account show -g "$SOURCE_RG" -n "$CACHE_STORAGE_ACCT" --query "id" -o tsv)

# Ensure the vault has a system-assigned MSI, then grant it access to the cache
# storage account. ASR uses the vault MSI to reach the cache; without this,
# enable-replication fails with error 28143.
VAULT_URL="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}?api-version=2024-04-01"
VAULT_MSI=$(az rest --method get --url "$VAULT_URL" --query "identity.principalId" -o tsv 2>/dev/null || echo "")
if [[ -z "$VAULT_MSI" || "$VAULT_MSI" == "null" ]]; then
    detail "  Enabling system-assigned identity on vault $VAULT_NAME..."
    az rest --method patch --url "$VAULT_URL" \
        --headers "Content-Type=application/json" \
        --body '{"identity":{"type":"SystemAssigned"}}' -o none
    for _ in $(seq 1 12); do
        VAULT_MSI=$(az rest --method get --url "$VAULT_URL" --query "identity.principalId" -o tsv 2>/dev/null || echo "")
        [[ -n "$VAULT_MSI" && "$VAULT_MSI" != "null" ]] && break
        sleep 5
    done
fi
if [[ -n "$VAULT_MSI" && "$VAULT_MSI" != "null" ]]; then
    detail "  Granting vault MSI ($VAULT_MSI) access to cache storage..."
    # Cache account is Premium BlockBlob → "Storage Blob Data Owner" (per ASR guidance).
    for role in "Storage Blob Data Owner" "Contributor"; do
        az role assignment create --assignee-object-id "$VAULT_MSI" --assignee-principal-type ServicePrincipal \
            --role "$role" --scope "$CACHE_STORAGE_ID" -o none 2>/dev/null \
            || detail "    role '$role' already assigned or pending"
    done
    # RBAC propagation for a fresh MSI can lag several minutes; wait before ASR
    # enable relies on it. If enable still fails with 28143, re-run — the item is
    # now self-healing (purged and retried) once propagation completes.
    detail "  Waiting 150s for role assignments to propagate..."
    sleep 150
else
    warn "  Could not obtain vault managed identity — ASR enable may fail with error 28143"
fi

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
    # Retry with backoff — vault may report "invalid state" immediately after
    # container creation (transient ASR timing issue).
    mapping_created=false
    for attempt in 1 2 3 4 5; do
        if AZ_SR_CMD_TIMEOUT=900 az_sr protection-container mapping create \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            --fabric-name "$SRC_FABRIC" \
            --protection-container "$SRC_CONTAINER" \
            -n "$MAPPING_NAME" \
            --policy-id "$POLICY_ID" \
            --target-container "$TGT_CONTAINER_ID" \
            --provider-input '{a2a:{}}' 2>/dev/null; then
            mapping_created=true
            break
        fi
        detail "  Container mapping attempt $attempt failed — vault may still be stabilizing. Waiting 60s..."
        sleep 60
    done
    if [[ "$mapping_created" == false ]]; then
        err "Failed to create container mapping after 5 attempts. Vault may need more time to stabilize — try re-running the script."
    fi
    wait_for_asr_resource "$ASR_MAPPING_TIMEOUT" "container mapping $MAPPING_NAME" \
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
SOURCE_SUBNET_NAME=$(echo "$source_subnet_id" | awk -F'/subnets/' '{print $2}')
SOURCE_VNET_ID=$(az network vnet show -g "$SOURCE_RG" -n "$SOURCE_VNET_NAME" --query "id" -o tsv)
TARGET_VNET_ID=$(az network vnet show -g "$TARGET_RG" -n "$TARGET_VNET" --query "id" -o tsv)

# ── Private endpoint so source VMs push replication data to the cache account
#    over private link (the account firewall denies all other public access) ──
PE_NAME="pe-${CACHE_STORAGE_ACCT}-blob"
BLOB_DNS_ZONE="privatelink.blob.core.windows.net"
if ! az network private-endpoint show -g "$SOURCE_RG" -n "$PE_NAME" &>/dev/null; then
    info "Creating private endpoint $PE_NAME for cache storage in $SOURCE_VNET_NAME/$SOURCE_SUBNET_NAME..."
    az network private-dns zone create -g "$SOURCE_RG" -n "$BLOB_DNS_ZONE" -o none 2>/dev/null || true
    az network private-dns link vnet create -g "$SOURCE_RG" --zone-name "$BLOB_DNS_ZONE" \
        -n "link-${SOURCE_VNET_NAME}" --virtual-network "$SOURCE_VNET_NAME" \
        --registration-enabled false -o none 2>/dev/null || true
    az network private-endpoint create -g "$SOURCE_RG" -n "$PE_NAME" \
        --vnet-name "$SOURCE_VNET_NAME" --subnet "$SOURCE_SUBNET_NAME" \
        --private-connection-resource-id "$CACHE_STORAGE_ID" --group-id blob \
        --connection-name "${CACHE_STORAGE_ACCT}-blob-conn" -l "$SOURCE_REGION" -o none
    az network private-endpoint dns-zone-group create -g "$SOURCE_RG" \
        --endpoint-name "$PE_NAME" -n zg-blob \
        --private-dns-zone "$BLOB_DNS_ZONE" --zone-name blob -o none
    ok "Created private endpoint for cache storage (private data path)"
else
    ok "Private endpoint $PE_NAME already exists"
fi

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

# ──────────── 6b. (Optional) Check/fix VM kernel for ASR compatibility ──
# ASR mobility service supports specific kernel versions. If the running kernel
# is unsupported, replication will fail with error 151141. The --fix-kernel flag
# installs a supported kernel and reboots the VMs.
#
# Supported Ubuntu 24.04 Azure kernel series (as of mobility service 9.66):
#   6.8.0-*-azure, 6.11.0-*-azure, 6.14.0-*-azure
# See: https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-support-matrix

# Max supported Azure kernel major.minor for Ubuntu 24.04
ASR_MAX_KERNEL_MAJOR=6
ASR_MAX_KERNEL_MINOR=14

check_kernel_supported() {
    local kernel_ver="$1"
    # Extract major.minor from kernel (e.g. 6.11.0-1018-azure → 6.11)
    local k_major k_minor
    k_major=$(echo "$kernel_ver" | cut -d. -f1)
    k_minor=$(echo "$kernel_ver" | cut -d. -f2)

    if (( k_major > ASR_MAX_KERNEL_MAJOR )) || \
       { (( k_major == ASR_MAX_KERNEL_MAJOR )) && (( k_minor > ASR_MAX_KERNEL_MINOR )); }; then
        return 1  # unsupported
    fi
    return 0  # supported
}

if [[ "$FIX_KERNEL" == true ]]; then
    info "Checking VM kernel versions for ASR compatibility..."
    for vm_name in "${VM_NAMES[@]}"; do
        vm_name="$(echo "$vm_name" | xargs)"

        # Get running kernel via run-command
        kernel_ver=$(az vm run-command invoke -g "$SOURCE_RG" -n "$vm_name" \
            --command-id RunShellScript --scripts 'uname -r' \
            --query "value[0].message" -o tsv 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-azure' | head -1)

        if [[ -z "$kernel_ver" ]]; then
            detail "  $vm_name: could not detect kernel — skipping check"
            continue
        fi

        if check_kernel_supported "$kernel_ver"; then
            ok "  $vm_name: kernel $kernel_ver is supported by ASR"
        else
            warn "$vm_name: kernel $kernel_ver is NOT supported by ASR (max supported: ${ASR_MAX_KERNEL_MAJOR}.${ASR_MAX_KERNEL_MINOR}.x)"
            info "  Installing supported kernel on $vm_name..."

            install_result=$(az vm run-command invoke -g "$SOURCE_RG" -n "$vm_name" \
                --command-id RunShellScript \
                --scripts 'export DEBIAN_FRONTEND=noninteractive; TARGET_KERNEL=$(apt-cache search "linux-image-6\.11\.0-.*-azure$" 2>/dev/null | grep -v fde | sort -V | tail -1 | awk "{print \$1}"); if [ -z "$TARGET_KERNEL" ]; then TARGET_KERNEL=$(apt-cache search "linux-image-6\.8\.0-.*-azure$" 2>/dev/null | grep -v fde | sort -V | tail -1 | awk "{print \$1}"); fi; if [ -z "$TARGET_KERNEL" ]; then echo "NO_KERNEL_FOUND"; exit 1; fi; MODULES_PKG=$(echo "$TARGET_KERNEL" | sed "s/linux-image-/linux-modules-/"); MODULES_EXTRA_PKG=$(echo "$TARGET_KERNEL" | sed "s/linux-image-/linux-modules-extra-/"); echo "Installing $TARGET_KERNEL..."; apt-get update -qq && apt-get install -y -qq "$TARGET_KERNEL" "$MODULES_PKG" "$MODULES_EXTRA_PKG" 2>&1 | tail -3 && echo "KERNEL_INSTALL_OK" || echo "KERNEL_INSTALL_FAILED"' \
                --query "value[0].message" -o tsv 2>/dev/null)

            if echo "$install_result" | grep -q "KERNEL_INSTALL_OK"; then
                ok "  $vm_name: supported kernel installed, rebooting..."
                az vm restart -g "$SOURCE_RG" -n "$vm_name" --no-wait -o none
            else
                err "  $vm_name: failed to install supported kernel. Check VM manually."
            fi
        fi
    done

    # Wait for any rebooting VMs to come back
    info "Waiting for VMs to come back online after kernel change..."
    sleep 60
    for vm_name in "${VM_NAMES[@]}"; do
        vm_name="$(echo "$vm_name" | xargs)"
        power=$(az vm show -g "$SOURCE_RG" -n "$vm_name" -d --query "powerState" -o tsv 2>/dev/null || echo "Unknown")
        while [[ "$power" != "VM running" ]]; do
            sleep 10
            power=$(az vm show -g "$SOURCE_RG" -n "$vm_name" -d --query "powerState" -o tsv 2>/dev/null || echo "Unknown")
        done
        ok "  $vm_name: running"
    done
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

    # Skip if already protected/healthy; purge and re-enable if a prior attempt
    # left the item in a *Failed* state (otherwise a re-run silently skips it).
    item_uri_existing="${ASR_BASE_URI}/replicationFabrics/${SRC_FABRIC}/replicationProtectionContainers/${SRC_CONTAINER}/replicationProtectedItems/${ITEM_NAME}?api-version=${ASR_API_VERSION}"
    existing_state=$(az rest --method get --uri "$item_uri_existing" \
        --query "properties.protectionState" -o tsv 2>/dev/null || echo "")
    if [[ -n "$existing_state" ]]; then
        if [[ "$existing_state" == *Failed* ]]; then
            warn "  $vm_name: found in $existing_state — purging to re-enable..."
            az rest --method delete --uri "$item_uri_existing" -o none 2>/dev/null || true
            for _ in $(seq 1 40); do
                az rest --method get --uri "$item_uri_existing" -o none 2>/dev/null || break
                sleep 15
            done
        else
            ok "  $vm_name: replication already enabled ($existing_state) — skipping"
            continue
        fi
    fi

    info "  Enabling replication for $vm_name..."

    vm_json=$(az vm show -g "$SOURCE_RG" -n "$vm_name" -o json)
    vm_id=$(echo "$vm_json" | jq -r '.id')
    security_type=$(echo "$vm_json" | jq -r '.securityProfile.securityType // "Standard"')

    # Build managed disk list (OS + data disks) as JSON array
    os_disk_id=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.managedDisk.id')
    os_disk_sku=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.managedDisk.storageAccountType')
    os_replica_sku=$(replica_sku_for "$os_disk_sku")   

    disk_array=$(jq -n \
        --arg diskId "$os_disk_id" \
        --arg cacheId "$CACHE_STORAGE_ID" \
        --arg recRg "$TARGET_RG_ID" \
        --arg sku "$os_disk_sku" \
        --arg replicaSku "$os_replica_sku" \
        '[{
            diskId: $diskId,
            primaryStagingAzureStorageAccountId: $cacheId,
            recoveryResourceGroupId: $recRg,
            recoveryReplicaDiskAccountType: $replicaSku,
            recoveryTargetDiskAccountType: $sku
        }]')

    data_disk_count=$(echo "$vm_json" | jq '.storageProfile.dataDisks | length')
    for i in $(seq 0 $((data_disk_count - 1))); do
        dd_id=$(echo "$vm_json" | jq -r ".storageProfile.dataDisks[$i].managedDisk.id")
        dd_sku=$(echo "$vm_json" | jq -r ".storageProfile.dataDisks[$i].managedDisk.storageAccountType")
        dd_replica_sku=$(replica_sku_for "$dd_sku")  
        disk_array=$(echo "$disk_array" | jq \
            --arg diskId "$dd_id" \
            --arg cacheId "$CACHE_STORAGE_ID" \
            --arg recRg "$TARGET_RG_ID" \
            --arg sku "$dd_sku" \
	    --arg replicaSku "$dd_replica_sku" \
            '. + [{
                diskId: $diskId,
                primaryStagingAzureStorageAccountId: $cacheId,
                recoveryResourceGroupId: $recRg,
                recoveryReplicaDiskAccountType: $replicaSku,
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
    
    # Premium SSD v2 / Ultra disks are zonal — a target availability zone is
    # required in zone-capable regions. Reuse the source VM's zone.
    vm_zone=$(echo "$vm_json" | jq -r '.zones[0] // empty')
    if [[ -n "$vm_zone" ]]; then
        detail "    Setting target availability zone: $vm_zone"
        provider_specific=$(echo "$provider_specific" | jq --arg z "$vm_zone" '. + {recoveryAvailabilityZone: $z}')
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

    rest_output=$(az rest --method put \
        --uri "$item_uri" \
        --body "$request_body" \
        -o json 2>&1) || {
        echo "$rest_output" >&2
        err "  Failed to enable replication for $vm_name. Check vault, fabric, and VM configuration."
    }
    # Catch async failures: PUT returns 200/202 (exit 0) but provisioningState may be Failed
    if echo "$rest_output" | jq -e '.properties.provisioningState == "Failed"' &>/dev/null; then
        echo "$rest_output" | jq '.properties' >&2
        err "  Replication enable failed for $vm_name — see error details above."
    fi
    detail "    Replication request accepted for $vm_name"

    # Poll using REST API directly — must use the same api-version as the PUT
    # to avoid the CLI extension's api-version returning a 404 for the new item.
    wait_for_asr_resource "$ASR_REPL_TIMEOUT" "replication item $ITEM_NAME" \
        az rest --method get --uri "$item_uri" -o none

    ok "  $vm_name: replication enabled (item: $ITEM_NAME)"
done

# ──────────── 8. Poll replication health ──────────────────────
if [[ "$NO_WAIT" == false ]]; then
    info "Polling replication health until initial sync completes..."
    info "(This can take 30-90 minutes depending on disk size. Ctrl+C is safe — replication continues.)"
    echo ""

    all_synced=false
    failed_vms=""
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

            case "$state" in
                Protected)
                    ok "  $vm_name: Protected (health: $health)" ;;
                *Failed*)
                    # Terminal failure — don't loop forever. Surface the health error.
                    hint=$(echo "$item_json" | jq -r '[.properties.healthErrors[]? | .errorMessage] | join("; ") // empty')
                    warn "  $vm_name: $state (health: $health) — enable FAILED: ${hint:-see portal}"
                    failed_vms="${failed_vms} ${vm_name}"
                    all_synced=false ;;
                *)
                    detail "  $vm_name: $state (health: $health) — syncing..."
                    all_synced=false ;;
            esac
        done

        # If every not-yet-Protected VM is in a *Failed* state, stop — no progress possible.
        if [[ "$all_synced" == false && -n "$failed_vms" ]]; then
            still_syncing=false
            for vm_name in "${VM_NAMES[@]}"; do
                vm_name="$(echo "$vm_name" | xargs)"
                [[ " $failed_vms " == *" $vm_name "* ]] && continue
                ITEM_NAME="asr-${vm_name}"
                st=$(az_sr protected-item show -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
                    --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
                    -n "$ITEM_NAME" --query "properties.protectionState" -o tsv 2>/dev/null || echo "")
                [[ "$st" != "Protected" ]] && still_syncing=true
            done
            if [[ "$still_syncing" == false ]]; then
                err "Enable replication failed for:${failed_vms}. Fix the health errors above (e.g. grant the vault MSI access to the cache storage account) and re-run this script."
            fi
        fi

        if [[ "$all_synced" == false ]]; then
            echo "  Waiting 60s before next check..."
            sleep 60
            failed_vms=""
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
info "== IMPORTANT: Replication bandwidth =="
info "  Default ASR bandwidth: 54 MB/s per VM (Normal Churn)."
info "  To increase:"
info "    1. Open a support request (Service: Azure Site Recovery, Problem type: Replication)"
info "    2. Request increased replication bandwidth for your subscription/region pair"
info "    3. Enable High Churn in ASR policy (requires Premium Block Blob cache — already configured)"
info "  See: asr-replication-speed-conclusions.md for full analysis"
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
