# Edge CX Region Migration — eastus → centralus

> **📦 PROJECT ARCHIVED (2026-08-31).** The customer paused the migration because ASR
> initial-replication throughput was too slow for their window (Azure caps per-VM churn
> at 54 MB/s; see [asr-replication-speed-conclusions.md](asr-replication-speed-conclusions.md)).
> Everything here is preserved for revival: automation, docs, validated e2e results, and a
> Terraform template that recreates the source environment.
> **Final status, open items, and the revival checklist: [PROJECT-STATUS.md](PROJECT-STATUS.md).**

Automation for migrating Azure **Trusted Launch** VMs (Gen2, Secure Boot + vTPM, NVMe)
and their network fabric across regions with **Azure Site Recovery (A2A)** — because
Azure Resource Mover does not support Trusted Launch VMs.

Core guarantees the tooling enforces (all validated e2e — see PROJECT-STATUS.md):

- **Destination mirrors source names verbatim** — VNet, subnet, NSG, LB, frontend/pool,
  probes/rules, PIPs. No `-target`/`-test` suffixes on migrated resources.
- **Private IPs are preserved exactly** (e.g. `192.168.1.4` stays `192.168.1.4`) —
  required by IP-pinned apps such as the customer's OpenSearch cluster. Target subnet
  range mirrors source; IPs are enforced on the NIC post-failover (ASR's own pins are
  unreliable — see PROJECT-STATUS.md § Technical findings).
- **PIP DNS labels are copied** (the cloudapp FQDN keeps the label; only the region
  suffix changes — repoint anything using the full FQDN).
- **Trusted Launch survives**: security profile, Secure Boot, vTPM, NVMe controller,
  data-disk LUNs all preserved (vTPM state does NOT migrate — escrow BitLocker keys).

## Repository map

| Path | Purpose |
|---|---|
| `00-create-test-env.sh` | Build a disposable source test env (VMs, LB, NSG, PIPs) |
| `00-reset-target.sh` | Wipe the target RG + ASR state; optional `--source-rg [--deep-clean]` strips stale ASR agents/snapshots from the source (fixes slow re-sync) |
| `01-preflight-and-stage.sh` | Inventory the source; stage the target fabric (VNet/subnets/NSG/LB/PIPs/vault) mirroring source names, ranges, probes, rules, DNS labels |
| `02-enable-asr-replication.sh` | Cache SA (private endpoint, no public access), policy, fabrics, mappings; enable replication per VM; poll sync with per-VM `sync: N%`; pin recovery IPs (best-effort) |
| `03-test-failover.sh` | Test failover into the staged target VNet; test VMs get source PIP names, DNS labels, and **exact source private IPs**; validation checklist; full cleanup |
| `04-planned-failover.sh` | Recovery plan → pre-failover gate (repoints recovery network/IP; aborts rather than fail over into a wrong VNet) → failover → NSG/PIP/LB wiring → **two-pass exact-IP enforcement + per-VM MATCH proof** → commit |
| `05-decommission.sh` | Post-soak source teardown |
| `06-verify-parity.sh` | Setting-by-setting source↔destination audit (VM profile, disks, NICs, IPs, NSG rules, LB config, DNS labels); exit code = unexpected diffs |
| `99-manual-snapshot-migration.sh` | Snapshot fallback for VMs ASR can't replicate (e.g. old Linux TL) |
| `terraform/source-env-eastus/` | **IaC recreate-template of the source env** (exported live, pruned, validated; `plan: 32 to add`) — see its README |
| `MIGRATION-PLAN.md` | Full migration plan (relative timeline, C-day anchored) — archived draft |
| `RUNBOOK.md` | Phase-by-phase operational runbook |
| `asr-replication-speed-conclusions.md` | Why sync is slow: churn caps, shared region-pair pipeline, what helps |
| `sync-slow-support.md` (repo root ↑) | Microsoft support thread on slow re-triggered sync; automated in `00-reset-target.sh --deep-clean` |
| `logs/` (gitignored) | Every run writes a timestamped, color-stripped log: `logs/<script>-<run>.log` |

## How to use

Typical end-to-end flow (each script prints the exact command for the next step):

```bash
# 0. (Repeat runs) wipe target + stale source-ASR state
./00-reset-target.sh --target-rg <TGT_RG> --target-region centralus \
  --vault-name <VAULT> --source-region eastus [--source-rg <SRC_RG> --deep-clean] --force

# 1. Inventory + stage target fabric (mirrors source names/ranges/LB config)
./01-preflight-and-stage.sh --source-rg <SRC_RG> --source-region eastus \
  --target-rg <TGT_RG> --target-region centralus --vault-name <VAULT> \
  --vm-names "vm1,vm2,..."

# 2. Enable replication + wait for sync (logs per-VM sync %)
./02-enable-asr-replication.sh --source-rg <SRC_RG> --source-region eastus \
  --target-rg <TGT_RG> --target-region centralus --vault-name <VAULT> \
  --vm-names "vm1,vm2,..." --target-vnet <SOURCE_VNET_NAME> --target-subnet <SOURCE_SUBNET> \
  [--fix-kernel]   # error 151141: kernel newer than the mobility agent supports

# 3. Test failover (mandatory before cutover; validates TL boot + exact IPs; cleans up)
./03-test-failover.sh --target-rg <TGT_RG> --target-region centralus \
  --vault-name <VAULT> --vm-names "vm1,..." --source-region eastus --source-rg <SRC_RG>

# 4. Planned failover (cutover) — gate → failover → wiring → IP proof → commit
./04-planned-failover.sh --source-rg <SRC_RG> --source-region eastus \
  --target-rg <TGT_RG> --target-region centralus --vault-name <VAULT> \
  --vm-names "vm1,..." [--skip-commit]

# 5. Audit parity, then (after soak) decommission
./06-verify-parity.sh --source-rg <SRC_RG> --target-rg <TGT_RG> --vm-names "vm1,..."
./05-decommission.sh ...
```

Operational rules that matter (learned the hard way — details in PROJECT-STATUS.md):

1. **Always pass `--target-vnet`/`--target-subnet` to 02 as the SOURCE names** (or rely on
   01's staging) — a stale differently-ranged target VNet is how VMs end up on foreign
   `10.x` IPs. Script 04's gate now blocks that failover, but wire it right in 02.
2. **Replication must be `Protected` + health `Normal` before any failover.**
   `Critical / sync 0%` almost always means the mobility agent can't run
   (unsupported kernel → `--fix-kernel`) or the cache SA is unreachable (private
   endpoint state).
3. Source and target must be **different resource groups** (names are mirrored verbatim).
4. Same-address-space VNets must never be **peered** during the transition.
5. Re-running after a failed/committed attempt requires cleanup — use `00-reset-target.sh`
   (it purges failed *and committed* items, replica disks, orphaned snapshots, stale agents).

## Requirements

`az` CLI (with `site-recovery` extension), `jq`, bash 3.2+; `terraform` + `aztfexport`
only for the IaC template; `pwsh` + Az module optional (deep-clean step 6).
