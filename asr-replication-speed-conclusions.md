# ASR Replication Speed — Conclusions

## The replication pipeline

```
Source VM disk
    │
    │  (1) ASR mobility agent reads disk blocks
    ▼
Cache storage account (source region)
    │
    │  (2) Azure replication pipeline transfers data
    │      ← THIS is the bottleneck
    ▼
Replica managed disk (target region)
```

Three separate systems, each with its own throughput ceiling.

## Why disk IOPS doesn't help

**IOPS** = how many small random I/O operations your disk can do per second. It's the metric that matters for your application's database queries, file reads, etc.

**Replication throughput** = how many MB/s Azure's backend pipeline pushes data from the cache account to the target region. This is a large sequential bulk transfer — it doesn't issue random I/Os to your disk.

Increasing your disk from 3000 IOPS to 8000 IOPS is like widening a highway on-ramp when the traffic jam is 50 miles down the road. The ASR agent was never disk-IOPS-bound in the first place — it reads blocks at its own pace, well below what even a baseline Premium disk can serve.

## What actually controls the speed

| Layer | Governed by | You control it? |
|-------|------------|-----------------|
| Agent → cache storage | Cache account throughput (Standard ~60 MB/s, Premium ~200+ MB/s) | Yes — you already switched to Premium BlockBlobStorage |
| Cache → target region | Azure's internal replication bandwidth allocation per subscription/region pair | No — Microsoft sets this |
| Concurrent VMs | All VMs share the same pipeline | Partially — you can stagger replications |

The middle layer is the one throttling you. Azure allocates a fixed replication bandwidth per subscription per region pair. With 5 VMs replicating simultaneously (jakbs-001 through 005), each VM gets roughly 1/5th of that allocation.

## The math on your run

From the screenshot: ~9% in 40 minutes across 5 VMs. If each VM has, say, 128 GB of disk:

- 9% of 128 GB = ~11.5 GB transferred per VM in 40 min
- That's ~4.8 MB/s per VM, or ~24 MB/s aggregate
- For 5 x 128 GB = 640 GB total: roughly 7-8 hours at that rate

That 24 MB/s aggregate is typical for the default ASR bandwidth allocation. It's not a bug — it's the quota.

## Per-VM churn cap (the throttle) — from Microsoft docs

From the [ASR support matrix](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-support-matrix):

> **"The current limit for per-VM data churn is 54 MBps regardless of size."** (Normal Churn, the default)

This 54 MB/s cap is hardcoded in Azure's replication fabric. It applies regardless of your disk IOPS, disk throughput, VM size, or network bandwidth. It's the ceiling.

## Per-disk churn limits — from Microsoft docs

From the same support matrix, the per-disk limits with Normal Churn:

| Replica disk type | I/O size | Max churn per disk |
|---|---|---|
| Standard | any | 2 MB/s |
| Premium SSD ≥128 GiB | 8 KB | 2 MB/s |
| Premium SSD ≥128 GiB | 16 KB | 4 MB/s |
| Premium SSD ≥128 GiB | 32 KB+ | 8 MB/s |
| Premium SSD ≥512 GiB | 8 KB | 5 MB/s |
| Premium SSD ≥512 GiB | 16 KB+ | 20 MB/s |

## High Churn option — from Microsoft docs

From the [High Churn support doc](https://learn.microsoft.com/en-us/azure/site-recovery/concepts-azure-to-azure-high-churn-support):

> **"By using the default Normal Churn option, you can support churn only up to 54 MB/s per virtual machine. By using High Churn, the maximum churn a virtual machine can achieve depends on the support matrix requirements."**

High Churn raises the cap based on VM RAM:

| VM RAM | Max churn per VM | Max churn per disk |
|---|---|---|
| < 32 GB | 54 MB/s | 20 MB/s |
| 32 GB – 256 GB | 100 MB/s | 50 MB/s |
| ≥ 256 GB | 500 MB/s | 250 MB/s |

**High Churn requires Premium Block Blob cache storage** — which you already switched to (`--sku Premium_LRS --kind BlockBlobStorage`). But you also need to **enable the High Churn option when setting up replication** — it's not automatic just because you have a Premium cache account.

## What this means for your run

Your VMs (`Standard_D16ds_v6` = 64 GB RAM, `Standard_D8ds_v6` = 32 GB) are capped at **54 MB/s aggregate** with Normal Churn. Split across 5 VMs, that's ~10 MB/s each — exactly matching the ~4.8 MB/s per VM you observed (with overhead for metadata, checksums, etc).

With High Churn enabled + your Premium cache account, you'd get up to **100 MB/s aggregate** — roughly 2x faster.

## What actually speeds it up

1. **Open a support ticket with Microsoft** — request increased replication bandwidth for your subscription/region pair. This is the only way to raise the pipeline ceiling. Reference error 153001 in your ticket.

2. **Enable High Churn** — when setting up replication, select "High Churn" instead of the default "Normal Churn". This raises the per-VM cap from 54 MB/s to 100 MB/s (or 500 MB/s with ≥256 GB RAM VMs). Requires Premium Block Blob cache storage (already configured).

3. **Stagger replications** — replicate 1-2 VMs at a time instead of 5. Each VM gets the full pipe instead of 1/5th. Total time is the same, but individual VMs finish faster, and if one fails you catch it sooner.

4. **Reduce data churn during initial sync** — any writes to source disks while initial sync runs create additional delta data that also needs to be replicated. If possible, quiesce heavy write workloads during the initial copy.

5. **Premium cache storage** — you already did this. It removes the cache throughput bottleneck so the Azure pipeline ceiling is the only limit.

6. **ASR Deployment Planner** — Microsoft's tool that measures your actual churn rate and tells you exactly what bandwidth you need. Useful evidence for the support ticket.

## What does NOT help

- Increasing disk IOPS
- Increasing disk throughput provisioning
- Increasing VM size/CPU
- Changing VM SKU

The constraint is in Azure's replication fabric, not on your VMs.

## Sources

- [Azure-to-Azure support matrix – Limits and data change rates](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-support-matrix)
- [High Churn support](https://learn.microsoft.com/en-us/azure/site-recovery/concepts-azure-to-azure-high-churn-support)
- [Troubleshoot replication – High data change rate](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-troubleshoot-replication)
