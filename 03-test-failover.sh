#!/usr/bin/env bash
#
# 03-test-failover.sh
# Cross-region ASR migration — Phase 3: Test failover.
#
# Mandatory validation step before planned cutover. Creates an isolated test
# VNet, triggers test failover per VM, waits for completion, prompts the
# operator to validate (Secure Boot, vTPM, app health), then cleans up.
#
# NOTE: The az CLI site-recovery extension does not expose test-failover or
# test-failover-cleanup subcommands. This script uses `az rest` to call the
# ASR REST API directly for those operations.
#
# Prerequisite: Run 02-enable-asr-replication.sh first (VMs must be in Protected state).
# Next step:    Run 04-planned-failover.sh to execute the planned cutover.
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

Run ASR test failover for Trusted Launch VMs into an isolated test network.

Required:
  --target-rg NAME              Target resource group (where vault lives)
  --target-region REGION        Target region (e.g. centralus)
  --vault-name NAME             Recovery Services vault name
  --vm-names VM1,VM2,...        Comma-separated list of VM names
  --source-region REGION        Source region (e.g. eastus)

Optional:
  --test-vnet-name NAME         Test VNet name           (default: vnet-asr-test)
  --test-vnet-cidr CIDR         Test VNet address space  (default: 10.99.0.0/16)
  --test-subnet-cidr CIDR       Test subnet prefix       (default: 10.99.1.0/24)
  --test-nsg-name NAME          NSG to attach to test NICs (optional)
  -h, --help                    Show this help

Example:
  $(basename "$0") \\
    --target-rg rg-prod-centralus --target-region centralus \\
    --vault-name vault-asr-centralus \\
    --vm-names "vm-app01,vm-app02" \\
    --source-region eastus
EOF
    exit 0
}

# ──────────────────────────── Parse args ────────────────────────
TARGET_RG=""
TARGET_REGION=""
VAULT_NAME=""
VM_NAMES_CSV=""
SOURCE_REGION=""
TEST_VNET_NAME="vnet-asr-test"
TEST_VNET_CIDR="10.99.0.0/16"
TEST_SUBNET_CIDR="10.99.1.0/24"
TEST_NSG_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-rg)        TARGET_RG="$2";         shift 2;;
        --target-region)    TARGET_REGION="$2";      shift 2;;
        --vault-name)       VAULT_NAME="$2";         shift 2;;
        --vm-names)         VM_NAMES_CSV="$2";       shift 2;;
        --source-region)    SOURCE_REGION="$2";      shift 2;;
        --test-vnet-name)   TEST_VNET_NAME="$2";     shift 2;;
        --test-vnet-cidr)   TEST_VNET_CIDR="$2";     shift 2;;
        --test-subnet-cidr) TEST_SUBNET_CIDR="$2";   shift 2;;
        --test-nsg-name)    TEST_NSG_NAME="$2";      shift 2;;
        -h|--help)          usage;;
        *) err "Unknown argument: $1";;
    esac
done

[[ -z "$TARGET_RG" ]]     && err "--target-rg is required"
[[ -z "$TARGET_REGION" ]] && err "--target-region is required"
[[ -z "$VAULT_NAME" ]]    && err "--vault-name is required"
[[ -z "$VM_NAMES_CSV" ]]  && err "--vm-names is required"
[[ -z "$SOURCE_REGION" ]] && err "--source-region is required"

IFS=',' read -ra VM_NAMES <<< "$VM_NAMES_CSV"

SUB_ID=$(az account show --query "id" -o tsv)
SRC_FABRIC="fabric-${SOURCE_REGION}"
SRC_CONTAINER="container-${SOURCE_REGION}"
API_VERSION="2025-08-01"

info "== Phase 3: Test Failover =="

# ──────────── 1. Create isolated test VNet ────────────────────
info "Creating isolated test VNet: $TEST_VNET_NAME"

if ! az network vnet show -g "$TARGET_RG" -n "$TEST_VNET_NAME" &>/dev/null; then
    az network vnet create \
        -g "$TARGET_RG" -n "$TEST_VNET_NAME" -l "$TARGET_REGION" \
        --address-prefix "$TEST_VNET_CIDR" \
        --subnet-name "snet-test" --subnet-prefix "$TEST_SUBNET_CIDR" \
        -o none
    ok "Created test VNet $TEST_VNET_NAME ($TEST_VNET_CIDR) — no connectivity to source"
else
    ok "Test VNet $TEST_VNET_NAME already exists"
fi

TEST_VNET_ID=$(az network vnet show -g "$TARGET_RG" -n "$TEST_VNET_NAME" --query "id" -o tsv)

# ──────────── 2. Trigger test failover per VM ─────────────────
info "Triggering test failover for ${#VM_NAMES[@]} VM(s)..."

for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"
    ITEM_NAME="asr-${vm_name}"

    info "  Starting test failover for $vm_name..."

    # Build the REST API URL
    item_url="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}/replicationFabrics/${SRC_FABRIC}/replicationProtectionContainers/${SRC_CONTAINER}/replicationProtectedItems/${ITEM_NAME}"

    # Trigger test failover via REST API
    az rest --method post \
        --url "${item_url}/testFailover?api-version=${API_VERSION}" \
        --body "{\"properties\":{\"failoverDirection\":\"PrimaryToRecovery\",\"networkType\":\"VmNetworkAsInput\",\"networkId\":\"${TEST_VNET_ID}\",\"providerSpecificDetails\":{\"instanceType\":\"A2A\"}}}" \
        -o none 2>/dev/null || true

    ok "  $vm_name: test failover initiated"
done

# ──────────── 3. Wait for test failover completion ────────────
# The ONLY correct success state is testFailoverState == "WaitingForCompletion".
# Earlier states (Initiating, TestFailoverCompleting, TestFailoverCompletionPending)
# are all transient — the test failover is NOT done until WaitingForCompletion.
info "Waiting for testFailoverState → WaitingForCompletion for each VM..."
info "(This may take 10-30 minutes per VM.)"
echo ""

TFO_TIMEOUT=3600  # 60 min max wait
TFO_START=$SECONDS

# Parallel arrays to store discovered NIC names (bash 3.x compatible)
TEST_NIC_NAMES=()
TEST_NIC_VM_NAMES=()

all_done=false
while [[ "$all_done" == false ]]; do
    if (( SECONDS - TFO_START >= TFO_TIMEOUT )); then
        err "Timed out waiting for test failover after ${TFO_TIMEOUT}s. Check ASR jobs in the portal."
    fi
    all_done=true
    for vm_name in "${VM_NAMES[@]}"; do
        vm_name="$(echo "$vm_name" | xargs)"
        ITEM_NAME="asr-${vm_name}"

        # Skip VMs already confirmed done
        already_found=false
        if [[ ${#TEST_NIC_VM_NAMES[@]} -gt 0 ]]; then
            for stored_vm in "${TEST_NIC_VM_NAMES[@]}"; do
                if [[ "$stored_vm" == "$vm_name" ]]; then
                    already_found=true
                    break
                fi
            done
        fi
        if [[ "$already_found" == true ]]; then
            continue
        fi

        # Check ASR testFailoverState
        test_status=$(az site-recovery protected-item show \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
            -n "$ITEM_NAME" --query "properties.testFailoverState" \
            -o tsv 2>/dev/null || echo "Unknown")

        if [[ "$test_status" == "WaitingForCompletion" ]]; then
            # Test failover is done — derive NIC name from the test VM
            test_vm_name="${vm_name}-test"
            test_nic_id=$(az vm show -g "$TARGET_RG" -n "$test_vm_name" \
                --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null || echo "")
            test_nic_name="${test_nic_id##*/}"
            TEST_NIC_VM_NAMES+=("$vm_name")
            TEST_NIC_NAMES+=("$test_nic_name")
            ok "  $vm_name: WaitingForCompletion — test VM ready (NIC=$test_nic_name)"
        elif [[ "$test_status" == "TestFailoverFailed" ]]; then
            err "  $vm_name: test failover FAILED. Check ASR jobs in the portal."
        else
            detail "  $vm_name: $test_status — waiting..."
            all_done=false
        fi
    done

    if [[ "$all_done" == false ]]; then
        local_elapsed=$(( SECONDS - TFO_START ))
        echo "  Waiting 30s before next check... (${local_elapsed}s / ${TFO_TIMEOUT}s)"
        sleep 30
    fi
done
ok "All VMs reached WaitingForCompletion — test failover complete."

# ──────────── 3b. Create PIPs for test VMs and attach to test NICs ──
info "Creating public IPs for test VMs..."

for i in "${!VM_NAMES[@]}"; do
    vm_name="$(echo "${VM_NAMES[$i]}" | xargs)"
    # Look up NIC name from parallel arrays
    TEST_NIC_NAME=""
    for j in "${!TEST_NIC_VM_NAMES[@]}"; do
        if [[ "${TEST_NIC_VM_NAMES[$j]}" == "$vm_name" ]]; then
            TEST_NIC_NAME="${TEST_NIC_NAMES[$j]}"
            break
        fi
    done
    TEST_PIP_NAME="${vm_name}-pip-test"

    # Verify the test NIC was discovered
    if [[ -z "$TEST_NIC_NAME" ]]; then
        warn "No test NIC found for $vm_name — skipping PIP creation"
        continue
    fi

    # Create public IP
    info "  Creating PIP: $TEST_PIP_NAME"
    az network public-ip create \
        -g "$TARGET_RG" -n "$TEST_PIP_NAME" -l "$TARGET_REGION" \
        --sku Standard --allocation-method Static \
        -o none

    # Get the first ip-config name from the test NIC
    ipconfig_name=$(az network nic show -g "$TARGET_RG" -n "$TEST_NIC_NAME" \
        --query "ipConfigurations[0].name" -o tsv)

    # Attach PIP to test NIC
    az network nic ip-config update \
        -g "$TARGET_RG" --nic-name "$TEST_NIC_NAME" \
        -n "$ipconfig_name" \
        --public-ip-address "$TEST_PIP_NAME" \
        -o none
    ok "  $vm_name: PIP $TEST_PIP_NAME attached to $TEST_NIC_NAME"

    # Attach NSG to test NIC (if specified)
    if [[ -n "$TEST_NSG_NAME" ]]; then
        az network nic update \
            -g "$TARGET_RG" -n "$TEST_NIC_NAME" \
            --network-security-group "$TEST_NSG_NAME" \
            -o none
        ok "  $vm_name: NSG $TEST_NSG_NAME attached to $TEST_NIC_NAME"
    fi
done

# ──────────── 4. Print validation checklist ───────────────────
echo ""
info "======================================================================"
info "  TEST FAILOVER COMPLETE — VALIDATE BEFORE PROCEEDING"
info "======================================================================"
echo ""
echo "  Validation checklist for each test-failover VM:"
echo ""
echo "  [ ] 1. VM boots successfully in the target region"
echo "  [ ] 2. Secure Boot is enabled:  az vm show -g $TARGET_RG -n <vm>-test --query securityProfile"
echo "  [ ] 3. vTPM is enabled:         (same command — check uefiSettings.vTpmEnabled)"
echo "  [ ] 4. Disk controller type matches source (NVMe/SCSI)"
echo "  [ ] 5. All data disks attached at correct LUNs"
echo "  [ ] 6. Application health check passes (SSH/RDP, service ports)"
echo "  [ ] 7. No connectivity leak to source network (test VNet is isolated)"
echo ""
warn "Do NOT proceed to planned failover until all checks pass."
echo ""

read -rp "Press ENTER when validation is complete (or Ctrl+C to abort)..."

# ──────────── 5. Cleanup test failover ────────────────────────
info "Cleaning up test failover..."

for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"
    ITEM_NAME="asr-${vm_name}"

    item_url="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}/replicationFabrics/${SRC_FABRIC}/replicationProtectionContainers/${SRC_CONTAINER}/replicationProtectedItems/${ITEM_NAME}"

    az rest --method post \
        --url "${item_url}/testFailoverCleanup?api-version=${API_VERSION}" \
        --body '{"properties":{"comments":"Test failover validated — cleaning up"}}' \
        -o none 2>/dev/null || true

    ok "  $vm_name: test failover cleanup initiated"
done

# Wait for cleanup to settle
info "Waiting for cleanup to complete..."
sleep 30

# Verify items are back to normal protection state
for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"
    ITEM_NAME="asr-${vm_name}"

    item_json=$(az site-recovery protected-item show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
        -n "$ITEM_NAME" -o json 2>/dev/null || echo "{}")

    state=$(echo "$item_json" | jq -r '.properties.protectionState // "Unknown"')
    ok "  $vm_name: back to state=$state"
done

# ──────────── 6. Delete test PIPs ─────────────────────────────
info "Deleting test public IPs..."
for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"
    TEST_PIP_NAME="${vm_name}-pip-test"
    az network public-ip delete -g "$TARGET_RG" -n "$TEST_PIP_NAME" -o none 2>/dev/null || true
    ok "  Deleted $TEST_PIP_NAME"
done

# ──────────── 7. Delete test VNet ─────────────────────────────
info "Deleting test VNet: $TEST_VNET_NAME"
az network vnet delete -g "$TARGET_RG" -n "$TEST_VNET_NAME" -o none 2>/dev/null || true
ok "Test VNet deleted"

# ──────────── Done ──────────────────────────────────────────────
echo ""
info "== Test failover validated and cleaned up. =="
info ""
info "Next step:"
info "  Run 04-planned-failover.sh to execute the planned cutover."
info ""
info "  Example:"
echo "    ./04-planned-failover.sh \\"
echo "      --source-rg \"<SOURCE_RG>\" --source-region \"$SOURCE_REGION\" \\"
echo "      --target-rg \"$TARGET_RG\" --target-region \"$TARGET_REGION\" \\"
echo "      --vault-name \"$VAULT_NAME\" --vm-names \"$VM_NAMES_CSV\""
