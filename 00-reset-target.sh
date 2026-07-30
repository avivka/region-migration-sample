#!/usr/bin/env bash
#
# 00-reset-target.sh
# Cross-region ASR migration — Reset target region for repeatable e2e testing.
#
# Deletes ALL resources in the target resource group in the correct dependency
# order: ASR items first, then vault, then compute, then networking.
#
# This script is idempotent: every deletion uses || true so missing resources
# are silently skipped.
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

Delete ALL resources in the target resource group for repeatable e2e testing.

Required:
  --target-rg NAME              Target resource group to clean
  --target-region REGION        Target region (e.g. centralus)

Optional:
  --vault-name NAME             Recovery Services vault name (auto-detected if omitted)
  --source-region REGION        Source region (needed to derive ASR fabric names)
  --force                       Skip confirmation prompt
  -h, --help                    Show this help

Example:
  $(basename "$0") \\
    --target-rg rg-migration-test-centralus \\
    --target-region centralus \\
    --vault-name vault-asr-test-centralus \\
    --source-region eastus --force
EOF
    exit 0
}

# ──────────────────────────── Parse args ────────────────────────
TARGET_RG=""
TARGET_REGION=""
VAULT_NAME=""
SOURCE_REGION=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-rg)      TARGET_RG="$2";       shift 2;;
        --target-region)  TARGET_REGION="$2";    shift 2;;
        --vault-name)     VAULT_NAME="$2";       shift 2;;
        --source-region)  SOURCE_REGION="$2";    shift 2;;
        --force)          FORCE=true;            shift;;
        -h|--help)        usage;;
        *) err "Unknown argument: $1";;
    esac
done

[[ -z "$TARGET_RG" ]]     && err "--target-rg is required"
[[ -z "$TARGET_REGION" ]] && err "--target-region is required"

# ──────────────────────── Confirmation ──────────────────────────
info "== Reset Target: $TARGET_RG =="
echo ""
warn "This will DELETE ALL resources in $TARGET_RG including:"
echo "  - ASR replication items, fabrics, containers, policies"
echo "  - Recovery Services vault"
echo "  - VMs, disks, NICs"
echo "  - Load Balancers, Public IPs"
echo "  - VNets, NSGs"
echo "  - Storage accounts"
echo ""

if [[ "$FORCE" != true ]]; then
    read -rp "Type 'RESET' to confirm: " confirmation
    if [[ "$confirmation" != "RESET" ]]; then
        err "Aborted."
    fi
fi

# ──────────────────── Auto-detect vault ─────────────────────────
if [[ -z "$VAULT_NAME" ]]; then
    info "Auto-detecting Recovery Services vault in $TARGET_RG..."
    VAULT_NAME=$(az backup vault list -g "$TARGET_RG" --query "[0].name" -o tsv 2>/dev/null || true)
    if [[ -n "$VAULT_NAME" ]]; then
        ok "  Found vault: $VAULT_NAME"
    else
        detail "  No vault found — skipping ASR cleanup"
    fi
fi

# ──────────── 1. ASR cleanup (must come before vault deletion) ──
if [[ -n "$VAULT_NAME" ]]; then
    info "Cleaning up ASR resources in vault $VAULT_NAME..."

    # List all fabrics in the vault
    fabrics=$(az site-recovery fabric list -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --query "[].name" -o tsv 2>/dev/null || true)

    for fabric in $fabrics; do
        info "  Processing fabric: $fabric"

        # List containers in this fabric
        containers=$(az site-recovery protection-container list \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" --fabric-name "$fabric" \
            --query "[].name" -o tsv 2>/dev/null || true)

        for container in $containers; do
            # Delete protected items
            items=$(az site-recovery protected-item list \
                -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
                --fabric-name "$fabric" --protection-container "$container" \
                --query "[].name" -o tsv 2>/dev/null || true)

            SUB_ID=$(az account show --query "id" -o tsv)
            for item in $items; do
                info "    Removing protected item: $item (via REST DELETE)"
                item_url="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.RecoveryServices/vaults/${VAULT_NAME}/replicationFabrics/${fabric}/replicationProtectionContainers/${container}/replicationProtectedItems/${item}?api-version=2025-08-01"
                az rest --method delete --url "$item_url" -o none 2>/dev/null || true
            done

            # Wait for protected items to be fully deleted
            if [[ -n "$items" ]]; then
                info "    Waiting for protected items to be purged..."
                for attempt in $(seq 1 20); do
                    remaining_items=$(az site-recovery protected-item list \
                        -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
                        --fabric-name "$fabric" --protection-container "$container" \
                        --query "length(@)" -o tsv 2>/dev/null || echo "0")
                    if [[ "$remaining_items" == "0" ]]; then
                        ok "    Protected items purged"
                        break
                    fi
                    sleep 15
                done
            fi

            # Delete container mappings
            mappings=$(az site-recovery protection-container mapping list \
                -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
                --fabric-name "$fabric" --protection-container "$container" \
                --query "[].name" -o tsv 2>/dev/null || true)

            for mapping in $mappings; do
                info "    Removing container mapping: $mapping"
                az site-recovery protection-container mapping remove \
                    -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
                    --fabric-name "$fabric" --protection-container "$container" \
                    -n "$mapping" --yes -o none 2>/dev/null || true
            done
        done

        # Delete network mappings
        net_mappings=$(az site-recovery network-mapping list \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" --fabric-name "$fabric" \
            --query "[].name" -o tsv 2>/dev/null || true)

        for nm in $net_mappings; do
            info "    Removing network mapping: $nm"
            az site-recovery network-mapping delete \
                -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
                --fabric-name "$fabric" -n "$nm" --yes -o none 2>/dev/null || true
        done
    done

    # Wait for ASR operations to settle
    info "  Waiting for ASR deletions to propagate..."
    sleep 30

    # Delete containers
    for fabric in $fabrics; do
        containers=$(az site-recovery protection-container list \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" --fabric-name "$fabric" \
            --query "[].name" -o tsv 2>/dev/null || true)

        for container in $containers; do
            info "    Removing container: $container"
            az site-recovery protection-container remove \
                -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
                --fabric-name "$fabric" -n "$container" --yes -o none 2>/dev/null || true
        done
    done

    # Delete fabrics
    for fabric in $fabrics; do
        info "    Removing fabric: $fabric"
        az site-recovery fabric delete \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            -n "$fabric" --yes -o none 2>/dev/null || true
    done

    # Delete policies
    policies=$(az site-recovery policy list -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --query "[].name" -o tsv 2>/dev/null || true)
    for policy in $policies; do
        info "    Removing policy: $policy"
        az site-recovery policy delete \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            -n "$policy" --yes -o none 2>/dev/null || true
    done

    # Delete recovery plans
    plans=$(az site-recovery recovery-plan list -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
        --query "[].name" -o tsv 2>/dev/null || true)
    for plan in $plans; do
        info "    Removing recovery plan: $plan"
        az site-recovery recovery-plan delete \
            -g "$TARGET_RG" --vault-name "$VAULT_NAME" \
            -n "$plan" --yes -o none 2>/dev/null || true
    done

    ok "  ASR resources cleaned up"

    # Wait for ASR cleanup to fully propagate
    info "  Waiting for ASR cleanup to propagate..."
    sleep 30

    # ──────────── 2. Delete Recovery Services vault ─────────────
    info "Deleting Recovery Services vault: $VAULT_NAME"

    # Disable soft delete
    az backup vault backup-properties set \
        --soft-delete-feature-state Disable \
        -g "$TARGET_RG" -n "$VAULT_NAME" -o none 2>/dev/null || true

    # Retry vault deletion (ASR items may still be draining)
    for attempt in $(seq 1 6); do
        az backup vault delete -g "$TARGET_RG" -n "$VAULT_NAME" \
            --yes --force -o none 2>/dev/null && break || true
        if [[ $attempt -lt 6 ]]; then
            detail "  Vault deletion pending (attempt $attempt/6) — waiting 30s..."
            sleep 30
        fi
    done

    if ! az backup vault show -g "$TARGET_RG" -n "$VAULT_NAME" &>/dev/null 2>&1; then
        ok "  Vault deleted"
    else
        warn "Vault $VAULT_NAME could not be deleted — ASR items may still be draining. Run again later."
    fi
fi

# ──────────── 3. Delete Move Collection (if exists) ─────────────
info "Checking for Azure Resource Mover collections..."
move_collections=$(az resource list -g "$TARGET_RG" \
    --resource-type "Microsoft.Migrate/moveCollections" \
    --query "[].name" -o tsv 2>/dev/null || true)

for mc in $move_collections; do
    info "  Deleting move collection: $mc"
    # List and remove move resources first
    mr_ids=$(az resource-mover move-resource list \
        --move-collection-name "$mc" --resource-group "$TARGET_RG" \
        --query "[].id" -o tsv 2>/dev/null || true)
    for mr_id in $mr_ids; do
        mr_name=$(echo "$mr_id" | awk -F'/' '{print $NF}')
        az resource-mover move-resource delete \
            --move-collection-name "$mc" --resource-group "$TARGET_RG" \
            --name "$mr_name" --yes -o none 2>/dev/null || true
    done
    az resource-mover move-collection delete \
        --name "$mc" --resource-group "$TARGET_RG" --yes -o none 2>/dev/null || true
    ok "  Move collection $mc deleted"
done

# ──────────── 4. Delete VMs ────────────────────────────────────
info "Deleting VMs..."
vms=$(az vm list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null || true)
for vm in $vms; do
    info "  Deleting VM: $vm"
    az vm delete -g "$TARGET_RG" -n "$vm" --yes --force-deletion true -o none 2>/dev/null || true
    ok "  Deleted $vm"
done

# ──────────── 5. Delete disks ──────────────────────────────────
info "Deleting disks..."
disks=$(az disk list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null || true)
for disk in $disks; do
    info "  Deleting disk: $disk"
    az disk delete -g "$TARGET_RG" -n "$disk" --yes -o none 2>/dev/null || true
    ok "  Deleted $disk"
done

# ──────────── 6. Delete NICs ──────────────────────────────────
info "Deleting NICs..."
nics=$(az network nic list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null || true)
for nic in $nics; do
    info "  Deleting NIC: $nic"
    az network nic delete -g "$TARGET_RG" -n "$nic" -o none 2>/dev/null || true
    ok "  Deleted $nic"
done

# ──────────── 7. Delete Load Balancers ─────────────────────────
info "Deleting Load Balancers..."
lbs=$(az network lb list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null || true)
for lb in $lbs; do
    info "  Deleting LB: $lb"
    az network lb delete -g "$TARGET_RG" -n "$lb" -o none 2>/dev/null || true
    ok "  Deleted $lb"
done

# ──────────── 8. Delete Public IPs ─────────────────────────────
info "Deleting Public IPs..."
pips=$(az network public-ip list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null || true)
for pip in $pips; do
    info "  Deleting PIP: $pip"
    az network public-ip delete -g "$TARGET_RG" -n "$pip" -o none 2>/dev/null || true
    ok "  Deleted $pip"
done

# ──────────── 9. Delete VNets ──────────────────────────────────
info "Deleting VNets..."
vnets=$(az network vnet list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null || true)
for vnet in $vnets; do
    info "  Deleting VNet: $vnet"
    az network vnet delete -g "$TARGET_RG" -n "$vnet" -o none 2>/dev/null || true
    ok "  Deleted $vnet"
done

# ──────────── 10. Delete NSGs ──────────────────────────────────
info "Deleting NSGs..."
nsgs=$(az network nsg list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null || true)
for nsg in $nsgs; do
    info "  Deleting NSG: $nsg"
    az network nsg delete -g "$TARGET_RG" -n "$nsg" -o none 2>/dev/null || true
    ok "  Deleted $nsg"
done

# ──────────── 11. Delete Storage accounts ──────────────────────
info "Deleting storage accounts..."
accounts=$(az storage account list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null || true)
for acct in $accounts; do
    info "  Deleting storage account: $acct"
    az storage account delete -g "$TARGET_RG" -n "$acct" --yes -o none 2>/dev/null || true
    ok "  Deleted $acct"
done

# ──────────── Verify ───────────────────────────────────────────
echo ""
remaining=$(az resource list -g "$TARGET_RG" --query "length(@)" -o tsv 2>/dev/null || echo "0")
if [[ "$remaining" == "0" ]]; then
    ok "== Target RG $TARGET_RG is now empty. Ready for e2e test. =="
else
    warn "$remaining resources still remain in $TARGET_RG. Check the portal."
    az resource list -g "$TARGET_RG" --query "[].{name:name, type:type}" -o table 2>/dev/null || true
fi
