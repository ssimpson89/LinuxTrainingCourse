---
title: Filesystems and the VFS
type: module
track: linux-internals
tags: [linux, filesystems, vfs, ext4, xfs, btrfs, zfs, overlayfs, page-cache, mount-namespaces, xattr, extended-attributes, capabilities, nfs, smb]
requires: [Rocky 9.x VM with root, "kernel>=5.10 (kernel>=5.16 for folio-era page cache)", "xfsprogs/e2fsprogs/btrfs-progs/attr installed", "BTF/CO-RE kernel + bpftrace (Lab 5)", "overlayfs + mount namespaces (Lab 4)"]
module_number: 4
status: reviewed
created: 2026-07-08
---

# 04 - Filesystems and the VFS

Backlink: [[00 - Track Overview]]

> The filesystem is where the kernel's cleanest abstraction (everything is a file) meets the messiest physical reality (spinning rust, flash translation layers, write caches that lie about durability). The VFS is the indirection layer that makes `cat /proc/self/status`, `cat /home/x/notes.txt`, and `cat /dev/sda` all go through the same four `read()` code path. Staff-level filesystem work is about knowing exactly where a symptom lives in the stack: is it the dcache, the page cache, the journal, the block layer, or the device lying about `fsync()`?

---

## Concept deep-dive

### 1. The VFS object model: four structs that run everything

The Virtual File System is an in-kernel object-oriented layer. Concrete filesystems (ext4, xfs, overlayfs, procfs) register a `file_system_type` and populate a set of *operations* vtables. The generic syscall handlers (`sys_read`, `sys_openat`, `sys_stat`) call through function pointers, so the same syscall entry point drives every filesystem. Source of truth: `Documentation/filesystems/vfs.rst`, and the structs live in `include/linux/fs.h` and `include/linux/dcache.h`.

The four core objects:

```
 mount (struct mount / struct vfsmount)   "this fs, mounted here, with this propagation"
   │  points at
   ▼
 superblock (struct super_block)          one per mounted filesystem instance
   │  s_op = super_operations
   │  owns list of inodes, the backing device, block size, s_maxbytes
   ▼
 inode (struct inode)                      one per file object (regardless of #names)
   │  i_op = inode_operations  (lookup, create, link, setattr, getattr…)
   │  i_fop = file_operations  (default fops for files opened from this inode)
   │  i_mapping -> address_space (the page cache for this file's data)
   │  i_ino, i_mode, i_uid/gid, i_size, i_nlink, timestamps
   ▲
   │  d_inode points up
 dentry (struct dentry)                    one per path component, cached (dcache)
   │  d_name, d_parent, d_sb, d_op = dentry_operations
   │  MANY dentries can point at ONE inode (hard links, bind mounts)
   ▲
   │  f_path.dentry
 file (struct file)                        one per open() — the open file description
      f_pos (offset), f_flags, f_mode, f_op = file_operations
      f_count (refcount; dup/fork share the same struct file)
```

Key relationships that trip people up:

- **inode ≠ file ≠ fd.** The inode is the on-disk object's in-memory representation (metadata + pointer to the page cache mapping). The `struct file` is the *open file description* — offset, flags, mode. The fd (an `int`) is an index into the per-process `fd` array (`struct fdtable` in `files_struct`) that points at a `struct file`. `dup()`/`fork()` share the `struct file` (shared offset); two separate `open()`s of the same path get two `struct file`s pointing at the same inode. This is the three-level fd → OFD → inode model from TLPI, and it explains `O_APPEND` atomicity, why `lseek` in one fd after `dup` moves the other, and why `fork`ed children share a file position.
- **dentry ≠ inode.** A dentry names an inode. Hard links = N dentries, one inode, `i_nlink == N`. This is why you cannot hard-link across filesystems (inode numbers are per-superblock) and why `rm` is really `unlink()` (decrement `i_nlink`; free the inode only when it hits 0 *and* no open `struct file` holds it — the classic "deleted but space not freed until the process exits" behavior).

### 2. The dcache: why path lookup is fast (and how it lies)

Path resolution (`link_path_walk` / `walk_component` in `fs/namei.c`) is the hottest metadata path in the kernel. Naively, resolving `/usr/lib/x/y` requires a directory read + inode lookup per component. The **dentry cache (dcache)** is an in-memory hash table (`dentry_hashtable`, keyed on parent dentry pointer + name hash) that memoizes name→dentry→inode. Since 2.6.38, the common case uses **RCU-walk** (`rcu_read_lock`, no refcount bumps, no spinlocks) and falls back to **ref-walk** (`dget`/`dput`, seqlock-protected) when it hits something it can't resolve locklessly (a mountpoint, a symlink, a revalidate-required dentry on a network fs).

Structures worth knowing:

- **Negative dentries.** The dcache caches *failed* lookups too — a dentry with `d_inode == NULL` records "this name does not exist here." This makes repeated `stat()` of nonexistent files (compilers hunting include paths, `ld.so` walking `LD_LIBRARY_PATH`) cheap. At scale, negative dentries can balloon and consume reclaimable slab memory; watch `dentry` in `/proc/slabinfo` and reclaim with `echo 2 > /proc/sys/vm/drop_caches` (test only) or under memory pressure via the shrinker.
- **Mountpoints** are handled in the dcache: a dentry that is a mountpoint has `DCACHE_MOUNTED`; `__lookup_mnt` crosses into the mounted fs's root dentry. This is why `stat` on a mountpoint shows the mounted fs, but `stat` on the underlying directory (visible only if you bind-mount elsewhere or from another namespace) shows the covered directory.

**Failure/scale behavior.** dcache and inode cache are the two biggest reclaimable slab consumers on a busy fileserver. `slabtop` showing `dentry` and `ext4_inode_cache`/`xfs_inode` dominating is normal, not a leak — it's cache. Real pathologies: a workload that `stat()`s millions of unique nonexistent paths (negative dentry flood), or `find /` across a huge tree pulling every inode into cache and evicting hot pages. The `vfs_cache_pressure` sysctl tunes how aggressively the kernel reclaims dentry/inode cache vs page cache.

### 3. The page cache: where read/write and mmap converge

Every file's data lives (when cached) in that inode's `address_space` (`i_mapping`). The `address_space` maps file offset → page, backed since ~5.x by an **XArray** (replacing the old radix tree) and increasingly by **folios** (a folio is a power-of-2-order run of contiguous pages managed as one unit — the abstraction that let the page cache use large/huge pages without every function guessing "head page or tail page?"). Reference: `docs.kernel.org/mm/page_cache.html` and the ongoing LWN folio coverage.

```
read(fd, buf, n):
  generic_file_read_iter
    -> filemap_read
       -> for each page: is it in i_mapping (page cache)?
            HIT  -> copy_to_iter (page cache -> user buffer)        [no I/O]
            MISS -> page_cache_ra / readahead -> a_ops->readpage(s) -> block layer -> DMA into page
                    then copy_to_iter
write(fd, buf, n):   (buffered, the default)
  generic_perform_write
    -> a_ops->write_begin ; copy_from_iter ; a_ops->write_end
    -> mark folio DIRTY, tag in the XArray, account in NR_DIRTY
    -> return  (data is NOT on disk yet — it's a dirty page)
```

The crucial senior insight: **a successful buffered `write()` guarantees nothing about durability.** It only guarantees the data is in the page cache and the write will *eventually* hit disk. Durability requires `fsync()`/`fdatasync()` (flush this file's dirty pages + metadata) or `O_SYNC`/`O_DSYNC`. See the fsync/barrier chain below.

**Dirty writeback path.** Dirty pages are flushed by per-bdi (backing device info) writeback worker threads (`flush-MAJOR:MINOR`, visible in `ps`), which replaced the old single `pdflush` pool around 2.6.32 to avoid one slow device starving writeback for a fast one. Tunables (`/proc/sys/vm/`):

- `dirty_background_ratio` / `dirty_background_bytes` — threshold at which background writeback *starts* (async, app doesn't block).
- `dirty_ratio` / `dirty_bytes` — hard ceiling; a process dirtying pages past this is **throttled** in `balance_dirty_pages` (synchronous stall). This is a classic invisible latency source: an app doing bulk writes suddenly sees multi-hundred-ms `write()` latency and blames the disk, when it's dirty-page throttling.
- `dirty_expire_centisecs` / `dirty_writeback_centisecs` — max age of a dirty page before forced writeout / how often the flusher wakes.

On a box with lots of RAM and a slow disk, the default ratio-based thresholds can queue gigabytes of dirty data, producing enormous latency spikes and a "sawtooth" when writeback finally fires. Set `dirty_bytes`/`dirty_background_bytes` (absolute) instead of ratios on large-memory machines. Observe with `grep -E 'Dirty|Writeback' /proc/meminfo` and `/proc/vmstat` (`nr_dirty`, `nr_writeback`, `nr_dirtied`, `pgpgout`).

### 4. On-disk anatomy: inodes, extents, directories, journals

#### ext4

ext4 lays the disk out as **block groups** (each with a block bitmap, inode bitmap, inode table, and data blocks). Key evolutions over ext2/3:

- **Extents, not indirect blocks.** ext2/3 mapped file logical blocks via direct/singly/doubly/triply-indirect block pointers — terrible for large files (one pointer per 4K block). ext4 uses an **extent tree**: an inode holds up to 4 extents inline in `i_block` (the `ext4_extent_header` + 4 `ext4_extent` entries), each extent mapping a contiguous run of up to 32768 blocks with (logical block, length, physical block). Larger/fragmented files grow a B-tree of extents (`ext4_extent_idx` internal nodes). This is why `filefrag -v somefile` shows extents, and why a freshly written large file on ext4 is often a single extent.
- **HTree directories.** Directories beyond a couple of blocks switch from linear to a **constant-depth hashed B-tree** (HTree, `EXT4_INDEX_FL`), hashing the filename to locate the block — O(1)-ish lookups in million-entry directories instead of O(n) linear scans.
- **Delayed allocation.** ext4 does not allocate physical blocks at `write()` time; it reserves space and allocates at writeback (`ext4_writepages`), letting the allocator pick large contiguous extents. Downside: the infamous post-2.6.30 "zero-length files after crash" surprise for apps that `write()`-then-`rename()` without `fsync()` — the rename metadata journaled before the data was allocated. ext4 added the `auto_da_alloc` heuristic to force allocation on such renames.
- **JBD2 journal.** ext4 journals *metadata* (and optionally data) through the JBD2 layer (`fs/jbd2/`). Modes:
  - `data=ordered` (default): metadata is journaled; data blocks are forced to disk *before* the metadata transaction commits. Prevents the "metadata points at stale/garbage blocks" exposure without the cost of journaling data.
  - `data=journal`: data *and* metadata go through the journal first. Safest, slowest; disables delayed allocation and O_DIRECT.
  - `data=writeback`: metadata journaled, data written whenever. Fastest, but a crash can expose stale block contents in files whose size grew before the data landed.
  JBD2 batches changes into transactions; a commit writes the journal blocks, a barrier/FUA flush, then the commit block (with CRC32C checksum since ext4). On mount after a crash, `e2fsck`/kernel replays committed transactions and discards incomplete ones. `fast_commit` (kernel 5.10+) adds a lighter-weight logical journal for common fsync-heavy paths.

#### XFS

XFS is the RHEL/Rocky default. Design center: **parallelism and scale**, from SGI's origins on big NUMA IRIX boxes. Spec: the XFS Algorithms & Data Structures PDF (linked below).

- **Allocation Groups (AGs).** The filesystem is split into multiple AGs (typically several GB each), and each AG has its *own* free-space B+trees, inode B+trees, and locking. This is the key to XFS's parallel write scalability — N threads writing into N different AGs contend on nothing. It's also why XFS **cannot shrink** (AGs are laid out at mkfs time) and why you grow it with `xfs_growfs` (add AGs), never shrink.
- **B+trees everywhere.** Free space is tracked by *two* B+trees per AG — one keyed by block number, one keyed by extent size — so the allocator can answer both "space near here" and "a free run of at least this size" efficiently. Inodes are tracked by an inode-allocation B+tree (and a free-inode B+tree, `finobt`). Directories and file block maps are extent-based B+trees.
- **Delayed logging.** Modern XFS (default for years) uses **delayed logging**: instead of writing each metadata change to the on-disk log, changes accumulate in an in-memory Committed Item List (CIL) and are aggregated, dramatically reducing log traffic for hot metadata (a directory updated 1000 times logs roughly once, not 1000 times). No on-disk log format change; it's a relog-in-memory optimization. Reference: `docs.kernel.org/filesystems/xfs/xfs-delayed-logging-design.html`.
- **Dynamic inodes, no fixed inode table.** Unlike ext4's fixed inode count at mkfs, XFS allocates inodes dynamically (`imaxpct` caps the fraction of space inodes may consume). You generally don't run out of inodes on XFS the way you can on ext4.
- **Online repair trend.** `xfs_repair` runs offline (unmounted); the modern direction is `xfs_scrub` for online metadata verification and eventual online repair.

#### Btrfs and ZFS (copy-on-write filesystems)

Both are **CoW**: a modified block is written to a *new* location, then pointers up the tree are rewritten to point at it, up to a new superblock/uberblock. Never overwrite in place → the on-disk state is always consistent (no fsck needed for consistency; a crash just loses the last un-committed transaction). This enables atomic snapshots (freeze a tree root; shared blocks are refcounted) and end-to-end checksums (every block's checksum stored in its parent pointer).

- **Btrfs** is a single giant forest of CoW B-trees (the "b-tree fs"): the extent tree, fs tree (per subvolume), checksum tree, etc. Subvolumes and snapshots share one namespace and are cheap. Strengths: flexible, in-tree (no external module), transparent compression, `send`/`receive`. Weaknesses/tradeoffs: **CoW fragmentation** under random-overwrite workloads (databases, VM images, torrents) — mitigate with `chattr +C` (nodatacow) on those files, but that *also disables checksums* for them; RAID5/6 write hole is still considered unstable. `btrfs balance` and `btrfs scrub` are operational necessities.
- **ZFS** (out-of-tree on Linux via OpenZFS, CDDL-licensed so it can't be merged) treats integrity as the core promise: a pooled storage model (vdevs → zpool → datasets), the ZFS Intent Log (ZIL) for sync writes, the ARC (its own page-cache-competing adaptive cache in kernel memory), and transactional groups (txg). ZFS's ARC lives outside the Linux page cache and must be sized deliberately (`zfs_arc_max`) or it competes with everything else for RAM — a classic ZFS-on-Linux memory-pressure surprise.

**When each breaks at scale:** ext4 — huge directories were the historical wall (HTree helped); fixed inode count; fsck time on multi-TB volumes is brutal (offline, scans all inodes). XFS — cannot shrink; metadata-heavy small-file workloads were historically weaker than ext4 (largely closed); log contention on ancient kernels (delayed logging fixed it). Btrfs — random-overwrite fragmentation and full-filesystem ENOSPC behavior (CoW means "delete to free space" can itself need to allocate metadata). ZFS — RAM appetite and the licensing/DKMS operational tax on kernel upgrades.

### 5. The durability chain: fsync, barriers, FUA, and lying hardware

The most consequential thing a filesystem engineer can get wrong. The chain from `write()` to "bytes are safe on stable media":

```
app write()          -> page cache (dirty)          [survives process crash, NOT power loss]
fsync(fd)            -> flush this file's dirty pages + metadata to the block layer
block layer          -> issues writes, then a FLUSH (barrier) and/or FUA-tagged write
device write cache   -> volatile DRAM on the disk/controller
FLUSH forces         -> device commits its write cache to stable media (platter/NAND)
                     -> ONLY NOW is the data power-loss durable
```

Failure modes:

- **Consumer SSDs / USB enclosures that ignore FLUSH** report the flush complete while data sits in volatile cache. Power loss = corruption despite correct `fsync()`. This is why enterprise drives have power-loss protection (capacitors) and why virtualization `cache=` modes matter (`cache=none`/`writethrough` vs `writeback`).
- **`fdatasync` vs `fsync`.** `fdatasync` skips metadata that isn't needed to read the data back (e.g., mtime) — a real throughput win for databases doing millions of syncs. But it *does* flush size-changing metadata, because you need the size to read the data.
- **Write barriers.** Historically an explicit `barrier=1` mount option; on modern kernels FLUSH/FUA is always issued when the fs needs ordering, and disabling it (`nobarrier`) is a data-integrity gamble only safe with battery/capacitor-backed cache. Flag any `nobarrier` recommendation loudly.

### 6. Mounts, bind mounts, and mount propagation

A mount is not the filesystem; it's an *instance of a filesystem attached at a point in a mount namespace*. `struct mount` (internal, `fs/mount.h`) wraps the public `struct vfsmount` and holds the parent mount, mountpoint dentry, and **propagation** state. The mount table for a namespace is in `/proc/PID/mountinfo` (richer than `/proc/mounts` — it shows propagation flags, peer group IDs, and the root of the mount within its fs).

- **Bind mount** (`mount --bind A B`): makes the subtree at A also appear at B, same superblock, same inodes. It's a second `vfsmount` pointing at the same fs subtree — the mechanism behind exposing one directory in multiple places and the foundation of container root construction.
- **Mount propagation** (shared-subtree model, `Documentation/filesystems/sharedsubtree.rst`) controls whether mount/unmount *events* cross between mounts:
  - **shared** (`MS_SHARED`): members of a *peer group*; a new mount under one member propagates to all peers. This is the default on systemd systems (systemd sets `/` to shared at boot) so that, e.g., plugging in a USB drive shows up everywhere.
  - **private** (`MS_PRIVATE`): no propagation in or out.
  - **slave** (`MS_SLAVE`): one-way — receives events from its master peer group but doesn't send back. This is exactly what a container runtime wants for `/`: see host mounts appear, but don't leak container-internal mounts back to the host.
  - **unbindable** (`MS_UNBINDABLE`): private + cannot be bind-mounted (prevents recursive-bind explosions).
  - A mount can be **shared *and* slave** simultaneously (slave of an upstream master, shared with its own downstream peers).

Why this matters for containers: `mount --make-rprivate /` before constructing a container mount tree is the standard incantation so your `pivot_root` gymnastics don't propagate back into the host namespace. Getting propagation wrong is why "my bind mount leaked into every container" or "unmounting in the container unmounted it on the host" happens.

### 7. overlayfs: how container images actually stack

overlayfs is a **union/stacking** filesystem: it presents a merged view of a read-only **lowerdir** (or a colon-separated stack of lowers — this is how each container image layer maps to a lowerdir) and a writable **upperdir**, plus a **workdir** (must be an empty dir on the same fs as upper, used for atomic internal operations). Reference: `docs.kernel.org/filesystems/overlayfs.html`.

Mechanism:

- **Reads** hit upper if present, else fall through the lower stack (first match wins).
- **Copy-up.** The first *write* to a file that exists only in lower triggers **copy-up**: the whole file is copied into upper, then modified there. This is why the first write to a large file in a container is slow (copies the file) and why container write layers grow. `metacopy=on` optimizes chmod/chown-only changes to copy just metadata, deferring the data copy until an actual data write.
- **Whiteouts.** Deleting a file that exists in lower can't touch the read-only lower, so overlayfs records a **whiteout** in upper: a character device with device number `0/0`. A lookup that finds a whiteout returns ENOENT. Deleting a directory that has lower content marks the upper directory **opaque** (`trusted.overlay.opaque` xattr).
- **redirect_dir.** Renaming a merged directory is recorded via the `trusted.overlay.redirect` xattr so the rename doesn't require recursively copying up the whole tree. Conflicts with `metacopy` in some combinations.

Scale/failure notes: overlayfs needs the underlying fs to support the `trusted.*` xattr namespace (ext4/xfs yes; some don't) — this is why `overlay2` on certain backing stores fails. Inode number semantics across the merge (the `xino`/`index` features) matter for tools that assume stable `st_ino`; `du`/`find -inum` can behave surprisingly across a copy-up. And overlayfs is *not* a general clustered/CoW fs — it's a namespacing/layering tool.

### 8. fsck and repair: what recovery actually does

- **Journaling filesystems (ext4/xfs) after a clean crash** don't need a full fsck — they **replay the journal/log** (ext4: JBD2 replay at mount or via `e2fsck` journal recovery; xfs: log recovery at mount). This restores *metadata consistency*, not lost application data.
- **`e2fsck`** runs five passes: (1) inodes, blocks, sizes; (2) directory structure; (3) directory connectivity (reachability from root); (4) reference counts (`i_nlink` vs actual dentries); (5) group summary (bitmaps, free counts). Orphaned inodes (positive `i_nlink`, no directory entry) land in `lost+found/` named by inode number. If the primary superblock is trashed, `e2fsck -b <backup>` uses a backup superblock (locations depend on block size / `sparse_super`; `mke2fs -n` prints them without formatting).
- **`xfs_repair`** runs eight phases (superblock, AG freespace/inode maps, inode discovery, directory checks, pathname/reachability, link counts, freemap, cleanup). It runs **offline only** (must be unmounted). If the log is dirty and the fs won't mount, you may need `xfs_repair -L` to zero the log — **destructive**: it discards un-replayed metadata changes, potential data loss. Always mount-to-replay first if the disk is healthy; only zero the log when the log itself is corrupt.
- **CoW filesystems** largely sidestep offline fsck for consistency (the tree is always consistent on disk), but need `btrfs scrub` / `zpool scrub` to *detect and repair* bit rot via checksums (repair requires redundancy — RAID1/mirror — to have a good copy).

⚠️ Any `fsck`/`xfs_repair`/`xfs_repair -L`/backup-superblock recovery is a destructive-capable operation on a production filesystem. Image the device first if the data matters, and never run fsck on a mounted fs.

---

### 9. Extended attributes: the four namespaces and what crosses a network

Everything in the last section that "just worked" (overlayfs whiteouts via `trusted.overlay.opaque`, SELinux labels, POSIX ACLs) rides on one under-appreciated VFS facility: the **extended attribute**. An xattr is an opaque `name=value` pair bound to an inode, living *outside* the classic `stat` metadata. The filesystem stores and access-controls the pair but does not interpret the value; interpretation is the job of whatever subsystem owns the name. Names are always `namespace.attribute` (`user.mime_type`, `security.selinux`, `security.capability`, `system.posix_acl_access`, `trusted.overlay.redirect`). The authoritative statement of the model is `xattr(7)`; the VFS ceiling is a 255-byte name, a 64 KB value, and a 64 KB total returned name list, with individual filesystems imposing tighter limits (§4).

**The four namespaces are four different access-control regimes, not four folders.** This is the whole mental model:

- **`user.*`** — arbitrary application metadata, governed purely by the file's ordinary permission bits: read permission to get the value, write permission to set it. Allowed only on regular files and directories (not symlinks or special files; a sticky or non-owner directory further restricts writes to the owner / `CAP_FOWNER`). This is the *only* namespace with portable, cross-platform semantics, and the only one that survives a hop across a network filesystem (below).
- **`trusted.*`** — visible and writable only to a process holding **`CAP_SYS_ADMIN`**. Completely hidden from unprivileged processes: an ordinary user's `getfattr -m -` will not even list it. overlayfs keeps its `trusted.overlay.*` bookkeeping (§7) here precisely so container users can't see or forge it.
- **`system.*`** — access policy is defined per-attribute by the kernel filesystem code. This is where **POSIX ACLs** live (`system.posix_acl_access`, `system.posix_acl_default`), which is why the ACL machinery in [[01 - Permissions and Access Control]] is "just xattrs" under the hood.
- **`security.*`** — access policy is defined by the loaded LSM. With no LSM, all processes can read and only `CAP_SYS_ADMIN` can write. This namespace holds **SELinux labels** (`security.selinux`, see [[12 - SELinux and Hardening]]) and **file capabilities** (`security.capability`).

**The syscall surface is small and regular.** From `<sys/xattr.h>`: `setxattr`/`getxattr`/`listxattr`/`removexattr`, each with an `l*` variant that acts on a symlink itself and an `f*` variant that takes an open fd (`setxattr(2)` et al.). `setxattr` takes `XATTR_CREATE` (fail with `EEXIST` if it exists) or `XATTR_REPLACE` (fail with `ENODATA` if it doesn't); default is create-or-replace. `listxattr` returns null-terminated names concatenated into one buffer; call with `size=0` first to size it, same as `getxattr` with `size=0` returns the value length. The load-bearing errno is **`ENOTSUP`/`EOPNOTSUPP`** ("Operation not supported"), returned when the namespace prefix is invalid *or the filesystem doesn't support xattrs at all* — this is the exact error that surfaces when you try to write a `security.*` attribute onto a network mount.

**Caps, SELinux, and ACLs are all the same mechanism.** `setcap` is a thin wrapper that writes `security.capability` (requiring `CAP_SETFCAP`); the on-disk blob is `struct vfs_ns_cap_data` (VFS_CAP_REVISION_3 since Linux 4.14: the older `vfs_cap_data` plus a trailing `rootid` so namespaced file caps are honored inside a user namespace without letting a host-unprivileged user forge host-wide privilege — the full transition formula is in [[01 - Permissions and Access Control]]). `chcon`/`restorecon` write `security.selinux`. `setfacl` writes `system.posix_acl_access`. `getfattr -m - -d` shows you all three at once, which is the fastest way to *see* that these "different" security features are one storage layer. Note `getfattr` defaults to matching only `^user\.`, so system/security/trusted attributes are invisible until you pass `-m -`.

**On disk** (recap of §4 from the xattr angle): ext4 stores small xattrs inline in the slack of a large inode (`ext4_xattr_ibody_header` after `i_extra_isize`) and spills larger sets to a shared, refcounted external block pointed to by `i_file_acl`; values bigger than a block go into a dedicated ea_inode (`e_value_inum`). XFS (the Rocky 9 default) keeps them in the inode's attribute fork, spilling to out-of-line extents / a b-tree with effectively no practical size cap. Heavy ACL/label/cap use multiplies xattrs and can push ext4 off the inline fast path, slowing `stat`-heavy workloads.

**What crosses a network is the punchline.** Only `user.*` survives NFS or SMB. **NFS**: RFC 8276 ("File System Extended Attributes in NFSv4") deliberately scopes the wire protocol to the user namespace — §10 limits xattr names to `user.*`, and §9 is normative that "Clients MUST NOT accord any system-interpreted semantics to xattrs." The Linux NFSv4.2 implementation (merged in kernel 5.9, present in the EL8/EL9 kernels) matches: it strips the Linux-specific `user.` prefix on the client and re-adds it server-side, and carries nothing else. **SMB/CIFS** has the same shape: the Linux cifs client maps only `user.*`/`os2.*` names to server EAs, gated by the `user_xattr` mount option and Samba's `ea support = yes` in `smb.conf` (see [[13 - Samba and SMB]]). Neither protocol carries `security.*`, `system.*`, or `trusted.*`. Concretely: `setfattr -n user.foo` succeeds on an NFS/SMB mount, but `setcap` (which writes `security.capability`) fails with `ENOTSUP` — the failure is namespace-scoped, not a total xattr failure, which is exactly what makes it so easy to miss.

Scale/failure notes: the top real-world footgun is unpacking a container image, rootfs, or backup onto NFS- or SMB-backed storage — the copy **silently drops everything outside `user.*`**. File capabilities vanish (`/usr/bin/newuidmap`/`newgidmap` lose `cap_setuid`/`cap_setgid`, breaking rootless podman and Apptainer uid/gid mapping) and SELinux labels vanish (files land with a wrong/default context, then the service that worked on a fresh install "fails after a restore"). It's silent because the copy tools skip unsupported namespaces per-file rather than aborting, and because `cp` without `-a`, `tar` without `--xattrs`, and `rsync` without `-X` drop xattrs on the copy *even on a local xattr-capable filesystem*. The fix direction: keep container/rootfs stores on local XFS or ext4, always copy with xattr preservation, and re-apply caps/labels after placement with `setcap`/`restorecon` — but remember caps still cannot live on the network mount itself, only on local storage.

## Hands-on labs

> All labs assume a **throwaway Linux VM** (any recent distro: Rocky/Fedora/Ubuntu/Debian with a ≥5.10 kernel; kernel ≥5.16 preferred for folio-era behavior). Run as root or via `sudo`. Nothing here should touch a real disk — we use loopback-backed images and tmpfs. Install once, distro-agnostic:
>
> ```bash
> # Debian/Ubuntu
> sudo apt-get update && sudo apt-get install -y e2fsprogs xfsprogs btrfs-progs strace bpftrace util-linux attr
> # RHEL/Rocky/Fedora
> sudo dnf install -y e2fsprogs xfsprogs btrfs-progs strace bpftrace util-linux attr
> ```

### Lab 1 — The fd → open-file-description → inode triangle

**Objective:** Prove, with syscall evidence, that fds are indices into a table of `struct file`s that point at inodes, and see how `dup`/`fork`/second-`open` differ in offset sharing and inode identity.

**Setup:**
```bash
mkdir -p /tmp/fslab && cd /tmp/fslab
printf 'ABCDEFGHIJ' > data.txt
```

**Steps:**
1. Watch a single open+read at the syscall level:
   ```bash
   strace -e trace=openat,read,lseek,dup,close cat data.txt
   ```
   Note the `openat(...) = 3` — fd 3 is the returned index.
2. Create a hard link and confirm one inode, two names:
   ```bash
   ln data.txt data_link.txt
   stat -c '%i %h %n' data.txt data_link.txt
   ```
3. Observe deleted-but-open space retention (the inode outlives its last dentry only while a fd holds it):
   ```bash
   # hold the file open in the background, then unlink all names
   exec 7< data.txt          # fd 7 in this shell holds the inode
   rm -f data.txt data_link.txt
   ls -l /proc/$$/fd/7        # still points at the (now deleted) inode
   cat /proc/$$/fd/7          # data still readable — space not freed yet
   exec 7<&-                  # close it; NOW the inode is freed
   ```
4. Show shared offset via a child process. Two separate `open()`s get independent offsets; a `fork`ed/`dup`ed fd shares one. Demonstrate with a tiny C program:
   ```bash
   cat > offset.c <<'EOF'
   #include <fcntl.h>
   #include <unistd.h>
   #include <stdio.h>
   #include <sys/wait.h>
   int main(){
     printf("XYZ0123456789") ; // silence unused warnings on some compilers
     int fd = open("shared.txt", O_RDONLY|O_CREAT|O_TRUNC, 0644);
     write(fd, "0123456789", 10); lseek(fd, 0, SEEK_SET);
     char b[4];
     if (fork()==0){ read(fd, b, 3); write(1, b, 3); write(1,"\n",1); _exit(0);} // child reads 0-2
     wait(0);
     read(fd, b, 3); write(1, b, 3); write(1,"\n",1); // parent continues from SHARED offset -> 3-5
     return 0;
   }
   EOF
   cc -o offset offset.c && ./offset
   ```
   Child prints `012`, parent prints `345` — the offset advanced across the fork because they share one `struct file`.

**Prove it:**
```bash
# The inode is identical across hard links; the link count reflects #dentries.
stat -c 'inode=%i links=%h' /tmp/fslab/shared.txt
# And the fork-shared-offset program printed non-overlapping bytes:
./offset | tr '\n' ' '   # expect: 012 345
```
If child+parent printed overlapping bytes (`012 012`), the offset was NOT shared — meaning you accidentally re-opened rather than inherited the fd.

**Teardown:**
```bash
# fd 7 is already closed in step 3; remove the files and binary this lab created.
cd /tmp/fslab && rm -f data.txt data_link.txt shared.txt offset.c offset
```

### Lab 2 — Make the page cache and dirty writeback visible

**Objective:** See buffered writes sit dirty in the page cache, watch writeback drain them, and trigger dirty-page throttling.

**Setup:**
```bash
cd /tmp/fslab
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches   # clean slate (test box only)
```

**Steps:**
1. Watch dirty pages accumulate on a buffered write and NOT be on disk yet:
   ```bash
   # in one terminal, watch dirty/writeback counters at 1s cadence
   watch -n1 "grep -E 'Dirty|Writeback:' /proc/meminfo"
   ```
   ```bash
   # in another: write 512MB buffered, then observe Dirty spike before it drains
   dd if=/dev/zero of=big.bin bs=1M count=512 conv=notrunc oflag=nonblock 2>&1
   grep -E 'Dirty|Writeback' /proc/meminfo
   ```
   `Dirty:` jumps, then decays as the `flush-*` worker writes back.
2. Prove `write()` returned before durability — force it down explicitly and time it:
   ```bash
   sync                                   # push everything to the block layer + flush
   /usr/bin/time -v sh -c 'dd if=/dev/zero of=fsync.bin bs=1M count=256 conv=fsync' 2>&1 | grep -E 'Elapsed|conv'
   ```
   Compare wall time with and without `conv=fsync` — the fsync version is slower because it waits for the device.
3. Trigger dirty-ratio throttling and watch a write *stall*. Temporarily set an aggressive absolute limit:
   ```bash
   cat /proc/sys/vm/dirty_bytes /proc/sys/vm/dirty_background_bytes
   echo 33554432  | sudo tee /proc/sys/vm/dirty_background_bytes   # 32MB
   echo 67108864  | sudo tee /proc/sys/vm/dirty_bytes              # 64MB hard cap
   strace -T -e trace=write dd if=/dev/zero of=throttle.bin bs=1M count=256 2>&1 | grep 'write(' | tail -20
   ```
   The `<...>` timing on late `write()` calls balloons once you cross the 64MB cap — that's `balance_dirty_pages` throttling in action.

**Prove it:**
```bash
# restore defaults, then confirm a cold read is I/O-bound and a warm read is cache-bound.
echo 0 | sudo tee /proc/sys/vm/dirty_bytes /proc/sys/vm/dirty_background_bytes
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
echo "COLD:"; dd if=big.bin of=/dev/null bs=1M 2>&1 | tail -1   # slow, hits disk
echo "WARM:"; dd if=big.bin of=/dev/null bs=1M 2>&1 | tail -1   # fast, hits page cache
```
The WARM throughput should be many times the COLD throughput — direct proof the second read served from `i_mapping`, not the device.

**Teardown:**
```bash
# Restore the dirty-writeback sysctls to their defaults (0 = fall back to the ratio knobs)
# and remove the test files. This lab modified vm.dirty_bytes / vm.dirty_background_bytes.
echo 0 | sudo tee /proc/sys/vm/dirty_bytes /proc/sys/vm/dirty_background_bytes
cd /tmp/fslab && rm -f big.bin fsync.bin throttle.bin
```
(These sysctls are runtime-only and reset on reboot; setting them back to 0 restores the stock ratio-based behavior on Rocky 9.)

### Lab 3 — ext4 vs XFS on-disk anatomy on loopback images

**Objective:** Build both filesystems on loop devices and inspect their real structures: extents, block groups, allocation groups, journals.

**Setup:**
```bash
cd /tmp/fslab
truncate -s 1G ext4.img
truncate -s 1G xfs.img
mkfs.ext4 -q ext4.img
mkfs.xfs -q -f xfs.img
mkdir -p /mnt/e4 /mnt/xf
sudo mount -o loop ext4.img /mnt/e4
sudo mount -o loop xfs.img  /mnt/xf
```

**Steps:**
1. ext4 superblock and geometry — read it without mounting semantics via `dumpe2fs`:
   ```bash
   sudo dumpe2fs ext4.img 2>/dev/null | grep -E 'Inode count|Block count|Block size|Blocks per group|Inodes per group|Journal|First inode|superblock at'
   ```
   Note the fixed inode count and the backup-superblock locations.
2. Create a large file and see it stored as extents (not indirect blocks):
   ```bash
   sudo dd if=/dev/zero of=/mnt/e4/large bs=1M count=200 conv=fsync 2>/dev/null
   filefrag -v /mnt/e4/large | head -20     # extent map: few large extents
   # inspect the inode's extent tree directly:
   sudo debugfs -R "stat large" ext4.img 2>/dev/null | sed -n '1,40p'
   ```
   `debugfs stat` shows `ETB` / extent entries in `i_block`.
3. Now force fragmentation and watch the extent count climb (interleaved writes):
   ```bash
   for i in $(seq 1 50); do sudo dd if=/dev/zero of=/mnt/e4/frag_$i bs=4k count=256 conv=fsync 2>/dev/null; done
   for i in $(seq 1 2 50); do sudo rm -f /mnt/e4/frag_$i; done
   sudo dd if=/dev/zero of=/mnt/e4/hole bs=4k count=6400 conv=fsync 2>/dev/null
   filefrag /mnt/e4/hole    # more extents than the clean 'large' file
   ```
4. XFS: see allocation groups and geometry, then prove it can grow but not shrink:
   ```bash
   sudo xfs_info /mnt/xf | sed -n '1,12p'    # 'agcount=' and 'agsize=' = allocation groups
   # grow the underlying image + fs:
   sudo umount /mnt/xf
   truncate -s 2G xfs.img
   sudo mount -o loop xfs.img /mnt/xf
   sudo xfs_growfs /mnt/xf | tail -3         # agcount increases
   # there is no xfs_shrink — confirm:
   which xfs_shrink; echo "exit=$?"          # exit=1, no such tool exists
   ```

**Prove it:**
```bash
# ext4 exposes a fixed inode count; XFS reports dynamic inodes.
echo "ext4 free inodes:"; df -i /mnt/e4 | tail -1
echo "xfs agcount after grow:"; sudo xfs_info /mnt/xf | grep -o 'agcount=[0-9]*'
# And the large file is a handful of extents, not thousands:
echo "large-file extents:"; filefrag /mnt/e4/large
```
**Teardown:**
```bash
sudo umount /mnt/e4 /mnt/xf; rm -f /tmp/fslab/ext4.img /tmp/fslab/xfs.img; sudo rmdir /mnt/e4 /mnt/xf
```

### Lab 4 — overlayfs and mount propagation: build a container rootfs by hand

**Objective:** Construct an overlay merge, trigger copy-up and a whiteout, then use mount namespaces + propagation to see how a container isolates (or leaks) mounts.

**Setup:**
```bash
cd /tmp/fslab
rm -rf over && mkdir -p over/{lower,upper,work,merged}
echo "from lower - readonly base" > over/lower/base.txt
echo "shared file"                > over/lower/shared.txt
```

**Steps:**
1. Mount the overlay and confirm reads fall through to lower:
   ```bash
   sudo mount -t overlay overlay \
     -o lowerdir=/tmp/fslab/over/lower,upperdir=/tmp/fslab/over/upper,workdir=/tmp/fslab/over/work \
     /tmp/fslab/over/merged
   cat /tmp/fslab/over/merged/base.txt      # served from lower
   ls -la /tmp/fslab/over/upper             # empty — no writes yet
   ```
2. Trigger copy-up by modifying a lower-only file, and watch upper populate:
   ```bash
   echo "modified in merged" >> /tmp/fslab/over/merged/shared.txt
   ls -la /tmp/fslab/over/upper             # shared.txt now exists in upper (copied up)
   cat /tmp/fslab/over/lower/shared.txt     # lower UNCHANGED — still one line
   ```
3. Delete a lower file through the merge and find the whiteout (a 0/0 char device):
   ```bash
   rm /tmp/fslab/over/merged/base.txt
   ls -la /tmp/fslab/over/upper/base.txt    # 'c' type, device 0, 0  => whiteout
   ls /tmp/fslab/over/merged/               # base.txt gone from the merged view
   cat /tmp/fslab/over/lower/base.txt       # still present in lower
   ```
4. Mount propagation: prove a mount inside a new mount namespace with a private root does NOT leak to the host:
   ```bash
   # host: make a fresh mount namespace, make / private there, then mount tmpfs
   sudo unshare --mount --propagation private bash -c '
     mkdir -p /tmp/fslab/ns_mnt
     mount -t tmpfs tmpfs /tmp/fslab/ns_mnt
     echo "inside-ns: $(grep ns_mnt /proc/self/mountinfo | wc -l) mount(s) of ns_mnt"
   '
   # back on the host: the tmpfs mount did NOT propagate out
   echo "on-host: $(grep ns_mnt /proc/self/mountinfo | wc -l) mount(s) of ns_mnt"
   ```

**Prove it:**
```bash
# Whiteout is a char device 0/0:
stat -c '%F %t,%T %n' /tmp/fslab/over/upper/base.txt   # "character special file 0,0"
# Copy-up left lower pristine (1 line) while merged/upper have 2:
echo "lower lines:  $(wc -l < /tmp/fslab/over/lower/shared.txt)"
echo "upper lines:  $(wc -l < /tmp/fslab/over/upper/shared.txt)"
# Propagation: host count is 0 (isolated), in-ns count was 1.
```
**Teardown:**
```bash
sudo umount /tmp/fslab/over/merged; rm -rf /tmp/fslab/over /tmp/fslab/ns_mnt
```

### Lab 5 (bonus, high-value) — Trace VFS with bpftrace: watch the dcache and syscalls live

**Objective:** Use dynamic tracing to make VFS internals observable with no source changes, connecting syscalls to the concept model.

**Setup:** bpftrace installed (from the common-install block); run as root.

**Steps:**
1. Count VFS-level operations by process for 10 seconds:
   ```bash
   sudo bpftrace -e '
     kprobe:vfs_read  { @reads[comm]  = count(); }
     kprobe:vfs_write { @writes[comm] = count(); }
     kprobe:vfs_open  { @opens[comm]  = count(); }
     interval:s:10    { exit(); }'
   ```
2. See dcache lookups vs misses (negative-dentry / real lookup path). Trace `d_lookup` and `lookup_slow`:
   ```bash
   sudo bpftrace -e '
     kprobe:d_lookup    { @dcache_lookup = count(); }
     kprobe:lookup_slow { @slow_path_disk_lookup = count(); }
     interval:s:5 { exit(); }' &
   # in another shell, generate a mix of cached and cold lookups:
   ls -R /usr/include >/dev/null 2>&1
   stat /nonexistent/a /nonexistent/b /nonexistent/c 2>/dev/null
   ```
3. Watch copy-up happen in real time during an overlay write (re-mount the Lab 4 overlay first), by tracing the fs read/write path latency histogram:
   ```bash
   sudo bpftrace -e '
     kprobe:vfs_write { @start[tid] = nsecs; }
     kretprobe:vfs_write /@start[tid]/ {
       @ns = hist(nsecs - @start[tid]); delete(@start[tid]); }
     interval:s:10 { exit(); }'
   ```

**Prove it:**
```bash
# Re-run step 1 while doing known work in another shell (e.g. `find /usr -type f | wc -l`);
# the @reads/@opens map should attribute the counts to `find`. Non-empty maps for the
# expected command name prove you instrumented the live VFS layer without a debugger.
```

---

### Lab 6 — Extended attributes across namespaces and the copy/backup footgun

**Objective:** Exercise the `user`, `trusted`, and `security` xattr namespaces directly; prove `trusted.*` needs `CAP_SYS_ADMIN` and that `security.capability` is just an xattr written by `setcap`; then reproduce the silent data-loss footgun where `cp` without `-a` and `tar` without `--xattrs` drop everything outside `user.*`, while `cp -a` / `rsync -X` / `tar --xattrs` preserve it. All on local XFS.

**Setup:** run as root (or via `sudo`); `attr`, `libcap`, `xfsprogs`, and `util-linux` from the common-install block.
```bash
mkdir -p /tmp/xalab && cd /tmp/xalab
truncate -s 512M xfs.img
mkfs.xfs -q -f xfs.img
mkdir -p /mnt/xattrlab
sudo mount -o loop xfs.img /mnt/xattrlab
cd /mnt/xattrlab
echo hello > file
cp /usr/bin/true ./mytool          # a harmless binary to hang a capability on
```

**Steps:**
1. `user.*` is permission-bit controlled and works unprivileged. Set one and note that plain `getfattr -d` only shows the user namespace:
   ```bash
   setfattr -n user.comment -v "owned metadata" file
   getfattr -d file                 # shows user.comment only (default -m '^user\.')
   getfattr -n user.comment file
   ```
2. `trusted.*` requires `CAP_SYS_ADMIN`. Prove an unprivileged user can neither set nor even *see* it, while root can:
   ```bash
   runuser -u nobody -- setfattr -n trusted.secret -v x file \
     2>&1 || echo "unprivileged trusted.* write: DENIED (expected)"
   setfattr -n trusted.secret -v x file          # root succeeds
   getfattr -n trusted.secret file               # root sees it
   runuser -u nobody -- getfattr -d -m - file    # nobody's listing has NO trusted.secret
   ```
3. `security.capability` is just an xattr that `setcap` writes. Set a capability and read it back both ways:
   ```bash
   setcap cap_net_raw+ep ./mytool
   getcap ./mytool                               # ./mytool cap_net_raw=ep
   getfattr -m - -d -e hex ./mytool              # security.capability=0x... (the raw blob)
   ```
   The same value seen through `getcap` and through `getfattr` is the point: capabilities and xattrs are one storage layer.
4. The copy/backup footgun. `file` now carries `user.comment` + `trusted.secret`; `mytool` carries `security.capability`. Copy them the naive way and the correct way, and compare:
   ```bash
   mkdir -p /tmp/xalab/ex_plain /tmp/xalab/ex_keep

   # cp WITHOUT -a: xattrs dropped
   cp file file.plain
   cp ./mytool ./mytool.plain
   getfattr -d -m - file.plain                   # empty: user.comment AND trusted.secret gone
   getcap ./mytool.plain                          # empty: capability lost

   # cp -a (= --preserve=all): preserved
   cp -a file file.arch
   cp -a ./mytool ./mytool.arch
   getfattr -d -m - file.arch                     # user.comment + trusted.secret present
   getcap ./mytool.arch                           # cap_net_raw=ep preserved

   # tar WITHOUT --xattrs: dropped
   tar -cf plain.tar file mytool
   tar -xf plain.tar -C /tmp/xalab/ex_plain
   getcap /tmp/xalab/ex_plain/mytool              # empty

   # tar --xattrs (must pass on BOTH create and extract): preserved
   tar --xattrs -cf keep.tar file mytool
   tar --xattrs -xf keep.tar -C /tmp/xalab/ex_keep
   getcap /tmp/xalab/ex_keep/mytool              # cap_net_raw=ep preserved
   getfattr -d -m - /tmp/xalab/ex_keep/file

   # rsync -X (as root, copies all namespaces except system.*)
   rsync -X file file.rsync
   getfattr -d -m - file.rsync                    # user.comment + trusted.secret present
   ```

**Prove it:**
```bash
echo "plain-copy cap: [$(getcap /mnt/xattrlab/mytool.plain)]"   # []  -> dropped
echo "cp -a    cap: [$(getcap /mnt/xattrlab/mytool.arch)]"      # [... cap_net_raw=ep] -> kept
echo "tar --xattrs cap: [$(getcap /tmp/xalab/ex_keep/mytool)]"  # [... cap_net_raw=ep] -> kept
```
An empty bracket for the plain copy next to a populated one for `cp -a`/`tar --xattrs` is the proof: the naive copy silently discarded a `security.*` xattr while reporting success.

**Note (why this matters off-box):** this drop is guaranteed, not optional, on **NFS and SMB** mounts regardless of copy flags, because those protocols only carry the `user.*` namespace (NFS per RFC 8276; SMB via the cifs `user_xattr` mapping — see [[13 - Samba and SMB]]). A `setcap` on such a mount returns `ENOTSUP`, and unpacking a container rootfs there silently strips file capabilities (breaking rootless `newuidmap`/`newgidmap`) and SELinux labels ([[12 - SELinux and Hardening]]). Keep those stores on local XFS/ext4. No NFS/SMB server is needed to internalize the failure mode — steps 4 reproduces the same namespace-scoped loss locally.

**Teardown:**
```bash
cd /
sudo umount /mnt/xattrlab
sudo rmdir /mnt/xattrlab
rm -rf /tmp/xalab
```
(The loopback image and its mount are the only system state this lab created; unmounting and removing the scratch dir fully reverts it.)

## Curated resources

**Primary kernel documentation (the definitive statements of behavior):**

- [Overview of the Linux Virtual File System — kernel.org](https://docs.kernel.org/filesystems/vfs.html) — The authoritative description of the superblock/inode/dentry/file object model and every `*_operations` vtable. Read this before any filesystem-specific doc; it's the abstraction all the others plug into.
- [Page Cache — kernel.org](https://docs.kernel.org/mm/page_cache.html) — The `address_space`/XArray/folio model where `read`, `write`, and `mmap` converge. The folio material is the current-kernel piece most older tutorials get wrong.
- [Shared Subtrees — kernel.org](https://docs.kernel.org/filesystems/sharedsubtree.html) — The canonical explanation of shared/slave/private/unbindable propagation and peer groups. This *is* the mechanism behind container mount isolation.
- [mount_namespaces(7) — man7](https://man7.org/linux/man-pages/man7/mount_namespaces.7.html) — Dense reference tying mount namespaces to propagation, `/proc/PID/mountinfo` fields, and `MS_*` flags. Read alongside `/proc/self/mountinfo` open in another pane.
- [Overlay Filesystem — kernel.org](https://docs.kernel.org/filesystems/overlayfs.html) — lowerdir/upperdir/workdir, copy-up, whiteouts (char 0/0), opaque dirs, redirect_dir, metacopy, and the xino/index inode-number features. The primary source for why container storage drivers behave as they do.
- [ext4 Data Structures and Algorithms — kernel.org](https://docs.kernel.org/filesystems/ext4/index.html) — On-disk layout: block groups, the extent tree, HTree directories, and the JBD2 on-disk journal format. The [JBD2 journal chapter](https://www.kernel.org/doc/html/latest/filesystems/ext4/journal.html) specifically explains transactions, commit records, and checksums.
- [XFS Delayed Logging Design — kernel.org](https://docs.kernel.org/filesystems/xfs/xfs-delayed-logging-design.html) — Why modern XFS logs metadata roughly once per hot object instead of once per change (the CIL). Pairs with the [XFS Algorithms & Data Structures on-disk spec (PDF)](https://cdn.kernel.org/pub/linux/utils/fs/xfs/docs/xfs_filesystem_structure.pdf) for allocation groups, the free-space/inode B+trees, and why XFS can't shrink.
- [Device Mapper — kernel admin-guide](https://docs.kernel.org/admin-guide/device-mapper/) — The layer under LVM (linear, snapshot COW exception store, thin provisioning, dm-crypt, dm-verity). Essential context for the block layer beneath these filesystems and for decoding `dmsetup table`.

**Books (canonical):**

- [The Linux Programming Interface (TLPI) — Kerrisk](https://man7.org/tlpi/) — The fd → open-file-description → inode three-level model, file I/O buffering, `fsync`/`O_SYNC` semantics, hard/symbolic links, and the whole syscall boundary. Written by the man-pages maintainer, still current because the ABI is stable. Chapters 4–5, 13–15, and 18 are the filesystem core; the ~200 example programs are the lab companion.
- [Understanding the Linux Kernel — Bovet & Cesati (3rd ed)](https://www.oreilly.com/library/view/understanding-the-linux-kernel/0596005652/) — Traces the actual data structures: the VFS objects, the dentry cache, the page cache and how a page fault / `do_generic_file_read` walks it. 2.6-era specifics have drifted, but the architecture of the walk is still the best paper explanation.
- [Linux Kernel Development — Robert Love (3rd ed)](https://www.amazon.com/Linux-Kernel-Development-Robert-Love/dp/0672329468) — The most approachable on-ramp to the VFS, the block I/O layer, and the page cache. Read the VFS and "The Block I/O Layer" chapters before Bovet/Cesati.
- [Operating Systems: Three Easy Pieces (OSTEP) — free](https://pages.cs.wisc.edu/~remzi/OSTEP/) — The Persistence section is the theory beneath everything here: filesystem design, journaling/crash-consistency, the fsck-vs-journaling tradeoff, and why CoW works. Read "Crash Consistency: FSCK and Journaling" before touching real journals.
- [Systems Performance, 2nd ed — Brendan Gregg](https://www.brendangregg.com/systems-performance-2nd-edition-book.html) — The Filesystems and Disks chapters: the USE method applied to the storage stack, page-cache hit ratio analysis, and where latency actually accrues from VFS down to the device.

**Deep dives, journalism, and hands-on:**

- [BPF Performance Tools — Brendan Gregg](https://www.brendangregg.com/bpf-performance-tools-book.html) — The Filesystems and Disk chapters give ready-to-run bcc/bpftrace tools (`cachestat`, `xfsslower`, `ext4slower`, `filelife`, `vfsstat`) with the methodology for *when* to reach for each. This is the observability endgame for filesystem latency.
- [LWN "Fast commits for ext4"](https://lwn.net/Articles/842385/) and the [LWN Kernel index](https://lwn.net/Kernel/Index/) (Filesystems / Page cache / folios topics) — How to keep current as the tree moves: the folio conversion, MGLRU, fast-commit, and online-fsck all landed with their reasoning explained here first. A subscription is the single best staleness-defense for staff-level fs knowledge.
- [Understanding ext4 — Opensource.com (Jim Salter)](https://opensource.com/article/18/4/ext4-filesystem) — A clear, correct narrative walkthrough of ext4's design decisions and the delayed-allocation crash-safety history. Good bridge before the kernel on-disk docs.
- [Klara Systems: ZFS vs Btrfs architecture](https://klarasystems.com/articles/zfs-vs-btrfs-architects-features-and-stability-2/) — An honest, technically deep comparison of the two CoW filesystems' architecture, RAID handling, and stability tradeoffs from a team that ships OpenZFS in production.
- [Julia Evans — jvns.ca](https://jvns.ca/) — The best explainers for building the reflex of interrogating a live filesystem (strace, `/proc` spelunking, "what is a file descriptor really"). The container and namespace zines complement the mount-propagation material here.
- [rockyman.org](https://rockyman.org/) — https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here (the `mkfs.xfs`, `xfs_repair`, `debugfs`, `filefrag`, `unshare`, and `df` flags used in the labs above were checked against it).
- Source to keep open in another window: `fs/namei.c` (path walk), `fs/dcache.c` (the dcache), `mm/filemap.c` (page cache read/write), `fs/overlayfs/` (copy-up, whiteouts), `include/linux/fs.h` (the structs). Reading the struct definitions once demystifies every doc above.

---

## Senior signal

- **Knows a successful `write()` is not durability, and can prove it.** Distinguishes page-cache-dirty (survives a process crash) from disk-committed (survives power loss), traces the `fsync` → block FLUSH/FUA → device-write-cache chain, and treats `nobarrier` / `cache=writeback` / consumer-SSD-ignoring-FLUSH as data-integrity red flags, not performance knobs.
- **Diagnoses dirty-writeback throttling as an invisible latency source.** When bulk writes suddenly stall, reaches for `/proc/meminfo` (Dirty/Writeback) and `balance_dirty_pages` rather than blaming "the disk," and knows to set `dirty_bytes` (absolute) over `dirty_ratio` on large-RAM boxes.
- **Reads `/proc/PID/mountinfo`, not just `mount`, and reasons in propagation types.** Can explain why systemd makes `/` shared, why a container runtime makes its root slave-or-private, and why a bind mount leaked (or didn't) across a namespace — the shared-subtree model, not hand-waving about "containers isolate things."
- **Explains a container image in filesystem terms.** overlayfs lower-stack = image layers, copy-up = first-write cost and growing write layers, whiteout = a 0/0 char device, and knows the backing fs must support `trusted.*` xattrs. Understands why the first write to a big file in a container is slow.
- **Matches the filesystem to the workload from first principles.** Picks XFS for many parallel writers (independent allocation groups) but knows it can't shrink; avoids Btrfs/ZFS CoW for random-overwrite DB/VM workloads (fragmentation) or applies `nodatacow` while understanding it kills checksums; knows ext4's fixed inode count and HTree history.
- **Treats fsck/repair as destructive-capable and sequences recovery correctly.** Replays the journal/log by mounting a healthy disk before reaching for `e2fsck`/`xfs_repair`; images the device first when data matters; understands `xfs_repair -L` zeroes the log and can lose data; knows backup-superblock recovery and that CoW filesystems need `scrub` + redundancy to *repair*, not just detect, bit rot.
- **Distinguishes the dcache/inode-cache slab from a memory leak.** Sees `dentry` and `xfs_inode`/`ext4_inode_cache` dominating `slabtop` as reclaimable cache, understands negative dentries and `vfs_cache_pressure`, and doesn't panic-`drop_caches` in production.
- **Traces a symptom to the right layer of the stack.** Can localize "slow file I/O" to the dcache (path-walk/negative dentries), the page cache (cold vs warm, readahead), the filesystem (journal commit, fragmentation, allocation), or the block/device layer (queue depth, flush latency) — and picks `strace` vs `filefrag` vs `cachestat`/`*slower` bpftrace tools vs `iostat` to *prove* which one, stating in advance what output would confirm the hypothesis.

---

## See also

- [[05 - Storage and LVM]] — the block layer beneath the filesystem: device-mapper, LVM, and loop devices are what these filesystems actually sit on, and the durability chain (fsync → FLUSH/FUA) continues down through it to the physical device.
- [[10 - Namespaces and cgroups v2]] — mount namespaces and mount propagation (covered here) are one of the namespaces that construct a container; that module ties the bind-mount/overlayfs/`pivot_root` mechanics from Labs 4 into the full container isolation model.
- [[03 - Containers from the Ground Up]] — overlayfs lowerdir/upperdir/copy-up (§7) is the mechanism behind container image layers; that module builds the image and rootfs story on top of this VFS layer.
- [[07 - Parallel and Networked Filesystems]] — Lustre, GPFS, and NFS extend the VFS/page-cache/fsync model here across the network; the durability chain and `fsync` semantics are what parallel filesystems must preserve at scale.
- [[06 - S3 and Storage Security]] — object storage as the non-POSIX alternative to a filesystem; contrast its eventual-consistency and flat-namespace model with the inode/dentry/page-cache model here.
- [[07 - Data and Storage for ML]] — dataset layout, page-cache warmth, and read-throughput for ML pipelines are direct applications of the readahead/page-cache and cold-vs-warm behavior in §3.
