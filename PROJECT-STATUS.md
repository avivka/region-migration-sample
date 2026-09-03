# Project Status — ARCHIVED

**Project:** Edge CX region migration, `eastus` → `centralus` (ASR A2A, Trusted Launch VMs)
**Status:** **ARCHIVED 2026-08-31** — customer paused the project: initial-replication
throughput was too slow for their maintenance window (Azure hard-caps per-VM churn at
54 MB/s Normal / ~100 MB/s High Churn, and the subscription/region-pair pipeline is
shared across VMs; a bandwidth-increase support ticket was the recommended path).
**Owner:** Aviv Kabesa

---

## 1. Where things stand

### Delivered and validated end-to-end (test env, multiple full cycles)
- **Full pipeline** 00→06 runs clean: reset → stage → replicate → test failover →
  planned failover → parity audit.
- **Name mirroring:** destination resources carry the exact source names (VNet, subnet,
  NSG, LB + frontend/pool/probes/rules, PIPs). Parity audit: **0 unexpected diffs**.
- **Private-IP preservation:** validated at NIC **and in-guest** for test failover, and
  for planned failover (per-VM `source==destination MATCH`, committed). Mechanism:
  target subnet mirrors the source range + post-failover NIC enforcement (two-pass:
  park → claim, handles sibling VMs stealing each other's IPs).
- **DNS labels:** copied for per-VM PIPs and the LB PIP (test PIPs use the label
  verbatim; region suffix of the FQDN changes — documented).
- **Trusted Launch:** Secure Boot/vTPM/NVMe/LUNs preserved in every failover.
- **Ops hygiene:** timestamped per-run logs (`logs/`), per-VM `sync: N%` progress,
  stale-ASR deep-clean automation (from the Microsoft support action plan),
  Terraform recreate-template of the source env (`terraform/source-env-eastus/`,
  `plan: 32 to add`, validated).

### Customer (CX) environment — last known state
- 5 VMs (`andrei-test-migration-jakbs-001..005`) in `RG_TENANTS_EASTUS`, source IPs
  `192.168.1.4–.8`, synced to Protected several times.
- Their planned failover (pre-fix scripts) landed VMs in the stale **`vnet-target`
  (10.1.x)** — root cause: 02's old default target VNet + leftover VNet in
  `RG_TENANTS_centralus`; their test failover landed in the right VNet but with
  shuffled IPs (sibling test VMs grabbed each other's addresses).
- Both failure modes are addressed in the current scripts (see § 2), but **CX never
  re-ran with the fixed versions** before archiving.

## 2. Open items (start here on revival)

1. **Finish the hostile-repro validation of 04's pre-failover gate.**
   Status when archived: the gate correctly **refused** to fail over into a wrong VNet
   (safety half proven). The repoint PATCH (`selectedRecoveryAzureNetworkId` via
   UpdateVmProperties) did not read back within the verification window in the repro —
   debug was interrupted (run the PATCH with visible error output; check whether the
   GET simply lags or the call needs a different payload/api-version). Until green,
   treat "repoint an already-synced item" as unverified; re-staging 02 with the correct
   `--target-vnet` is the known-good path.
2. **CX re-run with fixed scripts** after cleaning their `vnet-target` leftovers and
   the wrongly-failed-over VMs (00-reset now purges committed items too).
3. **Replication speed** (the archive reason): file the bandwidth ticket (error 153001
   reference), enable High Churn policy, stagger enablement; see
   `asr-replication-speed-conclusions.md` for the math.
4. Test-env niceties: sandbox auto-deallocates VMs (start them before 02) and kernel
   auto-upgrades break the ASR agent (error 151141) — GRUB is pinned to a supported
   kernel; `02 --fix-kernel` exists but installs without pinning (pin logic proven
   manually, worth folding in).

## 3. Technical findings worth keeping (hard-won)

| # | Finding | Consequence |
|---|---|---|
| 1 | **Resource Mover doesn't support Trusted Launch VMs** | ASR A2A is the only managed path; public LBs aren't movable either — recreate + clone config |
| 2 | **ASR ignores `tfoStaticIPAddress`** (verified across 3 api-versions) | Test-failover IPs can't be pre-pinned → set the NIC IP post-boot + reboot (implemented in 03) |
| 3 | **`recoveryStaticIPAddress` pin is best-effort** — silently dropped if the item is unhealthy or the IP is outside the mapped subnet | Never hard-fail on the pin; enforce the IP post-failover (04 4e) and gate the network pre-failover (04 2b) |
| 4 | **The failed-over VM lands in whatever recovery network the protected item holds** — a NIC can never change VNets after creation | Wrong target VNet at enable time is unrecoverable at failover time; hence 04's abort-don't-failover gate |
| 5 | **Parallel failovers steal each other's wanted IPs** (dynamic allocation) | Two-pass park-then-claim IP assignment (03 + 04) |
| 6 | **Stale ASR artifacts make re-triggered sync slow/stuck** (orphaned blob + recovery snapshots, leftover mobility agent, error 151083 reboot-pending) | Deep-clean automation in 00-reset (extensions, cache SA **and its private endpoints**, snapshots, in-guest uninstall + reboot) — from the Microsoft support action plan |
| 7 | **Deleting the cache SA orphans its private endpoint**; 02's create-if-missing then skips it → enable fails with 150190 | 00-reset deletes cache PEs first; 02 recreates a `Disconnected` PE |
| 8 | **Mobility agent has a kernel support matrix** (151141) — auto-upgraded kernels break enable | Pin GRUB to a supported kernel (≤6.14 for Ubuntu 24.04 at time of writing) |
| 9 | **az CLI property casing varies by version** (`publicIpAddress` vs `publicIPAddress`) | All jq/JMESPath in these scripts handle both; do the same in new code |
| 10 | **Per-VM churn cap 54 MB/s (Normal) / ~100 (High Churn)**, shared region-pair pipeline | Set expectations; stagger; support ticket for bandwidth; this ultimately archived the project |
| 11 | DNS label is region-unique and part of the cloudapp FQDN | Same label works cross-region during migration; full-FQDN references must be repointed; test PIPs must be deleted before cutover claims the label |
| 12 | vTPM state and Boot-Integrity-Monitoring are **not** replicated | Escrow BitLocker keys pre-cutover; re-enable BIM post-failover |

## 4. Environment disposition (at archive time)

- **Subscription:** `c64fd005-…` (test). CX subscription (`40adf449-…`) not accessible
  from this tooling.
- **`rg-migration-test-eastus` (source):** 3 TL VMs + fabric, **live** (sandbox may
  auto-deallocate; VMs carry pinned 6.11 kernel). Fully captured as Terraform.
- **`rg-migration-test-centralus` (target):** last repro left synced/Protected items
  wired (deliberately) to a decoy `vnet-target`, plus staged `vnet-source` fabric.
  **Safe to wipe** with `00-reset-target.sh` — nothing of value.
- **Cost note:** if the pause is long, deallocate/decommission both RGs;
  `terraform/source-env-eastus/` recreates the source (infra only — no disk contents).

## 5. Revival checklist

1. `terraform apply` the source template (or verify the live env still matches: `06`).
2. Wipe target: `00-reset-target.sh … --source-rg … --deep-clean --force`.
3. Run 01 → 02 (correct `--target-vnet`!) → 03 → 04 → 06 in the test env; all green
   including per-VM IP MATCH lines.
4. Close open item #1 (repoint verification) with the hostile repro
   (decoy `vnet-target` → fixed 04 must repoint or abort).
5. Only then schedule CX: clean their target leftovers, re-sync, test failover,
   sign-off, cutover per `MIGRATION-PLAN.md` (dates were never set — plan is C-day
   relative).
