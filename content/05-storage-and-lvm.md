---
title: Storage and LVM
type: module
track: linux-internals
tags: [linux-internals, storage, block-layer, lvm, device-mapper, dm-crypt, md-raid, nvme, multipath, observability]
requires: [Rocky 9.x VM with root, loop-device and device-mapper kernel support, "packages: lvm2 cryptsetup mdadm blktrace bpftrace fio device-mapper-persistent-data", "BTF/CO-RE for eBPF labs (biolatency/bpftrace)"]
module_number: 5
status: reviewed
created: 2026-07-08
---

# 05 - Storage and LVM

Backlink: [[00 - Track Overview]]

> The storage stack is the deepest vertical slice in the kernel: a single `write()` traverses the VFS, the page cache, the filesystem, the block layer, one or more device-mapper targets, an I/O scheduler, a driver's submission queue, and finally hardware. Every layer reorders, merges, caches, or defers. A staff engineer can name which layer is lying when `iostat` says the disk is 100% busy but the application is idle, or when `df` says there's free space but every write returns `ENOSPC`. This module is about owning that vertical slice end to end.

---

## Concept deep-dive

### The shape of the stack

```
 write(2) / read(2) / fsync(2)
        │
   ┌────▼─────────────────────────────────────────────┐
   │ VFS  (dentry, inode, file, address_space)         │
   └────┬─────────────────────────────────────────────┘
        │  page cache (dirty pages, writeback via pdflush/wb)
   ┌────▼─────────────────────────────────────────────┐
   │ Filesystem (ext4 / XFS): maps file offset → LBA   │
   │  builds struct bio (segments = pages + offsets)   │
   └────┬─────────────────────────────────────────────┘
        │  submit_bio()
   ┌────▼─────────────────────────────────────────────┐
   │ Block layer (blk-mq)                              │
   │  bio → request; per-CPU software queues (ctx)     │
   │  optional I/O scheduler (mq-deadline/bfq/kyber)   │
   │  hardware dispatch queues (hctx)                  │
   └────┬─────────────────────────────────────────────┘
        │  (device-mapper targets stack HERE as virtual bdevs)
   ┌────▼─────────────────────────────────────────────┐
   │ dm targets: linear│stripe│crypt│thin│snapshot│mpath│
   │ md/RAID (separate personality layer)              │
   └────┬─────────────────────────────────────────────┘
   ┌────▼─────────────────────────────────────────────┐
   │ Low-level driver (nvme, scsi/sd, virtio-blk)      │
   │  SQ/CQ rings (NVMe), doorbells, MSI-X, IRQ/NAPI   │
   └────┬─────────────────────────────────────────────┘
        ▼  hardware (controller FTL, disk cache, platters/NAND)
```

Two things are worth internalizing before anything else:

1. **The block layer is asynchronous by design.** `submit_bio()` returns almost immediately; completion happens later in an interrupt/softirq or a poll context. Latency you measure at the syscall boundary is queueing + service, and the two are separable (that's the whole point of `blktrace` Q2D vs D2C, below).
2. **device-mapper targets *are* block devices.** A dm device consumes bios and re-emits (possibly remapped, split, or duplicated) bios to underlying block devices. This recursion is why you can stack `dm-crypt` on top of `dm-thin` on top of `md` on top of `nvme` and it just works: each layer speaks the same bio protocol.

### The block layer: bio, request, and blk-mq

The fundamental I/O unit is `struct bio` (defined in `include/linux/blk_types.h`). A bio describes a contiguous *device* region (a starting sector + length, `bi_iter`) scattered across possibly-noncontiguous *memory* (a vector of `bio_vec`, each a `{page, offset, len}`). This scatter/gather is why zero-copy works: the DMA engine walks the bio_vec.

A `struct request` (in `include/linux/blk-mq.h`) is a *collection of adjacent bios* plus driver bookkeeping. Merging adjacent bios into one request is one of the block layer's main jobs; a single 1 MB request is far cheaper than 256 × 4 KB requests at the hardware doorbell.

**blk-mq (multi-queue), the only block layer since kernel 5.0** (the legacy single-queue request layer was removed): it is built around two queue tiers.

- **Software queues** (`struct blk_mq_ctx`), one per CPU. Submission from a CPU lands in that CPU's ctx with no cross-CPU lock. This is the scalability fix: the old single request queue had one `queue_lock` that became the bottleneck on many-core boxes driving millions of IOPS.
- **Hardware queues** (`struct blk_mq_hw_ctx`, "hctx"), mapping to what the device actually exposes. For NVMe, each hctx maps to one NVMe **SQ/CQ pair** with its own MSI-X interrupt vector, so completions are steered back to the submitting CPU. A cheap SATA disk has one hctx; a modern NVMe drive has one per CPU.

The mapping ctx→hctx is in `/sys/block/<dev>/mq/`. Count the directories to see the hardware queue depth:

```
$ ls /sys/block/nvme0n1/mq/
0  1  2  3  4  5  6  7
$ cat /sys/block/nvme0n1/mq/0/nr_tags     # per-hctx queue depth
1023
```

**Plugging** (`blk_start_plug`/`blk_finish_plug`): the kernel batches submissions on a per-task "plug" list so it can merge and sort before flushing to the hctx. A process doing many small sequential writes gets them coalesced. When you see huge `rrqm/s` or `wrqm/s` (merges) in `iostat -x`, that's plugging + the scheduler at work.

**Failure/scale behavior:** the visible queue depth ceiling is `nr_requests` (`/sys/block/<dev>/queue/nr_requests`). When it's exhausted, submitters block in `blk_mq_get_tag()` waiting for a free tag, and that time shows up as elevated `await` in iostat that is *not* device latency. This is the classic "the disk isn't slow, the queue is full" case.

### I/O schedulers under blk-mq

Schedulers are pluggable elevators sitting between the software queues and dispatch. Live in `/sys/block/<dev>/queue/scheduler` (brackets show the active one):

```
$ cat /sys/block/sda/queue/scheduler
[mq-deadline] kyber bfq none
```

- **none** — FIFO passthrough, no reordering. Correct default for NVMe and fast SSDs: the device's internal FTL reorders far better than the kernel can, and scheduler CPU overhead just steals IOPS. NVMe defaults to `none`.
- **mq-deadline** — two sorted queues (read, write) plus deadline expiry (default 500 ms read, 5 s write). Prevents starvation by forcing an expired request out of sort order. Safe general-purpose default for SATA/SAS SSDs and rotational disks; the choice when you want bounded latency.
- **bfq** (Budget Fair Queueing) — proportional-share, per-cgroup/per-process fairness with heuristics for interactive workloads. Expensive per-request; shines on rotational disks and desktops with contending processes. Rarely right for a database on NVMe.
- **kyber** — latency-target scheduler for fast devices; throttles based on measured read/write latency targets. Niche.

The senior read: **scheduler choice is a latency-vs-throughput-vs-fairness tradeoff, and on NVMe the answer is almost always `none`.** RHEL/Rocky set this per device class via udev rules (`/usr/lib/udev/rules.d/60-block-scheduler.rules`) keyed on the `queue/rotational` attribute.

### device-mapper: the virtualization layer

device-mapper (dm) is a kernel framework (`drivers/md/dm*.c`) that builds virtual block devices from *targets*. Each dm device has a **table**: a list of `start length target-type target-args` rows mapping regions of the virtual device to targets. Inspect the live table with `dmsetup table`:

```
$ dmsetup table vg0-root
0 41943040 linear 259:0 2048
```

That reads: sectors 0..41943040 of `vg0-root` are a `linear` remap onto major:minor `259:0` starting at sector 2048. **LVM is a userspace metadata manager that programs dm tables.** `lvs`/`vgs` read metadata; the actual I/O path is pure device-mapper. When `lvs` disagrees with reality, `dmsetup table` and `dmsetup status` are ground truth.

Targets you must know (all documented under `Documentation/admin-guide/device-mapper/`):

| Target | What it does | The failure mode to know |
|---|---|---|
| `linear` | 1:1 remap (the building block of LVM LVs) | none interesting |
| `striped` | RAID0 across devices | one leg dies → whole LV dead |
| `snapshot` / `snapshot-origin` | COW exception store | store fills → snapshot **invalid** |
| `thin` / `thin-pool` | shared pool, allocate-on-write, B-tree metadata | pool full → I/O errors or queue |
| `crypt` | dm-crypt transparent encryption | wrong cipher/key → garbage, not error |
| `multipath` | path failover/grouping | all paths down → queue or fail |
| `dm-cache` / `dm-writecache` | SSD cache in front of HDD | writeback semantics |
| `dm-verity` | read-only Merkle-tree integrity | hash mismatch → EIO (verified boot) |
| `dm-integrity` | per-sector checksums/journaling | detects bit rot |

`dmsetup status` gives per-target *runtime* state (e.g., thin-pool used blocks, snapshot store fullness, multipath path status). This is the single most under-used forensic command in the storage stack.

### LVM on-disk anatomy

Three logical tiers: **PV** (physical volume) → **VG** (volume group) → **LV** (logical volume). The mechanism:

- **PV label** lives in the second 512-byte sector by default (`label_header`, magic `LABELONE`), pointing at the **metadata area (MDA)**. The MDA holds the VG metadata as *human-readable text* (a small config-language blob), stored in a ring buffer so the previous copy survives a torn write. This is why `/etc/lvm/archive/` and `/etc/lvm/backup/` exist and why `vgcfgrestore` can rewind a VG to a prior metadata generation. **The text metadata is the crown jewel: back it up, and you can recover from almost any PV-header disaster.**
- **PE (physical extent)** is the allocation unit on a PV, default 4 MiB. **LE (logical extent)** is the LV-side unit. An LV is fundamentally a map of LEs → PEs, which dm expresses as one or more `linear`/`striped` table rows. `pvdisplay --maps` / `lvdisplay --maps` show the extent mapping.

```
PV (/dev/sdb)   VG (vg0)                LV (data)
┌───────────┐   allocates PEs           LE0 → PE12
│ label     │   into LVs                LE1 → PE13
│ MDA (text)│                           LE2 → PE14  (linear run)
│ PE0 PE1 …│  ───────────────────────▶ …
└───────────┘
```

Because it's just an extent map, `lvextend` is trivial (append extents + reload the dm table with no I/O interruption). `lvreduce` is dangerous: it truncates the map, and if the filesystem wasn't shrunk first you've cut off live data. **XFS cannot shrink at all**, which is why "grow the LV, grow the FS" is safe but the reverse is a footgun.

### LVM snapshots: the COW exception store and the freeze failure

A traditional (thick) LVM snapshot creates a `snapshot-origin` target on the origin and a `snapshot` target backed by a separate **COW exception store** LV. On the first write to any origin chunk after the snapshot is taken, the *original* chunk is copied to the exception store, then the write proceeds. Reads of the snapshot check the exception store (changed chunks) then fall through to the origin.

```
Origin write to chunk N (post-snapshot):
  1. read old chunk N from origin
  2. write old chunk N → COW store   ← the "copy" in copy-on-write
  3. record exception (N → store loc) in store metadata
  4. write new data to origin chunk N
```

**The failure mode every senior must know:** if the COW store fills (100% in `lvs` `Data%`), the snapshot is **dropped/invalidated** — it becomes unreadable, and you lose the point-in-time view. In older behavior a full store could stall the origin. This is why thick snapshots are only for short-lived operations (a consistent backup window), sized generously, and monitored. Write amplification is real: every first-touch write to the origin becomes read+write+write.

### Thin provisioning (dm-thin): allocate-on-write and the ENOSPC cliff

`thin-pool` decouples *allocated* from *provisioned*. A pool has a **data device** and a **metadata device**. Thin LVs claim virtual size up front but consume pool data blocks only on first write (allocate-on-write). The metadata is a **B-tree** (managed by `dm-persistent-data`, `drivers/md/persistent-data/`) mapping (thin-dev-id, virtual block) → pool physical block, with reference counts that make **thin snapshots O(1)**: a snapshot just shares the mapping tree and bumps refcounts; divergence copies blocks lazily. This is strictly better than thick snapshots for most uses.

Metadata is written in **transactions** with a superblock commit; a power cut mid-transaction leaves the previous consistent tree intact (the new tree isn't referenced until the superblock flips). Repair tooling is `thin_check` / `thin_repair` / `thin_dump` from `device-mapper-persistent-data`.

**The cliff:** because you overprovision, the pool data device can be exhausted while thin LVs still believe they have space. When data hits 100%, the pool enters an error/queue mode (`error_if_no_space` vs the default queue-then-timeout) and writes fail with EIO or hang. **Worse: if the *metadata* device fills, the pool goes read-only and requires offline repair.** Always monitor both `Data%` and `Meta%` in `lvs`. Set `thin_pool_autoextend_threshold` in `lvm.conf` so the pool grows before the cliff. This is the mechanism behind "the VM host wedged all guests at once" incidents.

### md/RAID: superblocks, the write hole, and rebuild math

md (`drivers/md/`) is a separate layer from dm (though both live under `drivers/md/`). `mdadm` manages arrays whose member disks carry a **metadata superblock**. Default is **v1.2** (superblock 4 KiB from the start of the device — survives being mistaken for a whole-disk filesystem, unlike the old v0.90 at the end).

Know the failure physics:

- **The RAID5/6 write hole.** A stripe write is non-atomic: data blocks and parity are separate writes. A crash between them leaves parity inconsistent. On a later disk failure, reconstruction uses stale parity → **silent corruption**. Mitigations: a **write-intent bitmap** (`--bitmap=internal`) speeds resync but doesn't close the hole; **PPL (Partial Parity Log)** for RAID5 or a **journal device** actually closes it. This is *the* reason many shops avoid RAID5 for critical data and prefer RAID10 or a checksumming filesystem (ZFS/btrfs) that detects the corruption.
- **Rebuild-window risk.** Rebuilding an N-disk RAID5 reads *every sector of every surviving disk*. With multi-TB drives and a realistic URE rate (~1 in 10^14 bits), the probability of hitting an unrecoverable read error mid-rebuild — killing the array — is non-trivial. This is the quantitative argument against wide RAID5 on large disks, and why RAID6 (two parity) or RAID10 (short rebuild, only reads the mirror) exist.
- Watch `/proc/mdstat` and `/sys/block/mdX/md/` for state, resync speed (`sync_speed_max/min`), and `mismatch_cnt` after a `check` scrub.

### NVMe and multipath

NVMe replaces the single SCSI command queue with up to 64K deep, 64K-count **submission/completion queue pairs**, one set per CPU, each with its own doorbell register and interrupt. That's the hardware reason NVMe scales linearly with cores and wants `none` as scheduler.

**Two multipath worlds:**

- **dm-multipath** (userspace `multipathd` + `dm` `multipath` target). Generic, SCSI-era, hugely configurable (path groups, `path_selector` policies like round-robin/service-time, `prio` callouts, `no_path_retry` queueing). Presents `/dev/mapper/mpathX`. This is the enterprise-SAN answer.
- **Native NVMe multipath** (in-kernel, no userspace). Driven by **ANA (Asymmetric Namespace Access)** — the fabric tells the host which paths are optimized/non-optimized and the kernel steers accordingly. Policies: `numa` (default), `round-robin`, `queue-depth`. Enabled by default (`nvme-core.multipath=Y`); disable with `nvme-core.multipath=0` to fall back to dm-multipath. Lower overhead, protocol-aware, but less policy flexibility than dm-multipath.

The senior distinction: **know which one is active** (`nvme list-subsys` / `multipath -ll`), because they're mutually exclusive per device and troubleshooting steps differ entirely.

### dm-crypt and LUKS2

`dm-crypt` is the `crypt` dm target: it encrypts/decrypts bios in flight, default cipher `aes-xts-plain64`. It knows nothing about keys or metadata — you hand it a raw key and a table. **LUKS** is the on-disk key-management envelope on top.

**LUKS2 header** (current default, spec v1.x from the cryptsetup project):

- A binary header + a **JSON metadata area** (kept in two redundant copies for torn-write survival) describing `keyslots`, `segments` (the encrypted data regions and their cipher), `digests`, `tokens`, and `config`.
- Up to **32 keyslots**. Each holds the single **master volume key** (the key dm-crypt actually uses) encrypted by a passphrase-derived key. This is why you can have 32 passphrases for one volume and change any without re-encrypting: they all unlock the same master key.
- **Argon2id** is the default KDF (memory-hard — resists GPU/ASIC brute force), replacing LUKS1's PBKDF2. The cost params (memory, iterations, parallelism) are per-keyslot and benchmarked at format time. This is the concrete reason to prefer LUKS2 and to *re-key old LUKS1 volumes*.

Failure modes: **a corrupted/overwritten header = unrecoverable data** (the master key lives only there, wrapped). Hence `cryptsetup luksHeaderBackup` before any header operation. Wrong key produces *garbage plaintext*, not an error — dm-crypt has no integrity check unless layered with dm-integrity (authenticated encryption).

### Quotas and the durability chain

- **Quotas:** `usrquota`/`grpquota`/`prjquota` mount options; XFS project quotas (`prjquota`) enforce limits on directory *trees* (the mechanism behind container/tenant dir limits). Soft limits give a grace period; hard limits return EDQUOT immediately. `repquota`, `xfs_quota`.
- **The durability chain** — the thing that separates people who understand storage from people who lose data on power loss: `write()` → page cache (volatile) → `fsync()`/`fdatasync()` forces writeback → filesystem issues a **FLUSH/FUA** barrier → the drive is told to persist its **volatile write cache** to media. If the app doesn't fsync, or the drive lies about cache flush (cheap consumer SSDs), or a virtualization layer drops the barrier, you get the "the file was there before the crash" data-loss class. `hdparm -W`, the `queue/write_cache` sysfs attr, and knowing whether your storage has power-loss-protected cache are the levers.

### Observability: which counter is lying

- **`iostat -x 1`:** `%util` is *not* saturation for multi-queue devices — an NVMe drive with 64 queues can be "100% util" (had at least one in-flight I/O every sample) while barely loaded. Trust `aqu-sz` (average queue depth) and `await`/`r_await`/`w_await` (per-I/O latency) instead. Merges (`rrqm/s`,`wrqm/s`) reveal scheduler/plug behavior.
- **`blktrace` → `blkparse`/`btt`:** the forensic scalpel. It timestamps each I/O at every stage, letting you split **Q2D** (queue→device: time in the kernel block layer + scheduler) from **D2C** (device→completion: actual hardware service time). If Q2D dominates, your problem is queueing/scheduling/starvation, not the disk. If D2C dominates, it's the hardware/fabric. Nothing else separates these cleanly.
- **eBPF/bpftrace:** `biolatency` (histogram of D2C), `biosnoop` (per-I/O with PID + latency), `bitesize` (I/O size distribution). These attach to the `block:block_rq_*` tracepoints live, no restart, and tie an I/O back to the responsible process — the thing iostat can't do.

---

## Hands-on labs

> Assume a **throwaway VM** (any distro; commands below use `dnf`/`apt` where they differ). You need root, a kernel with dm/loop, and the packages `lvm2 cryptsetup mdadm blktrace bpftrace fio util-linux thin-provisioning-tools` (Debian) / `lvm2 cryptsetup mdadm blktrace bpftrace fio util-linux device-mapper-persistent-data` (RHEL/Rocky). All labs use **loop devices backed by sparse files**, so you never touch a real disk. Clean up per each lab's teardown.

### Lab 1 — LVM snapshots: watch the COW store fill and the snapshot die

**Objective:** Make copy-on-write visible, then trigger the exception-store-full failure and confirm the snapshot is invalidated (not the origin).

**Setup**

```bash
# 1 GiB backing file → loop device → PV → VG
truncate -s 1G /var/tmp/pv1.img
losetup -f --show /var/tmp/pv1.img          # note the /dev/loopN it prints, e.g. /dev/loop0
LOOP=$(losetup -j /var/tmp/pv1.img | cut -d: -f1)
pvcreate "$LOOP"
vgcreate labvg "$LOOP"
lvcreate -L 400M -n origin labvg
mkfs.ext4 -q /dev/labvg/origin
mkdir -p /mnt/origin && mount /dev/labvg/origin /mnt/origin
dd if=/dev/urandom of=/mnt/origin/base.bin bs=1M count=300 status=none
sync
```

**Steps**

1. Take a *deliberately undersized* snapshot so you can fill it fast:
   ```bash
   lvcreate -L 50M -s -n snap /dev/labvg/origin
   lvs -o lv_name,lv_size,data_percent,lv_attr labvg
   ```
   Note `snap` shows a low `Data%` and attr starting with `s` (snapshot).
2. Watch the COW store in one pane while you rewrite the origin in another:
   ```bash
   watch -n1 'lvs -o lv_name,data_percent,lv_attr labvg; echo; dmsetup status labvg-snap'
   ```
3. Rewrite origin data — *every rewritten chunk copies the old chunk into the 50M store*:
   ```bash
   dd if=/dev/urandom of=/mnt/origin/base.bin bs=1M count=300 conv=notrunc status=none
   sync
   ```
4. Observe `snap` `Data%` climb past 100% and its `lv_attr` flip to `I` (Invalid). The origin is untouched.

**Prove it**

```bash
lvs -o lv_name,data_percent,lv_attr labvg | grep snap
# A healthy snapshot shows attr 'swi-a-s---'; an overflowed one shows 'Swi-I-s---' (capital S + I = Invalid).
dmsetup status labvg-snap
# On overflow the status reports the snapshot as "Invalid" instead of "<used>/<total> sectors".
```
Seeing the `I` flag *and* confirming `/mnt/origin/base.bin` still reads back fine proves the failure is isolated to the snapshot's COW store, not the origin — the core mental model of thick snapshots.

**Teardown**

```bash
umount /mnt/origin; lvremove -y labvg; vgremove -y labvg; pvremove -y "$LOOP"
losetup -d "$LOOP"; rm -f /var/tmp/pv1.img
```

---

### Lab 2 — Thin pool overprovisioning: drive it off the ENOSPC cliff

**Objective:** Overprovision a thin pool, then exhaust the *data* device and observe the difference between the default queue-and-timeout behavior and `error_if_no_space`. Inspect the metadata B-tree with `thin_dump`.

**Setup**

```bash
truncate -s 2G /var/tmp/thin.img
LOOP=$(losetup -f --show /var/tmp/thin.img)
pvcreate "$LOOP"; vgcreate thinvg "$LOOP"
# A 500M pool, but we'll provision 2 GiB of thin volumes on top of it (4x overcommit).
lvcreate -L 500M --thinpool pool thinvg
lvs -a -o lv_name,lv_size,data_percent,metadata_percent,lv_attr thinvg
```

**Steps**

1. Create two thin LVs each *larger than the whole pool*:
   ```bash
   lvcreate -V 1G -T thinvg/pool -n thin_a
   lvcreate -V 1G -T thinvg/pool -n thin_b
   lvs -a -o lv_name,lv_size,data_percent,pool_lv thinvg   # both claim 1G; pool is 500M
   ```
2. Set the pool to fail fast instead of the default queueing (so the lab terminates deterministically):
   ```bash
   lvchange --errorwhenfull y thinvg/pool
   ```
3. Watch allocation while you write past pool capacity:
   ```bash
   # pane 1
   watch -n1 'lvs -a -o lv_name,data_percent,metadata_percent,lv_attr thinvg'
   # pane 2: write ~600M into a 500M pool
   mkfs.ext4 -q /dev/thinvg/thin_a && mount /dev/thinvg/thin_a /mnt || true
   dd if=/dev/zero of=/dev/thinvg/thin_a bs=1M count=600 oflag=direct status=progress
   ```
   The `dd` fails with `No space left on device` (EIO/ENOSPC) once the pool `Data%` hits ~100%, even though `thin_a` "has" 1G.
4. Dump the metadata B-tree to see the (virtual→physical) mappings that ran out:
   ```bash
   lvchange -an thinvg/pool           # deactivate to inspect metadata safely
   thin_dump /dev/mapper/thinvg-pool_tmeta | head -40
   ```
   You'll see `<device dev_id=...>` blocks with `<range_mapping origin_begin=... data_begin=... length=...>` — the literal extent map, and `<superblock>` transaction counters.

**Prove it**

```bash
dmsetup status thinvg-pool
# The thin-pool status line reads:  <transaction_id> <used_meta>/<total_meta> <used_data>/<total_data> ...
# When full it appends "out_of_data_space" (or "error_if_no_space" mode reports read-only/error).
```
Reading `used_data == total_data` in `dmsetup status` while `lvs` still shows the thin volumes as 1 GiB is the whole lesson: **provisioned size is a promise, allocated size is the truth, and the truth lives in the pool, not the volume.**

**Teardown**

```bash
umount /mnt 2>/dev/null; lvremove -y thinvg; vgremove -y thinvg
losetup -d "$LOOP"; rm -f /var/tmp/thin.img
```

---

### Lab 3 — Separate queueing latency from device latency (blk-mq, schedulers, blktrace, bpftrace)

**Objective:** Prove the "the disk isn't slow, the queue is full" hypothesis. Change the I/O scheduler, generate contention, and use `btt` (Q2D vs D2C) plus `biolatency` to attribute latency to the right layer.

**Setup**

```bash
# Use a real-ish block device: a loop dev over a file on your fastest disk, or a spare /dev/vdb if present.
truncate -s 3G /var/tmp/io.img
DEV=$(losetup -f --show /var/tmp/io.img)      # e.g. /dev/loop0
BASE=$(basename "$DEV")
cat /sys/block/$BASE/queue/scheduler          # loop devices often show [none]; that's fine, we observe layers
```

**Steps**

1. Inspect the multi-queue topology and the tunable that caps in-flight I/O:
   ```bash
   ls /sys/block/$BASE/mq/ 2>/dev/null; echo "hw queues above (may be 1 for loop)"
   cat /sys/block/$BASE/queue/nr_requests
   ```
2. Start a `blktrace` capture, then hammer the device with a deliberately deep, mixed workload:
   ```bash
   blktrace -d "$DEV" -o - | blkparse -i - > /var/tmp/trace.txt &   # live parse
   # OR capture to files for btt:
   ( blktrace -d "$DEV" -o lab3 & echo $! > /var/tmp/bt.pid )
   fio --name=mix --filename="$DEV" --direct=1 --rw=randrw --bs=4k \
       --iodepth=64 --numjobs=4 --runtime=15 --time_based --group_reporting
   kill "$(cat /var/tmp/bt.pid)"; sleep 1
   ```
3. Post-process with `btt` to split the latency budget:
   ```bash
   btt -i lab3.blktrace.* | sed -n '1,40p'
   ```
   Read the **Q2D** (queue-to-issue: kernel/scheduler time) vs **D2C** (issue-to-complete: device time) averages. Under `iodepth=64` contention you'll see Q2D grow — that's queueing, not the medium.
4. In parallel, attribute latency live with eBPF (attaches to `block_rq_*` tracepoints):
   ```bash
   biolatency-bpfcc 5 1     # or: bpftrace -e 'tracepoint:block:block_rq_complete { @us = hist((nsecs)/1000); }'
   ```
5. Now flip the scheduler on a device that supports it (a real SATA/SSD `/dev/vdb`, not loop) and repeat step 2, comparing `await` in `iostat -x 1`:
   ```bash
   echo mq-deadline > /sys/block/vdb/queue/scheduler   # then 'none', then 'bfq'
   iostat -x 1 /dev/vdb
   ```

**Prove it**

```bash
btt -i lab3.blktrace.* | awk '/Q2D|D2C|Q2C/'
```
If you can point at the numbers and say "Q2C is 900 µs but D2C is only 150 µs, so 750 µs is queue/scheduler time — the device is fine, we're saturating the queue," you've demonstrated the single most valuable storage-debugging skill: **attributing latency to a layer instead of blaming `%util`.**

**Teardown**

```bash
rm -f lab3.blktrace.* /var/tmp/trace.txt
losetup -d "$DEV"; rm -f /var/tmp/io.img
```

---

### Lab 4 — LUKS2 internals: assemble dm-crypt by hand, dissect the header

**Objective:** See that LUKS is *just metadata around a raw dm-crypt table*. Format a LUKS2 volume, dump its JSON metadata, prove the master key is independent of passphrases (add/remove keyslots), then open the same encryption manually with `dmsetup create` using the exported master key.

**Setup**

```bash
truncate -s 256M /var/tmp/luks.img
LOOP=$(losetup -f --show /var/tmp/luks.img)
```

**Steps**

1. Format LUKS2 and inspect the header + KDF:
   ```bash
   echo -n 'passOne' | cryptsetup luksFormat --type luks2 "$LOOP" -
   cryptsetup luksDump "$LOOP"       # note: Version 2, Argon2id KDF, keyslot 0 populated, segment cipher aes-xts-plain64
   ```
2. Prove multi-keyslot / single-master-key design — add a second passphrase, confirm both open the *same* volume:
   ```bash
   echo -e 'passOne\npassTwo' | cryptsetup luksAddKey "$LOOP"
   cryptsetup luksDump "$LOOP" | grep -A2 'Keyslots' | head
   # Now 2 keyslots exist; both decrypt the identical master key.
   ```
3. Dump the raw JSON metadata area to see the structure the man pages describe:
   ```bash
   cryptsetup luksDump --dump-json-metadata "$LOOP" | python3 -m json.tool | sed -n '1,60p'
   # Observe keys: config / keyslots / segments / digests / tokens
   ```
4. **Back up the header** (drill the discipline) and prove its criticality:
   ```bash
   cryptsetup luksHeaderBackup "$LOOP" --header-backup-file /var/tmp/hdr.bin
   ls -l /var/tmp/hdr.bin
   ```
5. Open normally, then extract the master key and open *manually* with dm-crypt to show LUKS is only key management:
   ```bash
   echo -n 'passOne' | cryptsetup open "$LOOP" secure -
   dmsetup table --showkeys secure        # shows: 0 <sectors> crypt aes-xts-plain64 <MASTERKEY-hex> 0 <dev> <offset>
   cryptsetup close secure
   ```
   The `crypt` table row is exactly what `dm-crypt` needs; LUKS's whole job was to store and unwrap that master key.

**Prove it**

```bash
cryptsetup luksDump "$LOOP" | grep -E 'Version|PBKDF|Cipher|Keyslots' 
```
Output showing `Version: 2`, `PBKDF: argon2id`, `Cipher: aes-xts-plain64`, and two keyslots proves you understand the LUKS2 envelope: memory-hard KDF, multiple passphrases wrapping one master key, XTS cipher handed to dm-crypt. Bonus mastery: `cryptsetup luksDump --dump-json-metadata` returning valid JSON with `segments`/`keyslots`/`digests` shows you can read the on-disk format directly.

**Teardown**

```bash
cryptsetup close secure 2>/dev/null
losetup -d "$LOOP"; rm -f /var/tmp/luks.img /var/tmp/hdr.bin
```

---

## Curated resources

**Primary kernel docs (ground truth):**

- [Device Mapper — kernel admin-guide](https://docs.kernel.org/admin-guide/device-mapper/) — The per-target reference (linear, striped, snapshot, thin, crypt, cache, verity, integrity, multipath). This is what lets you decode `dmsetup table`/`dmsetup status`. The `thin-provisioning.rst` and `snapshot.rst` pages are the authoritative statement of the COW and allocate-on-write mechanics used in Labs 1–2.
- [Multi-Queue Block IO Queueing (blk-mq) — kernel.org](https://docs.kernel.org/block/blk-mq.html) — The definitive description of software (`blk_mq_ctx`) vs hardware (`blk_mq_hw_ctx`) queues, tags, and dispatch. Read alongside `Documentation/block/` for `queue-sysfs.rst` (every `/sys/block/*/queue/` knob) and `bfq-iosched.rst`.
- [Thin provisioning — kernel.org](https://docs.kernel.org/admin-guide/device-mapper/thin-provisioning.html) — The exact `thin-pool` table format, `error_if_no_space` vs queueing, low-water-mark semantics, and the metadata/data device split. The spec behind Lab 2's cliff.
- [Linux NVMe multipath — kernel.org](https://docs.kernel.org/admin-guide/nvme-multipath.html) — Native (ANA) multipath policies (`numa`/`round-robin`/`queue-depth`) and the `nvme-core.multipath` switch. The primary source for the native-vs-dm distinction.
- [LUKS2 On-Disk Format Specification (cryptsetup project)](https://fossies.org/linux/cryptsetup/docs/on-disk-format-luks2.pdf) — The actual binary+JSON header layout: keyslots, segments, digests, tokens, config, and the redundant metadata copies. Read this once and `luksDump` stops being magic.
- [cryptsetup(8) / cryptsetup-luksFormat man pages (man7)](https://www.man7.org/linux/man-pages/man8/cryptsetup.8.html) — Argon2id defaults, keyslot operations, header backup/restore, `--dump-json-metadata`. The operational reference for Lab 4.

**Man7 / util references:**

- [lvm(8), lvmthin(7), lvmraid(7), dmsetup(8)](https://man7.org/linux/man-pages/man8/lvm.8.html) — `lvmthin(7)` and `lvmraid(7)` are dense, well-written conceptual essays (not just flag lists) on thin pools and LVM-integrated RAID. `dmsetup(8)` documents the forensic `table`/`status`/`--showkeys` output used throughout the labs.
- [md(4) and mdadm(8) — man7](https://man7.org/linux/man-pages/man4/md.4.html) — Superblock versions, `/sys/block/mdX/md/` attributes, resync/check semantics, bitmap and journal/PPL for the write hole.
- [btt(1) / blktrace(8) / blkparse(1) man pages](https://manpages.debian.org/testing/blktrace/btt.1.en.html) — The Q2D/D2C/Q2C latency-stage definitions that make Lab 3's attribution rigorous.
- [rockyman.org](https://rockyman.org/) — https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here (the `lvcreate`/`lvchange`/`dmsetup`/`cryptsetup`/`losetup`/`btt` options used in the labs above were checked against the Rocky 9 pages).

**Books (canonical):**

- [Systems Performance, 2nd ed — Brendan Gregg](https://www.brendangregg.com/systems-performance-2nd-edition-book.html) — Chapter 9 (Disks) is the methodology bible for the block I/O stack: the USE method applied to storage, why `%util` misleads on multi-queue devices, the full queueing model, and how to read `iostat`/`blktrace`/`biolatency` as a system rather than as isolated commands.
- [BPF Performance Tools — Brendan Gregg](https://www.brendangregg.com/bpf-performance-tools-book.html) — The disk-I/O chapter's tools (`biolatency`, `biosnoop`, `bitesize`, `mdflush`) with the diagnostic thinking for *when* each applies. The observability endgame for this module.
- [Operating Systems: Three Easy Pieces (OSTEP) — free](https://pages.cs.wisc.edu/~remzi/OSTEP/) — The "Persistence" section: disk scheduling theory, RAID (including the RAID5 small-write and reliability math behind the rebuild-window argument), journaling, and crash consistency. The *why* under everything Linux-specific here.

**Deep dives / blog + articles:**

- [Beyond iostat: storage performance analysis with blktrace — Marc Brooker](https://brooker.co.za/blog/2013/07/14/io-performance.html) — The clearest short piece on using `blktrace`/`btt` to separate kernel queueing from device service time, with the offset-plotting trick (`btt -B`) for seeing seek patterns.
- [LWN: dm-thin / thin provisioning coverage](https://lwn.net/Articles/465740/) — The original design discussion for dm-thin: why the B-tree metadata + transaction/superblock-commit model was chosen and its failure semantics. Pair with the current LWN Kernel Index for MGLRU/folio-era writeback changes.
- [Red Hat: Configuring device mapper multipath (RHEL 9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/configuring_device_mapper_multipath/index) — The production reference for `multipath.conf`, `no_path_retry`, path groups, `path_selector`/`prio`, and the NVMe multipath interop chapter. This is RHEL/Rocky-current, matching the CIQ environment.
- [Red Hat: Setting the disk scheduler (RHEL 8/9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/managing_storage_devices/setting-the-disk-scheduler_managing-storage-devices) — How the distro sets per-device-class schedulers via udev keyed on `queue/rotational`, and the persistence mechanism (tuned profiles vs udev rules).
- [Julia Evans — jvns.ca](https://jvns.ca/) — The "how do I even see what's happening" reflex-builders for `strace`/`/proc` spelunking of stuck-in-D-state processes blocked on I/O — the human-facing symptom of everything in this module.

**Source (when docs aren't enough):**

- `drivers/md/dm-thin.c`, `drivers/md/persistent-data/` (thin B-tree), `drivers/md/dm-crypt.c`, `drivers/md/raid5.c` (write-hole logic + PPL), and `block/blk-mq.c` / `block/mq-deadline.c` in the kernel tree. `git log` on these files via LWN or `git.kernel.org` shows the design churn (e.g., the removal of the legacy request layer).

---

## Senior signal

- **Attributes I/O latency to a layer, not a device.** Reflexively splits Q2D (kernel/scheduler queueing) from D2C (hardware service) with `blktrace`/`btt` and knows that `iostat %util` is meaningless on a 64-queue NVMe drive — reads `aqu-sz` and `await` instead. A mid-level engineer says "the disk is at 100%"; a senior says "the queue is full but the device is idle."
- **Treats `dmsetup table`/`dmsetup status` as ground truth over `lvs`.** Understands that LVM is userspace metadata programming device-mapper, so when the two disagree (or `lvs` hangs), they drop to the dm layer and read the live table and per-target runtime state (thin pool `used_data/total_data`, snapshot Invalid flag, multipath path status).
- **Knows the two ENOSPC cliffs of thin provisioning cold** — data-device-full (I/O errors or queue-then-timeout) *and* the nastier metadata-device-full (pool goes read-only, needs offline `thin_repair`) — and monitors both `Data%` and `Meta%` with autoextend thresholds set *before* the incident, because overcommit is a promise the pool can't always keep.
- **Sizes and time-bounds thick snapshots deliberately** because they understand the COW exception store fills and *invalidates the snapshot* (write-amplifying every origin first-write into read+write+write), and reaches for thin snapshots (O(1), shared refcounted B-tree) when the workload is long-lived.
- **Reasons quantitatively about RAID reliability:** the RAID5 write hole causes silent corruption on crash-then-failure (mitigated only by PPL/journal, not by a bitmap), and the URE-during-rebuild math makes wide RAID5 on multi-TB disks a real data-loss risk — which is *why* RAID10 or a checksumming filesystem is the recommendation, stated as physics rather than dogma.
- **Owns the durability chain end to end:** knows that data isn't safe until `fsync()` forces a FLUSH/FUA barrier through the filesystem to the drive's volatile cache, can name every place the barrier gets dropped (missing fsync, lying consumer SSD, a hypervisor discarding cache flushes), and checks `queue/write_cache` and power-loss protection before trusting a "successful" write.
- **Picks the I/O scheduler from mechanism:** `none` for NVMe (the FTL reorders better and the scheduler just burns IOPS), `mq-deadline` for bounded latency on SATA/SAS SSD, `bfq` only where per-process fairness on slow media actually matters — and knows the distro sets this via udev on `queue/rotational`.
- **Distinguishes native NVMe multipath (in-kernel, ANA-driven) from dm-multipath (userspace `multipathd`, SCSI-era, richer policy)**, checks which is active before troubleshooting, and knows they're mutually exclusive per device via `nvme-core.multipath`.
- **Backs up the LUKS header before touching it** and understands *why* it's fatal to lose: the master volume key exists only there, wrapped by each keyslot's Argon2id-derived key — so 32 passphrases unlock one key, a wrong key yields garbage rather than an error, and there's no integrity check unless dm-integrity is layered in.

---

## See also

- [[04 - Filesystems and the VFS]] — the layer directly above this one: the filesystem builds the `struct bio` that the block layer and device-mapper stack here consume, and the durability chain (`fsync` → FLUSH/FUA) begins in the VFS/page cache before it reaches the block devices covered in this module.
- [[05 - EC2 and Compute Internals]] — EBS volumes, instance store, and NVMe in cloud VMs are exactly the block layer / blk-mq / device-mapper stack here; the `%util`-lies-on-multiqueue lesson applies directly to cloud volume performance debugging.
- [[07 - Parallel and Networked Filesystems]] — the parallel-FS backends (Lustre OSTs, GPFS NSDs) sit on this block/multipath/NVMe-over-fabric layer; multipath and the durability chain carry straight over.
- [[07 - Data and Storage for ML]] — throughput and latency of the block layer under ML dataset loads; `blktrace` Q2D-vs-D2C attribution is how you prove whether an ML data stall is the queue or the device.
- [[02 - Warewulf Stateless Provisioning]] — stateless nodes assemble root storage (iSCSI/NVMe-oF, LVM, overlays) at boot; the LVM/device-mapper mechanics here are what the provisioning layer programs.
