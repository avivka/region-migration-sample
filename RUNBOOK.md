# Cross-Region Migration Runbook — Trusted Launch v7 VMs via Azure Site Recovery

**Scope:** Migrate VMs (Gen2, Trusted Launch, NVMe/SCSI controller), attached OS + data disks,
VNet/subnets, NICs, private + public IPs, NSGs, and a Load Balancer from Source Region → Target Region.

---

## Why not Azure Resource Mover?

**Azure Resource Mover does NOT support Trusted Launch VMs.** This is confirmed by Microsoft
support — any attempt to move a Trusted Launch VM via Resource Mover fails at the validation
step. Additional limitations:

- Resource Mover only moves *attached* disks; it cannot replicate the Trusted Launch security
  profile (Secure Boot, vTPM settings) to the target.
- Resource Mover does not support continuous replication — it requires full downtime during the
  move, with no delta sync.
- There is no announced timeline for Trusted Launch support in Resource Mover.

**Instead, this toolchain uses Azure Site Recovery (ASR)** for continuous replication with
near-zero-downtime cutover. ASR fully supports Trusted Launch VMs:
- **Windows Trusted Launch:** GA for cross-region replication.
- **Linux Trusted Launch:** GA for VMs created **after 2024-04-01**. Older Linux Trusted Launch
  VMs must use the manual snapshot fallback path (`99-manual-snapshot-migration.sh`).

---

## How ASR is used in this migration

**Division of labor:**
- **ASR replicates:** VM + Trusted Launch profile (Secure Boot, vTPM) + OS disk + all data disks.
- **You pre-stage in target:** VNet/subnets, NSGs, Load Balancer, public IPs (new), Recovery Services vault.
- **Post-failover script wires:** NSG association, public IP assignment, LB backend membership.

**Script workflow:**

| Script | Phase | What it does |
|--------|-------|-------------|
| `01-preflight-and-stage.sh` | 0-1 | Captures source inventory, creates target fabric (VNet, NSGs, LB, vault) |
| `02-enable-asr-replication.sh` | 2 | Creates ASR policy, fabrics, containers, mappings; enables replication per VM |
| `03-test-failover.sh` | 3 | Runs test failover into isolated VNet; validates Trusted Launch boot path |
| `04-planned-failover.sh` | 4-5 | Builds recovery plan, executes planned failover, wires network, commits |
| `05-decommission.sh` | 6 | Disables replication, deletes source VMs/disks/snapshots |
| `99-manual-snapshot-migration.sh` | — | **Fallback** for VMs where ASR is blocked (e.g., pre-2024-04-01 Linux TL) |

---

## Phase 0 — Pre-flight validation (do this first)

1. **OS + creation date check.** Windows Trusted Launch → supported. Linux Trusted Launch → supported
   ONLY if VM created after 2024-04-01. Older Linux Trusted Launch VMs fall back to manual snapshot
   rebuild (`99-manual-snapshot-migration.sh`).
2. **Target region capacity.** Confirm the v7/NVMe-capable size exists and has quota in the target region.
   v7 + NVMe is not in every region — check before committing.
3. **Disk controller type.** Note SCSI vs NVMe per VM. Target VM size must support the same controller type.
4. **Encryption.** If CMK / Disk Encryption Set is used, the DES + Key Vault must exist in the TARGET region
   first (Key Vault does not move cross-region). If BitLocker, escrow recovery keys before cutover —
   the target VM gets a NEW vTPM; ASR does not migrate vTPM-sealed state.
5. **Address space decision.** To retain identical private IPs, the target subnet must use the same
   address space AND the source must not be peered to the target simultaneously during transition.

## Phase 1 — Pre-stage target fabric

**Script:** `01-preflight-and-stage.sh` (or `01-preflight-and-stage.ps1` for PowerShell)

Captures source inventory and stamps target fabric. Creates/validates:
- Recovery Services vault (target region)
- Target VNet + subnets (matching address space if retaining private IPs)
- Target NSGs (ASR does NOT replicate NSGs — must pre-exist)
- Target Load Balancer (frontend + backend pool + rules/probes)
- New target-region public IP(s)

## Phase 2 — Enable ASR replication

**Script:** `02-enable-asr-replication.sh`

For each VM: creates the replication policy (A2A), source + target fabrics, protection containers,
container mapping (policy ↔ containers), network mapping (source VNet → target VNet), then enables
replication with target resource group, target VNet/subnet, and disk SKU mappings. ASR seeds the
initial copy, then replicates deltas continuously. **Source stays live.**

Key `az site-recovery` commands used:
- `az site-recovery policy create` — A2A policy with multi-VM sync
- `az site-recovery fabric create` — source + target region fabrics
- `az site-recovery protection-container create` — A2A containers
- `az site-recovery protection-container mapping create` — maps policy to containers
- `az site-recovery network mapping create` — maps source VNet to target VNet
- `az site-recovery protected-item create` — enables replication per VM

## Phase 3 — Test failover (mandatory)

**Script:** `03-test-failover.sh`

Fail over into an **isolated, non-production VNet** (no connectivity to source). Validate:
- VM boots with Secure Boot + vTPM intact
- Application health
- Disk controller type matches source (NVMe/SCSI)
- All data disks attached at correct LUNs

Clean up the test failover afterward. **Do not skip** — this proves the Trusted Launch boot path
in the target region.

> **Note:** The `az site-recovery` CLI extension does not expose `test-failover` or
> `test-failover-cleanup` subcommands. The script uses `az rest` to call the ASR REST API directly.

## Phase 4-5 — Recovery plan + planned cutover

**Script:** `04-planned-failover.sh`

1. Build recovery plan grouping all VMs (`az site-recovery recovery-plan create`).
2. Quiesce / notify; lower DNS TTL (e.g., 60s) a day prior.
3. Trigger **planned failover** per VM (`az site-recovery protected-item planned-failover`).
4. **Post-failover network wiring** (automated by the script):
   - Associate target NSG to each NIC
   - Assign new public IP
   - Add NICs to LB backend pool
5. Re-enable **Boot integrity monitoring** on the failed-over VM (ASR does not replicate this state).
6. Cut DNS / Traffic Manager to the new public IP.
7. Validate end-to-end with real traffic.
8. **Commit** the failover (`az site-recovery protected-item failover-commit`).

## Phase 6 — Decommission

**Script:** `05-decommission.sh`

After a soak period (e.g., 24–72h) and customer sign-off:
- Disable replication / remove ASR protected items
- Delete source VMs + disks (with confirmation prompt)
- Delete source snapshots if any
- Delete ASR cache storage account
- Keep the source VNet until DNS fully propagated

---

## Fallback: Manual snapshot migration

**Script:** `99-manual-snapshot-migration.sh`

Use this when ASR replication is blocked:
- Linux Trusted Launch VMs created **before 2024-04-01**
- ASR is unavailable or not eligible for specific VMs
- You need full control over the rebuild process

This path requires a maintenance window (stop VM → snapshot → cross-region copy → rebuild).

---

## Downtime profile

Continuous replication means the only downtime is the cutover window (planned failover + DNS swing),
typically minutes. The heavy lifting (seeding, dependency staging, test failover) happens while
source is fully live.

## Trusted Launch gotchas (put in change ticket)

- vTPM is NOT migrated — target gets a fresh vTPM. Escrow BitLocker/sealed secrets first.
- Boot integrity monitoring state is NOT replicated — re-enable post-failover.
- Security type (TrustedLaunch), Gen2, Secure Boot, vTPM are preserved by ASR for the VM itself.
- Public IP address always changes — plan DNS, never hard-coded IPs.
