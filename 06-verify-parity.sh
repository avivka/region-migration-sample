#!/usr/bin/env bash
#
# 06-verify-parity.sh
# Cross-region ASR migration — Post-failover parity audit.
#
# Compares source vs target setting-by-setting after failover:
# VM profile, disks, NIC wiring, per-VM PIPs (SKU/allocation/DNS label),
# NSG rules, LB frontend/pools/probes/rules, subnet prefixes.
#
# Exit code: number of unexpected DIFFs (0 = full parity).
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

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Compare source vs target settings after failover.

Required:
  --source-rg NAME              Source resource group
  --target-rg NAME              Target resource group
  --vm-names VM1,VM2,...        Comma-separated list of VM names

Optional:
  --source-lb NAME              Source LB name (default: derived from source NICs)
  --target-lb NAME              Target LB name (default: <source-lb>-target)
  -h, --help                    Show this help
EOF
    exit 0
}

SOURCE_RG=""; TARGET_RG=""; VM_NAMES_CSV=""; SOURCE_LB=""; TARGET_LB=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-rg)  SOURCE_RG="$2";    shift 2;;
        --target-rg)  TARGET_RG="$2";    shift 2;;
        --vm-names)   VM_NAMES_CSV="$2"; shift 2;;
        --source-lb)  SOURCE_LB="$2";    shift 2;;
        --target-lb)  TARGET_LB="$2";    shift 2;;
        -h|--help)    usage;;
        *) err "Unknown argument: $1";;
    esac
done
[[ -z "$SOURCE_RG" ]]    && err "--source-rg is required"
[[ -z "$TARGET_RG" ]]    && err "--target-rg is required"
[[ -z "$VM_NAMES_CSV" ]] && err "--vm-names is required"
IFS=',' read -ra VM_NAMES <<< "$VM_NAMES_CSV"

DIFFS=0
EXPECTED=0

# compare LABEL SRC TGT [expected]  — "expected" marks known-different settings
compare() {
    local label="$1" src="$2" tgt="$3" expected="${4:-}"
    if [[ "$src" == "$tgt" ]]; then
        ok "  SAME      $label = $src"
    elif [[ -n "$expected" ]]; then
        detail "  EXPECTED  $label: $src -> $tgt ($expected)"
        EXPECTED=$((EXPECTED + 1))
    else
        echo -e "${RED}  DIFF      $label${NC}"
        echo "              source: $src"
        echo "              target: $tgt"
        DIFFS=$((DIFFS + 1))
    fi
}

# Normalizers (property casing differs across az CLI versions)
VM_NORM='{size: .hardwareProfile.vmSize,
          security: (.securityProfile.securityType // "Standard"),
          secureBoot: (.securityProfile.uefiSettings.secureBootEnabled // false),
          vtpm: (.securityProfile.uefiSettings.vTpmEnabled // false),
          controller: (.storageProfile.diskControllerType // "SCSI"),
          osDiskSku: .storageProfile.osDisk.managedDisk.storageAccountType,
          dataDisks: ([.storageProfile.dataDisks[] | {lun, sku: .managedDisk.storageAccountType, sizeGB: .diskSizeGB}] | sort_by(.lun))}'
NIC_NORM='{subnet: (.ipConfigurations[0].subnet.id | split("/") | last),
           privateIp: (.ipConfigurations[0] | (.privateIPAddress // .privateIpAddress)),
           nsg: ((.networkSecurityGroup.id // "none") | split("/") | last),
           pip: ((.ipConfigurations[0] | (.publicIPAddress // .publicIpAddress // {}).id // "none") | split("/") | last),
           lbPools: ([(.ipConfigurations[0].loadBalancerBackendAddressPools // [])[].id | split("/") | last] | sort)}'
PIP_NORM='{sku: .sku.name,
           allocation: (.publicIPAllocationMethod // .publicIpAllocationMethod),
           dnsLabel: (.dnsSettings.domainNameLabel // "none")}'
NSG_NORM='[(.securityRules // [])[] | {name, priority, direction, access, protocol,
           dstPorts: (.destinationPortRange // .destinationPortRanges),
           srcPrefix: (.sourceAddressPrefix // .sourceAddressPrefixes)}] | sort_by(.priority)'
LB_NORM='{frontends: ([(.frontendIPConfigurations // .frontendIpConfigurations // [])[].name] | sort),
          pools: ([.backendAddressPools[].name] | sort),
          probes: ([(.probes // [])[] | {name, protocol, port, requestPath, interval: .intervalInSeconds}] | sort_by(.name)),
          rules: ([(.loadBalancingRules // [])[] | {name, protocol, fPort: .frontendPort, bPort: .backendPort,
                   probe: ((.probe.id // "none") | split("/") | last),
                   floatingIP: .enableFloatingIP, idleTimeout: .idleTimeoutInMinutes,
                   distribution: .loadDistribution}] | sort_by(.name))}'

info "== Parity audit: $SOURCE_RG vs $TARGET_RG =="

# ──────────── Per-VM comparison ─────────────────────────────────
for vm_name in "${VM_NAMES[@]}"; do
    vm_name="$(echo "$vm_name" | xargs)"
    info ""
    info "── VM: $vm_name ──"

    src_vm=$(az vm show -g "$SOURCE_RG" -n "$vm_name" -o json 2>/dev/null || echo '{}')
    tgt_vm=$(az vm show -g "$TARGET_RG" -n "$vm_name" -o json 2>/dev/null || echo '{}')
    [[ "$(jq -r '.name // empty' <<<"$src_vm")" == "" ]] && { warn "$vm_name missing in $SOURCE_RG"; DIFFS=$((DIFFS+1)); continue; }
    [[ "$(jq -r '.name // empty' <<<"$tgt_vm")" == "" ]] && { warn "$vm_name missing in $TARGET_RG"; DIFFS=$((DIFFS+1)); continue; }

    for key in size security secureBoot vtpm controller osDiskSku dataDisks; do
        compare "vm.$key" "$(jq -Sc "$VM_NORM | .$key" <<<"$src_vm")" \
                          "$(jq -Sc "$VM_NORM | .$key" <<<"$tgt_vm")"
    done

    # NIC wiring
    src_nic_id=$(jq -r '.networkProfile.networkInterfaces[0].id' <<<"$src_vm")
    tgt_nic_id=$(jq -r '.networkProfile.networkInterfaces[0].id' <<<"$tgt_vm")
    src_nic=$(az network nic show --ids "$src_nic_id" -o json)
    tgt_nic=$(az network nic show --ids "$tgt_nic_id" -o json)

    compare "nic.subnet" "$(jq -r "$NIC_NORM | .subnet" <<<"$src_nic")" "$(jq -r "$NIC_NORM | .subnet" <<<"$tgt_nic")"
    compare "nic.privateIp" "$(jq -r "$NIC_NORM | .privateIp" <<<"$src_nic")" "$(jq -r "$NIC_NORM | .privateIp" <<<"$tgt_nic")" \
            "different VNet address space"
    compare "nic.nsg" "$(jq -r "$NIC_NORM | .nsg" <<<"$src_nic")" "$(jq -r "$NIC_NORM | .nsg" <<<"$tgt_nic")"
    compare "nic.pip" "$(jq -r "$NIC_NORM | .pip" <<<"$src_nic")" "$(jq -r "$NIC_NORM | .pip" <<<"$tgt_nic")"
    compare "nic.lbPools" "$(jq -Sc "$NIC_NORM | .lbPools" <<<"$src_nic")" "$(jq -Sc "$NIC_NORM | .lbPools" <<<"$tgt_nic")"

    # Per-VM PIP settings + DNS label
    src_pip_id=$(jq -r '(.ipConfigurations[0] | (.publicIPAddress // .publicIpAddress // {}).id) // empty' <<<"$src_nic")
    tgt_pip_id=$(jq -r '(.ipConfigurations[0] | (.publicIPAddress // .publicIpAddress // {}).id) // empty' <<<"$tgt_nic")
    if [[ -n "$src_pip_id" && -n "$tgt_pip_id" ]]; then
        src_pip=$(az network public-ip show --ids "$src_pip_id" -o json)
        tgt_pip=$(az network public-ip show --ids "$tgt_pip_id" -o json)
        for key in sku allocation dnsLabel; do
            compare "pip.$key" "$(jq -r "$PIP_NORM | .$key" <<<"$src_pip")" "$(jq -r "$PIP_NORM | .$key" <<<"$tgt_pip")"
        done
        compare "pip.address" "$(jq -r '.ipAddress' <<<"$src_pip")" "$(jq -r '.ipAddress' <<<"$tgt_pip")" "public IP always changes"
        compare "pip.fqdn" "$(jq -r '.dnsSettings.fqdn // "none"' <<<"$src_pip")" "$(jq -r '.dnsSettings.fqdn // "none"' <<<"$tgt_pip")" \
                "region suffix changes"
    elif [[ -n "$src_pip_id" || -n "$tgt_pip_id" ]]; then
        compare "pip.present" "$([[ -n "$src_pip_id" ]] && echo yes || echo no)" "$([[ -n "$tgt_pip_id" ]] && echo yes || echo no)"
    fi

    # NSG rules of the NSG actually attached to each NIC
    src_nsg_id=$(jq -r '.networkSecurityGroup.id // empty' <<<"$src_nic")
    tgt_nsg_id=$(jq -r '.networkSecurityGroup.id // empty' <<<"$tgt_nic")
    if [[ -n "$src_nsg_id" && -n "$tgt_nsg_id" ]]; then
        compare "nsg.rules" \
            "$(az network nsg show --ids "$src_nsg_id" -o json | jq -Sc "$NSG_NORM")" \
            "$(az network nsg show --ids "$tgt_nsg_id" -o json | jq -Sc "$NSG_NORM")"
    fi

    # Subnet address prefix
    src_subnet_id=$(jq -r '.ipConfigurations[0].subnet.id' <<<"$src_nic")
    tgt_subnet_id=$(jq -r '.ipConfigurations[0].subnet.id' <<<"$tgt_nic")
    compare "subnet.prefix" \
        "$(az network vnet subnet show --ids "$src_subnet_id" -o json | jq -Sc '.addressPrefix // .addressPrefixes')" \
        "$(az network vnet subnet show --ids "$tgt_subnet_id" -o json | jq -Sc '.addressPrefix // .addressPrefixes')" \
        "different VNet address space"
done

# ──────────── Load balancer comparison ──────────────────────────
if [[ -z "$SOURCE_LB" ]]; then
    SOURCE_LB=$(az network lb list -g "$SOURCE_RG" --query "[0].name" -o tsv 2>/dev/null || true)
fi
if [[ -n "$SOURCE_LB" ]]; then
    [[ -z "$TARGET_LB" ]] && TARGET_LB="${SOURCE_LB}-target"
    info ""
    info "── LB: $SOURCE_LB vs $TARGET_LB ──"
    src_lb=$(az network lb show -g "$SOURCE_RG" -n "$SOURCE_LB" -o json 2>/dev/null || echo '{}')
    tgt_lb=$(az network lb show -g "$TARGET_RG" -n "$TARGET_LB" -o json 2>/dev/null || echo '{}')
    if [[ "$(jq -r '.name // empty' <<<"$tgt_lb")" == "" ]]; then
        warn "Target LB $TARGET_LB not found in $TARGET_RG"
        DIFFS=$((DIFFS+1))
    else
        for key in frontends pools probes rules; do
            compare "lb.$key" "$(jq -Sc "$LB_NORM | .$key" <<<"$src_lb")" "$(jq -Sc "$LB_NORM | .$key" <<<"$tgt_lb")"
        done
        # LB frontend PIP settings
        src_lb_pip_id=$(jq -r '(((.frontendIPConfigurations // .frontendIpConfigurations // [])[0] | (.publicIPAddress // .publicIpAddress // {}).id) // empty)' <<<"$src_lb")
        tgt_lb_pip_id=$(jq -r '(((.frontendIPConfigurations // .frontendIpConfigurations // [])[0] | (.publicIPAddress // .publicIpAddress // {}).id) // empty)' <<<"$tgt_lb")
        if [[ -n "$src_lb_pip_id" && -n "$tgt_lb_pip_id" ]]; then
            src_lb_pip=$(az network public-ip show --ids "$src_lb_pip_id" -o json)
            tgt_lb_pip=$(az network public-ip show --ids "$tgt_lb_pip_id" -o json)
            for key in sku allocation dnsLabel; do
                compare "lb.pip.$key" "$(jq -r "$PIP_NORM | .$key" <<<"$src_lb_pip")" "$(jq -r "$PIP_NORM | .$key" <<<"$tgt_lb_pip")"
            done
            compare "lb.pip.fqdn" "$(jq -r '.dnsSettings.fqdn // "none"' <<<"$src_lb_pip")" \
                    "$(jq -r '.dnsSettings.fqdn // "none"' <<<"$tgt_lb_pip")" "region suffix changes"
        else
            compare "lb.pip.present" "$([[ -n "$src_lb_pip_id" ]] && echo yes || echo no)" "$([[ -n "$tgt_lb_pip_id" ]] && echo yes || echo no)"
        fi
    fi
else
    detail "No source LB found — skipping LB comparison"
fi

# ──────────── Summary ───────────────────────────────────────────
echo ""
if [[ "$DIFFS" -eq 0 ]]; then
    ok "== Parity audit PASSED: 0 unexpected diffs ($EXPECTED expected region/IP differences) =="
else
    warn "== Parity audit found $DIFFS unexpected diff(s) ($EXPECTED expected) — review above =="
fi
exit "$DIFFS"
