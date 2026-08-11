---
title: Permissions and Access Control
type: module
track: linux-internals
tags: [linux-internals, permissions, dac, acl, capabilities, security, vfs, kernel, credentials]
requires: ["Rocky 9.x VM with root", "gcc toolchain (Lab 2)", "libcap/libcap-ng-utils, acl, attr, e2fsprogs, util-linux (setcap/getfacl/getfattr/chattr/setpriv)", "BTF/CO-RE for bcc/bpftrace cap_capable trace (Lab 4, optional)"]
module_number: 1
status: reviewed
created: 2026-07-08
---

# 01 - Permissions and Access Control

Backlink: [[00 - Track Overview]]

> Scope: the Discretionary Access Control (DAC) model as the kernel actually implements it. Mode bits, set-user-ID / set-group-ID / sticky, umask, POSIX ACLs, ext-family inode attributes (`chattr`/`lsattr`), and POSIX capabilities (file, ambient, bounding, permitted, effective, inheritable). The through-line is the kernel access-check path: `inode->i_mode` + the caller's `struct cred` + `capable()`. If you finish this module you should be able to read `generic_permission()` in `fs/namei.c` and predict the exact `-EACCES` / `0` outcome for any (subject, object, mask) triple, and explain why `ping` no longer needs setuid.

---

## Concept deep-dive

### 1. The mental model: subject credentials vs object labels vs the check

Every access decision in the DAC model is a function of three things:

```
       SUBJECT                    OBJECT                 OPERATION
  struct cred (per-task)     struct inode (per-file)      mask
  ---------------------      --------------------      -----------
  fsuid, fsgid               i_mode (type + 12 bits)   MAY_READ
  supplementary groups       i_uid, i_gid              MAY_WRITE
  cap_effective / permitted  POSIX ACL (xattr)         MAY_EXEC
  cap_inheritable            i_flags (immutable, ...)  MAY_APPEND
  cap_ambient / bounding                               MAY_ACCESS ...
        |                          |                        |
        +--------------------------+------------------------+
                                   v
                   inode_permission() -> generic_permission()
                                   v
                        return 0 (allow) or -EACCES/-EPERM
```

The subject side is the **credential**. In the kernel this is `struct cred` (see `include/linux/cred.h`), reference-counted and shared copy-on-write across tasks. The identity fields you care about for filesystem access are the **filesystem UID/GID** (`fsuid`/`fsgid`), *not* the effective UID/GID. On Linux, `fsuid` normally tracks `euid` (they were split historically so an NFS server could act as a client without being vulnerable to signals; `setfsuid(2)` still exists but is essentially vestigial). The credential also carries four/five capability sets and the supplementary group list (`group_info`).

The object side is the **inode**. `inode->i_mode` is a 16-bit field: the top 4 bits are the file *type* (`S_IFREG`, `S_IFDIR`, `S_IFLNK`, ...), and the low 12 bits are the permission bits, which decompose as:

```
  bit:  11  10   9    8 7 6   5 4 3   2 1 0
       [suid][sgid][svtx][ rwx ][ rwx ][ rwx ]
        4000  2000  1000  owner  group  other
```

`S_ISUID=04000`, `S_ISGID=02000`, `S_ISVTX=01000` (the "sticky"/save-text bit). `S_IRWXU=0700`, `S_IRWXG=070`, `S_IRWXO=07`. These constants are in `include/uapi/linux/stat.h`.

### 2. The kernel access-check path, line by line

This is the crux of the module. When you `open("/a/b/c", O_RDWR)`, the kernel walks the path (`path_lookup` -> `link_path_walk`), and for **each component** it must have search (`x`) permission on the directory, then finally the requested access on the leaf. The workhorse is `inode_permission()` -> `do_inode_permission()` -> `generic_permission()` -> `acl_permission_check()` in `fs/namei.c`.

Here is `acl_permission_check()` as it exists in current kernels (6.x), which is the pure Unix-bits + ACL check with **no capability override**:

```c
static int acl_permission_check(struct mnt_idmap *idmap,
                                struct inode *inode, int mask)
{
    unsigned int mode = inode->i_mode;
    vfsuid_t vfsuid;

    /* Fast path: if the "other" bits already grant everything asked,
       and there's no ACL, allow without comparing uid/gid at all. */
    if (!((mask & 7) * 0111 & ~mode)) {
        if (no_acl_inode(inode))
            return 0;
        if (!IS_POSIXACL(inode))
            return 0;
    }

    /* OWNER check: if fsuid == file owner, use the owner triad (mode>>6) */
    vfsuid = i_uid_into_vfsuid(idmap, inode);
    if (likely(vfsuid_eq_kuid(vfsuid, current_fsuid()))) {
        mask &= 7;
        mode >>= 6;
        return (mask & ~mode) ? -EACCES : 0;
    }

    /* NAMED-USER / NAMED-GROUP / owning-group via ACL, if present */
    if (IS_POSIXACL(inode) && (mode & S_IRWXG)) {
        int error = check_acl(idmap, inode, mask);
        if (error != -EAGAIN)
            return error;
    }

    /* GROUP check: if any of our groups matches file gid, use group triad */
    mask &= 7;
    if (mask & (mode ^ (mode >> 3))) {
        vfsgid_t vfsgid = i_gid_into_vfsgid(idmap, inode);
        if (vfsgid_in_group_p(vfsgid))
            mode >>= 3;
    }

    /* OTHER check: whatever mode we landed on */
    return (mask & ~mode) ? -EACCES : 0;
}
```

Three non-obvious things a staff engineer notices here:

1. **The triads are checked in strict precedence, not additively.** If you are the owner, *only* the owner bits are consulted. This is why `chmod 077 file` locks the **owner** out while giving group/other full access: the owner triad `0` short-circuits and returns `-EACCES` before group/other are ever considered. Mid-level engineers reliably get this wrong.

2. **The `mask & (mode ^ (mode >> 3))` trick.** This is an optimization to only do the (relatively expensive) supplementary-group membership test when the group bits actually *differ* from the other bits for the requested access. If group and other already agree on the requested bits, the group membership check is pointless.

3. **`vfsuid`/`vfsgid` and `mnt_idmap`.** Modern kernels (5.12+) thread an "id-mapped mount" transform through here. On a normal mount `vfsuid == kuid`, but idmapped mounts let a mount shift UIDs/GIDs (used heavily by containers and rootless setups). The comparison is always done in the *mount's* view.

`generic_permission()` wraps that and adds the **capability overrides** for `root` (or a process holding the relevant capability):

```c
int generic_permission(struct mnt_idmap *idmap, struct inode *inode, int mask)
{
    int ret;
    ret = acl_permission_check(idmap, inode, mask);
    if (ret != -EACCES)
        return ret;                 /* allowed by bits/ACL, or a hard -EPERM etc. */

    if (S_ISDIR(inode->i_mode)) {
        /* read/search on a directory */
        if (!(mask & MAY_WRITE))
            if (capable_wrt_inode_uidgid(idmap, inode, CAP_DAC_READ_SEARCH))
                return 0;
        if (capable_wrt_inode_uidgid(idmap, inode, CAP_DAC_OVERRIDE))
            return 0;
        return -EACCES;
    }

    mask &= MAY_READ | MAY_WRITE | MAY_EXEC;
    if (mask == MAY_READ)
        if (capable_wrt_inode_uidgid(idmap, inode, CAP_DAC_READ_SEARCH))
            return 0;

    /* CAP_DAC_OVERRIDE grants exec ONLY if at least one x bit is set.
       This is why root cannot execute a 0644 file: no x bit anywhere. */
    if (!(mask & MAY_EXEC) || (inode->i_mode & S_IXUGO))
        if (capable_wrt_inode_uidgid(idmap, inode, CAP_DAC_OVERRIDE))
            return 0;

    return -EACCES;
}
```

The subtle, interview-grade fact lives in the last `if`: **`CAP_DAC_OVERRIDE` does not let even root execute a file that has no execute bit set anywhere** (`S_IXUGO = 0111`). Read/write override is unconditional for root; execute override requires at least one `x` bit. So `chmod 000 script.sh; sh script.sh` works as root (root reads it, `sh` interprets), but `chmod 644 binary; ./binary` fails with `EACCES` even as root because the exec check on the binary itself finds no `x` bit. Everyone "knows root ignores permissions"; this is the exception that proves you've read the code.

`capable_wrt_inode_uidgid()` is itself important: it checks the capability **against the inode's owning user namespace**, i.e. root-in-a-user-namespace can only override DAC for files owned by UIDs mapped into that namespace. This is the mechanism that makes rootless containers safe.

Above `generic_permission()`, `inode_permission()` layers two more gates *before* the DAC check:

```c
int inode_permission(struct mnt_idmap *idmap, struct inode *inode, int mask)
{
    retval = sb_permission(inode->i_sb, inode, mask);   /* read-only mount? */
    if (mask & MAY_WRITE) {
        if (IS_IMMUTABLE(inode))       return -EPERM;    /* chattr +i */
        if (HAS_UNMAPPED_ID(idmap, inode)) return -EACCES;
    }
    retval = do_inode_permission(...);                  /* -> generic_permission */
    ...
    return security_inode_permission(inode, mask);      /* LSM hook: SELinux/AppArmor */
}
```

Two takeaways: (a) a **read-only mount or an immutable inode returns `-EPERM`/`-EROFS` before DAC even runs**, which is why `chattr +i` defeats even root (root has `CAP_DAC_OVERRIDE` but the immutable check is upstream of DAC and requires `CAP_LINUX_IMMUTABLE` to *clear* the flag, not to bypass it); and (b) the **LSM hook runs last** (`security_inode_permission`), so SELinux/AppArmor can only *further deny* what DAC already allowed. DAC and MAC are AND-ed, never OR-ed. If DAC says no, SELinux never gets a vote.

```
   MAY_WRITE? --immutable/RO--> -EPERM/-EROFS   (before DAC)
        |
        v
   generic_permission  (DAC: bits + ACL + capability override)  -> -EACCES?
        |  allow
        v
   security_inode_permission  (MAC: SELinux/AppArmor)  -> can only deny further
        |  allow
        v
      access granted
```

### 3. set-user-ID, set-group-ID, sticky: what they mean per file type

These bits are overloaded by file type, which is a frequent source of confusion.

**On an executable regular file:**
- `setuid` (`04000`): on `execve(2)`, the new process's `euid` (and `fsuid`) become the file **owner's** UID; `ruid` is unchanged, and `suid` (saved) is set to the new `euid`. This is the classic privilege escalation vector (`passwd`, historically `ping`, `sudo`).
- `setgid` (`02000`): same for `egid`/`fsgid` -> file group.
- The kernel clears these bits automatically on write to the file (`file_remove_privs()` / `should_remove_privs()`), so you can't append to a setuid binary and keep the bit.
- The real/effective split is what lets a setuid program *drop* privilege temporarily (`seteuid`) and regain it (from `suid`). Getting this wrong (dropping euid but leaving suid) is a canonical local-root bug.

**On a directory:**
- `setgid` (`02000`): new files/subdirs created inside **inherit the directory's group** rather than the creator's fsgid, and new subdirectories inherit the setgid bit too. This is the standard mechanism for shared group directories. (`setuid` on a directory is **ignored** on Linux; on some BSDs it affected ownership inheritance, but not here.)
- `sticky`/`S_ISVTX` (`01000`): the "restricted deletion" flag. In a sticky directory, a file may be unlinked/renamed only by the file's owner, the directory's owner, or `CAP_FOWNER`. This is why `/tmp` (mode `1777`) is world-writable but users can't delete each other's files. Historically on executables the sticky bit meant "keep text segment in swap"; that meaning is dead on Linux.

`execve` privilege transitions are gated further: a setuid transition is suppressed if the mount is `nosuid`, if the file has file capabilities (fcaps and setuid on the same file: fcaps win for the transition semantics), or if the process is being traced. And with `no_new_privs` set (see §6), setuid bits are ignored entirely.

### 4. umask: the complement mask, and where it actually applies

`umask` is a per-process field (`current->fs->umask`, in `struct fs_struct`, shared per-thread-group). It is **not** a permission; it's a mask of bits to *clear* from the mode requested at creation time. `open(..., mode)` and `mkdir(..., mode)` compute `mode & ~umask` as the *starting* mode (the filesystem/ACL layer may then further modify it).

Critical mechanism points:
- umask only affects **newly created** objects, and only the bits the creating call requests. `open` with `0666` under `umask 022` yields `0644`; a compiler emitting `0777` for a binary under the same umask yields `0755`.
- **umask does not clear setuid/setgid/sticky** in the sense you'd expect: those come from the requested mode, and most `open`/`mkdir` callers don't request them anyway.
- **Default ACLs override umask.** If a directory has a POSIX *default* ACL, the umask is ignored for objects created in it and the default ACL supplies the permissions instead (see `posix_acl_create()` in `fs/posix_acl.c`). This is a common "why did my umask not apply" mystery. This behavior is mandated by the POSIX ACL spec.
- The shell builtin `umask` and the syscall `umask(2)` are the same state; there is no way to *read* the umask without also setting it via the syscall (`umask(2)` returns the previous value), which is why `/proc/<pid>/status` gained a `Umask:` line so you can inspect a running process's umask non-destructively.

### 5. POSIX ACLs: the extended DAC

POSIX ACLs (the never-ratified POSIX.1e draft, but universally implemented) extend the three-triad model to arbitrary named users and groups. They are stored as the extended attributes `system.posix_acl_access` and `system.posix_acl_default` (binary-packed `struct posix_acl_xattr_header` + entries), and the kernel caches the parsed form on the inode (`inode->i_acl`).

An ACL is an ordered list of entries, each a `(tag, id, perms)` triple:

```
  ACL_USER_OBJ   (the owner; == owner mode bits)
  ACL_USER       (a named user, has an id)
  ACL_GROUP_OBJ  (the owning group)
  ACL_GROUP      (a named group, has an id)
  ACL_MASK       (the effective-rights mask)
  ACL_OTHER      (everyone else; == other mode bits)
```

The check algorithm (`posix_acl_permission()` in `fs/posix_acl.c`) walks entries in the order above and stops at the **first matching tag class**:

```
  if fsuid == ACL_USER_OBJ.id      -> use USER_OBJ perms (NOT masked)
  elif fsuid matches an ACL_USER   -> use that entry's perms & MASK
  elif a group matches GROUP_OBJ
       or matches an ACL_GROUP     -> use (that entry's perms) & MASK
  else                             -> use ACL_OTHER perms (NOT masked)
```

The two mechanism points that trip people up:

1. **The mask is an upper bound, not a grant.** `ACL_MASK` is the maximum effective permission for **named users, named groups, and the owning group** (`ACL_USER`, `ACL_GROUP`, `ACL_GROUP_OBJ`). It does **not** limit `ACL_USER_OBJ` (owner) or `ACL_OTHER`. `getfacl` prints `#effective:` comments to show you the post-mask result of each affected entry. A user can grant `rwx` to a named user, then set the mask to `r--`, and the named user effectively has only `r--`.

2. **The mask *is* the group mode bits.** When an ACL with a mask exists, the file's "group" permission bits shown by `ls -l` are actually the **mask**, not `ACL_GROUP_OBJ`. `ls -l` appends a `+` to signal "there's an ACL here, the middle triad is lying to you." This is why `chmod g=rw file` on an ACL'd file changes the *mask* and silently caps every named entry, a nasty foot-gun in automation.

**Default ACLs** (`system.posix_acl_default`, directories only) are the inheritance template: they don't affect access to the directory itself, but on object creation they (a) become the new object's access ACL and (b) for subdirectories are copied as the child's default ACL too, giving recursive inheritance. They override umask as noted above. The intersection of "default ACL" + the mode requested by `open`/`mkdir` is computed in `posix_acl_create()`.

Scale/failure notes: ACLs live in xattrs, which on ext4 are stored inline in the inode's extra space if small, else in a shared external xattr block (`ext4_xattr_block`). Deep default-ACL inheritance across millions of files bloats inodes and can defeat the inline-xattr fast path, hurting `stat`-heavy workloads. `nfsv4` ACLs are a *different*, richer model (`NFSv4`/Windows-style, with allow/deny ordering) mapped imperfectly onto POSIX ACLs; cross-protocol (SMB/NFS/local) ACL translation is where real production pain lives.

### 6. Linux capabilities: decomposing root

`CAP_*` splits the historic all-or-nothing `uid==0` superpower into ~40+ distinct privileges (`include/uapi/linux/capability.h`; the authoritative list is `capabilities(7)`). Examples: `CAP_NET_BIND_SERVICE` (bind < 1024), `CAP_NET_RAW` (raw sockets, what `ping` needs), `CAP_DAC_OVERRIDE` (bypass file rwx), `CAP_DAC_READ_SEARCH` (bypass read+search), `CAP_FOWNER` (act as file owner for chmod/utime/etc.), `CAP_SYS_ADMIN` (the sprawling catch-all), `CAP_LINUX_IMMUTABLE` (set/clear `+i`/`+a`), `CAP_SETUID`/`CAP_SETGID`, `CAP_CHOWN`.

Every task has **five** capability sets in its `struct cred` (`kernel/cred.c`, type `kernel_cap_t`, a bitmask):

```
  Permitted   (P) : the superset the thread MAY put into effective
  Effective   (E) : the set actually checked by capable()
  Inheritable (I) : preserved across execve, ANDed with file's I
  Bounding    (B) : per-thread ceiling; caps here can never be gained
  Ambient     (A) : caps preserved across execve of a NON-fcap binary (since 4.3)
```

`capable(CAP_X)` (kernel side) simply asks "is CAP_X in the current thread's **effective** set (in the relevant user namespace)?" -> `security_capable()` -> `cap_capable()` in `security/commoncap.c`. Everything else (permitted, inheritable, bounding, ambient, file caps) exists only to control **what ends up in effective** across `execve`.

**File capabilities** live in the `security.capability` xattr. Format is `struct vfs_ns_cap_data` (VFS_CAP_REVISION_3 today), which is the older `vfs_cap_data` (a magic/version word, plus permitted and inheritable 32-bit halves for the low and high cap ranges, plus an "effective" flag bit) **with a trailing `rootid`** (a `uid_t` in the initial user namespace). The v3/rootid addition (Linux 4.14, Christian Brauner) is what lets an *unprivileged* user in a user namespace set file capabilities that are only honored for files whose rootid maps to that namespace's root, i.e. namespaced fcaps. The kernel transparently translates v2<->v3 based on the writer's user namespace.

The transition at `execve` is the formula every staff candidate should be able to reproduce (`capabilities(7)`):

```
  P'(ambient)     = (file is privileged) ? 0 : P(ambient)
  P'(permitted)   = (P(inheritable) & F(inheritable))
                     | (F(permitted) & P(bounding))
                     | P'(ambient)
  P'(effective)   = F(effective) ? P'(permitted) : P'(ambient)
  P'(inheritable) = P(inheritable)          (unchanged)
  P'(bounding)    = P(bounding)             (unchanged)
```

Where `P` is the thread set before exec, `P'` after, `F` the file set. "File is privileged" means the file has fcaps or a set-uid/set-gid bit. Read what this actually says:

- **`F(effective)` is a single bit, not a set.** If set, all of `P'(permitted)` is copied into effective (the binary is "capability-dumb", it gets its caps active immediately, like a legacy setuid program). If clear, the binary is "capability-aware" and must raise caps from permitted into effective itself via `capset(2)`/`libcap`.
- **The `F(permitted) & P(bounding)` term** is how fcaps grant privilege: set `cap_net_raw+p` on a file, and any execer gets `CAP_NET_RAW` in permitted (bounded by their bounding set). This is *exactly* how modern `ping` works: `setcap cap_net_raw+ep /usr/bin/ping` instead of setuid-root. No UID change, blast radius is one capability, not full root.
- **The inheritable term `P(I) & F(I)` is the "pass a cap through exec" path**, but it requires *both* the process and the file to opt in, which is why it's rarely used and confusing.
- **Ambient (Linux 4.3+) fixed the real-world gap:** inheritable caps were useless for the common case because a normal binary has empty `F(inheritable)`, so caps evaporated on exec. Ambient caps survive exec of a *non-privileged* file without needing fcaps on it, provided the cap is in both permitted and inheritable. This is how you run a normal daemon under a specific capability without setcap and without root, e.g. `systemd`'s `AmbientCapabilities=`.

**`no_new_privs`** (`prctl(PR_SET_NO_NEW_PRIVS)`, `/proc/<pid>/status: NoNewPrivs`) is the modern safety latch: once set (and inherited by all children, cleared only by a fresh exec that... can't clear it), `execve` will **not** grant any new privileges, so setuid bits and file capabilities are ignored. seccomp requires it; container runtimes and `systemd` (`NoNewPrivileges=yes`) set it. Knowing it exists and why setcap "stopped working" under it is a senior tell.

The **bounding set** is the per-thread ceiling. Dropping a cap from the bounding set (`prctl(PR_CAPBSET_DROP)`, or `capsh --drop=` / systemd `CapabilityBoundingSet=`) means no `execve` of any fcap binary can ever bring it back for that process tree. This is the real hardening primitive: don't run as non-root and hope, *drop the capability from the bound* so it's unreachable.

### 7. Inode flags: `chattr`/`lsattr` (the fourth access dimension)

Beyond mode/ACL/caps there's a set of per-inode flags manipulated by `chattr(1)`/`lsattr(1)` via the `FS_IOC_SETFLAGS`/`FS_IOC_GETFLAGS` ioctls (`ioctl_iflags(2)`), stored in the on-disk inode's flags field (e.g. `EXT4_IMMUTABLE_FL = 0x10`, `EXT4_APPEND_FL = 0x20`). Implemented by ext2/3/4, XFS, btrfs, f2fs (XFS also exposes some via `FS_IOC_FSSETXATTR`).

The two that matter for access control:
- **`i` (immutable):** the inode cannot be modified, renamed, unlinked, hard-linked to, or opened for write, *by anyone including root*. Enforced upstream of DAC in `inode_permission()` via `IS_IMMUTABLE()` -> `-EPERM`. Setting/clearing it needs `CAP_LINUX_IMMUTABLE`.
- **`a` (append-only):** the file can be opened for write only with `O_APPEND`, and cannot be truncated/unlinked/renamed. The log-tamper-resistance primitive. Also gated by `CAP_LINUX_IMMUTABLE`.

These are the mechanism behind "even root can't touch this": root's `CAP_DAC_OVERRIDE` is checked *inside* `generic_permission`, but the immutable/append gate is *above* it and only yields to a *different* capability whose whole job is toggling the flag. A machine where an attacker has root but not `CAP_LINUX_IMMUTABLE` (dropped from the bounding set) genuinely cannot alter `+i` files. Other flags of note: `A` (no atime updates), `d` (no dump), `j` (data journaling, ext4), `C` (no-COW, btrfs), `S`/`D` (synchronous updates).

### 8. How it composes at scale / failure modes

- **`/proc/<pid>/status`** exposes the live subject side: `Uid:` `Gid:` (real/eff/saved/fs), `Groups:`, `CapInh/CapPrm/CapEff/CapBnd/CapAmb` (hex bitmasks, decode with `capsh --decode=`), `NoNewPrivs`, `Seccomp`, `Umask`. This is your primary forensic surface when "permission denied" makes no sense.
- **`capable()` audit noise:** `CAP_SYS_ADMIN` is checked in hundreds of call sites; granting it to a container is nearly equivalent to root. "Least privilege" means enumerating the *specific* caps a workload uses (trace with `capable` from bcc / `bpftrace` on the `cap_capable` kprobe) and dropping the rest from the bounding set.
- **NFS and the squashing problem:** NFSv3 does DAC on the *server* by UID number; capabilities don't cross the wire, and `root_squash` maps client-root to `nobody`. `CAP_DAC_OVERRIDE` on the client is meaningless server-side. Cross-host UID/GID drift is the classic "works locally, EACCES over NFS."
- **Idmapped mounts / user namespaces:** the same on-disk UID can be a different subject depending on the mount's idmap and the caller's userns. At container scale, "who owns this file" has no answer without naming the namespace.
- **xattr exhaustion:** heavy ACL/fcap/SELinux-label use multiplies xattrs; on ext4 that can spill inline xattrs to external blocks and slow metadata-heavy workloads.

---

## Hands-on labs

> All labs assume a **throwaway VM** (any recent distro: Rocky/Alma 9, Fedora, Ubuntu 22.04+, Debian 12). Run as a user with `sudo`. Install tooling once, distro-agnostically:
>
> ```bash
> # Debian/Ubuntu
> sudo apt-get update && sudo apt-get install -y libcap2-bin acl strace attr bpfcc-tools
> # RHEL/Rocky/Fedora
> sudo dnf install -y libcap libcap-ng-utils acl strace attr bcc-tools
> ```
> `libcap2-bin`/`libcap` gives you `getcap`/`setcap`/`capsh`; `acl` gives `getfacl`/`setfacl`; `attr`/`e2fsprogs` gives `getfattr`/`chattr`. Do everything in a scratch dir: `mkdir -p ~/lab01 && cd ~/lab01`.

### Lab 1 — Watch the kernel make the decision (the precedence rule made visible)

**Objective:** Prove that triads are checked by precedence (owner-then-group-then-other, first match wins) and that this can lock the owner out. Then watch the exact syscall + errno.

**Setup:**
```bash
cd ~/lab01
sudo useradd -m alice 2>/dev/null; sudo useradd -m bob 2>/dev/null
echo secret > file.txt
```

**Steps:**
1. Give the *owner* no access but group/other full access, an "impossible"-looking mode:
   ```bash
   sudo chown alice:alice file.txt
   sudo chmod 077 file.txt      # owner: ---, group: rwx, other: rwx
   ls -l file.txt
   ```
2. As the **owner** alice, try to read it, and trace the syscall:
   ```bash
   sudo -u alice strace -f -e trace=openat cat file.txt 2>&1 | grep -E 'openat|EACCES'
   ```
   You will see `openat(... O_RDONLY) = -1 EACCES (Permission denied)` even though group and other have `rwx`. The owner triad `---` matched first and short-circuited.
3. Now as **bob** (not the owner, not in alice's group), read succeeds via the "other" triad:
   ```bash
   sudo -u bob cat file.txt      # prints: secret
   ```
4. Prove root's exec exception. Make a runnable script but strip *all* execute bits:
   ```bash
   printf '#!/bin/sh\necho ran\n' > s.sh
   chmod 644 s.sh                # rw-r--r--, no x anywhere
   sudo ./s.sh                   # -> Permission denied, EVEN AS ROOT
   sudo sh s.sh                  # -> ran   (root reads it, sh interprets)
   ```
   Step 4 is `generic_permission()`'s `(inode->i_mode & S_IXUGO)` guard on `CAP_DAC_OVERRIDE` in action: root can read anything, but cannot *exec* a file with zero x bits.

**Prove it:**
```bash
sudo -u alice sh -c 'cat file.txt 2>&1; echo "exit=$?"'
# Expected: "cat: file.txt: Permission denied" and exit=1
# because as owner, mode 077's owner-triad (---) denies and short-circuits.
```
If alice is *denied* while bob is *allowed* on the same file, you have demonstrated triad precedence. Bonus: `sudo ./s.sh` returning "Permission denied" as root proves the exec-bit exception to `CAP_DAC_OVERRIDE`.

**Teardown:**
```bash
sudo userdel -r alice 2>/dev/null; sudo userdel -r bob 2>/dev/null
rm -f ~/lab01/file.txt ~/lab01/s.sh
```

### Lab 2 — Replace setuid with a file capability (the `ping` mechanism)

**Objective:** Build a minimal program that binds a privileged port, watch it fail as an ordinary user, then grant exactly `CAP_NET_BIND_SERVICE` via a file capability, and confirm via the transition formula. This is the "why `ping` isn't setuid anymore" lab.

**Setup:**
```bash
cd ~/lab01
sudo dnf install -y gcc 2>/dev/null || sudo apt-get install -y gcc
cat > bind80.c <<'EOF'
#include <stdio.h>
#include <string.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
int main(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(80);
    if (bind(s, (struct sockaddr*)&a, sizeof a) < 0) { perror("bind"); return 1; }
    printf("bound port 80 as uid=%d\n", getuid());
    return 0;
}
EOF
gcc -O2 -o bind80 bind80.c
```

**Steps:**
1. Run as your normal (non-root) user, and trace the failing syscall:
   ```bash
   strace -e trace=bind ./bind80
   # bind(...) = -1 EACCES (Permission denied)   <- kernel wanted CAP_NET_BIND_SERVICE
   ```
2. Confirm the binary currently has no file caps:
   ```bash
   getcap ./bind80          # (no output = no fcaps)
   ```
3. Grant exactly the one capability, in the "effective+permitted" form (the `+ep` means: put it in the file permitted set, and set the file effective bit so it's live immediately, no `capset` needed):
   ```bash
   sudo setcap cap_net_bind_service+ep ./bind80
   getcap ./bind80          # ./bind80 cap_net_bind_service=ep
   getfattr -n security.capability -e hex ./bind80   # see the raw xattr
   ```
4. Run again as the **unprivileged** user, it now succeeds with **no UID change**:
   ```bash
   ./bind80                 # bound port 80 as uid=1000
   ```
5. Inspect the live process caps to see the formula's output. In one shell, make it sleep; in another, read `/proc/<pid>/status`:
   ```bash
   # add a getchar()/sleep to bind80, OR just reason from the static xattr:
   capsh --decode=$(getpcaps $$ 2>/dev/null; echo) 2>/dev/null
   # Static reasoning: F(permitted)={cap_net_bind_service}, F(effective)=set
   #   => P'(permitted) includes it (bounded by P(bounding)),
   #      P'(effective) = P'(permitted) because F(effective) bit is set.
   ```
6. Contrast with the old way and the danger it removes:
   ```bash
   sudo chmod u+s ./bind80  # the OLD setuid-root approach (don't ship this)
   ls -l bind80             # -rwsr-xr-x  => full root euid for the whole process
   sudo chmod u-s ./bind80  # revert; fcaps are strictly less blast radius
   ```

**Prove it:**
```bash
id -u                                        # confirm you are NOT 0
sudo setcap cap_net_bind_service+ep ./bind80
./bind80 && echo "SUCCESS: bound :80 as uid $(id -u) with one capability, no setuid"
```
Success = an unprivileged UID bound a <1024 port carrying exactly one capability. Now test the `no_new_privs` interaction, the senior gotcha:
```bash
# Under no_new_privs, fcaps are IGNORED -> bind fails again even with the setcap above:
sudo dnf install -y util-linux 2>/dev/null
setpriv --no-new-privs ./bind80    # -> bind: Permission denied
```
That last command failing *despite* the file capability being present is the whole point: `NoNewPrivs` short-circuits privilege gain at `execve`.

**Teardown:**
```bash
rm -f ~/lab01/bind80 ~/lab01/bind80.c
# (the security.capability xattr is removed with the file)
```

### Lab 3 — POSIX ACLs and the mask foot-gun

**Objective:** Grant a named user access beyond the mode bits, then demonstrate that (a) `ls -l`'s middle triad is actually the ACL mask, (b) `chmod g=` silently caps every named entry via the mask, and (c) default ACLs override umask on creation.

**Setup:**
```bash
cd ~/lab01
sudo useradd -m carol 2>/dev/null
mkdir shared && echo data > shared/report.txt
chmod 640 shared/report.txt          # rw-r----- , owned by you
sudo -u carol cat shared/report.txt  # -> Permission denied (carol not owner/group)
```

**Steps:**
1. Grant carol read via a named-user ACL entry, without touching group/other:
   ```bash
   setfacl -m u:carol:r-- shared/report.txt
   getfacl shared/report.txt
   sudo -u carol cat shared/report.txt   # -> data  (works now)
   ls -l shared/report.txt               # note the trailing '+'
   ```
2. Observe that the `mask::` line appeared and that `ls -l`'s middle triad now reflects the **mask**, not the owning group. Add a fuller entry and watch `#effective`:
   ```bash
   setfacl -m u:carol:rwx shared/report.txt
   setfacl -m m::r-- shared/report.txt      # cap the mask at r--
   getfacl shared/report.txt
   # carol shows "user:carol:rwx  #effective:r--"  -> mask clamped her to r--
   ```
3. Demonstrate the `chmod` foot-gun: `chmod g=` rewrites the mask, silently clamping every named entry:
   ```bash
   setfacl -m u:carol:rwx -m m::rwx shared/report.txt
   getfacl shared/report.txt | grep carol   # effective rwx
   chmod g=r shared/report.txt              # LOOKS like it only touches group...
   getfacl shared/report.txt | grep carol   # ...but carol is now #effective:r--
   ```
4. Default ACLs vs umask. Set a permissive umask, then prove the default ACL wins:
   ```bash
   umask 077                                       # would normally strip group/other
   setfacl -d -m u:carol:rwx shared                # default ACL on the directory
   touch shared/new.txt
   getfacl shared/new.txt
   # new.txt has user:carol:rwx from the inherited default ACL, DESPITE umask 077.
   ```

**Prove it:**
```bash
getfacl --omit-header shared/report.txt | grep '^user:carol'
# After step 3, expected: user:carol:rwx  #effective:r--
# Seeing "#effective:r--" while the entry says "rwx" proves you understand
# that the mask is an upper bound and that chmod g= rewrites it.
```

**Teardown:**
```bash
sudo userdel -r carol 2>/dev/null
rm -rf ~/lab01/shared
```

### Lab 4 — Immutable files and capability bounding: locking out root

**Objective:** Show that `chattr +i` denies write to root (the gate is above DAC), that only `CAP_LINUX_IMMUTABLE` can clear it, and that dropping that cap from the bounding set makes even root unable to unlock the file, then trace `cap_capable` to see the check fire.

**Setup:**
```bash
cd ~/lab01
echo "audit log" | sudo tee /root/protected.log >/dev/null
```

**Steps:**
1. Make it immutable and prove root can't write or delete it:
   ```bash
   sudo chattr +i /root/protected.log
   lsattr /root/protected.log                 # ----i---------e-- ...
   echo more | sudo tee -a /root/protected.log    # -> Operation not permitted (EPERM)
   sudo rm -f /root/protected.log             # -> cannot remove: Operation not permitted
   ```
   Note the errno is **EPERM**, not EACCES: this is the `IS_IMMUTABLE()` gate in `inode_permission()`, upstream of DAC. Root's `CAP_DAC_OVERRIDE` is irrelevant here.
2. Confirm only `CAP_LINUX_IMMUTABLE` clears it. Drop that cap and try, using `capsh`:
   ```bash
   sudo capsh --drop=cap_linux_immutable -- -c 'chattr -i /root/protected.log' \
     ; echo "exit=$?"
   # -> chattr: Operation not permitted while setting flags ... exit non-zero
   lsattr /root/protected.log                 # still immutable
   ```
3. Now clear it *with* the capability present (normal root), and confirm write works:
   ```bash
   sudo chattr -i /root/protected.log
   echo more | sudo tee -a /root/protected.log >/dev/null && echo "write OK"
   ```
4. Watch the capability check fire in the kernel (needs bcc/bpftrace). In one terminal:
   ```bash
   # bcc 'capable' tool: prints every capable() check with the cap name + comm
   sudo /usr/share/bcc/tools/capable 2>/dev/null || sudo capable
   ```
   In another terminal, run `sudo chattr +i /root/protected.log` and watch the first
   terminal log a `CAP_LINUX_IMMUTABLE` check by `chattr`. (If `capable` isn't packaged,
   use bpftrace: `sudo bpftrace -e 'kprobe:cap_capable { printf("%s cap=%d\n", comm, arg2); }'`.)

**Prove it:**
```bash
sudo chattr +i /root/protected.log
sudo sh -c 'echo x >> /root/protected.log' 2>&1; echo "root-write-exit=$?"
sudo chattr -i /root/protected.log     # cleanup
# Expected: an EPERM error and root-write-exit=1, with the file unchanged.
```
A non-zero exit and unchanged file while running as root demonstrates that the immutable flag sits above the DAC/capability-override path and yields only to `CAP_LINUX_IMMUTABLE` toggling the flag itself, not to any file-access capability.

**Teardown:**
```bash
sudo chattr -i /root/protected.log 2>/dev/null   # clear immutable first, or rm fails with EPERM
sudo rm -f /root/protected.log
```

---

## Curated resources

**Primary references (the ABI is the source of truth):**

- [capabilities(7) — Linux man page](https://man7.org/linux/man-pages/man7/capabilities.7.html) — The single most important page for this module. Read it end to end, not as lookup. It contains the exact `execve` transformation formula, the full cap list, the file-capability xattr semantics (v1/v2/v3), ambient/bounding rules, `securebits`, and `no_new_privs` interaction. When a blog and this page disagree, this page wins.
- [credentials(7)](https://man7.org/linux/man-pages/man7/credentials.7.html) and [path_resolution(7)](https://man7.org/linux/man-pages/man7/path_resolution.7.html) — The subject model (real/effective/saved/fs UIDs, supplementary groups, the credential lifecycle) and the exact per-component permission requirement during path walk. `path_resolution(7)` is what makes "you need `x` on every parent directory" precise.
- [acl(5)](https://man7.org/linux/man-pages/man5/acl.5.html), [getfacl(1)](https://man7.org/linux/man-pages/man1/getfacl.1.html), [setfacl(1)](https://man7.org/linux/man-pages/man1/setfacl.1.html) — The definitive statement of the ACL entry types, the mask-as-upper-bound rule, `#effective` semantics, and default-ACL inheritance. `acl(5)`'s "correspondence between ACL entries and file permission bits" section is the one that explains why the middle `ls -l` triad is the mask.
- [inode(7)](https://man7.org/linux/man-pages/man7/inode.7.html) — The full `i_mode` bit layout and per-file-type meaning of setuid/setgid/sticky. The canonical reference for the overloaded semantics in §3.
- [ioctl_iflags(2)](https://man7.org/linux/man-pages/man2/ioctl_iflags.2.html) and [chattr(1)](https://man7.org/linux/man-pages/man1/chattr.1.html) — The inode-flag mechanism (`FS_IOC_GET/SETFLAGS`), the full flag list, which filesystems implement it, and which flags require `CAP_LINUX_IMMUTABLE`.
- [execve(2)](https://man7.org/linux/man-pages/man2/execve.2.html) and [user_namespaces(7)](https://man7.org/linux/man-pages/man7/user_namespaces.7.html) — `execve(2)`'s "capabilities and set-user-ID" section ties fcaps, setuid bits, `nosuid`, and `no_new_privs` together in one place. `user_namespaces(7)` explains `capable_wrt_inode_uidgid()` / namespaced capabilities and why rootless works.
- https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here. When a lab command (`setcap`, `setfacl`, `getfattr`, `chattr`, `capsh`, `setpriv`, `useradd`) needs to match the shipped Rocky 9 tooling exactly, this is the reference to check against rather than upstream man7.org, which may describe a newer option set.

**Kernel source (read alongside the man pages):**

- [fs/namei.c — `acl_permission_check`, `generic_permission`, `inode_permission`](https://github.com/torvalds/linux/blob/master/fs/namei.c) — The actual DAC decision. This module's §2 is a walkthrough of these ~60 lines; reading them yourself is the highest-leverage 20 minutes here.
- [security/commoncap.c — `cap_capable`, `cap_bprm_creds_from_file`, `get_vfs_caps_from_disk`](https://github.com/torvalds/linux/blob/master/security/commoncap.c) — Where the `execve` capability transformation formula is *implemented* (not just documented). `cap_bprm_creds_from_file()` is the formula in code; watch it compute the new permitted set.
- [fs/posix_acl.c — `posix_acl_permission`, `posix_acl_create`](https://github.com/torvalds/linux/blob/master/fs/posix_acl.c) — The ACL walk (first-matching-class, mask application) and the create-time interaction with umask/default ACLs.

**Books:**

- [The Linux Programming Interface — Michael Kerrisk](https://man7.org/tlpi/) — Chapters 15 (file attributes), 17 (ACLs), 9 (process credentials), and 39 (capabilities). Written by the man-pages maintainer; the credential and capability chapters are the clearest prose anywhere on the real/effective/saved model and the setuid-program privilege dance. The ~200 example programs (esp. the capability-dropping and credential ones) are the companion lab; build and `strace` them.
- [Linux Kernel Development, 3rd ed — Robert Love](https://www.amazon.com/Linux-Kernel-Development-Robert-Love/dp/0672329468) — For the surrounding structures: `struct cred`, the VFS inode/dentry objects, and how the credential is attached to a task. The on-ramp before reading `namei.c` cold.

**Landmark articles / talks:**

- [Linux Capabilities and Namespaces (slides) — Kerrisk, man7 training](https://www.man7.org/training/download/capns_caps_slides.pdf) — The best diagram-driven walk through the five cap sets, the transition formula, and ambient caps. Kerrisk's training decks are effectively the extended commentary on the man page.
- ["Unprivileged File Capabilities" — Christian Brauner](https://brauner.io/2018/08/05/unprivileged-file-capabilities.html) and [LWN: "user-namespaced file capabilities"](https://lwn.net/Articles/689169/) — The rationale and mechanism for VFS_CAP_REVISION_3 / rootid and namespaced fcaps, from the people who built it. Read these to understand *why* the xattr grew a rootid and how v2<->v3 translation works.
- [LWN.net Kernel Index](https://lwn.net/Kernel/Index/) (Capabilities / Security sections) — Ongoing primary journalism. `no_new_privs`, ambient caps, and idmapped mounts were all explained here as they landed; this is how you keep the model from going stale.
- [Julia Evans — jvns.ca](https://jvns.ca/) — For the debugging reflexes: `strace`/`/proc` spelunking and "how do I actually see what the kernel decided." Excellent palate-cleanser between the primary sources.

---

## Senior signal

- **Reads `generic_permission()` from memory and knows the exceptions.** Can state that triads are precedence-checked (owner-first, first match wins, so `chmod 077` locks out the owner), and that `CAP_DAC_OVERRIDE` grants read/write unconditionally to root but grants *execute* only if at least one `x` bit is set. Mid-level says "root ignores permissions" and stops there.
- **Knows the DAC/MAC ordering and errno semantics.** DAC (`generic_permission`) runs, *then* the LSM hook (`security_inode_permission`); SELinux can only deny further, never grant. Immutable/read-only checks sit *above* DAC and return `EPERM`/`EROFS`, not `EACCES`, so root's `CAP_DAC_OVERRIDE` can't touch a `+i` file. Uses the errno to locate which gate fired.
- **Reproduces the capability `execve` transformation and uses fcaps instead of setuid.** Can write `P'(permitted) = (P(I)&F(I)) | (F(P)&P(bounding)) | P'(ambient)` and explain that `setcap cap_net_raw+ep ping` replaced setuid-root to shrink blast radius from "full root euid" to "one capability." Knows `F(effective)` is a single bit that means "auto-raise into effective."
- **Hardens by dropping from the bounding set, not by hoping.** Understands that a cap absent from the bounding set is unreachable by any `execve` in the process tree, and that `no_new_privs`/`NoNewPrivileges=` makes setuid bits and fcaps no-ops. Diagnoses "setcap stopped working" as a `no_new_privs` interaction instantly.
- **Treats the ACL mask as a live foot-gun.** Knows `ls -l`'s middle triad is the mask when a `+` is present, that `chmod g=...` silently rewrites the mask and clamps every named entry, and that default ACLs override umask at creation. Won't run `chmod` blindly on ACL'd trees in automation.
- **Reasons about identity per namespace, not per number.** Knows `capable_wrt_inode_uidgid()` checks the cap against the inode's owning user namespace, that idmapped mounts remap `vfsuid`, and that a UID is meaningless as a subject without naming the userns/mount, which is why rootless containers are safe and why NFS `root_squash` defeats client-side `CAP_DAC_OVERRIDE`.
- **Uses `/proc/<pid>/status` and `cap_capable` tracing as first-line forensics.** Decodes `CapEff`/`CapBnd` with `capsh --decode=`, checks `NoNewPrivs`/`Umask`/`Uid` when a denial makes no sense, and traces the `cap_capable` kprobe (bcc `capable` / bpftrace) to enumerate exactly which capabilities a workload actually exercises before dropping the rest.
- **Knows the setuid privilege-drop pitfalls.** Real vs effective vs saved: dropping `euid` while leaving `suid` set leaves a regain path and is a classic local-root bug; the kernel clears setuid/setgid bits on write to defeat "append to a setuid binary" attacks.

---

## See also

- [[02 - Users, Authentication and PAM]] — where the subject-side credentials in this module (`fsuid`/`fsgid`, supplementary groups, the `struct cred`) actually get established: login, PAM, and NSS decide *who* a process is before any DAC check runs.
- [[10 - Namespaces and cgroups v2]] — expands on the user-namespace and idmapped-mount hooks touched here (`capable_wrt_inode_uidgid()`, `vfsuid`/`vfsgid`); it's why "root" and a UID are only meaningful relative to a namespace, and why rootless containers are safe.
- [[12 - SELinux and Hardening]] — the MAC layer that runs *after* DAC via the `security_inode_permission()` LSM hook: DAC and MAC are AND-ed, so SELinux can only deny further what the bits/ACLs/capabilities in this module already allowed.
- [[01 - IAM Core and the Policy Evaluation Engine]] — the cloud authorization model: AWS IAM is explicit default-deny with policy evaluation, the mirror image of Unix DAC's owner-based default-allow, but the same (principal, action, resource) decision at a different layer.
- [[06 - Kubernetes Security (CKS-level)]] — `securityContext`, capability dropping, and `no_new_privs` in pods are exactly the file-capability and setuid mechanics here applied to containers.
- [[06 - S3 and Storage Security]] — bucket policies, object ACLs, and their "the mask silently caps you" footguns are the cloud-storage analog of the POSIX ACL mask covered in §5.
- [[06 - Apptainer for HPC Containers]] — Apptainer's security model leans on file capabilities vs setuid (the `ping`-without-setuid mechanism from Lab 2) to run containers without root.
