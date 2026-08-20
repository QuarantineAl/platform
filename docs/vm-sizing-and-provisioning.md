# VM sizing and provisioning

How to size an Incus VM for this platform, how to change one that is already
running, and the handful of things that bite if you do it the obvious way.

Written after a production incident in which agent turns were being killed
mid-run inside `quarantine-qualitech-lazaretto-backend`. The container's
ceiling was too low, and the VM had no swap, so memory pressure went straight
to a SIGKILL instead of slowing down. Every number below is measured on the
real hosts rather than estimated — where a figure came from a guess, it says
so.

- [The short version](#the-short-version)
- [The host](#the-host)
- [How to size a VM](#how-to-size-a-vm)
- [Creating a new VM](#creating-a-new-vm)
- [Changing an existing VM's memory](#changing-an-existing-vms-memory)
- [Guest setup checklist](#guest-setup-checklist)
- [Things that bite](#things-that-bite)
- [Open items](#open-items)

## The short version

| | Minimum | Recommended |
|---|---|---|
| RAM | `2.5 GiB + Σ app ceilings − swap` | `2.5 GiB + Σ app ceilings`, in RAM alone |
| Swap | **4 GiB, never zero** | 4–8 GiB |
| vCPU | 4 | 4, or 6–8 above four tenants |
| Disk | 100 GiB | 150–200 GiB on a host that also builds images |

`Σ app ceilings` is the sum of every container `mem_limit` on that VM. For
Lazaretto that is **1350 MiB** at concurrency 1, **1800 MiB** at 2 and
**2700 MiB** at 4 — see `apps/first-party/lazaretto/compose.yaml` for the model
and lazaretto's own `docs/PER_TENANT_CONTAINER_PLAN.md` §7a for its derivation.

Concretely, for `prod` as it stands (qualitech at concurrency 4, santec and
lumistry at 2, plus the shared catalog instance at 4):

```
2700 + 1800 + 1800 + 2700  = 9000 MiB of ceilings
                    + 2500 = 11500 MiB ≈ 11.2 GiB
```

So **prod should be 12 GiB**, not the 8 GiB it runs today. It survives at 8
only because ceilings are not reservations and two of the three tenants have
never run a turn.

## The host

`homelab-ext` (hostname `homelab`), and what is already committed on it:

| | |
|---|---|
| CPU | 16 threads — i7-11850H, 8 cores |
| RAM | 31.07 GiB (`MemTotal` 32,581,352 kB) |
| Swap | 8 GiB `/swap.img`, priority −2, 0 bytes used |
| Root | ext4 on LVM, 914 GiB, 558 GiB free |
| Hypervisor | Incus 6.0.0-1ubuntu0.3 (deb, not snap), QEMU, `memory-backend-memfd` |

| Consumer | GiB |
|---|---|
| VM guest RAM (2 × 8 GiB) | 16.00 |
| Host's own docker stack (10 containers) | 2.99 |
| Kernel slab, page tables, QEMU overhead | 0.76 |
| Non-docker host daemons (incusd, containerd, fail2ban, ollama, …) | ~0.40 |
| **Committed** | **≈ 20.15** |
| **Unallocated** | **≈ 10.9** |

**About 5–6 GiB of that 10.9 can safely move into the VMs.** The rest is not
spare: roughly 3 GiB is a page-cache floor (both VM disk images, docker
overlay2 and every volume share one ext4 root, so squeezing cache to zero slows
both VMs' disk I/O), and roughly 3 GiB is burst reserve for the host's own
services — **none of which has a memory limit**, and one of which is
`ollama.service`, uncapped and native, where a single model load is an instant
4–8 GiB.

| Move | Resulting host `MemAvailable` | Verdict |
|---|---|---|
| prod 8 → **12 GiB** | ≈ 7.5 GiB | **Safe. Recommended.** |
| prod 8 → 14 GiB | ≈ 5.5 GiB | Ceiling. Only with `ollama.service` stopped |
| prod **and** dev → 12 GiB | ≈ 3.5 GiB | Needs ~2.5 GiB of host slack reclaimed first |

If you need more than that, reclaim host slack before growing a VM. The
candidates, largest first: `stirling-pdf` (1.56 GiB at 0.16% CPU, uncapped
JVM), the `immich` stack (0.93 GiB), `uptime-kuma` (0.20 GiB). Masking
`ollama.service` removes the biggest latent spike vector on the box even though
it reclaims almost nothing today.

**What breaks first if you overshoot**, in order:

1. Page cache evicts — host and VM disk latency rises.
2. The host starts swapping VM RAM. This is a cliff, not a slope; see
   [Things that bite](#things-that-bite).
3. The host OOM killer fires **and it kills QEMU.** Both QEMU processes carry
   `oom_score = 804`, by far the highest on the box, and nothing protects them
   (`incus.service` has `memory.max = max`). That is a hard power-off of both
   VMs at once, not a container kill.

## How to size a VM

```
VM RAM  ≥  baseline + Σ app ceilings − swap
```

**Baseline is 2.5 GiB.** Measured on `prod`, and it is everything that is not
an application container:

| | MiB |
|---|---|
| Platform containers (traefik, postgres, zitadel ×2, searxng, portainer, runner, frontends, oauth2-proxies) | 1280 |
| `dockerd` + `containerd` anon + init/user slices | ~1030 |
| Unreclaimable slab + page tables | ~200 |
| **Baseline** | **~2510** |

Read that as a floor that grows with the platform, not a constant. Note that
`containerd.service` shows ~1.9 GiB of `memory.current`, but ~1.7 GiB of it is
reclaimable page cache for unpacked image layers — do not budget it as anon.

**Σ app ceilings** is a sum of `mem_limit` values, so it is the *theoretical*
simultaneous peak. Real load is lower, which is why a VM can run
oversubscribed. Which of the two numbers your RAM should cover is the whole
distinction between the two tiers:

- **Minimum** — RAM covers the realistic concurrent peak, swap covers the
  theoretical one. The VM works; it will swap during a broad peak, and a turn
  takes a one-off hiccup rather than dying.
- **Recommended** — RAM covers `baseline + Σ ceilings` on its own. Nothing
  swaps in normal operation and swap is purely a crash-avoidance backstop.

`provisioners/lazaretto-tenant.sh` warns when the ceilings on a host exceed
what it can back, so you will hear about it on the next `tenant add` or
`upgrade-all` rather than discovering it during an incident.

### vCPU

4 is enough for four tenants, and CPU is not what runs out: an agent turn burns
**0.5% CPU**, spending ~99.5% of its wall time blocked on API round-trips.
Builds are the real load. Two VMs at 4 vCPU each on a 16-thread host is
comfortable; oversubscribing is fine for work this I/O-bound.

One coupling to know about: a container's CPU quota also decides its memory
appetite, because Node reads the cgroup quota in `os.availableParallelism()`
and JS toolchains size worker pools from it. **Giving a VM more vCPU raises the
memory ceiling its containers need**, unless those containers pin `cpus`
(Lazaretto's does, at 2). Verified: uncapped reports 4, `--cpus 2` reports 2,
`--cpus 1.5` reports 1.

### Disk

146 GiB today with 13 GiB used, so disk is not tight — but image layers and
build cache grow without bound on a VM that also runs a CI runner
(`docker system df` on `dev` showed ~7.9 GiB of reclaimable build cache). 100
GiB minimum, 150–200 GiB where builds happen.

## Creating a new VM

Read an existing VM's config first and copy from it rather than from this
document — it is the live source of truth:

```bash
sudo incus config show prod --expanded
```

```bash
sudo incus remote list && sudo incus image list images: ubuntu/24.04 type=virtual-machine
```

Then launch, sizing per [How to size a VM](#how-to-size-a-vm):

```bash
sudo incus launch images:ubuntu/24.04 NAME --vm -c limits.cpu=4 -c limits.memory=12GiB -d root,size=150GiB
```

`limits.memory` is what becomes QEMU's `-m`, and it is the one value you cannot
raise later without a stop/start — so err high at creation time. Lowering it
later is live and free.

Then work through the [guest setup checklist](#guest-setup-checklist).

## Changing an existing VM's memory

**Growing needs a stop/start. Shrinking is live.** This asymmetry is the single
most important thing on this page, and it is not obvious from the CLI.

Incus 6.0.0 changes a running VM's memory by driving QEMU's **virtio-balloon**
over QMP. A balloon can only inflate — that is, take memory *away* from the
guest, down from the boot-time `-m`. It can never exceed it. `virtio-mem`, the
device that could hot-add memory, is **absent**: not merely unconfigured, the
string does not appear in the `incusd` binary at all. There are no DIMM hotplug
slots either (the guest has exactly 64 × 128 MiB blocks at 8 GiB, all online,
nothing beyond). And `limits.memory.hotplug` does not exist in this version —
the complete set of keys is `limits.memory`, `.enforce`, `.hugepages`, `.swap`
and `.swap.priority`.

So:

- `sudo incus config set prod limits.memory 12GiB` on a **running** VM cannot
  deliver 12 GiB. Incus asks the balloon for a size QEMU clamps to 8 GiB, the
  poll loop never sees the target, and after ~5 s you get
  `Failed setting memory to 12288MiB (currently 8192MiB) as it was taking too long`.
  The guest stays where it was.
- **A `reboot` from inside the guest does not help.** Same QEMU process, same
  `-m`. It has to be `incus stop` + `incus start`, which re-renders
  `qemu.conf`.
- Shrinking *does* apply live, which is a useful lever: live-shrink `dev` to
  hand RAM back to the host, then stop/start `prod` larger.

### Growing (needs an outage)

```bash
sudo incus config get prod limits.memory
```

```bash
sudo incus stop prod --timeout 180 && sudo incus config set prod limits.memory 12GiB && sudo incus start prod
```

Everything on the VM comes back by itself — `docker.service` is enabled and
every container is `restart: unless-stopped` or `always`. What does *not*
survive is any in-flight agent turn, so drain first if you can.

Verify from the host and then from inside the guest:

```bash
grep -E 'MemTotal|MemFree|MemAvailable|Shmem' /proc/meminfo && free -h
```

```bash
ssh prod-vm 'head -4 /proc/meminfo; free -h; docker ps --format "{{.Names}}\t{{.Status}}" | column -t; systemctl --failed'
```

Expect `MemTotal` ≈ 12,290,000–12,600,000 kB at 12 GiB — the guest loses ~290
MB of the nominal figure to e820-reserved regions, the same ratio as today's
8,102,648 kB out of 8,388,608 kB.

### Shrinking (live)

```bash
sudo incus config set dev limits.memory 6GiB
```

Applies immediately; the balloon inflates and QEMU `MADV_DONTNEED`s the freed
memfd pages, so host RSS drops within seconds. Reversible the same way, as long
as you stay at or below the boot-time `-m`.

### Rolling back

```bash
sudo incus stop prod --timeout 180 && sudo incus config set prod limits.memory 8GiB && sudo incus start prod
```

## Guest setup checklist

Everything here is inside the VM, where `sudo` is passwordless.

**1. Swap. Never skip this.** It is the difference between "a turn takes a
one-off hiccup" and "the kernel kills a turn".

```bash
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

4 GiB is sized against a worst-case overshoot of roughly one turn plus one
heavy tool run. Note that for **VM** instances this is a guest-side swapfile —
`limits.memory.swap` is a container-instance key and does nothing here.

Why it matters so much for this workload: at kill time the offending cgroup
held `anon 359 MiB` against `file 78 MiB`, a 4.6:1 ratio with swap
unavailable, so the only reclaimable pool was 78 MiB of page cache. The kernel
scanned 2.2M pages to steal 642K — 29% efficiency — then gave up and killed.
There was nothing to reclaim. That is the mechanical reason pressure was lethal
rather than merely slow.

And agent workloads swap unusually well. A turn burns 0.5% CPU, so at any
instant nearly every concurrent heap is cold; faulting 100 MB back on NVMe is
≈ 2 s once, amortised across a multi-minute turn.

**2. Confirm cgroup v2 with swap accounting**, which is what makes container
`memswap_limit` mean anything:

```bash
stat -fc %T /sys/fs/cgroup && docker info --format '{{.CgroupVersion}} {{.CgroupDriver}} {{range .Warnings}}{{println .}}{{end}}'
```

Expect `cgroup2fs`, version 2, driver `systemd`, and no swap-limit warning.

**3. Optional: correct the disk's rotational flag.** The guest sees
`/dev/sda` as rotational because virtio does not pass the hint through, and the
real backing is NVMe. This makes the kernel needlessly conservative about swap
readahead:

```bash
echo 'w /sys/block/sda/queue/rotational - - - - 0' | sudo tee /etc/tmpfiles.d/rotational.conf && sudo systemd-tmpfiles --create
```

**4. Leave `vm.swappiness` at 60** and `vm.overcommit_memory` at 0. There is no
per-cgroup swappiness in cgroup v2 (`memory.swappiness` does not exist —
Docker's `mem_swappiness` is a silent no-op), so this is a VM-wide setting and
the default is right. In particular **do not set
`vm.overcommit_memory=2` on the host**: its `Committed_AS` already exceeds
`CommitLimit` by ~2.3 GiB, and allocations would start failing instantly.

## Things that bite

**Setting `memswap_limit` equal to `mem_limit` disables swap entirely.** It
does not cap it — runc reads equal values as an explicit instruction and writes
`memory.swap.max = 0`. So `docker update --memory 3g --memory-swap 3g`, the
obvious way to widen a ceiling during an incident, silently removes the shock
absorber at the same moment. This is what left qualitech the only one of four
backends with swap disabled. Always set `memswap_limit` **above** `mem_limit`.

**`docker update` does not survive a redeploy.** It writes `HostConfig` on
disk, so the value survives a container restart and even a VM stop/start — but
`lazaretto-tenant.sh upgrade` and `compose up --force-recreate` *recreate* the
container and it reverts to the formula. A hand-widened ceiling is a stopgap
until the repo agrees with it.

**`free -h` double-counts the VMs on the host.** `buff/cache` includes `Shmem`,
and the VMs' memfd-backed RAM *is* shmem — 15.96 GiB of the host's 16.05 GiB
`Shmem` is the two QEMU processes. Real reclaimable page cache is
`Cached − Shmem + Buffers`, about 4.3 GiB, not the ~20 GiB the column shows.
`MemAvailable` is trustworthy: it correctly excludes shmem.

**A VM never gives memory back on its own.** memfd pages stay resident once
faulted, so a guest sitting at 2.4 GiB of internal `MemFree` still costs the
host its full 8 GiB. Plan for the whole `-m` of every VM as permanently
resident. The balloon is the only thing that returns it.

**Swapping VM RAM is a cliff, not a slope.** The guest kernel believes those
pages are DRAM and makes every scheduling and reclaim decision on that basis;
it cannot see the host-side fault, and freeing memory inside the guest does not
un-swap anything. It surfaces as unexplained multi-millisecond stalls with no
iowait and no steal to blame. `/swap.img` also shares one ext4 volume with both
VM disk images and docker overlay2, so swap I/O contends directly with VM disk
I/O. **Budget zero of the host's 8 GiB as usable VM RAM** — it buys a degraded
VM instead of a killed one, nothing more. That it sits at 0 bytes after six
days means the box has never been under real pressure, not that there is spare
capacity.

**`.State.OOMKilled` does not mean the container died.** It reflects a cgroup
OOM *event*, and stays `true` on a container that is still running happily. The
counters are the real record:

```bash
docker inspect -f '{{.Id}}' CONTAINER | xargs -I{} cat /sys/fs/cgroup/system.slice/docker-{}.scope/memory.events
```

`oom_kill` counts kills. A large `max` means the container is living *at* its
ceiling even when nothing is being killed — a sizing problem rather than a
runaway session. The qualitech backend read `max 13285` before it was resized.

**Do not size containers off `docker stats` or `memory.current`.** Both count
page cache the cgroup can reclaim under pressure. Worse, file-backed pages are
charged to whoever touched them first — `containerd.service`, which unpacked the
image — so `file_mapped` reads 0 in the tenant cgroups while per-task `rss_file`
sums to hundreds of MiB. Size off `anon`.

## Open items

- **`prod` should be 12 GiB.** It runs 8 against ~11.2 GiB of committed
  ceilings. Needs the stop/start above.
- **PR sandboxes on `dev` take the bare compose defaults** — concurrency 4 and
  a 2700 MiB ceiling each, with no per-PR scaling. Two concurrent sandboxes
  plus the shared instance is 8100 MiB of ceilings against a 7.7 GiB VM. They
  should be pinned to concurrency 1 (1350 MiB) by setting
  `LAZARETTO_CLI_MAX_CONCURRENT`, `LAZARETTO_MEM_LIMIT` and
  `LAZARETTO_MEMSWAP_LIMIT` where the sandbox is brought up
  (`QuarantineAl/.github`'s `pr-sandbox-up.yml`), not fixed in this repo.
- **No host container has a memory limit**, and neither `incus.service` nor
  `docker.service` has `MemoryMax`. Any one of them can consume the box, and
  the OOM killer will then pick QEMU over the offender. Capping them is worth
  more than the raw GiB it would reclaim.
- **Nothing in this repo provisions a VM.** The Incus instances were created by
  hand; there is no code that sizes them, configures guest swap, or sets
  sysctls. This document is the substitute for that automation.
