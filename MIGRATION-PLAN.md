# Edge CX Region Migration Plan

**Migration:** Edge CX workload, `eastus` → `centralus`
**Method:** Azure Site Recovery (A2A) continuous replication with planned failover
**Tooling:** Scripts `01`–`05` in this repo (see [RUNBOOK.md](RUNBOOK.md))
**Owner:** Aviv Kabesa
**Status:** Draft — pending sign-off; **calendar dates TBD, to be aligned in the planning meeting**

> Timeline notation: the plan spans **5 consecutive weeks** expressed as *Week N, Day N*
> (Day 1 = Monday). Cutover-adjacent steps are anchored to **C = cutover day** (C−2d, C+3d, …).
> Only the anchors move when dates are agreed; all durations and lead-time constraints below are
> fixed requirements.

---

## 1. Executive summary

Migrate the Edge CX VMs (Gen2, Trusted Launch, NVMe) plus their network fabric from East US to
Central US with near-zero downtime. ASR replicates continuously while the source stays live; the
only customer-visible downtime is the cutover window (planned failover + DNS swing), targeted at
**under 30 minutes**.

Azure Resource Mover is **not** an option — it does not support Trusted Launch VMs. ASR is the
supported path (Windows TL: GA; Linux TL: GA for VMs created after 2024-04-01; older Linux TL VMs
use the manual snapshot fallback `99-manual-snapshot-migration.sh`).

> **Open item — downtime behavior:** before the cutover plan is finalized, we must map how the
> user flow and the agents' data stream work end-to-end: how agents connect and reconnect, whether
> data is buffered or dropped while the service is unreachable, and what users experience during
> the window. This determines what actually happens during the cutover downtime (data loss vs.
> delayed delivery vs. transparent reconnect) and what mitigations or comms are needed. To be
> covered in the alignment meeting; feeds sections 6 and 7.

| Milestone | When |
|---|---|
| Pre-flight + target fabric staged | End of Week 1 |
| Replication enabled, initial sync complete | End of Week 2 |
| Test failover validated + sign-off | Mid Week 3 |
| DNS TTL lowered to 60s | C−2 days (≥48h before cutover) |
| **Production cutover** | **C-day — Week 4, 3-hour evening window (date/time TBD)** |
| Soak period ends, failover committed | C+3 days |
| Source decommission begins | C+5 days (start of Week 5) |

---

## 2. Scope

### In scope (from `source-inventory.json`)

| VM | Size | RAM | Security | Disk ctrl | Data disks |
|---|---|---|---|---|---|
| vm-test-01 | Standard_D16ds_v6 | 64 GB | TrustedLaunch (SB + vTPM) | NVMe | 1 × Premium_LRS (LUN 0) |
| vm-test-02 | Standard_D8ds_v6 | 32 GB | TrustedLaunch (SB + vTPM) | NVMe | 1 × PremiumV2_LRS (LUN 0) |
| vm-test-03 | Standard_D2ds_v6 | 8 GB | TrustedLaunch (SB + vTPM) | NVMe | 1 × Premium_LRS (LUN 0) |

Plus: VNet + subnets, NSGs (`nsg-workload`), NICs, Load Balancer (name mirrored source → target,
backend pool `bepool`), new target-region public IP (same name + DNS label as source), Recovery
Services vault. **All destination resources keep the source names verbatim** (region migration —
only the region and IP addresses change); this requires source and target to be in different RGs.

### Division of labor

- **ASR replicates:** VMs + Trusted Launch profile (Secure Boot, vTPM) + OS and data disks.
- **Pre-staged in target (script 01):** VNet/subnets, NSGs, LB, public IPs, vault. ASR does **not** replicate NSGs.
- **Post-failover wiring (script 04):** NSG-to-NIC association, public IP assignment, LB backend membership.

### Out of scope / handled separately

- PaaS dependencies (storage accounts, Key Vault, databases) — inventory and move/re-create before cutover.
- DNS zone hosting itself (records change; the zone does not move).

> ⚠️ **PremiumV2_LRS check:** vm-test-02's data disk is Premium SSD v2. Verify ASR A2A support for
> PremiumV2 target disks in `centralus` during pre-flight (Phase 0) — if unsupported, plan the
> snapshot fallback for that disk or convert SKU first.

---

## 3. Week-by-week timeline

### Week 1 — Pre-flight & staging

| Day | Task | Tool |
|---|---|---|
| Day 1–2 | Pre-flight checks (section 4) — quota, SKU/NVMe availability in centralus, Linux TL creation dates, encryption/CMK audit, PremiumV2 support check | manual + `01-preflight-and-stage.sh` (dry run) |
| Day 2 | DNS audit: enumerate every record pointing at Edge CX (A, CNAME, Traffic Manager endpoints); record current TTLs (section 6) | DNS provider |
| Day 3 | Open Microsoft support ticket: request increased ASR replication bandwidth for subscription/region pair eastus→centralus (reference error 153001) | Azure support |
| Day 3–4 | Stage target fabric: vault, VNet/subnets (same address space to retain private IPs), NSGs, LB, public IP | `01-preflight-and-stage.sh` |
| Day 4 | Create ASR cache storage account — **Premium BlockBlobStorage**, private endpoint, no public network access, least-privilege RBAC | script 02 prereq |
| Day 5 | Review staged fabric, freeze target config. **Milestone: fabric staged** | — |

### Week 2 — Replication

| Day | Task | Tool |
|---|---|---|
| Day 1 | Enable ASR replication with **High Churn** policy (not the default Normal Churn — see section 5). **Stagger: 1–2 VMs at a time**, largest first (vm-test-01, then 02, then 03) | `02-enable-asr-replication.sh` |
| Day 1–4 | Monitor initial sync; quiesce heavy write workloads where possible to reduce churn | Azure portal / vault |
| Day 5 | Confirm all VMs show *Protected* with healthy RPO. **Milestone: sync complete** | — |

### Week 3 — Test failover & sign-off

| Day | Task | Tool |
|---|---|---|
| Day 1 | Prep isolated test VNet (no connectivity to source) | — |
| Day 2 | **Test failover** all VMs: validate Secure Boot + vTPM boot path, NVMe controller, data disk LUNs, application health | `03-test-failover.sh` |
| Day 3 | Fix any findings, re-test if needed; clean up test failover. **Milestone: sign-off** | `03-test-failover.sh` |
| Day 4 | Build recovery plan; write & circulate change ticket (include Trusted Launch gotchas, section 8); customer comms sent | `04-planned-failover.sh` (plan-only) |
| Day 5 | Escrow BitLocker/vTPM-sealed secrets (target gets a **new** vTPM — sealed state does not migrate) | — |

### Week 4 — Cutover & soak

| When | Task |
|---|---|
| C−2d | **Lower DNS TTL to 60s** on all Edge CX records (≥48h before cutover, exceeds the 24h minimum) |
| C−1d | Go/no-go review: RPO healthy, TTL propagated (verify with `dig` from multiple resolvers), rollback plan rehearsed |
| **C-day, evening window** | **Production cutover** — see section 7 runbook |
| C+1d → C+3d | Soak: monitor with real traffic, keep source VMs stopped-but-intact for rollback |
| C+3d | Commit failover (`failover-commit`) after sign-off; **restore DNS TTLs** to normal values |

### Week 5 — Decommission

| When | Task | Tool |
|---|---|---|
| C+5d | Disable replication, delete source VMs/disks/snapshots, delete ASR cache storage account | `05-decommission.sh` |
| C+5d | **Keep source VNet** until DNS fully propagated globally (verify no residual traffic hits old public IP for 72h first) | — |
| C+9d or later | Delete source VNet + RG; close change ticket | — |

---

## 4. Phase 0 pre-flight checklist (gate for Week 1)

- [ ] **OS + creation date:** Windows TL → OK. Linux TL → OK only if created after 2024-04-01; otherwise mark for `99-manual-snapshot-migration.sh`.
- [ ] **Target capacity:** `Dds_v6` sizes with NVMe available + quota in `centralus` (v6/NVMe is not in every region).
- [ ] **Disk controller:** target sizes support NVMe (all three VMs are NVMe).
- [ ] **PremiumV2_LRS:** confirm ASR A2A support for vm-test-02's data disk SKU in centralus.
- [ ] **Encryption:** if CMK/DES — create DES + Key Vault in centralus first (Key Vault does not move). BitLocker keys escrowed.
- [ ] **Address space:** target subnets use the same address space to retain private IPs; source and target VNets must **not** be peered simultaneously during transition.
- [ ] **DNS record inventory complete** (section 6) with current TTLs captured.
- [ ] **Cache storage account:** Premium BlockBlobStorage, private endpoint only, public network access disabled, least-privilege RBAC.
- [ ] **Bandwidth ticket** filed with Microsoft (error 153001 reference); optionally run ASR Deployment Planner for evidence.

---

## 5. Replication sizing & speed

From `asr-replication-speed-conclusions.md`:

- Default **Normal Churn** caps replication at **54 MB/s per VM** regardless of disk IOPS/VM size — do not waste effort raising IOPS.
- **Enable High Churn** at replication setup (requires the Premium BlockBlob cache account, which we have): vm-test-01 (64 GB RAM) and vm-test-02 (32 GB) → up to **100 MB/s**; vm-test-03 (8 GB) stays at 54 MB/s.
- The subscription/region-pair pipeline is shared across concurrently replicating VMs — **stagger** enablement rather than starting all at once.
- Budget realistically: at the observed ~24 MB/s aggregate, ~640 GB takes 7–8 h. Week 2 allows 4 days of margin; if the bandwidth ticket lands, sync will finish early.

---

## 6. DNS change plan

### 6.1 Inventory (complete Week 1, Day 2)

Enumerate every record resolving to Edge CX in eastus:

| Record | Type | Current target | Current TTL | Owner/zone | Notes |
|---|---|---|---|---|---|
| `edge-cx.<domain>` | A / CNAME | eastus LB public IP | *(capture)* | *(capture)* | primary entry point |
| *(any regional aliases, api endpoints, monitoring probes…)* | | | | | |

Also check: hard-coded IPs in app configs, firewall allowlists at customers, third-party
integrations pinned to the eastus IP. **The public IP always changes** in this migration — anything
pinned to the IP breaks silently.

### 6.2 TTL strategy

- **C−2d:** lower TTL on all records to **60s**. This is ≥48h before cutover (runbook minimum is 24h).
- Verify propagation from multiple public resolvers (`dig +noall +answer @1.1.1.1`, `@8.8.8.8`) before go/no-go at C−1d.
- **C+3d** (after commit): restore TTLs to standard values (e.g., 3600s).

### 6.3 Cutover mechanics (during the C-day window)

1. Script 04 outputs the new centralus public IP (LB PIP keeps the source name, e.g. `pip-source-lb`).
2. Update A records to the new IP (or repoint CNAME / swap Traffic Manager endpoint priority if fronted).
3. With 60s TTL, client convergence is minutes; validate resolution from several resolvers and a client on a different network.
4. Watch source LB metrics — traffic to the old IP should decay to ~zero. Residual traffic after 1h = a cached resolver or a pinned client; chase it before decommission.

### 6.4 DNS rollback

Rollback is a DNS revert: point records back at the eastus IP (still live until failover commit).
With 60s TTL this takes effect in minutes. This is why we do **not** commit the failover until the
soak completes (C+3d) and do not decommission until Week 5.

### 6.5 Optional hardening (recommended if time permits in Week 1)

Front `edge-cx` with **Azure Traffic Manager or Front Door** before the migration. Cutover then
becomes an endpoint swap with health-probe-driven failback, independent of client DNS caching.
Decision point: Week 1, Day 3.

---

## 7. Cutover-day runbook — C-day, 3-hour evening window (date/time TBD)

| Time | Step | Tool / command |
|---|---|---|
| C−7d | Recovery plan built and reviewed | `az site-recovery recovery-plan create` (script 04) |
| C−48h | DNS TTL at 60s, propagation verified | DNS provider |
| C−24h | Go/no-go: RPO < 15 min on all VMs, change ticket approved, on-call staffed | — |
| T−1h | Freeze deployments; notify stakeholders; quiesce writers where possible | comms |
| **T-0 (window start)** | Planned failover per VM via recovery plan | `04-planned-failover.sh` |
| T+15m | Script wires network: NSG→NIC, public IP, LB backend pool | script 04 (automatic) |
| T+20m | Re-enable **Boot integrity monitoring** on each VM (not replicated by ASR) | portal / CLI |
| T+25m | Smoke test against new public IP directly (bypass DNS via hosts-file override) | — |
| **T+30m** | **Cut DNS** to new IP (section 6.3) | DNS provider |
| T+45m | End-to-end validation with real traffic; confirm Secure Boot/vTPM, LUNs, app health | — |
| T+2h | Monitor stable → declare success; **do not commit yet** | — |
| C+3d | Commit failover after soak + sign-off | `az site-recovery protected-item failover-commit` (script 04 `--skip-commit` was used at T-0) |

**Abort criteria (any → rollback):** VM fails Trusted Launch boot, data disk missing/wrong LUN,
application health checks fail for >30 min, data integrity concern.

**Rollback procedure:** revert DNS to eastus IP (minutes at 60s TTL) → start source VMs if stopped →
verify source healthy → do NOT commit failover → schedule post-mortem. Source remains fully intact
until decommission (Week 5).

---

## 8. Change-ticket callouts (Trusted Launch gotchas)

- vTPM is **not** migrated — target VMs get a fresh vTPM. BitLocker/sealed secrets must be escrowed before cutover (Week 3, Day 5).
- Boot integrity monitoring state is **not** replicated — re-enable post-failover (in runbook, T+20m).
- Security type (TrustedLaunch), Gen2, Secure Boot, and vTPM settings **are** preserved by ASR.
- Public IP **always changes** — DNS-only references; no hard-coded IPs anywhere.
- PIP **DNS labels** are copied to the target by script 04, but the cloudapp FQDN's **region suffix
  changes** (`<label>.eastus.cloudapp.azure.com` → `<label>.centralus.cloudapp.azure.com`) — audit
  and repoint anything referencing the full cloudapp FQDN.
- NSGs are **not** replicated by ASR — pre-staged by script 01, wired by script 04.

---

## 9. Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Initial sync slower than window | Medium | Schedule slip | High Churn + staggering + bandwidth ticket filed Week 1; 4 days of margin in Week 2 |
| PremiumV2 disk unsupported by ASR target | Medium | vm-test-02 blocked | Pre-flight check Week 1, Day 1–2; fallback: snapshot path or SKU convert before replication |
| Trusted Launch boot failure in target | Low | Cutover abort | Mandatory test failover (Week 3, Day 2) proves the boot path first |
| Client pinned to old public IP | Medium | Partial outage post-cutover | DNS/config audit Week 1, Day 2; monitor residual source traffic before decommission |
| centralus capacity for D*ds_v6 + NVMe | Low | Re-plan sizes | Quota check + reservation in pre-flight |
| DNS propagation stragglers | Low | Slow convergence | 60s TTL 48h ahead; keep source alive through soak; optional Traffic Manager fronting |

---

## 10. Roles & communications

| Role | Responsibility |
|---|---|
| Migration lead | Runs scripts, owns go/no-go |
| Network/DNS owner | TTL changes, record cutover, rollback |
| App owner | Health validation at test failover and cutover |
| Customer comms | T-7d notice, T-24h reminder, cutover start/complete, post-soak confirmation |

Comms checkpoints: change ticket approved by **end of Week 3**; customer notice at **test-failover
sign-off (Week 3, Day 4)**; maintenance window announcement once the **C-day date/time is agreed**;
all-clear after soak (**C+3d**).
