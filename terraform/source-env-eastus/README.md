# Source environment (eastus) — Terraform recreate-template

Infrastructure-as-code snapshot of `rg-migration-test-eastus`, exported live with
`aztfexport` on 2026-08-27 and pruned to the actual environment. Use it to recreate
the source env if the migration project is revived.

## What it recreates

- Resource group `rg-migration-test-eastus` (eastus)
- `vnet-source` 10.0.0.0/16, subnet `snet-workload` 10.0.1.0/24 (+ NSG association)
- `nsg-workload` with its rules
- 3× TrustedLaunch VMs (`vm-test-01/02/03`): D16ds_v6 / D8ds_v6 / D2ds_v6,
  Ubuntu 24.04, Secure Boot + vTPM, **NVMe** controller, zone 1
- NICs with **static** private IPs `10.0.1.4/.5/.6` (source had these dynamically;
  pinned static here because IP-pinned apps — e.g. OpenSearch in the CX env —
  require exact IPs to survive recreation)
- Per-VM public IPs with DNS labels (`controlup-sip-vm-test-0X-avivk8`)
- Data disks incl. the **PremiumV2_LRS** disk on vm-test-02, with attachments
- `lb-source` + backend pool `bepool`, probe `ping_api` (HTTP 9080 /hello),
  rule `route_https`, frontend PIP `pip-source-lb` (label `cu-lb-source-avivk8`)

## Deliberately excluded (migration debris, not the environment)

ASR cache storage account + containers, private endpoint + privatelink DNS zone,
SiteRecovery-* VM extensions, Defender's auto-injected MDE.Linux extension,
ASR snapshots, EventGrid system topic. Defender re-injects MDE on its own.

## How to recreate

```bash
terraform init
terraform plan    # review — this CREATES a new copy of the env
terraform apply
```

## Caveats

- **Auth:** VMs carry the exported *public* SSH key (`azureuser`). To log in you
  need the matching private key, or edit `admin_ssh_key` before applying.
- **Disk contents are NOT captured** — Terraform recreates empty data disks and
  fresh OS disks from the Ubuntu image. App state/config must be restored separately.
- **DNS labels are region-unique:** apply fails if the old PIPs still exist
  anywhere holding the same labels.
- `.import-archive/` holds the original aztfexport state/mapping from the live
  export — reference only, not needed to recreate.
- Resource addresses are aztfexport-style (`res-N`); rename at will (`terraform
  state mv` is irrelevant here since this is a create-from-scratch template).
