#!/usr/bin/env bash
#
# 04-planned-failover.sh
# Cross-region ASR migration — Phases 4-5: Recovery plan + planned cutover + post-failover wiring.
#
# Builds a recovery plan grouping all VMs, triggers planned failover, waits for
# completion, then wires the target network (NSG association, public IP assignment,
# LB backend pool membership). Finally commits the failover.
#
# This script absorbs the post-failover wiring logic from the former
# 02-failover-automation.sh.
#
# Prerequisite: Run 03-test-failover.sh first (test failover must pass).
# Next step:    Run 05-decommission.sh after soak period and sign-off.
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

# ──────────────────────────── Usage ─────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Execute ASR planned failover with post-failover network wiring.

Required:
  --source-rg NAME              Source resource group
  --source-region REGION        Source region (e.g. eastus)
  --target-rg NAME              Target resource group
  --target-region REGION        Target region (e.g. centralus)
  --vault-name NAME             Recovery Services vault name
  --vm-names VM1,VM2,...        Comma-separated list of VM names

Optional:
  --nsg-name NAME               Target NSG name (default: same name as the source NSG)
  --nsg-rg NAME                 RG holding the target NSG (default: search TARGET_RG then
                                RG_CORE_<target-region>; NSG often lives in a shared core RG)
  --public-ip-name NAME         Target public IP name       (default: mirror source LB PIP)
  --lb-name NAME                Target Load Balancer name   (default: mirror source LB)
  --lb-backend-pool NAME        LB backend pool name        (default: bepool)
  --source-inventory PATH       Source inventory JSON        (default: ./source-inventory.json)
  --recovery-plan-name NAME     Recovery plan name          (default: plan-region-migration)
  --skip-wiring                 Skip post-failover network wiring
  --skip-commit                 Skip failover commit (do it manually later)
  -h, --help                    Show this help

Example:
  $(basename "$0") \\
    --source-rg rg-prod-eastus --source-region eastus \\
    --target-rg rg-prod-centralus --target-region centralus \\
    --vault-name vault-asr-centralus \\
    --vm-names "vm-app01,vm-app02"
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
NSG_NAME=""
NSG_RG=""
PIP_NAME="pip-workload-lb"
LB_NAME="lb-workload"
LB_BACKEND_POOL="bepool"
INVENTORY_FILE="./source-inventory.json"
RECOVERY_PLAN_NAME="plan-region-migration"
SKIP_WIRING=false
SKIP_COMMIT=false
PIP_NAME_SET=false
LB_NAME_SET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-rg)           SOURCE_RG="$2";            shift 2;;
        --source-region)       SOURCE_REGION="$2";        shift 2;;
        --target-rg)           TARGET_RG="$2";            shift 2;;
        --target-region)       TARGET_REGION="$2";        shift 2;;
        --vault-name)          VAULT_NAME="$2";           shift 2;;
        --vm-names)            VM_NAMES_CSV="$2";         shift 2;;
        --nsg-name)            NSG_NAME="$2";             shift 2;;
        --nsg-rg)              NSG_RG="$2";               shift 2;;
        --public-ip-name)      PIP_NAME="$2"; PIP_NAME_SET=true; shift 2;;
        --lb-name)             LB_NAME="$2"; LB_NAME_SET=true; shift 2;;
        --lb-backend-pool)     LB_BACKEND_POOL="$2";      shift 2;;
        --source-inventory)    INVENTORY_FILE="$2";        shift 2;;
        --recovery-plan-name)  RECOVERY_PLAN_NAME="$2";   shift 2;;
        --skip-wiring)         SKIP_WIRING=true;          shift;;
        --skip-commit)         SKIP_COMMIT=true;          shift;;
        -h|--help)             usage;;
        *) err "Unknown argument: $1";;
    esac
done

[[ -z "$SOURCE_RG" ]]     && err "--source-rg is required"
[[ -z "$SOURCE_REGION" ]] && err "--source-region is required"
[[ -z "$TARGET_RG" ]]     && err "--target-rg is required"
[[ -z "$TARGET_REGION" ]] && err "--target-region is required"
[[ -z "$VAULT_NAME" ]]    && err "--vault-name is required"
[[ -z "$VM_NAMES_CSV" ]]  && err "--vm-names is required"

# Catch the common copy-paste trap where a placeholder is passed verbatim.
for _v in "--source-rg=$SOURCE_RG" "--target-rg=$TARGET_RG" "--nsg-rg=$NSG_RG"; do
    _flag="${_v%%=*}"; _val="${_v#*=}"
    [[ "$_val" == *"<"* || "$_val" == *">"* ]] && \
        err "$_flag looks like a placeholder ('$_val') — pass the real resource group name."
done

IFS=',' read -ra VM_NAMES <<< "$VM_NAMES_CSV"

# Target mirrors source resource names verbatim — requires distinct RGs.
if [[ "$SOURCE_RG" == "$TARGET_RG" ]]; then
    err "--source-rg and --target-rg must differ: the target mirrors source resource names, which would collide in the same RG."
fi

SUB_ID=$(az account show --query "id" -o tsv)
API_VERSION="2025-08-01"

# Mirror LB/PIP names from source (region migration → identical names in target RG)
if [[ "$LB_NAME_SET" == false ]] && [[ -f "$INVENTORY_FILE" ]]; then
    src_lb_id=$(jq -r '.[0].nics[0].ipConfigurations[0].lbBackends[0] // empty' "$INVENTORY_FILE")
    if [[ -n "$src_lb_id" ]]; then
        SOURCE_LB=$(echo "$src_lb_id" | awk -F'/loadBalancers/' '{print $2}' | awk -F'/' '{print $1}')
        LB_NAME="$SOURCE_LB"
        LB_BACKEND_POOL=$(echo "$src_lb_id" | awk -F'/backendAddressPools/' '{print $2}')
        if [[ "$PIP_NAME_SET" == false ]]; then
            # Mirror the source LB frontend PIP name (casing differs across az versions)
            PIP_NAME=$(az network lb show -g "$SOURCE_RG" -n "$SOURCE_LB" -o json 2>/dev/null \
                | jq -r '(((.frontendIPConfigurations // .frontendIpConfigurations // [])[0]
                    | (.publicIPAddress // .publicIpAddress // {}).id) // empty) | split("/") | last')
            [[ -z "$PIP_NAME" ]] && PIP_NAME="pip-${SOURCE_LB}"
        fi
        detail "Mirrored from inventory: LB=$LB_NAME PIP=$PIP_NAME POOL=$LB_BACKEND_POOL"
    fi
fi

SRC_FABRIC="fabric-${SOURCE_REGION}"
TGT_FABRIC="fabric-${TARGET_REGION}"
SRC_CONTAINER="container-${SOURCE_REGION}"

info "== Phases 4-5: Recovery Plan + Planned Failover + Post-Failover Wiring =="

# ──────────── 1. Build recovery plan ─────────────────────────
info "Building recovery plan: $RECOVERY_PLAN_NAME"

SRC_FABRIC_ID=$(az site-recovery fabric show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$SRC_FABRIC" \
    --query "id" -o tsv)

TGT_FABRIC_ID=$(az site-recovery fabric show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$TGT_FABRIC" \
    --query "id" -o tsv)

# Collect protected item IDs for the recovery plan group
protected_items_json="[]"
for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"
    ITEM_NAME="asr-${vm_name}"

    item_json=$(az site-recovery protected-item show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
        -n "$ITEM_NAME" -o json)

    item_id=$(echo "$item_json" | jq -r '.id')
    # The VM ID is in providerSpecificDetails.fabricObjectId
    vm_id=$(echo "$item_json" | jq -r '.properties.providerSpecificDetails.fabricObjectId // empty')

    protected_items_json=$(echo "$protected_items_json" | jq \
        --arg id "$item_id" \
        --arg vmId "$vm_id" \
        '. + [{id: $id, "virtual-machine-id": $vmId}]')
done

# Build groups JSON for recovery plan — single Boot group with all VMs
groups_json=$(echo "$protected_items_json" | jq '[{"group-type": "Boot", "replication-protected-items": .}]')

if az site-recovery recovery-plan show \
    -g "$TARGET_RG" --vault-name "$VAULT_NAME" -n "$RECOVERY_PLAN_NAME" &>/dev/null; then
    ok "Recovery plan $RECOVERY_PLAN_NAME already exists — will reuse"
else
    az site-recovery recovery-plan create \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        -n "$RECOVERY_PLAN_NAME" \
        --primary-fabric-id "$SRC_FABRIC_ID" \
        --recovery-fabric-id "$TGT_FABRIC_ID" \
        --groups "$groups_json" \
        --failover-deployment-model ResourceManager \
        --no-wait false
    ok "Created recovery plan: $RECOVERY_PLAN_NAME"
fi

# ──────────── 2. Pre-failover confirmation ────────────────────
echo ""
warn "=== PLANNED FAILOVER — POINT OF NO RETURN ==="
echo ""
echo "  This will:"
echo "    1. Stop replication from source → target"
echo "    2. Fail over all VMs to the target region"
echo "    3. Wire NSGs, public IP, and LB backend pool"
echo "    4. Commit the failover"
echo ""
echo "  Ensure:"
echo "    - DNS TTL has been lowered (recommended: 60s, at least 24h ago)"
echo "    - Test failover has been validated (03-test-failover.sh)"
echo "    - Change ticket / maintenance window is approved"
echo "    - BitLocker/vTPM recovery keys are escrowed"
echo ""

read -rp "Type 'FAILOVER' to proceed (or Ctrl+C to abort): " confirm
[[ "$confirm" != "FAILOVER" ]] && err "Aborted — you must type FAILOVER to proceed."

# ──────────── 3. Trigger failover per VM ──────────────────────
# A2A does NOT support "plannedFailover" — use "unplannedFailover" instead.
# When VMs are Protected and fully synced, unplannedFailover with the latest
# recovery point produces minimal-to-zero data loss (equivalent to a cutover).
info "Triggering failover for ${#VM_NAMES[@]} VM(s)..."

rp_url="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}/replicationRecoveryPlans/${RECOVERY_PLAN_NAME}"

for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"
    ITEM_NAME="asr-${vm_name}"

    info "  Failing over $vm_name..."

    item_url="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}/replicationFabrics/${SRC_FABRIC}/replicationProtectionContainers/${SRC_CONTAINER}/replicationProtectedItems/${ITEM_NAME}"

    az rest --method post \
        --url "${item_url}/unplannedFailover?api-version=${API_VERSION}" \
        --body '{"properties":{"failoverDirection":"PrimaryToRecovery","sourceSiteOperations":"NotRequired","providerSpecificDetails":{"instanceType":"A2A"}}}' \
        -o none
    ok "  $vm_name: failover triggered"
done

# Poll per-VM failover status
info "Waiting for failover to complete..."
fo_start=$SECONDS
all_done=false
while [[ "$all_done" == false ]]; do
    if (( SECONDS - fo_start >= 1800 )); then
        err "Timed out waiting for failover after 1800s"
    fi
    all_done=true
    for vm_name in "${VM_NAMES[@]}"; do
        vm_name="$(echo "$vm_name" | xargs)"
        ITEM_NAME="asr-${vm_name}"

        item_json=$(az site-recovery protected-item show \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
            -n "$ITEM_NAME" -o json 2>/dev/null || echo "{}")

        active_loc=$(echo "$item_json" | jq -r '.properties.activeLocation // "Unknown"')
        prot_state=$(echo "$item_json" | jq -r '.properties.protectionState // "Unknown"')

        if [[ "$active_loc" == "Recovery" ]]; then
            ok "  $vm_name: failover done (activeLocation=Recovery, protectionState=$prot_state)"
        elif [[ "$prot_state" == "UnplannedFailoverFailed" ]]; then
            err "  $vm_name: failover FAILED"
        else
            detail "  $vm_name: activeLocation=$active_loc protectionState=$prot_state — waiting..."
            all_done=false
        fi
    done
    if [[ "$all_done" == false ]]; then
        sleep 30
    fi
done
ok "All VMs failed over to $TARGET_REGION"

# ──────────── 4. Post-failover network wiring ─────────────────
VM_PIP_SUMMARY=()
if [[ "$SKIP_WIRING" == false ]]; then
    info "Running post-failover network wiring..."

    # Wait for VMs to be provisioned in target region
    info "Waiting for VMs to be provisioned in target region..."
    for vm_name in "${VM_NAMES[@]}"; do
        vm_name="$(echo "$vm_name" | xargs)"
        detail "  Waiting for $vm_name to appear in $TARGET_RG..."
        start=$SECONDS
        while (( SECONDS - start < 600 )); do
            if az vm show -g "$TARGET_RG" -n "$vm_name" --query "id" -o tsv &>/dev/null; then
                state=$(az vm show -g "$TARGET_RG" -n "$vm_name" --query "provisioningState" -o tsv 2>/dev/null)
                if [[ "$state" == "Succeeded" ]]; then
                    ok "  $vm_name: provisioned ($state)"
                    break
                fi
                detail "  $vm_name: exists but provisioningState=$state — waiting..."
            fi
            sleep 15
        done
        if ! az vm show -g "$TARGET_RG" -n "$vm_name" --query "id" -o tsv &>/dev/null; then
            warn "$vm_name not found in $TARGET_RG after 600s — skipping wiring"
        fi
    done

    # Ensure public IP exists at destination
    if ! az network public-ip show -g "$TARGET_RG" -n "$PIP_NAME" &>/dev/null; then
        info "Creating public IP $PIP_NAME in $TARGET_RG..."
        az network public-ip create \
            -g "$TARGET_RG" -n "$PIP_NAME" -l "$TARGET_REGION" \
            --sku Standard --allocation-method Static \
            -o none
        ok "Created public IP $PIP_NAME"
    fi

    # Copy the source LB frontend PIP DNS label onto the target LB PIP
    # (casing differs across az CLI versions)
    if [[ -n "${SOURCE_LB:-}" ]]; then
        src_lb_pip_id=$(az network lb show -g "$SOURCE_RG" -n "$SOURCE_LB" -o json 2>/dev/null \
            | jq -r '(((.frontendIPConfigurations // .frontendIpConfigurations // [])[0]
                | (.publicIPAddress // .publicIpAddress // {}).id) // empty)' || true)
        src_lb_label=""
        [[ -n "$src_lb_pip_id" ]] && src_lb_label=$(az network public-ip show --ids "$src_lb_pip_id" \
            --query "dnsSettings.domainNameLabel" -o tsv 2>/dev/null || true)
        if [[ -n "$src_lb_label" && "$src_lb_label" != "None" ]]; then
            az network public-ip update -g "$TARGET_RG" -n "$PIP_NAME" \
                --dns-name "$src_lb_label" -o none 2>/dev/null \
                && ok "DNS label '$src_lb_label' set on $PIP_NAME" \
                || warn "Could not set DNS label '$src_lb_label' on $PIP_NAME"
        fi
    fi
    pip_address=$(az network public-ip show -g "$TARGET_RG" -n "$PIP_NAME" --query "ipAddress" -o tsv 2>/dev/null || echo "N/A")
    pip_fqdn=$(az network public-ip show -g "$TARGET_RG" -n "$PIP_NAME" --query "dnsSettings.fqdn" -o tsv 2>/dev/null || true)

    # Verify LB exists
    bepool_id=""
    if ! az network lb show -g "$TARGET_RG" -n "$LB_NAME" &>/dev/null; then
        warn "Load balancer $LB_NAME not found in $TARGET_RG — skipping LB wiring"
    else
        lb_json=$(az network lb show -g "$TARGET_RG" -n "$LB_NAME" -o json)
        bepool_id=$(echo "$lb_json" | jq -r --arg pool "$LB_BACKEND_POOL" \
            '.backendAddressPools[] | select(.name == $pool) | .id')
        [[ -z "$bepool_id" ]] && warn "Backend pool '$LB_BACKEND_POOL' not found in LB '$LB_NAME' — skipping LB wiring"

        # Verify PIP is on LB frontend
        # Property casing differs across az CLI versions (publicIpAddress vs publicIPAddress)
        lb_fe_pip=$(echo "$lb_json" | jq -r '(((.frontendIPConfigurations // .frontendIpConfigurations // [])[0]
            | (.publicIPAddress // .publicIpAddress // {}).id) // empty)' | awk -F'/' '{print $NF}')
        if [[ -z "$lb_fe_pip" ]]; then
            lb_fe_name=$(echo "$lb_json" | jq -r \
                '(.frontendIPConfigurations // .frontendIpConfigurations // [])[0].name // "fe"')
            info "Attaching PIP $PIP_NAME to LB $LB_NAME frontend $lb_fe_name..."
            az network lb frontend-ip update \
                -g "$TARGET_RG" --lb-name "$LB_NAME" -n "$lb_fe_name" \
                --public-ip-address "$PIP_NAME" \
                -o none 2>/dev/null || warn "  Could not attach PIP to LB frontend"
            ok "  PIP $PIP_NAME attached to LB $LB_NAME frontend"
        else
            ok "  LB $LB_NAME frontend has PIP: $lb_fe_pip"
        fi

        # Probe parity check — target probes must match the source (e.g. ping_api)
        if [[ -n "${SOURCE_LB:-}" ]]; then
            src_probes=$(az network lb show -g "$SOURCE_RG" -n "$SOURCE_LB" -o json 2>/dev/null \
                | jq -S '[(.probes // [])[] | {name, protocol, port, requestPath}] | sort_by(.name)' || echo '[]')
            tgt_probes=$(echo "$lb_json" | jq -S '[(.probes // [])[] | {name, protocol, port, requestPath}] | sort_by(.name)')
            if [[ "$src_probes" != "$tgt_probes" ]]; then
                warn "Target LB probes differ from source LB — re-run 01-preflight-and-stage.sh to mirror probes/rules"
            else
                ok "  LB probes match source"
            fi
        fi
    fi

    for vm_name in "${VM_NAMES[@]}"; do
        vm_name="$(echo "$vm_name" | xargs)"
        info "  Wiring network for $vm_name"

        # Find the failed-over VM in the target RG
        vm_json=$(az vm show -g "$TARGET_RG" -n "$vm_name" -o json 2>/dev/null || echo "{}")
        if [[ "$(echo "$vm_json" | jq -r '.id // empty')" == "" ]]; then
            warn "  VM $vm_name not found in $TARGET_RG — it may have a different name post-failover. Check portal."
            continue
        fi

        nic_ids=$(echo "$vm_json" | jq -r '.networkProfile.networkInterfaces[].id')

        for nic_id in $nic_ids; do
            nic_json=$(az network nic show --ids "$nic_id" -o json)
            nic_name=$(echo "$nic_json" | jq -r '.name')

            # 4a. Associate NSG. Target NSG keeps the source NSG's name but usually
            # lives in a shared core RG (RG_CORE_<region>), not the tenant RG.
            if [[ -n "$NSG_NAME" ]]; then
                target_nsg="$NSG_NAME"
            else
                # NSG name from inventory; guarded live fallback (|| true so a missing
                # source NIC/NSG can't abort the run under set -euo pipefail).
                target_nsg=$(jq -r --arg nic "$nic_name" \
                    '.[].nics[]? | select(.nic == $nic) | .nsgOnNic // empty' \
                    "$INVENTORY_FILE" 2>/dev/null | head -n1 || true)
                if [[ -z "$target_nsg" ]]; then
                    target_nsg=$(az network nic show -g "$SOURCE_RG" -n "$nic_name" \
                        --query "networkSecurityGroup.id" -o tsv 2>/dev/null \
                        | awk -F'/' '{print $NF}' || true)
                fi
                [[ -z "$target_nsg" ]] && \
                    warn "  Could not determine source NSG for NIC $nic_name — skipping NSG"
            fi

            if [[ -n "$target_nsg" ]]; then
                # explicit --nsg-rg wins; otherwise search tenant RG then core RG.
                if [[ -n "$NSG_RG" ]]; then
                    nsg_search_rgs=("$NSG_RG")
                else
                    nsg_search_rgs=("$TARGET_RG" "RG_CORE_${TARGET_REGION}")
                fi

                # Target NSG mirrors the source name; search tenant RG then core RG.
                nsg_id=""; nsg_rg_found=""; nsg_name_found=""
                for cand_rg in "${nsg_search_rgs[@]}"; do
                    nsg_id=$(az network nsg show -g "$cand_rg" -n "$target_nsg" \
                        --query "id" -o tsv 2>/dev/null || true)
                    if [[ -n "$nsg_id" ]]; then nsg_rg_found="$cand_rg"; nsg_name_found="$target_nsg"; break; fi
                done

                if [[ -n "$nsg_id" ]]; then
                    # Cross-RG association requires the full NSG ID, not a bare name.
                    az network nic update \
                        --ids "$nic_id" \
                        --network-security-group "$nsg_id" \
                        -o none
                    ok "    NSG $nsg_name_found (in $nsg_rg_found) associated with NIC $nic_name"
                else
                    warn "  NSG $target_nsg not found in ${nsg_search_rgs[*]} — skipping NSG for $nic_name (pass --nsg-name/--nsg-rg)"
                fi
            fi

            # 4b. Per-VM public IP. If the source NIC has a direct PIP, recreate it in the
            # target (same name/SKU/DNS label) and attach it — the LB frontend PIP cannot
            # double as a NIC PIP. Inventory first, live lookup as fallback; property
            # casing differs across az CLI versions.
            primary_ipconfig=$(echo "$nic_json" | jq -r '.ipConfigurations[] | select(.primary == true) | .name')
            if [[ -z "$primary_ipconfig" ]]; then
                primary_ipconfig=$(echo "$nic_json" | jq -r '.ipConfigurations[0].name')
            fi

            src_pip_id=$(jq -r --arg nic "$nic_name" \
                '[.[].nics[]? | select(.nic == $nic) | .ipConfigurations[].publicIpId // empty] | first // empty' \
                "$INVENTORY_FILE" 2>/dev/null || true)
            if [[ -z "$src_pip_id" ]]; then
                src_pip_id=$(az network nic show -g "$SOURCE_RG" -n "$nic_name" -o json 2>/dev/null \
                    | jq -r '[.ipConfigurations[] | (.publicIPAddress // .publicIpAddress) | select(. != null) | .id][0] // empty' || true)
            fi

            if [[ -n "$src_pip_id" ]] && [[ "$src_pip_id" != "None" ]]; then
                src_pip_json=$(az network public-ip show --ids "$src_pip_id" -o json 2>/dev/null || echo '{}')
                vm_pip_name=$(echo "$src_pip_json" | jq -r '.name // empty')
                [[ -z "$vm_pip_name" ]] && vm_pip_name="${vm_name}-pip"
                vm_pip_sku=$(echo "$src_pip_json" | jq -r '.sku.name // "Standard"')
                # Basic PIPs can no longer be created — upgrade to Standard
                [[ "$vm_pip_sku" == "Basic" ]] && vm_pip_sku="Standard"
                vm_dns_label=$(echo "$src_pip_json" | jq -r '.dnsSettings.domainNameLabel // empty')

                if ! az network public-ip show -g "$TARGET_RG" -n "$vm_pip_name" &>/dev/null; then
                    info "    Creating per-VM public IP $vm_pip_name..."
                    pip_args=(-g "$TARGET_RG" -n "$vm_pip_name" -l "$TARGET_REGION"
                              --sku "$vm_pip_sku" --allocation-method Static)
                    [[ -n "$vm_dns_label" ]] && pip_args+=(--dns-name "$vm_dns_label")
                    if ! az network public-ip create "${pip_args[@]}" -o none 2>/dev/null; then
                        warn "  Could not create $vm_pip_name with DNS label '$vm_dns_label' (label taken?) — retrying without label"
                        az network public-ip create -g "$TARGET_RG" -n "$vm_pip_name" \
                            -l "$TARGET_REGION" --sku "$vm_pip_sku" --allocation-method Static -o none
                    fi
                elif [[ -n "$vm_dns_label" ]]; then
                    # PIP pre-staged without a label — set it now
                    az network public-ip update -g "$TARGET_RG" -n "$vm_pip_name" \
                        --dns-name "$vm_dns_label" -o none 2>/dev/null \
                        || warn "  Could not set DNS label '$vm_dns_label' on $vm_pip_name"
                fi

                az network nic ip-config update \
                    --nic-name "$nic_name" \
                    -g "$TARGET_RG" \
                    --name "$primary_ipconfig" \
                    --public-ip-address "$vm_pip_name" \
                    -o none 2>/dev/null || warn "  Could not assign public IP to $nic_name/$primary_ipconfig"

                vm_pip_addr=$(az network public-ip show -g "$TARGET_RG" -n "$vm_pip_name" --query ipAddress -o tsv 2>/dev/null || true)
                vm_pip_fqdn=$(az network public-ip show -g "$TARGET_RG" -n "$vm_pip_name" --query dnsSettings.fqdn -o tsv 2>/dev/null || true)
                ok "    Public IP $vm_pip_name (${vm_pip_addr:-pending}) assigned to $nic_name/$primary_ipconfig"
                if [[ -n "$vm_dns_label" ]]; then
                    ok "    DNS label '$vm_dns_label' — FQDN: ${vm_pip_fqdn:-pending}"
                    warn "  FQDN region suffix changed (${SOURCE_REGION} → ${TARGET_REGION}) — update anything referencing the old cloudapp FQDN"
                fi
                VM_PIP_SUMMARY+=("$vm_name: ${vm_pip_addr:-N/A}  ${vm_pip_fqdn:-(no DNS label)}")
            else
                detail "    Source NIC $nic_name has no direct PIP — skipping PIP assignment (PIP is on LB frontend)"
            fi

            # 4c. Add to LB backend pool
            if [[ -n "$bepool_id" ]]; then
                current_pools=$(echo "$nic_json" | jq -r ".ipConfigurations[] | select(.name == \"$primary_ipconfig\") | .loadBalancerBackendAddressPools[]?.id" 2>/dev/null || true)
                if echo "$current_pools" | grep -q "$bepool_id"; then
                    ok "    NIC $nic_name already in LB backend pool — skipping"
                else
                    az network nic ip-config address-pool add \
                        --nic-name "$nic_name" \
                        -g "$TARGET_RG" \
                        --ip-config-name "$primary_ipconfig" \
                        --lb-name "$LB_NAME" \
                        --address-pool "$LB_BACKEND_POOL" \
                        -o none 2>/dev/null || warn "  Could not add $nic_name to LB backend pool"
                    ok "    Added NIC $nic_name to LB backend pool $LB_BACKEND_POOL"
                fi
            fi
        done

        # 4d. Boot Integrity Monitoring reminder per VM
        detail "  ACTION REQUIRED: Re-enable Boot Integrity Monitoring on $vm_name"
    done

    ok "Post-failover network wiring complete"
else
    info "  Skipping network wiring (--skip-wiring)"
fi

# ──────────── 5. Commit failover ──────────────────────────────
if [[ "$SKIP_COMMIT" == false ]]; then
    info "Committing failover..."

    for vm_name in "${VM_NAMES[@]}"; do
        vm_name="$(echo "$vm_name" | xargs)"
        ITEM_NAME="asr-${vm_name}"

        item_url="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}/replicationFabrics/${SRC_FABRIC}/replicationProtectionContainers/${SRC_CONTAINER}/replicationProtectedItems/${ITEM_NAME}"

        az rest --method post \
            --url "${item_url}/failoverCommit?api-version=${API_VERSION}" \
            -o none

        ok "  $vm_name: failover committed"
    done

    ok "All failovers committed"
else
    warn "Skipping failover commit (--skip-commit). Commit manually when ready:"
    for vm_name in "${VM_NAMES[@]}"; do
        vm_name="$(echo "$vm_name" | xargs)"
        ITEM_NAME="asr-${vm_name}"
        echo "  az rest --method post --url 'https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}/replicationFabrics/${SRC_FABRIC}/replicationProtectionContainers/${SRC_CONTAINER}/replicationProtectedItems/${ITEM_NAME}/failoverCommit?api-version=${API_VERSION}' -o none"
    done
fi

# ──────────── Done ──────────────────────────────────────────────
echo ""
info "== Planned failover complete. =="
echo ""
info "Post-failover checklist:"
echo "  1. Verify LB probes are healthy:"
echo "     az network lb show -g $TARGET_RG -n $LB_NAME --query 'backendAddressPools[0].loadBalancerBackendAddresses'"
echo "  2. Cut DNS to new LB public IP: ${pip_address:-N/A}${pip_fqdn:+  ($pip_fqdn)}"
if [[ ${#VM_PIP_SUMMARY[@]} -gt 0 ]]; then
    echo "     Per-VM public IPs / FQDNs (region suffix changed — repoint cloudapp FQDN references):"
    for _line in "${VM_PIP_SUMMARY[@]}"; do
        echo "       $_line"
    done
fi
echo "  3. Re-enable Boot Integrity Monitoring on ALL VMs:"
echo "     Azure portal > VM > Security > Enable integrity monitoring"
echo "  4. Validate end-to-end with real traffic"
echo "  5. Monitor for 24-72h soak period"
echo ""
info "Next step (after soak):"
info "  Run 05-decommission.sh to disable replication and clean up source resources."
info ""
info "  Example:"
echo "    ./05-decommission.sh \\"
echo "      --source-rg \"$SOURCE_RG\" --source-region \"$SOURCE_REGION\" \\"
echo "      --target-rg \"$TARGET_RG\" --vault-name \"$VAULT_NAME\" \\"
echo "      --vm-names \"$VM_NAMES_CSV\""
