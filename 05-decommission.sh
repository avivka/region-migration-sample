#!/usr/bin/env bash
#
# 05-decommission.sh
# Cross-region ASR migration — Phase 6: Decommission source resources.
#
# Disables replication, removes protected items, and optionally deletes
# source VMs, disks, and snapshots. Run this AFTER the soak period and
# customer sign-off.
#
# Prerequisite: Run 04-planned-failover.sh first (failover must be committed).
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

Decommission source resources after successful ASR migration.

Required:
  --source-rg NAME              Source resource group
  --source-region REGION        Source region (e.g. eastus)
  --target-rg NAME              Target resource group
  --vault-name NAME             Recovery Services vault name
  --vm-names VM1,VM2,...        Comma-separated list of VM names

Optional:
  --delete-source-vms           Delete source VMs and their disks (requires confirmation)
  --delete-source-snapshots     Delete source-region snapshots
  --delete-cache-storage        Delete ASR cache storage account
  --force                       Skip confirmation prompts (use with caution)
  -h, --help                    Show this help

Example:
  $(basename "$0") \\
    --source-rg rg-prod-eastus --source-region eastus \\
    --target-rg rg-prod-centralus \\
    --vault-name vault-asr-centralus \\
    --vm-names "vm-app01,vm-app02" \\
    --delete-source-vms --delete-source-snapshots
EOF
    exit 0
}

# ──────────────────────────── Parse args ────────────────────────
SOURCE_RG=""
SOURCE_REGION=""
TARGET_RG=""
VAULT_NAME=""
VM_NAMES_CSV=""
DELETE_SOURCE_VMS=false
DELETE_SOURCE_SNAPSHOTS=false
DELETE_CACHE_STORAGE=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-rg)              SOURCE_RG="$2";          shift 2;;
        --source-region)          SOURCE_REGION="$2";      shift 2;;
        --target-rg)              TARGET_RG="$2";          shift 2;;
        --vault-name)             VAULT_NAME="$2";         shift 2;;
        --vm-names)               VM_NAMES_CSV="$2";       shift 2;;
        --delete-source-vms)      DELETE_SOURCE_VMS=true;   shift;;
        --delete-source-snapshots) DELETE_SOURCE_SNAPSHOTS=true; shift;;
        --delete-cache-storage)   DELETE_CACHE_STORAGE=true; shift;;
        --force)                  FORCE=true;              shift;;
        -h|--help)                usage;;
        *) err "Unknown argument: $1";;
    esac
done

[[ -z "$SOURCE_RG" ]]     && err "--source-rg is required"
[[ -z "$SOURCE_REGION" ]] && err "--source-region is required"
[[ -z "$TARGET_RG" ]]     && err "--target-rg is required"
[[ -z "$VAULT_NAME" ]]    && err "--vault-name is required"
[[ -z "$VM_NAMES_CSV" ]]  && err "--vm-names is required"

IFS=',' read -ra VM_NAMES <<< "$VM_NAMES_CSV"

SRC_FABRIC="fabric-${SOURCE_REGION}"
SRC_CONTAINER="container-${SOURCE_REGION}"

confirm_action() {
    local msg="$1"
    if [[ "$FORCE" == true ]]; then
        return 0
    fi
    read -rp "$msg [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

info "== Phase 6: Decommission =="

# ──────────── 1. Disable replication / remove protected items ─
info "Removing ASR protected items (disabling replication)..."

for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"
    ITEM_NAME="asr-${vm_name}"

    if az site-recovery protected-item show \
        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --fabric-name "$SRC_FABRIC" --protection-container "$SRC_CONTAINER" \
        -n "$ITEM_NAME" &>/dev/null; then

        info "  Removing replication for $vm_name..."

        az site-recovery protected-item remove \
            --fabric-name "$SRC_FABRIC" \
            --protection-container "$SRC_CONTAINER" \
            -n "$ITEM_NAME" \
            -g "$TARGET_RG" \
            --vault-name "$VAULT_NAME" \
            --no-wait false 2>/dev/null || \
        az site-recovery protected-item delete \
            --fabric-name "$SRC_FABRIC" \
            --protection-container "$SRC_CONTAINER" \
            -n "$ITEM_NAME" \
            -g "$TARGET_RG" \
            --vault-name "$VAULT_NAME" \
            --no-wait false 2>/dev/null || \
        warn "  Could not remove protected item $ITEM_NAME — may need manual cleanup in portal"

        ok "  $vm_name: replication disabled"
    else
        ok "  $vm_name: no protected item found (already removed)"
    fi
done

# ──────────── 2. Delete source VMs + disks ────────────────────
if [[ "$DELETE_SOURCE_VMS" == true ]]; then
    echo ""
    warn "=== SOURCE VM DELETION ==="
    echo ""
    echo "  The following VMs in $SOURCE_RG will be PERMANENTLY DELETED:"
    for vm_name in "${VM_NAMES[@]}"; do
        echo "    - $(echo "$vm_name" | xargs)"
    done
    echo ""

    if confirm_action "Proceed with source VM deletion?"; then
        for vm_name in "${VM_NAMES[@]}"; do
            vm_name="$(echo "$vm_name" | xargs)"
            info "  Deleting source VM: $vm_name"

            # Capture disk IDs before deleting the VM
            vm_json=$(az vm show -g "$SOURCE_RG" -n "$vm_name" -o json 2>/dev/null || echo "{}")
            if [[ "$(echo "$vm_json" | jq -r '.id // empty')" == "" ]]; then
                warn "  VM $vm_name not found in $SOURCE_RG — skipping"
                continue
            fi

            os_disk_id=$(echo "$vm_json" | jq -r '.storageProfile.osDisk.managedDisk.id // empty')
            data_disk_ids=$(echo "$vm_json" | jq -r '.storageProfile.dataDisks[].managedDisk.id // empty')
            nic_ids=$(echo "$vm_json" | jq -r '.networkProfile.networkInterfaces[].id')

            # Delete the VM (does not delete disks/NICs by default)
            az vm delete -g "$SOURCE_RG" -n "$vm_name" --yes -o none
            ok "    VM $vm_name deleted"

            # Delete OS disk
            if [[ -n "$os_disk_id" ]]; then
                az disk delete --ids "$os_disk_id" --yes -o none 2>/dev/null || true
                ok "    OS disk deleted"
            fi

            # Delete data disks
            for disk_id in $data_disk_ids; do
                az disk delete --ids "$disk_id" --yes -o none 2>/dev/null || true
                ok "    Data disk deleted: $(echo "$disk_id" | awk -F'/' '{print $NF}')"
            done

            # Delete NICs
            for nic_id in $nic_ids; do
                az network nic delete --ids "$nic_id" -o none 2>/dev/null || true
                ok "    NIC deleted: $(echo "$nic_id" | awk -F'/' '{print $NF}')"
            done
        done
    else
        info "  Skipping source VM deletion"
    fi
else
    info "Skipping source VM deletion (pass --delete-source-vms to delete)"
fi

# ──────────── 3. Delete source snapshots ──────────────────────
if [[ "$DELETE_SOURCE_SNAPSHOTS" == true ]]; then
    info "Deleting source-region snapshots..."

    snapshots=$(az snapshot list -g "$SOURCE_RG" --query "[].name" -o tsv 2>/dev/null || true)
    if [[ -n "$snapshots" ]]; then
        snap_count=$(echo "$snapshots" | wc -l | xargs)
        echo "  Found $snap_count snapshot(s) in $SOURCE_RG"

        if confirm_action "Delete all $snap_count snapshots in $SOURCE_RG?"; then
            for snap_name in $snapshots; do
                az snapshot delete -g "$SOURCE_RG" -n "$snap_name" -o none 2>/dev/null || true
                ok "    Deleted snapshot: $snap_name"
            done
        else
            info "  Skipping snapshot deletion"
        fi
    else
        ok "  No snapshots found in $SOURCE_RG"
    fi
else
    info "Skipping source snapshot deletion (pass --delete-source-snapshots to delete)"
fi

# ──────────── 4. Delete cache storage account ─────────────────
if [[ "$DELETE_CACHE_STORAGE" == true ]]; then
    info "Looking for ASR cache storage accounts in $SOURCE_RG..."

    SUB_ID=$(az account show --query "id" -o tsv)
    cache_name="asrcache${SOURCE_REGION}$(echo "$SUB_ID" | cut -c1-8)"
    cache_name=$(echo "$cache_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]' | cut -c1-24)

    if az storage account show -g "$SOURCE_RG" -n "$cache_name" &>/dev/null; then
        if confirm_action "Delete cache storage account $cache_name?"; then
            az storage account delete -g "$SOURCE_RG" -n "$cache_name" --yes -o none
            ok "  Deleted cache storage account: $cache_name"
        fi
    else
        ok "  Cache storage account $cache_name not found (may already be deleted or named differently)"
    fi
else
    info "Skipping cache storage deletion (pass --delete-cache-storage to delete)"
fi

# ──────────── Done ──────────────────────────────────────────────
echo ""
info "== Decommission complete. =="
echo ""
info "Summary of actions taken:"
echo "  - ASR replication disabled for ${#VM_NAMES[@]} VM(s)"
if [[ "$DELETE_SOURCE_VMS" == true ]]; then
    echo "  - Source VMs + disks + NICs deleted"
fi
if [[ "$DELETE_SOURCE_SNAPSHOTS" == true ]]; then
    echo "  - Source snapshots deleted"
fi
if [[ "$DELETE_CACHE_STORAGE" == true ]]; then
    echo "  - Cache storage account deleted"
fi
echo ""
info "Remaining manual cleanup (if needed):"
echo "  - Delete source VNet/subnets (keep until DNS fully propagated)"
echo "  - Delete source NSGs"
echo "  - Delete or repurpose the Recovery Services vault"
echo "  - Remove any Azure Automation runbooks created for the migration"
