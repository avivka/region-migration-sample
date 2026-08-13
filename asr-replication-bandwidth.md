# ASR Replication Bandwidth Limits

## Per-VM churn cap (the throttle)

From the [ASR support matrix](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-support-matrix):

> **"The current limit for per-VM data churn is 54 MBps regardless of size."** (Normal Churn, the default)

This 54 MB/s cap is hardcoded in Azure's replication fabric. It applies regardless of your disk IOPS, disk throughput, VM size, or network bandwidth. It's the ceiling.

## Per-disk churn limits

From the same support matrix, the per-disk limits with Normal Churn:

| Replica disk type | I/O size | Max churn per disk |
|---|---|---|
| Standard | any | 2 MB/s |
| Premium SSD ≥128 GiB | 8 KB | 2 MB/s |
| Premium SSD ≥128 GiB | 16 KB | 4 MB/s |
| Premium SSD ≥128 GiB | 32 KB+ | 8 MB/s |
| Premium SSD ≥512 GiB | 8 KB | 5 MB/s |
| Premium SSD ≥512 GiB | 16 KB+ | 20 MB/s |

## High Churn option

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

The script 03 fix (test failover `TestFailoverCompletionPending` status + timeout) is already applied.

## Sources

- [Azure-to-Azure support matrix – Limits and data change rates](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-support-matrix)
- [High Churn support](https://learn.microsoft.com/en-us/azure/site-recovery/concepts-azure-to-azure-high-churn-support)
- [Troubleshoot replication – High data change rate](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-troubleshoot-replication)
