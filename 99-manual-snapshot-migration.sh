#!/usr/bin/env bash
#
# 99-manual-snapshot-migration.sh
# FALLBACK PATH — End-to-end manual snapshot-based migration for Trusted Launch v7 VMs.
#
# This is the fallback path when ASR replication is blocked, e.g.:
#   - Linux Trusted Launch VMs created BEFORE 2024-04-01 (ASR does not support these)
#   - ASR is unavailable or not eligible for specific VMs
#   - A maintenance window is acceptable (snapshot + copy + rebuild)
#   - You need full control over the rebuild
#
# For the primary ASR-based migration path, use scripts 01 through 05.
#
# This script implements Phases 0-7 from the migration runbook:
#   Phase 0: Capture source inventory
#   Phase 1: Reproduce network fabric in target
#   Phase 2: Pre-cutover prep (encryption/key escrow)
#   Phase 3: Stop VM + snapshot all disks (DOWNTIME STARTS)
#   Phase 4: Copy snapshots to target region
#   Phase 5: Create target disks with Trusted Launch security profile
#   Phase 6: Build target VM from disks
#   Phase 7: Validate + cut over
#
# Requires: az cli, jq
# NOTE: Phase 5 (Trusted Launch disk creation) requires Az PowerShell — see inline note.
#       This is a documented Azure limitation: az cli does not expose Set-AzDiskSecurityProfile.
#       A PowerShell snippet is embedded for that step.
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

End-to-end manual snapshot migration for Trusted Launch VMs.

Required:
  --source-rg NAME              Source resource group
  --source-region REGION        Source region (e.g. eastus)
  --target-rg NAME              Target resource group
  --target-region REGION        Target region (e.g. centralus)
  --vm-name NAME                VM name to migrate

Optional:
  --target-vnet NAME            Target VNet name            (default: vnet-prod)
  --target-vnet-cidr CIDR       Target VNet address space   (default: 10.0.0.0/16)
  --target-subnet NAME          Target subnet name          (default: snet-app)
  --target-subnet-cidr CIDR     Target subnet prefix        (default: 10.0.1.0/24)
  --os-type linux|windows       OS type                     (default: linux)
  --disk-controller-type TYPE   NVMe or SCSI                (default: auto-detect)
  --skip-network                Skip network fabric creation (already staged)
  --skip-snapshot               Skip snapshot creation (already done)
  --skip-copy                   Skip snapshot copy (already copied)
  --dry-run                     Print commands without executing
  -h, --help                    Show this help

Example:
  $(basename "$0") \\
    --source-rg rg-prod-eastus --source-region eastus \\
    --target-rg rg-prod-centralus --target-region centralus \\
    --vm-name vm-app01 --os-type linux
EOF
    exit 0
}

# ──────────────────────────── Parse args ────────────────────────
SOURCE_RG=""
SOURCE_REGION=""
TARGET_RG=""
TARGET_REGION=""
VM_NAME=""
TARGET_VNET="vnet-prod"
TARGET_VNET_CIDR="10.0.0.0/16"
TARGET_SUBNET="snet-app"
TARGET_SUBNET_CIDR="10.0.1.0/24"
OS_TYPE="linux"
DISK_CONTROLLER=""
SKIP_NETWORK=false
SKIP_SNAPSHOT=false
SKIP_COPY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-rg)            SOURCE_RG="$2";             shift 2;;
        --source-region)        SOURCE_REGION="$2";         shift 2;;
        --target-rg)            TARGET_RG="$2";             shift 2;;
        --target-region)        TARGET_REGION="$2";         shift 2;;
        --vm-name)              VM_NAME="$2";               shift 2;;
        --target-vnet)          TARGET_VNET="$2";           shift 2;;
        --target-vnet-cidr)     TARGET_VNET_CIDR="$2";      shift 2;;
        --target-subnet)        TARGET_SUBNET="$2";         shift 2;;
        --target-subnet-cidr)   TARGET_SUBNET_CIDR="$2";    shift 2;;
        --os-type)              OS_TYPE="$2";               shift 2;;
        --disk-controller-type) DISK_CONTROLLER="$2";       shift 2;;
        --skip-network)         SKIP_NETWORK=true;          shift;;
        --skip-snapshot)        SKIP_SNAPSHOT=true;          shift;;
        --skip-copy)            SKIP_COPY=true;             shift;;
        --dry-run)              DRY_RUN=true;               shift;;
        -h|--help)              usage;;
        *) err "Unknown argument: $1";;
    esac
done

[[ -z "$SOURCE_RG" ]]     && err "--source-rg is required"
[[ -z "$SOURCE_REGION" ]] && err "--source-region is required"
[[ -z "$TARGET_RG" ]]     && err "--target-rg is required"
[[ -z "$TARGET_REGION" ]] && err "--target-region is required"
[[ -z "$VM_NAME" ]]       && err "--vm-name is required"

run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}[DRY RUN] $*${NC}"
    else
        "$@"
    fi
}

# ═══════════════════════════════════════════════════════════════
# PHASE 0 — Capture everything (source region, source live)
# ═══════════════════════════════════════════════════════════════
info "== PHASE 0: Capture source VM inventory =="

VM_JSON=$(az vm show -g "$SOURCE_RG" -n "$VM_NAME" -o json)

VM_SIZE=$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize')
SECURITY_TYPE=$(echo "$VM_JSON" | jq -r '.securityProfile.securityType // "Standard"')
SECURE_BOOT=$(echo "$VM_JSON" | jq -r '.securityProfile.uefiSettings.secureBootEnabled // false')
VTPM=$(echo "$VM_JSON" | jq -r '.securityProfile.uefiSettings.vTpmEnabled // false')
DETECTED_CONTROLLER=$(echo "$VM_JSON" | jq -r '.storageProfile.diskControllerType // "SCSI"')
OS_DISK_NAME=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.name')
OS_DISK_SKU=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.storageAccountType')

# Use detected controller unless overridden
[[ -z "$DISK_CONTROLLER" ]] && DISK_CONTROLLER="$DETECTED_CONTROLLER"

# Data disks
DATA_DISK_JSON=$(echo "$VM_JSON" | jq '[.storageProfile.dataDisks[] | {name: .name, lun: .lun, id: .managedDisk.id, sku: .managedDisk.storageAccountType}]')
DATA_DISK_COUNT=$(echo "$DATA_DISK_JSON" | jq 'length')

# NIC info (for rebuild)
NIC_IDS=$(echo "$VM_JSON" | jq -r '.networkProfile.networkInterfaces[].id')
FIRST_NIC_JSON=$(az network nic show --ids "$(echo "$NIC_IDS" | head -1)" -o json)
SOURCE_PRIVATE_IP=$(echo "$FIRST_NIC_JSON" | jq -r '.ipConfigurations[0].privateIpAddress')
SOURCE_NSG=$(echo "$FIRST_NIC_JSON" | jq -r '.networkSecurityGroup.id // empty' | awk -F'/' '{print $NF}')

detail "VM: $VM_NAME"
detail "  Size:           $VM_SIZE"
detail "  Security:       $SECURITY_TYPE"
detail "  Secure Boot:    $SECURE_BOOT"
detail "  vTPM:           $VTPM"
detail "  Disk Controller: $DISK_CONTROLLER"
detail "  OS Disk:        $OS_DISK_NAME ($OS_DISK_SKU)"
detail "  Data Disks:     $DATA_DISK_COUNT"
detail "  Private IP:     $SOURCE_PRIVATE_IP"

if [[ "$SECURITY_TYPE" != "TrustedLaunch" ]]; then
    warn "VM is not TrustedLaunch ($SECURITY_TYPE). Trusted Launch-specific steps may not apply."
fi

# Blocker check: verify target region has the VM size
info "Checking target region SKU availability..."
if az vm list-skus -l "$TARGET_REGION" --size "$VM_SIZE" --query "[?name=='$VM_SIZE'].name" -o tsv | grep -q "$VM_SIZE"; then
    ok "  $VM_SIZE is available in $TARGET_REGION"
else
    err "$VM_SIZE is NOT available in $TARGET_REGION. Choose a different target region or VM size."
fi

# Save full VM JSON for reference
echo "$VM_JSON" | jq '.' > "./vm-${VM_NAME}-source.json"
ok "Source VM config saved to ./vm-${VM_NAME}-source.json"

# ═══════════════════════════════════════════════════════════════
# PHASE 1 — Reproduce the network fabric in the target
# ═══════════════════════════════════════════════════════════════
if [[ "$SKIP_NETWORK" == false ]]; then
    info "== PHASE 1: Reproduce network fabric in target =="

    # Resource group
    if ! az group show -n "$TARGET_RG" &>/dev/null; then
        run az group create -n "$TARGET_RG" -l "$TARGET_REGION" -o none
        ok "Created target RG $TARGET_RG"
    fi

    # VNet + subnet (same CIDR to preserve private IPs)
    if ! az network vnet show -g "$TARGET_RG" -n "$TARGET_VNET" &>/dev/null; then
        run az network vnet create \
            -g "$TARGET_RG" -n "$TARGET_VNET" -l "$TARGET_REGION" \
            --address-prefix "$TARGET_VNET_CIDR" \
            --subnet-name "$TARGET_SUBNET" --subnet-prefix "$TARGET_SUBNET_CIDR" \
            -o none
        ok "Created VNet $TARGET_VNET ($TARGET_VNET_CIDR)"
    fi

    # NSG — replicate source rules
    if [[ -n "$SOURCE_NSG" ]]; then
        TARGET_NSG="${SOURCE_NSG}-target"
        if ! az network nsg show -g "$TARGET_RG" -n "$TARGET_NSG" &>/dev/null; then
            run az network nsg create -g "$TARGET_RG" -n "$TARGET_NSG" -l "$TARGET_REGION" -o none

            rules_json=$(az network nsg rule list -g "$SOURCE_RG" --nsg-name "$SOURCE_NSG" -o json)
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

                cmd=(az network nsg rule create
                    -g "$TARGET_RG" --nsg-name "$TARGET_NSG"
                    -n "$r_name" --priority "$r_priority"
                    --access "$r_access" --protocol "$r_protocol" --direction "$r_direction"
                    --source-address-prefixes $r_src_addr
                    --source-port-ranges $r_src_port
                    --destination-address-prefixes $r_dst_addr
                    --destination-port-ranges $r_dst_port
                    -o none)

                [[ -n "$r_desc" ]] && cmd+=(--description "$r_desc")
                run "${cmd[@]}"
            done
            ok "Created NSG $TARGET_NSG with $rule_count rules"
        fi

        run az network vnet subnet update \
            -g "$TARGET_RG" --vnet-name "$TARGET_VNET" -n "$TARGET_SUBNET" \
            --network-security-group "$TARGET_NSG" -o none
    else
        TARGET_NSG=""
        warn "No source NSG detected on NIC — skipping NSG replication"
    fi

    # Public IP (new address — source PIP cannot move cross-region)
    PIP_NAME="pip-${VM_NAME}"
    if ! az network public-ip show -g "$TARGET_RG" -n "$PIP_NAME" &>/dev/null; then
        run az network public-ip create \
            -g "$TARGET_RG" -n "$PIP_NAME" -l "$TARGET_REGION" \
            --sku Standard --allocation-method Static -o none
        ok "Created public IP $PIP_NAME (NEW address — update DNS at cutover)"
    fi

    # Load Balancer
    LB_NAME="lb-${VM_NAME}"
    if ! az network lb show -g "$TARGET_RG" -n "$LB_NAME" &>/dev/null; then
        run az network lb create \
            -g "$TARGET_RG" -n "$LB_NAME" -l "$TARGET_REGION" \
            --sku Standard --public-ip-address "$PIP_NAME" \
            --frontend-ip-name "fe" --backend-pool-name "bepool" -o none

        run az network lb probe create \
            -g "$TARGET_RG" --lb-name "$LB_NAME" \
            -n "tcp-probe" --protocol Tcp --port 80 \
            --interval 5 --threshold 2 -o none

        run az network lb rule create \
            -g "$TARGET_RG" --lb-name "$LB_NAME" \
            -n "rule-80" --protocol Tcp \
            --frontend-port 80 --backend-port 80 \
            --frontend-ip-name "fe" --backend-pool-name "bepool" \
            --probe-name "tcp-probe" -o none

        ok "Created Load Balancer $LB_NAME"
    fi
else
    info "== PHASE 1: SKIPPED (--skip-network) =="
    TARGET_NSG="${SOURCE_NSG}-target"
    PIP_NAME="pip-${VM_NAME}"
    LB_NAME="lb-${VM_NAME}"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 2 — Pre-cutover prep
# ═══════════════════════════════════════════════════════════════
info "== PHASE 2: Pre-cutover prep =="
warn "MANUAL CHECKS REQUIRED before proceeding:"
echo ""
echo "  1. If BitLocker (Windows) or DM-Crypt with vTPM sealing is in use:"
echo "     -> Escrow recovery keys to Key Vault or AD NOW."
echo "     -> The target VM gets a NEW vTPM; old vTPM-sealed secrets will NOT unseal."
echo ""
echo "  2. If CMK / Disk Encryption Set is in use:"
echo "     -> Create Key Vault + DES in the TARGET region before proceeding."
echo "     -> Neither moves cross-region."
echo ""
echo "     Example:"
echo "       az keyvault create -g $TARGET_RG -n kv-tgt-\$RANDOM -l $TARGET_REGION --enable-purge-protection true"
echo "       az disk-encryption-set create -g $TARGET_RG -n des-tgt -l $TARGET_REGION --source-vault <kv> --key-url <key-url>"
echo ""

read -rp "Press ENTER when pre-cutover checks are complete (or Ctrl+C to abort)..."

# ═══════════════════════════════════════════════════════════════
# PHASE 3 — Stop VM and snapshot all disks (DOWNTIME STARTS)
# ═══════════════════════════════════════════════════════════════
if [[ "$SKIP_SNAPSHOT" == false ]]; then
    info "== PHASE 3: Deallocate VM + snapshot all disks =="
    warn ">>> DOWNTIME STARTS NOW <<<"
    echo ""

    run az vm deallocate -g "$SOURCE_RG" -n "$VM_NAME"
    ok "VM $VM_NAME deallocated"

    # Snapshot OS disk
    OS_DISK_ID=$(az disk show -g "$SOURCE_RG" -n "$OS_DISK_NAME" --query "id" -o tsv)
    SNAP_OS="snap-${VM_NAME}-os"

    run az snapshot create \
        -g "$SOURCE_RG" -n "$SNAP_OS" -l "$SOURCE_REGION" \
        --source "$OS_DISK_ID" --incremental true -o none
    ok "Created OS disk snapshot: $SNAP_OS"

    # Snapshot each data disk
    SNAP_DATA_NAMES=()
    for i in $(seq 0 $((DATA_DISK_COUNT - 1))); do
        dd_name=$(echo "$DATA_DISK_JSON" | jq -r ".[$i].name")
        dd_id=$(echo "$DATA_DISK_JSON" | jq -r ".[$i].id")
        snap_name="snap-${VM_NAME}-data-${i}"

        run az snapshot create \
            -g "$SOURCE_RG" -n "$snap_name" -l "$SOURCE_REGION" \
            --source "$dd_id" --incremental true -o none
        ok "Created data disk snapshot: $snap_name (disk: $dd_name, lun: $i)"
        SNAP_DATA_NAMES+=("$snap_name")
    done

    warn "BLOCKER CHECK: If the OS disk snapshot fails later with 'vTPM state is locked / VMGS corrupt',"
    warn "you must boot the source VM, clear the vTPM lock, then re-snapshot."
else
    info "== PHASE 3: SKIPPED (--skip-snapshot) =="
    SNAP_OS="snap-${VM_NAME}-os"
    SNAP_DATA_NAMES=()
    for i in $(seq 0 $((DATA_DISK_COUNT - 1))); do
        SNAP_DATA_NAMES+=("snap-${VM_NAME}-data-${i}")
    done
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 4 — Copy snapshots to the target region
# ═══════════════════════════════════════════════════════════════
if [[ "$SKIP_COPY" == false ]]; then
    info "== PHASE 4: Copy snapshots to target region =="

    SNAP_OS_SRC_ID=$(az snapshot show -g "$SOURCE_RG" -n "$SNAP_OS" --query "id" -o tsv)
    SNAP_OS_TGT="snap-${VM_NAME}-os-tgt"

    run az snapshot create \
        -g "$TARGET_RG" -n "$SNAP_OS_TGT" -l "$TARGET_REGION" \
        --source "$SNAP_OS_SRC_ID" \
        --incremental true --copy-start -o none
    ok "Started cross-region copy of OS snapshot -> $SNAP_OS_TGT"

    SNAP_DATA_TGT_NAMES=()
    for i in "${!SNAP_DATA_NAMES[@]}"; do
        src_snap="${SNAP_DATA_NAMES[$i]}"
        tgt_snap="snap-${VM_NAME}-data-${i}-tgt"
        src_id=$(az snapshot show -g "$SOURCE_RG" -n "$src_snap" --query "id" -o tsv)

        run az snapshot create \
            -g "$TARGET_RG" -n "$tgt_snap" -l "$TARGET_REGION" \
            --source "$src_id" \
            --incremental true --copy-start -o none
        ok "Started cross-region copy of data snapshot -> $tgt_snap"
        SNAP_DATA_TGT_NAMES+=("$tgt_snap")
    done

    # Wait for all copies to complete
    info "Waiting for snapshot copies to complete..."
    all_snaps=("$SNAP_OS_TGT" "${SNAP_DATA_TGT_NAMES[@]}")
    for snap in "${all_snaps[@]}"; do
        while true; do
            pct=$(az snapshot show -g "$TARGET_RG" -n "$snap" --query "completionPercent" -o tsv 2>/dev/null || echo "0")
            if [[ "$pct" == "100" ]] || [[ "$pct" == "100.0" ]]; then
                ok "  $snap: copy complete"
                break
            fi
            echo "  $snap: ${pct}% — waiting 30s..."
            sleep 30
        done
    done
    ok "All snapshot copies complete"
else
    info "== PHASE 4: SKIPPED (--skip-copy) =="
    SNAP_OS_TGT="snap-${VM_NAME}-os-tgt"
    SNAP_DATA_TGT_NAMES=()
    for i in $(seq 0 $((DATA_DISK_COUNT - 1))); do
        SNAP_DATA_TGT_NAMES+=("snap-${VM_NAME}-data-${i}-tgt")
    done
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 5 — Create target disks with Trusted Launch security profile
# ═══════════════════════════════════════════════════════════════
info "== PHASE 5: Create target disks =="

OS_DISK_TGT="osdisk-${VM_NAME}-tgt"
SNAP_OS_TGT_ID=$(az snapshot show -g "$TARGET_RG" -n "$SNAP_OS_TGT" --query "id" -o tsv)

if [[ "$SECURITY_TYPE" == "TrustedLaunch" ]]; then
    warn "Trusted Launch OS disk requires Az PowerShell for Set-AzDiskSecurityProfile."
    warn "The az cli does not expose this flag. Running embedded PowerShell snippet."
    echo ""

    # Use PowerShell for the Trusted Launch disk — this is the documented workaround.
    # az cli's 'az disk create' does not have a --security-type flag for managed disks.
    if command -v pwsh &>/dev/null; then
        run pwsh -NoProfile -Command "
            \$snap = Get-AzSnapshot -ResourceGroupName '$TARGET_RG' -SnapshotName '$SNAP_OS_TGT'
            \$cfg  = New-AzDiskConfig -Location '$TARGET_REGION' -CreateOption Copy \`
                      -SourceResourceId \$snap.Id -HyperVGeneration V2 -OsType ${OS_TYPE^} \`
                      -SkuName '$OS_DISK_SKU'
            \$cfg  = Set-AzDiskSecurityProfile -Disk \$cfg -SecurityType 'TrustedLaunch'
            New-AzDisk -ResourceGroupName '$TARGET_RG' -DiskName '$OS_DISK_TGT' -Disk \$cfg
        "
        ok "Created Trusted Launch OS disk: $OS_DISK_TGT"
    else
        err "pwsh (PowerShell) is required for Trusted Launch disk creation but not found.
Install it: https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell

Alternatively, run this manually in PowerShell:

  \$snap = Get-AzSnapshot -ResourceGroupName '$TARGET_RG' -SnapshotName '$SNAP_OS_TGT'
  \$cfg  = New-AzDiskConfig -Location '$TARGET_REGION' -CreateOption Copy \`
            -SourceResourceId \$snap.Id -HyperVGeneration V2 -OsType ${OS_TYPE^} \`
            -SkuName '$OS_DISK_SKU'
  \$cfg  = Set-AzDiskSecurityProfile -Disk \$cfg -SecurityType 'TrustedLaunch'
  New-AzDisk -ResourceGroupName '$TARGET_RG' -DiskName '$OS_DISK_TGT' -Disk \$cfg

Then re-run this script with --skip-network --skip-snapshot --skip-copy."
    fi
else
    # Non-Trusted Launch: standard az cli disk create works
    run az disk create \
        -g "$TARGET_RG" -n "$OS_DISK_TGT" -l "$TARGET_REGION" \
        --source "$SNAP_OS_TGT_ID" \
        --sku "$OS_DISK_SKU" \
        --hyper-v-generation V2 \
        --os-type "$OS_TYPE" \
        -o none
    ok "Created OS disk: $OS_DISK_TGT"
fi

# Data disks (no security profile needed — plain copy)
DATA_DISK_TGT_NAMES=()
for i in "${!SNAP_DATA_TGT_NAMES[@]}"; do
    tgt_snap="${SNAP_DATA_TGT_NAMES[$i]}"
    dd_name="datadisk-${VM_NAME}-${i}-tgt"
    dd_sku=$(echo "$DATA_DISK_JSON" | jq -r ".[$i].sku")
    snap_id=$(az snapshot show -g "$TARGET_RG" -n "$tgt_snap" --query "id" -o tsv)

    run az disk create \
        -g "$TARGET_RG" -n "$dd_name" -l "$TARGET_REGION" \
        --source "$snap_id" \
        --sku "$dd_sku" \
        -o none
    ok "Created data disk: $dd_name (lun: $i)"
    DATA_DISK_TGT_NAMES+=("$dd_name")
done

# ═══════════════════════════════════════════════════════════════
# PHASE 6 — Build the target VM from the disks
# ═══════════════════════════════════════════════════════════════
info "== PHASE 6: Build target VM =="

# Create NIC (binds VM to reproduced VNet/LB)
NIC_NAME="nic-${VM_NAME}-tgt"
nic_create_cmd=(az network nic create
    -g "$TARGET_RG" -n "$NIC_NAME" -l "$TARGET_REGION"
    --vnet-name "$TARGET_VNET" --subnet "$TARGET_SUBNET"
    --private-ip-address "$SOURCE_PRIVATE_IP"
    -o none)

[[ -n "$TARGET_NSG" ]] && nic_create_cmd+=(--network-security-group "$TARGET_NSG")

run "${nic_create_cmd[@]}"
ok "Created NIC $NIC_NAME (private IP: $SOURCE_PRIVATE_IP)"

# Add NIC to LB backend pool
run az network nic ip-config address-pool add \
    --nic-name "$NIC_NAME" -g "$TARGET_RG" \
    --ip-config-name "ipconfig1" \
    --lb-name "$LB_NAME" --address-pool "bepool" \
    -o none 2>/dev/null || warn "Could not add NIC to LB backend pool — do this manually if needed."

# Create the VM
vm_create_cmd=(az vm create
    -g "$TARGET_RG" -n "$VM_NAME" -l "$TARGET_REGION"
    --attach-os-disk "$OS_DISK_TGT"
    --os-type "$OS_TYPE"
    --size "$VM_SIZE"
    --nics "$NIC_NAME"
    -o none)

if [[ "$SECURITY_TYPE" == "TrustedLaunch" ]]; then
    vm_create_cmd+=(--security-type TrustedLaunch)
    [[ "$SECURE_BOOT" == "true" ]] && vm_create_cmd+=(--enable-secure-boot true)
    [[ "$VTPM" == "true" ]] && vm_create_cmd+=(--enable-vtpm true)
fi

# Only pass disk controller if not SCSI (SCSI is default)
if [[ "$DISK_CONTROLLER" == "NVMe" ]]; then
    vm_create_cmd+=(--disk-controller-type NVMe)
fi

run "${vm_create_cmd[@]}"
ok "Created VM $VM_NAME in $TARGET_REGION"

# Attach data disks at their original LUNs
for i in "${!DATA_DISK_TGT_NAMES[@]}"; do
    dd_name="${DATA_DISK_TGT_NAMES[$i]}"
    run az vm disk attach \
        -g "$TARGET_RG" --vm-name "$VM_NAME" \
        --name "$dd_name" --lun "$i" \
        -o none
    ok "Attached data disk $dd_name at LUN $i"
done

# ═══════════════════════════════════════════════════════════════
# PHASE 7 — Validate + cut over
# ═══════════════════════════════════════════════════════════════
info "== PHASE 7: Validate + cut over =="
echo ""

# Verify security profile
if [[ "$SECURITY_TYPE" == "TrustedLaunch" ]]; then
    info "Verifying Trusted Launch security profile..."
    az vm show -g "$TARGET_RG" -n "$VM_NAME" \
        --query "{securityType:securityProfile.securityType, secureBoot:securityProfile.uefiSettings.secureBootEnabled, vTPM:securityProfile.uefiSettings.vTpmEnabled}" \
        -o jsonc
fi

# Get new public IP
NEW_PIP=$(az network public-ip show -g "$TARGET_RG" -n "$PIP_NAME" --query "ipAddress" -o tsv 2>/dev/null || echo "N/A")

echo ""
ok "=== Migration complete ==="
echo ""
info "Post-migration checklist:"
echo "  1. Verify VM boots and application is healthy"
echo "  2. Re-enable Boot Integrity Monitoring (not carried in disk copies)"
echo "     -> Azure portal: VM > Security > Enable integrity monitoring"
echo "  3. Confirm NIC is in LB backend pool and probes are healthy:"
echo "     az network lb show -g $TARGET_RG -n $LB_NAME --query 'backendAddressPools[0].loadBalancerBackendAddresses'"
echo "  4. Validate app end-to-end against new public IP: $NEW_PIP"
echo "  5. Cut DNS / Traffic Manager to new public IP (should have dropped TTL ahead of time)"
echo "  6. Soak, then delete source resources after sign-off"
echo ""
warn "REMINDER: The vTPM is NEW. If BitLocker/vTPM-sealed secrets were in use, apply escrowed recovery keys."
warn "REMINDER: Public IP address has changed. Update all DNS records and hardcoded references."
