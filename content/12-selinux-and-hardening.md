---
title: SELinux and Hardening
type: module
track: linux-internals
tags: [linux-internals, selinux, lsm, mac, type-enforcement, mcs, mls, apparmor, hardening, cis, auditd, sysctl, ssh, security]
requires: [Rocky 9.x VM with root, SELinux in enforcing mode (getenforce = Enforcing), VM snapshot capability (labs deliberately break labeling)]
module_number: 12
status: reviewed
created: 2026-07-08
---

# 12 - SELinux and Hardening

Backlink: [[00 - Track Overview]]

> Scope: SELinux as the kernel actually implements it (the LSM framework, the Flask architecture, the AVC, type enforcement, contexts/labels, on-disk policy and the module store), then the operator surface (booleans, `audit2allow`, writing and shipping a custom policy module, MCS/MLS), a contrast with AppArmor's path-based model, and finally a mechanism-level CIS-style hardening pass (services, `sysctl`, `auditd`, filesystem, SSH, systemd sandboxing). The through-line: **DAC answers "does this user own the bits?"; MAC answers "is this *domain* allowed this *access* on this *type*, regardless of who the user is?"** By the end you should be able to read a raw `avc: denied` record and name the source type, target type, object class, and missing permission without a lookup, decide in seconds whether the fix is a boolean, a file-context correction, or a real policy module, and harden a service to a `systemd-analyze security` score under 3 without touching SELinux policy at all.

---

## Concept deep-dive

### 1. Where MAC sits: the LSM framework and DAC ordering

SELinux is not a bolt-on. It is a **Linux Security Module (LSM)**, meaning it plugs into hook points the kernel core exposes at every security-sensitive operation. The LSM framework was created specifically so the NSA's SELinux (originally a kernel fork) could live upstream without hard-coding one security model into the VFS, the socket layer, IPC, etc.

The mechanism: a `struct security_hook_list` of callbacks. When the kernel is about to do something sensitive, core code calls a `security_*()` wrapper (defined in `security/security.c`). That wrapper walks the registered LSM hooks for that operation and calls each module's callback. For a file open the path is roughly:

```
open(2)
  do_sys_openat2 -> do_filp_open -> path_openat -> may_open
     -> inode_permission()                 # DAC: generic_permission(), the rwx/ACL check
     -> security_inode_permission()         # LSM hook -> selinux_inode_permission()
                                            #   -> avc_has_perm(...)  (SELinux MAC check)
```

Two facts that separate seniors from mid-level here:

1. **DAC runs first, MAC second, and both must pass.** SELinux can only *further restrict*. It never grants access that the Unix bits deny. If `chmod 000 file` blocks you, no `allow` rule will help. This is why "I set the SELinux type right but still get EACCES" is often a DAC problem, and vice-versa.
2. **The LSM hooks are the enforcement surface, and their count matters.** As of recent kernels (6.x) SELinux implements far more hooks (~200+) than AppArmor (~80). More hooks = more object classes mediated = finer, harder-to-bypass confinement. This is the concrete reason label-based MAC resists path tricks that path-based MAC can miss.

Historically LSM was **exclusive** (one "major" module owned the `security_*` blob pointers). Modern kernels support **LSM stacking** for some modules, but SELinux and AppArmor are still generally mutually exclusive as the primary MAC on a given system; you pick one per distro. RHEL/Rocky/Fedora = SELinux; Ubuntu/SUSE = AppArmor.

### 2. The Flask architecture: security server, object managers, AVC

SELinux implements the **Flask** architecture (Flux Advanced Security Kernel). Three pieces, and knowing the split is what lets you reason about *where* a decision is made and *why* it's fast:

```
   +-------------------------------------------------------------+
   |                        KERNEL                               |
   |                                                             |
   |   OBJECT MANAGERS (LSM hooks in VFS, net, IPC, ...)         |
   |     selinux_inode_permission(), selinux_socket_*(), ...     |
   |            |  "may SID_A do PERM on SID_B (class C)?"        |
   |            v                                                 |
   |         +-----+   hit    +--------------------------------+ |
   |         | AVC |<-------->| SECURITY SERVER                | |
   |         +-----+   miss   |  (policy engine)               | |
   |          cache           |  security_compute_av()         | |
   |                          |  loaded policy DB (from disk)  | |
   |                          +--------------------------------+ |
   +-------------------------------------------------------------+
                    ^ policy loaded via selinuxfs /load
                    |
   userspace: libselinux, semodule, policy store  (/etc/selinux)
```

- **Object managers** are the enforcement points. Each subsystem that owns objects (files, sockets, SysV IPC, keys, BPF, ...) labels its objects with a **Security Identifier (SID)** and asks the AVC for permission before acting. The kernel is one big object manager; userspace object managers exist too (e.g. `systemd`, `dbus-daemon`, X, `virtd`) using the **userspace AVC** in libselinux.
- **The security server** is the policy engine. It holds the loaded binary policy and computes an **access vector** (the bitmap of allowed permissions) for a `(source SID, target SID, class)` triple via `security_compute_av()` (`security/selinux/ss/services.c`).
- **The AVC (Access Vector Cache)** caches those computed decisions so the security server is consulted only on a miss. This is *the* performance mechanism. A denial check is normally a cache hit: a hash lookup, no policy walk. You can watch the cache: `cat /sys/fs/selinux/avc/cache_stats` and `avcstat -f /sys/fs/selinux`.

The kernel API the object manager actually calls is `avc_has_perm(source_sid, target_sid, class, requested_perms, &avd, audit_data)`. On a miss the AVC calls the security server, caches the result, and, critically, **emits the audit record if the decision includes a denied+auditable permission** (`avc_audit()`).

### 3. The security context (label): the four-tuple, SIDs, and where labels live

Everything mediated by SELinux carries a **security context**, a colon-delimited string:

```
   user_u : role_r : type_t : sensitivity[:categories]
   |        |        |        |
   SELinux  RBAC     Type     MLS/MCS level (RHEL "targeted" = MCS)
   user     role     Enforcement
```

Example: `system_u:system_r:httpd_t:s0`. For a file: `system_u:object_r:httpd_sys_content_t:s0`. Files use `object_r` as a placeholder role (roles only really matter for processes/subjects).

Key mechanism points:

- **On disk, a file's label lives in an extended attribute: `security.selinux`.** Read it raw: `getfattr -n security.selinux -d /var/www/html/index.html`, or human-formatted with `ls -Z`. It is a null-terminated string in the xattr. This is why labels survive across reboots (they're on the filesystem) but **do not survive a `cp` that doesn't preserve xattrs, a restore from a tar without `--selinux`, or a file created fresh in a directory** (new files inherit the *type* per policy transition rules, computed, not copied).
- Filesystems that can't store xattrs (older NFS, vfat, some virtual FS) get labels from policy via `genfscon`/`fscontext=` mount options instead. That's why `mount -o context=...` exists.
- Internally the kernel doesn't compare strings on the hot path. Each unique context string is interned into an integer **SID** via the SID table (`sidtab`). The AVC and security server work entirely in SIDs; string<->SID translation happens at labeling time. This is why a system with millions of files and only a few hundred distinct contexts stays fast: the working set of SIDs is tiny.

The `id -Z` of a process, `ps -eZ`, `ls -Z`, `netstat -Z`, `ss -Z` all surface the context. `/proc/PID/attr/current` is the process's context; `/proc/PID/attr/exec` is the context it will transition to on next `execve`.

### 4. Type enforcement (TE): the heart of it

RHEL's default policy is **type enforcement plus MCS**. RBAC and MLS ride on top but TE does 99% of the work. The model:

- Every **subject** (process) runs in a **domain** (a type, by convention suffixed `_t`, e.g. `httpd_t`, `sshd_t`, `unconfined_t`).
- Every **object** (file, socket, port, ...) has a **type** (e.g. `httpd_sys_content_t`, `ssh_port_t`).
- An **object class** names the kind of object (`file`, `dir`, `sock_file`, `tcp_socket`, `capability`, `process`, ...). Each class has a fixed set of **permissions** (an `access vector`): `file` has `read write open getattr execute append ...`; `process` has `transition sigkill ptrace setrlimit ...`.
- The atom of policy is the **allow rule**:

```
   allow SOURCE_TYPE TARGET_TYPE : CLASS { PERMISSIONS };
   allow httpd_t     httpd_sys_content_t : file { read getattr open };
```

Read it as: "a process in domain `httpd_t` may `read`/`getattr`/`open` a `file` labeled `httpd_sys_content_t`." No rule = no access. **SELinux is default-deny.** Everything you don't explicitly allow is denied (that's the whole point of MAC, versus DAC's default-allow-if-you-own-it).

This is the exact structure of an AVC denial. When you read:

```
avc:  denied  { read } for  pid=1234 comm="httpd"
   name="secret.txt" dev="dm-0" ino=131
   scontext=system_u:system_r:httpd_t:s0
   tcontext=unconfined_u:object_r:admin_home_t:s0
   tclass=file permissive=0
```

you are reading a *missing allow rule*: there is no `allow httpd_t admin_home_t : file read;`. The fix is never "turn off SELinux." The fix is one of: relabel the target to a type `httpd_t` may read (correct fix, because content was mislabeled), flip a boolean (if policy anticipated this), or add the rule via a module (if this is genuinely new behavior).

### 5. Transitions: how a process changes domain, how a file gets its type

Two transition mechanisms, and confusing them is a classic mid-level error.

**Domain transition (process):** when `sshd_t` execs `/usr/bin/passwd`, the process should end up in `passwd_t`, not stay `sshd_t`. This requires *three* allow rules plus a `type_transition`:

```
   type_transition sshd_t passwd_exec_t : process passwd_t;   # default new domain
   allow sshd_t passwd_exec_t : file { execute };             # may exec the entrypoint
   allow sshd_t passwd_t      : process { transition };       # may transition to it
   allow passwd_t passwd_exec_t : file { entrypoint };        # this file is the domain's entrypoint
```

All four must hold or the transition silently doesn't happen (you stay in the old domain, and then usually hit a denial). The `entrypoint` permission is the security-critical one: it's how policy says "you can only *become* `passwd_t` by running the blessed binary," preventing a compromised process from labeling arbitrary code as the trusted entrypoint.

**File type transition:** when `httpd_t` creates a file under a directory labeled `httpd_sys_rw_content_t`, what type does the new file get? By default it inherits the *parent directory's* type, but policy can override:

```
   type_transition httpd_t httpd_sys_rw_content_t : file httpd_sys_rw_content_t;
```

This is why creating a file in `/var/www/html` gives it `httpd_sys_content_t` automatically. It's computed at creation, not copied from a sibling. `cp` vs `mv` differences trace directly to this: `mv` preserves the source label (no new inode, xattr comes along), `cp` creates a new inode and gets the *transition-computed* label. This single fact explains a huge fraction of real-world "it worked from /tmp but not after I moved it" tickets.

### 6. RBAC, SELinux users, and the login mapping

Roles gate which domains a user may enter. `user_r` can reach `httpd_t`? Only if `role user_r types httpd_t;`. In targeted policy most of this is loose (everything unconfined runs in `unconfined_t`), but on a confined multi-user box roles matter: `staff_r`, `sysadm_r`, `user_r`, `guest_r`.

The mapping from a Linux login to an SELinux user is separate policy:

```
   semanage login -l          # Linux user  -> SELinux user
   semanage user  -l          # SELinux user -> roles + MLS range
```

Default: everyone maps to `__default__` -> `unconfined_u`. To confine a Linux user `alice` to the `user_u` sandbox: `semanage login -a -s user_u alice`. That's how you get a genuinely locked-down interactive account: no setuid, no domain transitions to admin tools.

### 7. MCS and MLS: sensitivity and categories

The fourth field of the context is the **level**: `sensitivity[:category-range]`.

- **MLS (Multi-Level Security):** hierarchical sensitivities `s0 < s1 < s2 ...` (think Unclassified < Secret < Top Secret), enforced by **dominance rules** (Bell-LaPadula: no read up, no write down). RHEL ships an `mls` policy but it's used mainly in government/defense deployments and needs heavy tailoring.
- **MCS (Multi-Category Security):** the default targeted policy uses **one** sensitivity `s0` and up to **1024 non-hierarchical categories** `c0..c1023`. A process labeled `s0:c1,c2` can access an object only if the object's category set is a **subset** of the process's. This is a compartment/tenant-isolation mechanism, not a classification hierarchy.

The killer application is **container isolation**. This is why containers matter to a support engineer: `podman`/`docker` with SELinux run each container's processes as `container_t` with a *unique random MCS pair* (e.g. `s0:c123,c456`) and label that container's volumes with the *same* pair. Container A (`c123,c456`) physically cannot read container B's files (`c789,c1011`) even though both are `container_file_t`, because the category sets don't dominate. TE says "container_t may read container_file_t"; MCS then says "but only files in *your* categories." That's defense in depth: even if two containers share a type, the category check isolates them. The `:z` / `:Z` volume flags on `podman run -v` are exactly this relabeling.

MCS is checked *after* DAC and TE, and can only further restrict, never grant. `s0-s0:c0.c1023` (a range) means "cleared for all categories" (that's what `unconfined` interactive sessions get).

### 8. The kernel interface: selinuxfs (`/sys/fs/selinux`)

The security server exposes its API to userspace through a pseudo-filesystem, **selinuxfs**, mounted at `/sys/fs/selinux` (`security/selinux/selinuxfs.c`). This is the whole control plane. Worth knowing by name:

```
/sys/fs/selinux/enforce        # 1/0, read = current mode, write = setenforce (needs perm)
/sys/fs/selinux/load           # write the binary policy blob here to (re)load policy
/sys/fs/selinux/policy         # read = dump the currently loaded binary policy
/sys/fs/selinux/policyvers     # policy DB format version the kernel supports
/sys/fs/selinux/access         # the compute-av interface (security_compute_av)
/sys/fs/selinux/create         # compute a transition/new-label (security_compute_create)
/sys/fs/selinux/context        # validate/canonicalize a context string
/sys/fs/selinux/booleans/      # one file per boolean: current + pending value
/sys/fs/selinux/avc/           # cache_stats, hash_stats, cache_threshold
/sys/fs/selinux/class/         # every object class and its permissions (the access-vector map)
/sys/fs/selinux/null           # the SELinux /dev/null equivalent for relabeling fds
```

`setenforce 1` is literally `echo 1 > /sys/fs/selinux/enforce`. `getenforce` reads it. Loading policy (what `semodule` ultimately triggers) is a write of the compiled binary to `.../load`. When someone asks "how does the kernel know the policy," the answer is: userspace compiled it and wrote it into this file; the kernel copied it into the security server and flushed the AVC.

`class/` is a goldmine for a senior: `cat /sys/fs/selinux/class/file/perms/*` lists every permission the `file` class defines. That's your ground truth for what a denial's permission name *means*.

### 9. On-disk policy, the module store, and CIL

The full policy layout on RHEL/Rocky:

```
/etc/selinux/config                     # SELINUX=enforcing|permissive|disabled ; SELINUXTYPE=targeted
/etc/selinux/targeted/
   policy/policy.NN                      # the compiled BINARY policy (NN = policyvers)
   contexts/files/file_contexts          # regex -> default context map (the labeling database)
   contexts/files/file_contexts.local    # your semanage fcontext -a additions
   active/modules/                        # the MODULE STORE (CIL modules, by priority)
```

The build pipeline (this is the part almost nobody internalizes):

```
   .te / .if / .fc  (human policy source, m4/refpolicy)
        | checkmodule -M -m -o mymod.mod mymod.te     # compile TE -> intermediate .mod
        v
   .mod + .fc
        | semodule_package -o mymod.pp -m mymod.mod -f mymod.fc   # package -> .pp
        v
   mymod.pp  (a "policy package", historically the shippable unit)
        | semodule -i mymod.pp
        v
   MODULE STORE: .pp is translated to CIL, added to the store, then ALL modules
   are linked + compiled by libsemanage into a fresh binary policy.NN,
   which is written to /sys/fs/selinux/load.
```

The modern truth: since userspace 2.4, **CIL (Common Intermediate Language)** is the real intermediate format. `.pp` files are treated as a "high-level language" and converted to CIL on install. You can now write and install CIL directly:

```
   semodule -i mymodule.cil
```

CIL is s-expression syntax and is what `semodule` actually links. Modules install at a **priority** (default 400; distro base is 100). Higher priority wins, which is how you override a shipped module without editing it. `semodule -l` lists installed modules; `semodule -E mymod` extracts one.

The key architectural insight: **LVM-style separation of metadata and mechanism.** libsemanage (userspace) owns the module store and *manages* policy the way LVM manages metadata; the kernel security server is the *mechanism* it programs, the way device-mapper is for LVM. `semodule -i` doesn't hand the kernel your one module; it relinks the *entire* policy and swaps it atomically.

### 10. Enforcing / permissive / disabled, and permissive *domains*

Three global modes (`getenforce`):

- **enforcing** - denials are enforced and audited.
- **permissive** - denials are *audited but allowed*. This is a debugging mode, not a security mode. Everything runs; you collect the AVCs you'd need to allow.
- **disabled** - SELinux off. On RHEL 9+ **you cannot fully disable SELinux via `/etc/selinux/config` anymore**; `SELINUX=disabled` there is deprecated. Real disable requires the kernel cmdline `selinux=0`. This is a deliberate hardening: `disabled` leaves files unlabeled, and re-enabling later triggers a full filesystem relabel (`.autorelabel`) which is slow and disruptive. Prefer **permissive** over disabled always.

The senior move: **permissive domains**, not global permissive. `semanage permissive -a httpd_t` makes *only* `httpd_t` permissive while the rest of the system stays enforcing. You debug one service's policy without opening the whole box. Undo with `semanage permissive -d httpd_t`, list with `semanage permissive -l`. This is how you develop a policy module on a production-adjacent box safely.

### 11. Booleans: conditional policy without a reload

Policy can embed conditional rules gated on a runtime **boolean**:

```
   if (httpd_can_network_connect) {
       allow httpd_t port_type : tcp_socket name_connect;
   }
```

Booleans let the shipped policy anticipate common variations and let you toggle them without compiling anything. This is almost always the right first fix before you reach for `audit2allow`.

```
   getsebool -a                         # list all with current values
   semanage boolean -l                  # list with descriptions + default vs current
   setsebool httpd_can_network_connect on          # runtime only (reverts on reboot)
   setsebool -P httpd_can_network_connect on        # -P = persistent (rewrites store)
```

The `-P` distinction is a real gotcha: without it, a reboot silently reverts your fix and the ticket reopens. Non-persistent toggles flip the value in `/sys/fs/selinux/booleans/<name>`; `-P` goes through libsemanage and rewrites the module store.

Classic booleans worth knowing cold: `httpd_can_network_connect`, `httpd_can_network_connect_db`, `httpd_use_nfs`, `httpd_read_user_content`, `ftpd_full_access`, `nfs_export_all_rw`, `use_nfs_home_dirs`, `samba_enable_home_dirs`, `container_manage_cgroup`, `nis_enabled`, `selinuxuser_execmod`.

### 12. Labeling tools and the file_contexts database

Labels don't come from nowhere. The **file context database** (`file_contexts`) maps path regexes to default contexts:

```
   /var/www(/.*)?    system_u:object_r:httpd_sys_content_t:s0
```

The tools:

- `matchpathcon /path` (or `selabel_lookup`) - "what *should* this path be labeled per policy?" without changing anything.
- `restorecon -v /path` - relabel to the policy default. `-R` recursive, `-n` dry-run, `-F` force even if user/role differ.
- `restorecon -Rv /` after `touch /.autorelabel; reboot` - full relabel (recovery from mass mislabeling).
- `semanage fcontext -a -t httpd_sys_content_t "/srv/web(/.*)?"` - **add a permanent rule** to the local file_contexts, then `restorecon -Rv /srv/web` to apply. This is the correct, durable way to teach the system "content here should be web content." Editing xattrs directly with `chcon` is the *temporary* way (a later `restorecon` or relabel wipes it).

**`chcon` vs `semanage fcontext` + `restorecon` is the single most important labeling distinction.** `chcon` sets the xattr now; it does not update the policy's idea of what the path should be, so it does not survive a relabel. `semanage fcontext` updates the database; `restorecon` then makes reality match. Always prefer the latter for anything permanent. (This is the SELinux instance of the general rule: don't hand-edit the derived artifact, edit the source of truth and regenerate.)

### 13. Auditing: AVC records, dontaudit, and the denial you *can't* see

Denials land in the audit log (`/var/log/audit/audit.log`) via the kernel audit subsystem, or in the journal / `dmesg` if `auditd` isn't running. Tools:

- `ausearch -m avc -ts recent` / `-ts today` - pull AVC records.
- `sealert -a /var/log/audit/audit.log` (setroubleshoot) - human-readable analysis with suggested fixes. Great for triage, dangerous if followed blindly (it often suggests `audit2allow`, which can over-permit).
- `journalctl -t setroubleshoot` - the same alerts via the journal.

Anatomy of the record fields you must parse fluently: `scontext` (source/subject domain), `tcontext` (target/object type), `tclass` (object class), the `{ ... }` permission(s) denied, `comm`/`exe` (the binary), `path`/`name` (the object), `permissive=0/1`. From those five you can reconstruct the exact missing `allow` rule.

**dontaudit** is the trap that catches everyone. Policy can mark a permission `dontaudit`, meaning "deny it but don't log it," to suppress noise from access the app probes-and-recovers-from. The failure mode: an app misbehaves, you check the audit log, **there's no denial**, and you conclude SELinux is innocent. It isn't. Turn off dontaudit rules temporarily:

```
   semodule -DB          # -D disable dontaudit, -B rebuild/reload policy
   # ...reproduce, collect the now-visible AVCs...
   semodule -B           # rebuild with dontaudit restored
```

A senior always runs `semodule -DB` before concluding "no SELinux denial." This is probably the highest-value single trick in the module.

### 14. Failure modes and behavior at scale

- **Mislabeled files after restore/migration.** `tar`/`rsync`/`cp` without xattr preservation strips `security.selinux`; files land with the wrong (often default `default_t` or the parent's) type. Symptom: service works on a fresh install, fails after a "restore." Fix: `restorecon -R`, and use `rsync -X`/`tar --selinux`/`cp -a` next time.
- **The `.autorelabel` storm.** Toggling from disabled back to enabled, or `fixfiles onboot`, triggers a full-filesystem relabel at next boot. On a box with tens of millions of inodes this is tens of minutes of downtime and heavy I/O. This is the concrete cost of "just disable it and turn it back on later."
- **AVC cache pressure.** The AVC is bounded (`/sys/fs/selinux/avc/cache_threshold`, default 512 entries). Workloads that touch a very large set of distinct `(src,tgt,class)` triples (huge multi-tenant container hosts) can thrash the cache, pushing decisions to the slow security-server path. Check `cache_stats` for a rising miss/reclaim rate. Rare, but it's a real "SELinux is adding latency" root cause.
- **SID table growth.** Each distinct context string consumes a SID. Pathological label churn (containers creating unique MCS labels at high rate and never freeing them) can grow the sidtab. Not usually a problem, but it's the mechanism behind "SELinux memory grew unbounded" reports.
- **Silent domain-transition failure.** Miss one of the four transition rules and the process stays in the wrong domain and then hits a cascade of denials that look unrelated. Diagnose with `ps -eZ` (is it in the domain you expect?) and `/proc/PID/attr/current`.
- **Constraint denials look like TE denials but aren't.** An MCS/MLS or RBAC constraint failure shows as a denial with matching-looking types. `audit2allow` will happily generate an `allow` that *can't* fix it, because the block is a constraint, not a missing allow. Tell: the types clearly *should* be allowed, categories/levels differ. Fix the level/category, not the allow rules.

---

## Hands-on labs

> All labs assume a throwaway VM running an SELinux distro in **enforcing** mode: Rocky/RHEL/Fedora 9+, or Alma. Confirm with `getenforce` (should print `Enforcing`). Install tooling once:
>
> ```bash
> sudo dnf install -y policycoreutils policycoreutils-python-utils \
>   selinux-policy-devel setools-console setroubleshoot-server \
>   audit checkpolicy httpd strace
> sudo systemctl enable --now auditd
> ```
> Take a VM snapshot now. Several labs deliberately break labeling; snapshot restore is your undo.

### Lab 1 - Make the invisible AVC visible: trace a denial end to end

**Objective:** Watch a single denial travel from `execve`/`open` -> LSM hook -> AVC miss -> audit record, and read the raw context four-tuple off the wire. Prove that DAC and MAC are independent gates.

**Setup:**

```bash
sudo mkdir -p /var/www/html
echo "hello from the right label" | sudo tee /var/www/html/ok.html
echo "secret in the wrong place"  | sudo tee /root/wrong.html
sudo cp /root/wrong.html /var/www/html/bad.html   # cp = new inode, gets transitioned label
sudo chcon -t admin_home_t /var/www/html/bad.html  # force a WRONG type to simulate mislabel
sudo systemctl enable --now httpd
```

**Steps:**

1. Look at the labels and note the type difference (`ls -Z`):

   ```bash
   ls -Z /var/www/html/
   ```

   `ok.html` should be `httpd_sys_content_t`; `bad.html` is now `admin_home_t`.

2. Confirm DAC would allow both (readable by all): `ls -l /var/www/html/`. Both `-rw-r--r--`. So any denial we see is *purely* MAC.

3. Watch the process's domain, then request both files:

   ```bash
   ps -eZ | grep httpd    # note httpd_t
   curl -s localhost/ok.html    # 200
   curl -s localhost/bad.html   # 403
   ```

4. Pull the raw AVC and dissect it:

   ```bash
   sudo ausearch -m avc -ts recent | tail -20
   ```

   Identify by eye: `scontext=...:httpd_t:s0`, `tcontext=...:admin_home_t:s0`, `tclass=file`, `{ read }` or `{ getattr }`, `permissive=0`.

5. Confirm the missing rule really is missing, using the policy directly (no guessing):

   ```bash
   sesearch --allow -s httpd_t -t admin_home_t -c file    # empty = no allow rule
   sesearch --allow -s httpd_t -t httpd_sys_content_t -c file   # shows read/open/getattr
   ```

6. Now prove the *correct* fix is a relabel, not disabling anything:

   ```bash
   sudo restorecon -v /var/www/html/bad.html   # snaps it back to httpd_sys_content_t
   curl -s localhost/bad.html                  # now 200
   ```

**Prove it:**

```bash
# Before-fix denial exists AND after-fix the type is correct AND request succeeds:
sudo ausearch -m avc -ts recent -c httpd | grep -q 'tcontext=.*admin_home_t' && echo "DENIAL CAPTURED" && \
ls -Z /var/www/html/bad.html | grep -q httpd_sys_content_t && echo "RELABELED OK" && \
[ "$(curl -s -o /dev/null -w '%{http_code}' localhost/bad.html)" = "200" ] && echo "SERVING OK"
```

Seeing all three lines proves you found the denial, understood the label was the cause, and fixed it at the label layer.

**Teardown:**

```bash
sudo systemctl disable --now httpd
sudo rm -f /var/www/html/ok.html /var/www/html/bad.html /root/wrong.html
```

### Lab 2 - The `audit2allow` trap vs the real fix (custom content directory)

**Objective:** Experience the most common real-world SELinux ticket, serving web content from a non-standard directory, and understand *why* `audit2allow` is the wrong reflex and `semanage fcontext` is right. Enumerate the solution space.

**Setup:**

```bash
sudo mkdir -p /srv/webapp
echo "app content" | sudo tee /srv/webapp/index.html
sudo tee /etc/httpd/conf.d/webapp.conf >/dev/null <<'EOF'
<VirtualHost *:8080>
  DocumentRoot /srv/webapp
  <Directory /srv/webapp>
    Require all granted
  </Directory>
</VirtualHost>
EOF
# add the port to policy so the port isn't the confound (see Lab 4 for ports):
sudo semanage port -a -t http_port_t -p tcp 8080 2>/dev/null || true
sudo systemctl restart httpd
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/   # expect 403
```

**Steps:**

1. Confirm the label is wrong for httpd: `ls -Z /srv/webapp/` shows `var_t` or `default_t`, not `httpd_sys_content_t`.

2. Enumerate the fixes (do this thinking explicitly, it's the senior habit):
   - **A. `audit2allow -M`** a module that adds `allow httpd_t default_t : file read;`. Works, but it grants httpd read to *everything* labeled `default_t` system-wide. Over-broad. Fragile against future denials (dir vs file vs getattr).
   - **B. `chcon -t httpd_sys_content_t`** the files. Works now, but does not survive `restorecon`/relabel. Not durable.
   - **C. `semanage fcontext -a` + `restorecon`.** Teaches the labeling database the durable rule. Survives relabel. Scoped exactly to this path. Canonical.
   - Recommend C.

3. Show why A is bad, concretely:

   ```bash
   sudo ausearch -m avc -ts recent | audit2allow      # read the suggested rule; note it targets a broad type
   ```

   Note the target type in the suggested `allow`. If it's `default_t`, granting it is a system-wide hole.

4. Apply the canonical fix (C):

   ```bash
   sudo semanage fcontext -a -t httpd_sys_content_t "/srv/webapp(/.*)?"
   sudo restorecon -Rv /srv/webapp
   ls -Z /srv/webapp/
   curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/   # expect 200
   ```

5. Prove durability against a relabel (the thing `chcon` fails):

   ```bash
   sudo touch /srv/webapp/index.html   # new mtime; simulate churn
   sudo restorecon -Rv /srv/webapp     # would revert chcon, but keeps our fcontext rule
   ls -Z /srv/webapp/index.html        # still httpd_sys_content_t
   ```

**Prove it:**

```bash
sudo semanage fcontext -l -C | grep -q '/srv/webapp' && echo "RULE PERSISTED IN DB" && \
ls -Z /srv/webapp/index.html | grep -q httpd_sys_content_t && echo "LABEL CORRECT AFTER RELABEL" && \
[ "$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/)" = "200" ] && echo "SERVING OK"
```

The `-C` flag lists *customizations* (local additions) only, proving your rule is in the database, not just in an xattr.

**Teardown:**

```bash
sudo semanage fcontext -d "/srv/webapp(/.*)?"
sudo semanage port -d -t http_port_t -p tcp 8080
sudo rm -f /etc/httpd/conf.d/webapp.conf
sudo rm -rf /srv/webapp
sudo systemctl restart httpd
```

### Lab 3 - Write and ship a real custom policy module (from denials, then hand-authored + CIL)

**Objective:** Build a confined domain for a toy daemon, generate a first-cut module from AVCs the right way, then hand-write and install both a `.te` and a `.cil` module. Understand the compile pipeline and priorities.

**Setup - a deliberately unconfined toy daemon that does something policy won't like:**

```bash
sudo tee /usr/local/bin/noisyd >/dev/null <<'EOF'
#!/bin/bash
# writes a pid file in /var/run and opens a listening port
echo $$ > /run/noisyd.pid
exec /usr/bin/nc -lk 9999
EOF
sudo chmod +x /usr/local/bin/noisyd
sudo tee /etc/systemd/system/noisyd.service >/dev/null <<'EOF'
[Service]
ExecStart=/usr/local/bin/noisyd
[Install]
WantedBy=multi-user.target
EOF
sudo dnf install -y nmap-ncat
sudo systemctl daemon-reload
```

**Steps:**

1. First, generate a proper domain skeleton with `sepolicy generate` (the right tool to *confine* a new app, versus `audit2allow` which only patches denials):

   ```bash
   cd /tmp && sudo sepolicy generate --init /usr/local/bin/noisyd
   ls -l noisyd.te noisyd.fc noisyd.if noisyd.sh
   ```

   Read `noisyd.te`: note the generated `noisyd_t` domain, `noisyd_exec_t` entrypoint, the `type_transition`, and the `init_daemon_domain(noisyd_t, noisyd_exec_t)` interface call that wires the systemd->domain transition.

2. Build and install using the generated helper (this runs `make -f /usr/share/selinux/devel/Makefile` under the hood: `checkmodule` -> `semodule_package` -> `semodule -i`):

   ```bash
   sudo ./noisyd.sh
   sudo restorecon -v /usr/local/bin/noisyd
   semodule -l | grep noisyd
   ```

3. Put the new domain in **permissive** so it runs while you collect what it actually needs (senior technique: permissive *domain*, not global):

   ```bash
   sudo semanage permissive -a noisyd_t
   sudo systemctl start noisyd
   ps -eZ | grep noisyd     # PROVE it's in noisyd_t, not unconfined
   ```

4. Exercise it, then harvest the AVCs into an incremental module. First disable dontaudit so nothing is hidden:

   ```bash
   sudo semodule -DB
   echo test | nc localhost 9999   # drive the daemon
   sudo ausearch -m avc -ts recent -c nc | audit2allow -m noisyd_local
   ```

   Read the proposed rules (pid file write to `var_run_t`, `name_bind` on port 9999, etc.). Decide which are legitimate.

5. Now hand-author a tight incremental `.te` instead of blindly taking audit2allow's output, and build it manually so you see every pipeline stage:

   ```bash
   cat > /tmp/noisyd_local.te <<'EOF'
   policy_module(noisyd_local, 1.0)

   require {
       type noisyd_t;
       type var_run_t;
       type unreserved_port_t;
   }

   # pid file in /run
   allow noisyd_t var_run_t:file { create write open getattr unlink };
   # listen on a high port
   allow noisyd_t unreserved_port_t:tcp_socket name_bind;
   allow noisyd_t self:tcp_socket { create bind listen accept read write };
   EOF

   checkmodule -M -m -o /tmp/noisyd_local.mod /tmp/noisyd_local.te
   semodule_package -o /tmp/noisyd_local.pp -m /tmp/noisyd_local.mod
   sudo semodule -i /tmp/noisyd_local.pp
   ```

6. Do the same thing in **CIL** to see the modern intermediate language directly, installed at a higher priority to demonstrate overrides:

   ```bash
   cat > /tmp/noisyd_cil.cil <<'EOF'
   (allow noisyd_t var_log_t (file (create write open getattr)))
   EOF
   sudo semodule -X 500 -i /tmp/noisyd_cil.cil
   sudo semodule --list-modules=full | grep noisyd     # note the priority column: 500 vs 400
   ```

7. Flip the domain back to enforcing and confirm the daemon works *confined*:

   ```bash
   sudo semanage permissive -d noisyd_t
   sudo systemctl restart noisyd
   echo test2 | nc localhost 9999
   sudo ausearch -m avc -ts recent -c nc   # should be empty: no denials, fully confined
   ```

**Prove it:**

```bash
ps -eZ | grep -q noisyd_t && echo "DAEMON CONFINED IN noisyd_t" && \
semodule -l | grep -q noisyd_local && echo "CUSTOM TE MODULE LOADED" && \
sudo semodule --list-modules=full | grep -q '^500.*noisyd_cil' && echo "CIL MODULE AT PRIORITY 500" && \
[ -z "$(sudo ausearch -m avc -ts recent -c nc 2>/dev/null | grep denied)" ] && echo "NO DENIALS UNDER ENFORCING"
```

**Teardown:**

```bash
sudo systemctl disable --now noisyd
sudo semodule -r noisyd_local noisyd_cil noisyd
sudo semanage permissive -d noisyd_t 2>/dev/null || true
sudo rm -f /etc/systemd/system/noisyd.service /usr/local/bin/noisyd /run/noisyd.pid
sudo systemctl daemon-reload
```

### Lab 4 - Full hardening pass with proof: MCS isolation, ports, sysctl, auditd, SSH, systemd sandboxing, OpenSCAP

**Objective:** Do a mechanism-level CIS-style hardening pass and *verify each control with a command*, not a checkbox. Cover the SELinux-adjacent surface (ports, MCS) and the classic hardening layers.

**Setup:**

```bash
sudo dnf install -y openscap-scanner scap-security-guide audit
sudo VMSNAP_TAKEN=yes true   # reminder: you snapshotted in the preamble
```

**Steps:**

*4a. SELinux port labeling (the other half of "why can't my service bind").*

```bash
sudo semanage port -l | grep -E '^http_port_t'     # see the ports httpd_t may bind
sudo semanage port -a -t http_port_t -p tcp 8443    # allow a new port for httpd
sesearch --allow -s httpd_t -t http_port_t -c tcp_socket | grep name_bind
```

*4b. MCS container-style isolation, by hand (prove category subset-ing).*

```bash
sudo mkdir -p /srv/tenantA /srv/tenantB
echo A | sudo tee /srv/tenantA/data; echo B | sudo tee /srv/tenantB/data
sudo chcon -l s0:c100 /srv/tenantA/data
sudo chcon -l s0:c200 /srv/tenantB/data
# a process at s0:c100 can read A, not B:
sudo runcon -l s0:c100 -- cat /srv/tenantA/data    # works
sudo runcon -l s0:c100 -- cat /srv/tenantB/data    # Permission denied (category mismatch)
```

*4c. Kernel/network sysctl hardening (drop-in, not editing package files).*

```bash
sudo tee /etc/sysctl.d/99-hardening.conf >/dev/null <<'EOF'
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 0
EOF
sudo sysctl --system
```

*4d. auditd rules for tamper-evident logging (the identity/privilege files).*

```bash
sudo tee /etc/audit/rules.d/hardening.rules >/dev/null <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group  -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /var/log/lastlog -p wa -k logins
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k rootcmd
-e 2
EOF
sudo augenrules --load
sudo auditctl -l | tail
```

*4e. SSH hardening via drop-in (RHEL 9 sshd reads `/etc/ssh/sshd_config.d/`).*

```bash
sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
EOF
sudo sshd -t && echo "sshd config valid"    # validate BEFORE restart
```
> ⚠️ Restarting sshd on a remote box can lock you out if the config is wrong. `sshd -t` validates without applying. Keep an existing session open and test a new login in a second terminal before closing the first. On production, confirm a maintenance window.

*4f. systemd service sandboxing (harden a service without touching SELinux).* Use a drop-in override, never edit the packaged unit:

```bash
sudo systemctl edit httpd    # creates /etc/systemd/system/httpd.service.d/override.conf
```
Put in the override:
```ini
[Service]
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
NoNewPrivileges=true
SystemCallFilter=@system-service
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/log/httpd /run/httpd /var/lib/httpd
```
Then:
```bash
sudo systemctl daemon-reload && sudo systemctl restart httpd
```

*4g. Score the whole thing with the actual tools.*

```bash
sudo systemd-analyze security httpd        # exposure score; aim to move it down
sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
   --results /tmp/cis.xml --report /tmp/cis.html \
   /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml || true
```
(Use `ssg-rhel9-ds.xml` on RHEL; `ssg-rl9-ds.xml` on Rocky. `|| true` because a nonzero exit just means some rules failed, which is expected.)

**Prove it:**

```bash
# MCS actually isolates:
sudo runcon -l s0:c100 -- cat /srv/tenantB/data 2>&1 | grep -q 'Permission denied' && echo "MCS ISOLATION ENFORCED"
# sysctl applied live:
[ "$(sysctl -n kernel.kptr_restrict)" = "2" ] && [ "$(sysctl -n net.ipv4.tcp_syncookies)" = "1" ] && echo "SYSCTL APPLIED"
# audit rule is immutable-loaded and watching shadow:
sudo auditctl -l | grep -q '/etc/shadow' && echo "AUDITD WATCHING SHADOW"
# sshd will refuse root + passwords:
sudo sshd -T | grep -E '^(permitrootlogin no|passwordauthentication no)' | wc -l | grep -q 2 && echo "SSH HARDENED"
# systemd sandbox reduced exposure:
sudo systemd-analyze security httpd | grep -qi 'OK\|MEDIUM\|Exposure' && echo "SYSTEMD SANDBOX ACTIVE"
```

`sshd -T` dumps the *effective* merged config (proving your drop-in won), and `systemd-analyze security` gives a numeric exposure delta you can screenshot before/after. That before/after number is the artifact a senior brings to a hardening review, not "I edited some files."

**Teardown:**

```bash
# SELinux port label + MCS test dirs
sudo semanage port -d -t http_port_t -p tcp 8443
sudo rm -rf /srv/tenantA /srv/tenantB
# drop-in config files
sudo rm -f /etc/sysctl.d/99-hardening.conf /etc/ssh/sshd_config.d/10-hardening.conf \
  /etc/audit/rules.d/hardening.rules
sudo sysctl --system
# systemd override for httpd
sudo systemctl revert httpd
sudo systemctl daemon-reload && sudo systemctl restart httpd
```
> The auditd ruleset was loaded immutable (`-e 2` in Lab 4d), so removing the rules file and running `augenrules --load` will not clear the live rules until a reboot. Reboot the VM (or restore the snapshot from the preamble) to fully revert auditd. The sshd drop-in was validated but not applied via a restart in the lab; if you did restart sshd, keep a session open and confirm a fresh login before closing it.

---

## Curated resources

**Primary / canonical**

- [The SELinux Notebook (4th ed) - Richard Haines](https://github.com/SELinuxProject/selinux-notebook) - The definitive free deep reference, donated to the SELinux project. Goes far past `setenforce 0`: the security server and AVC, how LSM hooks call into the policy, the binary policy format, type enforcement + MCS/MLS + constraints, labeling (the `security.selinux` xattr, `genfscon`, file contexts), and the CIL/refpolicy toolchain. This is what takes you from "run audit2allow" to actually understanding the object-manager/security-context model. Read `src/mls_mcs.md` and the AVC chapters closely.
- [SELinux Coloring Book - Dan Walsh & Máirín Duffy](https://people.redhat.com/duffy/selinux/selinux-coloring-book_A4-Stapled.pdf) - Not a joke resource. The clearest 30-minute mental model of type enforcement, MCS, and MLS via the cats/dogs analogy. Read it first to nail the vocabulary (subjects, objects, types, categories) before the Notebook. Its value is preventing the classic senior mistake of treating SELinux as noise to disable.
- [Implementing SELinux as a Linux Security Module - Smalley, Vance, Salamon (NSA)](https://www.nsa.gov/portals/75/documents/resources/everyone/digital-media-center/publications/research-papers/implementing-selinux-as-linux-security-module-report.pdf) - The original design paper. This is where LSM and the Flask decomposition (security server + object managers + AVC) come from. Dated in specifics but unmatched for *why the architecture is shaped this way* and how the AVC provides caching over the security server.
- [Using SELinux - Red Hat Enterprise Linux 9 documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/using_selinux/index) - The current, authoritative operator manual for the exact distro family you support (Rocky mirrors it). Chapter 8 "Writing a custom SELinux policy" and the MCS chapter are the canonical procedures behind Labs 3 and 4. When a blog and this disagree for RHEL/Rocky, this wins.
- [SELinux Project Wiki - NB CoreComponents](https://selinuxproject.org/page/NB_CoreComponents) and the [User Resources page](https://selinuxproject.org/page/User_Resources) - Upstream documentation of the components (checkpolicy, libsepol, libsemanage, policycoreutils) and the CIL reference. Go here for the ground truth on the module store and the compile pipeline.

**Kernel source (read alongside)**

- [`security/selinux/` in the Linux tree](https://github.com/torvalds/linux/tree/master/security/selinux) - `selinuxfs.c` (the `/sys/fs/selinux` interface you drove in Lab 1/3), `avc.c` (the cache and `avc_has_perm`), `ss/services.c` (`security_compute_av`, the security server), and `hooks.c` (every LSM hook SELinux implements). Reading `hooks.c` is the fastest way to see exactly which operations are mediated and for which object class.
- [LSM framework docs - kernel.org](https://docs.kernel.org/security/lsm.html) - The hook-list mechanism, stacking, and how `security_*()` wrappers dispatch. Explains *why* SELinux and AppArmor generally can't both be the primary MAC.

**Man pages (the ABI, read end to end not as lookup)**

- [`selinux(8)`](https://man7.org/linux/man-pages/man8/selinux.8.html), [`semanage(8)`](https://man7.org/linux/man-pages/man8/semanage.8.html), [`semodule(8)`](https://man7.org/linux/man-pages/man8/semodule.8.html), [`booleans(8)`](https://man7.org/linux/man-pages/man8/booleans.8.html), [`restorecon(8)`](https://man7.org/linux/man-pages/man8/restorecon.8.html), [`audit2allow(1)`](https://man7.org/linux/man-pages/man1/audit2allow.1.html), [`checkmodule(8)`](https://man7.org/linux/man-pages/man8/checkmodule.8.html) - The precise flags. `semodule -DB`, `semanage permissive -a`, `semodule -X <priority>` are all documented here; these are the senior-differentiator flags.
- [rockyman.org](https://rockyman.org/) - https://rockyman.org/ - authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here. This is where you confirm, for example, that the module list flag is `semodule --list-modules=full` (not `--list=full`) on Rocky 9.

**AppArmor contrast**

- [AppArmor vs SELinux (apparmor.net)](https://apparmor.net/about/apparmor_vs_selinux/) - The AppArmor project's own honest comparison: path-based vs label-based mediation, why path-based is easier to author but circumventable via hard links/bind mounts, and the LSM-hook-coverage difference (SELinux mediates far more object classes). Read this to be able to defend the choice of MAC to a vendor or auditor, not just parrot "SELinux is stricter."
- [AppArmor core policy reference (Ubuntu)](https://ubuntu.com/server/docs/security-apparmor) and [`apparmor.d(5)`](https://manpages.ubuntu.com/manpages/noble/man5/apparmor.d.5.html) - The profile language and the `complain` (learning) mode that has no clean SELinux equivalent. Understand `aa-genprof`/`aa-logprof` as the path-based analog of the `permissive-domain + audit2allow` workflow.

**Hardening**

- [CIS Red Hat Enterprise Linux 9 Benchmark](https://www.cisecurity.org/benchmark/red_hat_linux) - The authoritative control list. Pair it with the automated implementation rather than hand-applying: the SCAP Security Guide ships CIS profiles for RHEL/Rocky.
- [SCAP Security Guide (ComplianceAsCode) - GitHub](https://github.com/ComplianceAsCode/content) - The open-source source-of-truth for `oscap` content (`ssg-rhel9-ds.xml`, `ssg-rl9-ds.xml`). Contains the CIS, STIG, and PCI profiles as machine-checkable XCCDF plus Ansible/Bash remediation. This is how you *prove* compliance (Lab 4g) instead of asserting it, and how you generate a remediation playbook.
- [Red Hat: security hardening guide (RHEL 9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/index) - Distro-native coverage of `auditd` rule syntax, `sysctl` hardening, and the `pam`/`faillock` stack. The `auditd` chapter documents the rule field syntax (`-a always,exit -F arch=b64 -S execve ...`) used in Lab 4d.
- [systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html) and [systemd.resource-control(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html) - The sandbox directives from Lab 4f at the syscall/namespace level: `ProtectSystem`, `SystemCallFilter` (which is seccomp-bpf), `RestrictAddressFamilies`, `CapabilityBoundingSet`. `systemd-analyze security <unit>` scores a unit against exactly these. This is how you harden a service without writing any SELinux policy.

**Ongoing**

- [LWN.net kernel/security index](https://lwn.net/Kernel/Index/#Security) - How you avoid your MAC knowledge going stale: LSM stacking progress, Landlock (the unprivileged sandboxing LSM worth knowing exists), and SELinux changes land here first with the actual reasoning.

---

## Senior signal

- **Reads a raw `avc: denied` record like a sentence.** From `scontext`/`tcontext`/`tclass`/`{perm}` alone, names the source domain, target type, object class, and missing rule, and decides in seconds whether the fix is a boolean, a relabel, a port label, or a policy module, without running `sealert` and blindly pasting its suggestion. Mid-level reaches for `setenforce 0` or `audit2allow | semodule -i` reflexively.
- **Knows `chcon` vs `semanage fcontext` + `restorecon` cold, and why it matters.** Never leaves a "fix" that a future relabel silently reverts. Understands that labels live in the `security.selinux` xattr, that new files get a *computed transition* type (not the sibling's), and that this is why "worked in /tmp, broke after mv/cp" happens.
- **Runs `semodule -DB` before ever concluding "SELinux isn't the problem."** Understands that `dontaudit` rules hide real denials, so an empty audit log proves nothing until dontaudit is disabled. This one habit resolves a large fraction of "mysterious" failures that everyone else blames on the app.
- **Debugs in permissive *domains*, not global permissive.** `semanage permissive -a foo_t` to develop policy for one service on an otherwise-enforcing box, then `-d` to re-confine. Knows that RHEL 9 deprecated full disable for good reasons (unlabeled files + the `.autorelabel` storm on re-enable) and treats "disable SELinux" as a last resort that creates a bigger future outage.
- **Distinguishes a TE denial from a constraint (MCS/MLS/RBAC) denial**, because `audit2allow` can't fix the latter, it just generates a rule that already exists in spirit. Recognizes container isolation as MCS category subset-ing on top of a shared `container_t`/`container_file_t`, and can explain the `:z`/`:Z` volume flags in terms of category relabeling.
- **Understands the Flask split well enough to reason about performance.** Knows the AVC caches `(src,tgt,class)` decisions so the hot path is a hash hit, checks `avc/cache_stats` when someone claims "SELinux is adding latency," and knows the security server / `security_compute_av` is the slow path that only runs on a miss.
- **Writes and ships a real confined domain**, choosing `sepolicy generate` to *confine an app* versus `audit2allow` to *patch a denial*, hand-tightening the `.te` instead of accepting over-broad generated rules, and knows the full pipeline (`checkmodule` -> `semodule_package` -> CIL -> relinked binary policy loaded via `/sys/fs/selinux/load`) plus module priorities for overriding shipped policy.
- **Hardens with proof, and prefers override mechanisms over editing package-owned files.** Uses `sysctl.d` drop-ins, `sshd_config.d` drop-ins, `systemctl edit` overrides, and `augenrules`, never edits the shipped unit or config. Brings a `systemd-analyze security` before/after delta and an `oscap` XCCDF report to a hardening review instead of a list of files touched, and validates (`sshd -t`) before restarting a remote service.

---

## See also

- [[01 - Permissions and Access Control]] - the DAC layer (owner/group/mode, ACLs, setuid/capabilities) that runs *first* and must pass before SELinux MAC is even consulted; this module builds directly on that ordering ("DAC answers who owns the bits, MAC answers whether the domain is allowed the access").
- [[02 - Users, Authentication and PAM]] - the login and identity plumbing that feeds the SELinux login mapping (`semanage login`); how a Linux user becomes an SELinux user/role, and why confining an interactive account (`user_u`) depends on the PAM/authentication stack covered there.
- [[06 - Kubernetes Security (CKS-level)]] — seccomp, AppArmor/SELinux profiles, Pod Security admission, and least-privilege securityContexts are this module's MAC-and-hardening pass applied to the cluster; the `container_t`/MCS isolation here is the SELinux side of pod isolation.
- [[09 - Well-Architected Security and Least-Privilege in Practice]] — defense-in-depth and least privilege at the cloud layer mirror the MAC-after-DAC AND-ing and the systemd-sandbox/`sysctl`/SSH hardening pass here; same principles, different enforcement plane.
- [[08 - Logging Auditing and Detection]] — the cloud analog of the `auditd`/AVC auditing in §13 and Lab 4: tamper-evident logging, detecting policy violations, and the "the denial you can't see" (`dontaudit`) discipline generalized to cloud detection.
- [[06 - Apptainer for HPC Containers]] — SELinux/MCS confinement of HPC container payloads on enforcing nodes; the `:z`/`:Z`-style relabeling and category isolation are what keep multi-tenant HPC containers apart.
