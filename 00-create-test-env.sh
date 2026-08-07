#!/usr/bin/env bash
#
# 00-create-test-env.sh
# Create a source test environment for end-to-end ASR migration validation.
#
# Builds a resource group with VNet, NSG, public IP, Standard Load Balancer,
# and 3 Trusted Launch VMs (Gen2, Secure Boot, vTPM, SCSI) with data disks.
# Use this to validate the full migration pipeline (01→05) in a non-prod sub.
#
# This script is idempotent: it checks existence before creating. Safe to re-run
# if a previous run was interrupted.
#
# Next step: Run 01-preflight-and-stage.sh to capture inventory and stage the
# target region fabric.
#
# Requires: az cli, jq
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

Create a source test environment for ASR migration validation.

Optional:
  --source-rg NAME            Source resource group         (default: rg-migration-test-eastus)
  --source-region REGION      Source region                 (default: eastus)
  --admin-username USER       VM admin username             (default: azureuser)
  --ssh-key-path PATH         Path to SSH public key        (default: ~/.ssh/id_rsa.pub)
  -h, --help                  Show this help

Example:
  $(basename "$0") \\
    --source-rg rg-migration-test-eastus --source-region eastus \\
    --admin-username azureuser
EOF
    exit 0
}

# ──────────────────────────── Parse args ────────────────────────
SOURCE_RG="rg-migration-test-eastus"
SOURCE_REGION="eastus"
ADMIN_USERNAME="azureuser"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-rg)       SOURCE_RG="$2";        shift 2;;
        --source-region)   SOURCE_REGION="$2";     shift 2;;
        --admin-username)  ADMIN_USERNAME="$2";    shift 2;;
        --ssh-key-path)    SSH_KEY_PATH="$2";      shift 2;;
        -h|--help)         usage;;
        *) err "Unknown argument: $1";;
    esac
done

# ──────────────── SSH key check ─────────────────────────────────
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    warn "SSH public key not found at $SSH_KEY_PATH — generating a new key pair."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH%.pub}" -N "" -q
    ok "Generated SSH key pair at ${SSH_KEY_PATH%.pub}"
fi

# ──────────────── Resource names ────────────────────────────────
VNET_NAME="vnet-source"
VNET_CIDR="10.0.0.0/16"
SUBNET_NAME="snet-workload"
SUBNET_CIDR="10.0.1.0/24"
NSG_NAME="nsg-workload"
PIP_NAME="pip-source-lb"
LB_NAME="lb-source"
IMAGE="Canonical:ubuntu-24_04-lts:server:latest"

# VM definitions: name|size|data_disk_size|data_disk_sku|zone
# Premium SSD v2 LRS requires zonal deployment, so vm-test-02 uses zone 1
VM_DEFS=(
    "vm-test-01|Standard_D16ds_v6|64|Premium_LRS|"
    "vm-test-02|Standard_D8ds_v6|32|PremiumV2_LRS|1"
    "vm-test-03|Standard_D2ds_v6|16|Premium_LRS|"
)

info "== Phase 0: Create test source environment =="
info "  Resource group: $SOURCE_RG"
info "  Region:         $SOURCE_REGION"
info "  VMs:            vm-test-01, vm-test-02, vm-test-03"
echo ""

# ──────────── 1. Resource group ─────────────────────────────────
if ! az group show -n "$SOURCE_RG" &>/dev/null; then
    az group create -n "$SOURCE_RG" -l "$SOURCE_REGION" -o none
    ok "Created resource group $SOURCE_RG"
else
    ok "Resource group $SOURCE_RG already exists"
fi

# ──────────── 2. VNet + subnet ──────────────────────────────────
if ! az network vnet show -g "$SOURCE_RG" -n "$VNET_NAME" &>/dev/null; then
    az network vnet create \
        -g "$SOURCE_RG" -n "$VNET_NAME" -l "$SOURCE_REGION" \
        --address-prefix "$VNET_CIDR" \
        --subnet-name "$SUBNET_NAME" --subnet-prefix "$SUBNET_CIDR" \
        -o none
    ok "Created VNet $VNET_NAME ($VNET_CIDR) with subnet $SUBNET_NAME ($SUBNET_CIDR)"
else
    ok "VNet $VNET_NAME already exists"
    if ! az network vnet subnet show -g "$SOURCE_RG" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" &>/dev/null; then
        az network vnet subnet create \
            -g "$SOURCE_RG" --vnet-name "$VNET_NAME" \
            -n "$SUBNET_NAME" --address-prefix "$SUBNET_CIDR" \
            -o none
        ok "Created subnet $SUBNET_NAME in existing VNet"
    fi
fi

# ──────────── 3. NSG with rules ─────────────────────────────────
if ! az network nsg show -g "$SOURCE_RG" -n "$NSG_NAME" &>/dev/null; then
    az network nsg create \
        -g "$SOURCE_RG" -n "$NSG_NAME" -l "$SOURCE_REGION" \
        -o none

    az network nsg rule create \
        -g "$SOURCE_RG" --nsg-name "$NSG_NAME" \
        -n "AllowSSH" --priority 1000 \
        --access Allow --protocol Tcp --direction Inbound \
        --source-address-prefixes "*" --source-port-ranges "*" \
        --destination-address-prefixes "*" --destination-port-ranges "22" \
        --description "Allow SSH inbound" \
        -o none

    az network nsg rule create \
        -g "$SOURCE_RG" --nsg-name "$NSG_NAME" \
        -n "AllowHTTP" --priority 1010 \
        --access Allow --protocol Tcp --direction Inbound \
        --source-address-prefixes "*" --source-port-ranges "*" \
        --destination-address-prefixes "*" --destination-port-ranges "80" \
        --description "Allow HTTP inbound" \
        -o none

    ok "Created NSG $NSG_NAME with AllowSSH (22) and AllowHTTP (80) rules"
else
    ok "NSG $NSG_NAME already exists"
fi

# ──────────── 4. Associate NSG to subnet ────────────────────────
az network vnet subnet update \
    -g "$SOURCE_RG" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" \
    -o none 2>/dev/null || true
ok "Associated NSG $NSG_NAME with subnet $SUBNET_NAME"

# ──────────── 5. Public IP ──────────────────────────────────────
if ! az network public-ip show -g "$SOURCE_RG" -n "$PIP_NAME" &>/dev/null; then
    az network public-ip create \
        -g "$SOURCE_RG" -n "$PIP_NAME" -l "$SOURCE_REGION" \
        --sku Standard --allocation-method Static \
        -o none
    ok "Created public IP $PIP_NAME (Standard, Static)"
else
    ok "Public IP $PIP_NAME already exists"
fi

# ──────────── 6. Load Balancer ──────────────────────────────────
if ! az network lb show -g "$SOURCE_RG" -n "$LB_NAME" &>/dev/null; then
    az network lb create \
        -g "$SOURCE_RG" -n "$LB_NAME" -l "$SOURCE_REGION" \
        --sku Standard \
        --public-ip-address "$PIP_NAME" \
        --frontend-ip-name "fe" \
        --backend-pool-name "bepool" \
        -o none

    az network lb probe create \
        -g "$SOURCE_RG" --lb-name "$LB_NAME" \
        -n "tcp-probe" --protocol Tcp --port 80 \
        --interval 5 --threshold 2 \
        -o none

    az network lb rule create \
        -g "$SOURCE_RG" --lb-name "$LB_NAME" \
        -n "rule-80" --protocol Tcp \
        --frontend-port 80 --backend-port 80 \
        --frontend-ip-name "fe" --backend-pool-name "bepool" \
        --probe-name "tcp-probe" \
        -o none

    ok "Created Load Balancer $LB_NAME (frontend + backend pool + probe + rule)"
else
    ok "Load Balancer $LB_NAME already exists"
fi

# ──────────── 7. VMs (NIC + LB backend + VM + data disk) ───────
SUBNET_ID=$(az network vnet subnet show \
    -g "$SOURCE_RG" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" \
    --query "id" -o tsv)

for vm_def in "${VM_DEFS[@]}"; do
    IFS='|' read -r VM_NAME VM_SIZE DD_SIZE DD_SKU VM_ZONE <<< "$vm_def"

    info "Creating VM $VM_NAME ($VM_SIZE)..."

    NIC_NAME="nic-${VM_NAME}"
    DD_NAME="disk-data-${VM_NAME}"

    # ── NIC ──
    if ! az network nic show -g "$SOURCE_RG" -n "$NIC_NAME" &>/dev/null; then
        nic_cmd=(az network nic create
            -g "$SOURCE_RG" -n "$NIC_NAME" -l "$SOURCE_REGION"
            --subnet "$SUBNET_ID"
            --network-security-group "$NSG_NAME"
            -o none)

        "${nic_cmd[@]}"
        ok "  Created NIC $NIC_NAME"
    else
        ok "  NIC $NIC_NAME already exists"
    fi

    # ── Add NIC to LB backend pool ──
    az network nic ip-config address-pool add \
        --nic-name "$NIC_NAME" -g "$SOURCE_RG" \
        --ip-config-name "ipconfig1" \
        --lb-name "$LB_NAME" --address-pool "bepool" \
        -o none 2>/dev/null || true
    ok "  NIC $NIC_NAME added to LB backend pool"

    # ── VM ──
    if ! az vm show -g "$SOURCE_RG" -n "$VM_NAME" &>/dev/null; then
        vm_cmd=(az vm create
            -g "$SOURCE_RG" -n "$VM_NAME" -l "$SOURCE_REGION"
            --image "$IMAGE"
            --size "$VM_SIZE"
            --nics "$NIC_NAME"
            --os-disk-size-gb 30
            --storage-sku Premium_LRS
            --admin-username "$ADMIN_USERNAME"
            --ssh-key-values "$SSH_KEY_PATH"
            --security-type TrustedLaunch
            --enable-secure-boot true
            --enable-vtpm true
            --public-ip-address ""
            -o none)

        if [[ -n "$VM_ZONE" ]]; then
            vm_cmd+=(--zone "$VM_ZONE")
        fi

        "${vm_cmd[@]}"
        ok "  Created VM $VM_NAME (TrustedLaunch, SecureBoot, vTPM)"
    else
        ok "  VM $VM_NAME already exists"
    fi

    # ── Data disk ──
    if ! az disk show -g "$SOURCE_RG" -n "$DD_NAME" &>/dev/null; then
        disk_cmd=(az disk create
            -g "$SOURCE_RG" -n "$DD_NAME" -l "$SOURCE_REGION"
            --size-gb "$DD_SIZE"
            --sku "$DD_SKU"
            -o none)

        # Premium SSD v2 LRS requires zonal deployment
        if [[ -n "$VM_ZONE" ]]; then
            disk_cmd+=(--zone "$VM_ZONE")
        fi

        "${disk_cmd[@]}"
        ok "  Created data disk $DD_NAME (${DD_SIZE}GB, $DD_SKU)"
    else
        ok "  Data disk $DD_NAME already exists"
    fi

    # Attach data disk to VM
    az vm disk attach \
        -g "$SOURCE_RG" --vm-name "$VM_NAME" \
        --name "$DD_NAME" --lun 0 \
        -o none 2>/dev/null || true
    ok "  Attached data disk $DD_NAME to $VM_NAME at LUN 0"

    echo ""
done

# ──────────── 8. Summary + verification ─────────────────────────
echo ""
info "======================================================================"
info "  TEST ENVIRONMENT CREATED"
info "======================================================================"
echo ""
info "Resource group:  $SOURCE_RG ($SOURCE_REGION)"
echo ""
echo "  Resources:"
echo "    VNet:          $VNET_NAME ($VNET_CIDR)"
echo "    Subnet:        $SUBNET_NAME ($SUBNET_CIDR)"
echo "    NSG:           $NSG_NAME (SSH + HTTP)"
echo "    Public IP:     $PIP_NAME (Standard, Static)"
echo "    Load Balancer: $LB_NAME (Standard, rule-80)"
echo ""
echo "  VMs:"
echo "    vm-test-01  Standard_D16ds_v6   64GB Premium SSD LRS"
echo "    vm-test-02  Standard_D8ds_v6    32GB Premium SSD v2 LRS (zone 1)"
echo "    vm-test-03  Standard_D2ds_v6    16GB Premium SSD LRS"
echo ""

info "Verifying Trusted Launch security profile..."
for vm_def in "${VM_DEFS[@]}"; do
    IFS='|' read -r VM_NAME _ _ _ _ <<< "$vm_def"
    sec_json=$(az vm show -g "$SOURCE_RG" -n "$VM_NAME" \
        --query "{name:name, securityType:securityProfile.securityType, secureBoot:securityProfile.uefiSettings.secureBootEnabled, vTPM:securityProfile.uefiSettings.vTpmEnabled, diskController:storageProfile.diskControllerType}" \
        -o json)
    sec_type=$(echo "$sec_json" | jq -r '.securityType // "N/A"')
    sboot=$(echo "$sec_json" | jq -r '.secureBoot // false')
    vtpm=$(echo "$sec_json" | jq -r '.vTPM // false')
    dctrl=$(echo "$sec_json" | jq -r '.diskController // "SCSI"')
    ok "  $VM_NAME: security=$sec_type secureBoot=$sboot vTPM=$vtpm diskController=$dctrl"
done

# ──────────── Done ──────────────────────────────────────────────
echo ""
info "== Test environment ready. Next: run 01-preflight-and-stage.sh =="
info ""
info "Next step:"
info "  Run 01-preflight-and-stage.sh to capture source inventory and stage"
info "  the target region fabric (VNet, NSGs, LB, Recovery Services vault)."
info ""
info "  Example:"
echo "    ./01-preflight-and-stage.sh \\"
echo "      --source-rg \"$SOURCE_RG\" --source-region \"$SOURCE_REGION\" \\"
echo "      --target-rg \"rg-migration-test-centralus\" --target-region \"centralus\" \\"
echo "      --vault-name \"vault-asr-test\" --vm-names \"vm-test-01,vm-test-02,vm-test-03\""
