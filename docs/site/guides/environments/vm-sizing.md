---
title: VM sizing
description: How much RAM, swap, CPU and disk an environment VM needs, and how to grow an Incus VM.
sidebar:
  order: 2
---

Condensed from [`docs/vm-sizing-and-provisioning.md`](https://github.com/QuarantineAl/platform/blob/main/docs/vm-sizing-and-provisioning.md),
which has the measurements behind every number. Both VMs are Incus (QEMU)
guests on one host, `homelab-ext`. Nothing in the repository creates or sizes
a VM; this is a manual procedure.

## The numbers

| | Minimum | Recommended |
|---|---|---|
| RAM | `2.5 GiB + sum of container memory limits - swap` | `2.5 GiB + sum of container memory limits` |
| Swap | **4 GiB, never zero** | 4 to 8 GiB |
| vCPU | 4 | 4, or 6 to 8 above four tenants |
| Disk | 100 GiB | 150 to 200 GiB where images are built |

2.5 GiB is the measured baseline for everything that is not an app container
(platform containers, dockerd/containerd, kernel). Lazzaretto's memory limit is
**1350 MiB** at concurrency 1, **1800** at 2, **2700** at 4 (the shared
instance and PR sandboxes use 4). `quarantine tenant add` and `upgrade-all`
warn when the limits on a host pass 85% of what it can back.

## Grow a VM's memory (needs an outage)

Incus 6.0 can shrink a running VM's memory but **cannot grow it** (no
hot-add). Growing needs a stop and start, which interrupts every app and kills
agent turns in flight. On the hypervisor host:

```bash title="homelab host"
sudo incus config get prod limits.memory
sudo incus stop prod --timeout 180 && sudo incus config set prod limits.memory 12GiB && sudo incus start prod
```

A reboot from inside the guest does not apply it. Everything restarts on its
own (`restart: unless-stopped`). Check from the guest:

```bash title="prod VM"
head -4 /proc/meminfo; free -h; docker ps --format '{{.Names}}\t{{.Status}}'
```

Shrinking is live: `sudo incus config set dev limits.memory 6GiB`.

## Guest checklist

```bash title="Inside a new VM: 4 GiB swap file"
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

```bash title="Confirm cgroup v2"
stat -fc %T /sys/fs/cgroup && docker info --format '{{.CgroupVersion}} {{.CgroupDriver}}'
```

Expect `cgroup2fs` and `2 systemd`. Leave `vm.swappiness` at 60.

## Things that bite

- Setting a container's `memswap_limit` equal to `mem_limit` (for example
  `docker update --memory 3g --memory-swap 3g`) **disables** swap for it.
- `docker update` is undone by the next recreate (`tenant upgrade`, deploys).
- Size from cgroup `anon` memory, not `docker stats`, which counts page cache.
- `.State.OOMKilled` stays true after an OOM event even if the container is
  still running; read `memory.events` for real kill counts.
