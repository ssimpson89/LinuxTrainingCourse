---
title: Namespaces and cgroups v2
type: module
track: linux-internals
tags: [linux-internals, namespaces, cgroups, containers, clone, unshare, user-namespaces, rootless, resource-control, psi]
requires: ["Rocky 9.x VM with root", "kernel>=5.6 (time namespace lab)", "kernel>=5.2 (other labs)", "unprivileged user with /etc/subuid+/etc/subgid range (rootless labs)", "newuidmap/newgidmap from shadow-utils (range mapping on Rocky 9)", "util-linux>=2.38 for unshare --map-users/--map-groups (Rocky 10; NOT Rocky 9.7)"]
module_number: 10
status: reviewed
created: 2026-07-08
---

# 10 — Namespaces and cgroups v2

Backlink: [[00 - Track Overview]]

A container is not a kernel object. There is no `struct container` anywhere in the tree. A container is an *emergent* property of a process that happens to (a) live in a private set of namespaces, (b) be accounted and constrained by a cgroup subtree, (c) have a restricted capability/seccomp/LSM profile, and (d) have had its root filesystem replaced. This module is about the first two, which are the load-bearing halves. Understand namespaces + cgroups v2 at the syscall and kernel-structure level and you can build, break, and debug any container runtime, because runc/crun/containerd/systemd-nspawn are all just orchestrators of the same handful of syscalls you'll call by hand in the capstone.

The senior tell here is that you stop reciting "namespaces isolate, cgroups limit" and start reasoning about the *coupling*: which namespace a resource lives in, who owns a cgroup, why a delegation boundary exists, and what exactly breaks when you get uid mapping or mount propagation wrong. Namespaces isolate *what you can see and name*; cgroups control *how much you can consume*. They are orthogonal and independently composable, and every real bug lives in the seams between them.

---

## Concept deep-dive

### The two mechanisms, precisely

**Namespaces** partition kernel-global identifier spaces so that processes in different namespaces see different sets of the same *kind* of resource. Before namespaces, there was exactly one PID space, one mount table, one hostname, one network stack. A namespace wraps one of those global tables and lets you have many. The set of namespaces a task belongs to is reached through `task_struct->nsproxy` (a `struct nsproxy` in `include/linux/nsproxy.h`), which holds pointers to the mount, UTS, IPC, net, PID, cgroup, and time namespaces. The user namespace is *not* in nsproxy; it hangs off the credentials (`task_struct->cred->user_ns`) because it governs privilege, not resource visibility.

```
task_struct
  ├── cred ──────────► struct cred
  │                      └── user_ns ──► struct user_namespace   (privilege / uid-gid mapping)
  └── nsproxy ───────► struct nsproxy
                         ├── mnt_ns    ► struct mnt_namespace    (mount table)
                         ├── uts_ns    ► struct uts_namespace    (hostname, domainname)
                         ├── ipc_ns    ► struct ipc_namespace    (SysV IPC, POSIX mqueues)
                         ├── net_ns    ► struct net              (interfaces, routes, sockets, conntrack)
                         ├── pid_ns... ► struct pid_namespace    (PID→task allocation)
                         ├── cgroup_ns ► struct cgroup_namespace (root-relative cgroup view)
                         └── time_ns   ► struct time_namespace   (CLOCK_MONOTONIC/BOOTTIME offsets)
```

`nsproxy` is reference-counted and *shared* between tasks that share all their namespaces (the common case: every thread and most processes point at the same nsproxy). The moment you `unshare()` one namespace, the kernel copies the nsproxy for that task and swaps in a fresh namespace object. This copy-on-unshare is why unshare is cheap until you actually diverge.

Namespaces are exposed as inodes under `/proc/<pid>/ns/`. Each is a magic symlink like `net:[4026531840]` — the number is the namespace's inode number, and it is the *identity* of the namespace. Two processes are in the same net namespace iff `readlink /proc/PID/ns/net` returns the same inode. Holding an open fd to one of those files keeps the namespace alive even with no member processes (this is exactly how `ip netns add` persists a namespace: it bind-mounts `/proc/self/ns/net` onto `/run/netns/NAME`).

**cgroups v2** is the resource *accounting and control* mechanism: a single unified hierarchy where each node is a cgroup (a `struct cgroup`), processes are attached to leaf cgroups, and *controllers* (cpu, memory, io, pids, …) walk the tree to enforce limits and aggregate usage. Where v1 had a separate hierarchy per controller (a process could be in `/sys/fs/cgroup/cpu/A` and `/sys/fs/cgroup/memory/B` simultaneously, an incoherent mess that made joint cpu+memory decisions impossible), v2 has *one* tree and a process sits at exactly one node in it.

### The three syscalls

Everything namespace-related is three syscalls plus `clone3`:

- **`clone(2)` / `clone3(2)`** — create a new process, and with `CLONE_NEW*` flags, create *and enter* new namespaces in the child atomically. This is what runtimes use: the child is born already isolated.
- **`unshare(2)`** — move the *calling* process into new namespaces without forking. `unshare(CLONE_NEWNS)` gives the caller a private mount namespace right now. Caveat: `unshare(CLONE_NEWPID)` does *not* move the caller into the new PID namespace — it can't, because a process's PID can't change. Instead the caller's *next fork* becomes PID 1 of the new namespace. Same pattern for `CLONE_NEWTIME`.
- **`setns(2)`** — join an *existing* namespace referenced by an fd (either `/proc/PID/ns/*` or a pinned/bind-mounted ns file, or a pidfd). This is `nsenter`'s mechanism and how a runtime "execs into" a running container.

The flags (`CLONE_NEWNS`, `CLONE_NEWUTS`, `CLONE_NEWIPC`, `CLONE_NEWPID`, `CLONE_NEWNET`, `CLONE_NEWUSER`, `CLONE_NEWCGROUP`, `CLONE_NEWTIME`) are shared across all three calls. `CLONE_NEWNS` is the odd historical name — it predates the word "namespace" being generalized, so "NEWNS" means the *mount* namespace specifically.

### The eight namespace types

**Mount (`CLONE_NEWNS`, 2.4.19).** Owns the mount table — the set of `(source, mountpoint, fs, options)` tuples. The subtle and heavily-tested part is **mount propagation** (the shared-subtree model, kernel 2.6.15). Every mount has a propagation type:

- **shared** (`MS_SHARED`): member of a peer group; mount/unmount events propagate to all peers in both directions.
- **private** (`MS_PRIVATE`): isolated; no events in or out.
- **slave** (`MS_SLAVE`): receives events from its master peer group but sends none back. One-way mirror.
- **unbindable** (`MS_UNBINDABLE`): private *and* cannot be a bind-mount source. Used to stop recursive bind explosions.

Why this matters: when you `unshare(CLONE_NEWNS)`, the new namespace starts as a *copy* of the parent's mount table, and by default the copies are shared peers. So a mount you make inside can leak out and vice versa — unless propagation is set to private/slave. This is precisely why `systemd` remounts `/` as `MS_SHARED` at boot but container runtimes remount the container root as `MS_SLAVE` or `MS_PRIVATE`: they want host mounts (e.g. a new USB disk) to appear inside, but container mounts to *not* pollute the host. Get this wrong and either your bind mounts vanish or you leak mounts the host can never unmount (the classic "device or resource busy" on shutdown). `MS_REC` applies the change recursively to the whole subtree.

**UTS (`CLONE_NEWUTS`).** The trivial one. Owns `nodename` and `domainname` (UTS = UNIX Time-sharing System, from the `struct utsname` that `uname(2)` fills). This is why `hostname` inside a container differs from the host. That's the entire namespace.

**IPC (`CLONE_NEWIPC`).** Owns System V IPC objects (message queues, semaphore sets, shared memory segments — the `ipcs` stuff) and POSIX message queues (`/dev/mqueue`). Keys and IDs are namespace-local, so two containers can each `shmget` the same key without collision. Also isolates `/proc/sys/kernel/shmmax` and friends.

**PID (`CLONE_NEWPID`, 2.6.24).** The one with the richest semantics. It virtualizes PID allocation and creates a *hierarchy* — a PID namespace has a parent, and a task has a *different PID in each ancestor namespace* (its own, its parent's, up to the root). So a container's PID 1 might be PID 30451 on the host. Two rules that trip people up:

1. **init semantics.** The first process in a new PID namespace is PID 1 and inherits init duties: it reaps orphaned zombies (children whose parents died get reparented to it, not to host PID 1), and signals behave specially — the kernel only delivers signals to PID 1 for which it has installed a handler (so a naive PID 1 with no `SIGTERM` handler *ignores* `SIGTERM`, which is why `docker stop` on a shell-as-PID-1 hangs 10s then `SIGKILL`s). If PID 1 dies, the kernel `SIGKILL`s the entire namespace and tears it down.
2. **`unshare` timing.** As noted, `unshare(CLONE_NEWPID)` doesn't move you; your next child is PID 1. And `/proc` still shows the *old* namespace until you also give the new init a private mount namespace and mount a fresh `procfs` (procfs renders PIDs relative to the *reader's* PID namespace, but the mount is pinned to the pid-ns of whoever mounted it).

**Network (`CLONE_NEWNET`).** The heavyweight. A full independent network stack: its own loopback, network interfaces, IP addresses, routing tables, ARP/neighbor tables, firewall (netfilter/nftables) rules, conntrack table, port number space, and `/proc/net`, `/sys/class/net`. A fresh net namespace has *only* a down `lo`. Connectivity is built by moving one end of a `veth` pair into the namespace (`ip link set veth1 netns <pid>`) — veth is a virtual patch cable; a packet into one end comes out the other. This is the substrate under every CNI plugin, Docker bridge, and pod network. Creating a net namespace is expensive (the kernel allocates per-namespace copies of a lot of network state), which is why net-ns creation is a measurable cost at container-startup scale.

**User (`CLONE_NEWUSER`, 3.8, the keystone).** Virtualizes UID/GID *and capability* space. Inside a user namespace, a process can hold full capabilities (be "root") over resources owned by that namespace, while on the host it maps to an unprivileged UID with zero host capabilities. This is what makes **rootless containers** possible: an ordinary user creates a user namespace, becomes uid 0 inside it, and *then* creates the other namespaces (which normally need `CAP_SYS_ADMIN`) because they're now owned by a user namespace where the user has that capability.

The mapping lives in `/proc/PID/uid_map` and `gid_map`, each line `<inside_id> <outside_id> <count>`. Rules that bite people:
- You must write the map *before* the process does much, and each file is **write-once**.
- An **unprivileged** writer (no `CAP_SETUID` on the host) can only create a *single* mapping of *their own* uid: `0 <myuid> 1`. That's one uid inside. To map a *range* (needed for any real container, which uses many uids), you need the setuid helpers **`newuidmap`/`newgidmap`** (`cap_setuid+ep` / `cap_setgid+ep`), which validate the requested ranges against **`/etc/subuid`** and **`/etc/subgid`** — the sub-range delegated to your user by the admin (e.g. `ssimpson:100000:65536`). This is the entire mechanism behind rootless Podman.
- Before writing `gid_map` as an unprivileged user, you must first write `"deny"` to **`/proc/PID/setgroups`**. Otherwise you could use `setgroups(2)` to *drop* a group that was restricting your access to a file (a real CVE-class privilege escalation, CVE-2014-8989). The `setgroups=deny` is the fix.

Capabilities are namespaced: a capability is now a triple (capability, target namespace). You can be all-powerful in your userns and powerless outside it. Nested user namespaces (up to 32 deep) form a tree, and a capability in a parent userns implies it in children.

**Cgroup (`CLONE_NEWCGROUP`, 4.6).** Virtualizes the *view* of the cgroup hierarchy in `/proc/PID/cgroup` and `/proc/PID/mountinfo`. When you unshare it, your current cgroup becomes the apparent root, so processes inside see paths relative to it (`/` instead of `/machine.slice/…/container-abc`). Without this, a container could read its full host cgroup path and learn about the host layout, and cgroupfs mounted inside would expose the whole host tree. It changes *naming/visibility only* — it does not move you to a different cgroup or change your limits.

**Time (`CLONE_NEWTIME`, 5.6, the newest).** Virtualizes offsets for `CLOCK_MONOTONIC` and `CLOCK_BOOTTIME` *only* (not `CLOCK_REALTIME` — wall-clock is deliberately not virtualized). Offsets are written to `/proc/PID/timens_offsets` as `<clockid> <secs> <nanosecs>`, write-once after the first process enters, requires `CAP_SYS_TIME` in the owning userns. The *sole* motivation is checkpoint/restore (CRIU): when you freeze a container and thaw it an hour later on another host, `CLOCK_MONOTONIC` and uptime would jump by an hour and break anything that computed durations; the time namespace applies a compensating offset so the container sees continuity. Implemented partly in the VDSO so `clock_gettime` stays fast (`kernel/time/namespace.c`).

### cgroups v2: the unified hierarchy

Mounted once at `/sys/fs/cgroup` (filesystem type `cgroup2`, magic `0x63677270`). Every directory is a cgroup; you create one with `mkdir`. Key interface files and the rules that govern them:

- **`cgroup.procs`** — the PIDs in this cgroup. Write a PID to move it (moving a PID moves all its threads). Read to enumerate.
- **`cgroup.controllers`** — which controllers are *available* here (were enabled by the parent).
- **`cgroup.subtree_control`** — which controllers this cgroup *hands down to its children*. You enable/disable with `+cpu`/`-memory` etc. A controller is only usable in a child if the parent listed it here.

**The "no internal processes" rule** is the single most important structural constraint and the thing people fight. A cgroup that has controllers enabled in `subtree_control` may **not** simultaneously contain processes *and* enabled child controllers — put differently, once a cgroup distributes a resource to children, only leaf cgroups may hold processes. The root is exempt. This is why systemd builds `.slice` (branch) and `.scope`/`.service` (leaf) nodes: processes live in leaves, resource distribution happens at branches.

```
/sys/fs/cgroup/                      (root — exempt from the rule)
├── cgroup.subtree_control: cpu memory io pids
├── system.slice/                    (branch: no procs, subtree_control=cpu memory)
│   ├── sshd.service/                (leaf: has cgroup.procs, cpu.max, memory.max)
│   └── nginx.service/
├── user.slice/
│   └── user-1000.slice/
│       └── user@1000.service/       (the per-user systemd, delegated subtree below here)
└── machine.slice/                   (containers / VMs)
    └── libpod-<id>.scope/
```

**The controllers (mechanism):**

- **cpu** — `cpu.weight` (1–10000, default 100) is *proportional* share under contention (this is the EEVDF/CFS weight). `cpu.max` is the *absolute* cap: `"<quota> <period>"` in microseconds, e.g. `50000 100000` = 50ms of CPU every 100ms = half a core. The killer diagnostic: `cpu.stat` reports `nr_periods`, `nr_throttled`, and `throttled_usec`. **A process pinned at "50% CPU" on the dashboard can be catastrophically throttled** if its work is bursty — it burns its quota in the first 20ms of each 100ms window and is then *frozen* for 80ms, adding up to 80ms of tail latency, while average utilization reads a comfortable 50%. `nr_throttled` climbing is the smoking gun that the metric is lying.

- **memory** — three watermarks with distinct semantics that everyone conflates:
  - `memory.max` — the **hard limit / OOM boundary**. Exceed it and reclaim runs; if reclaim can't free enough, the cgroup OOM killer fires *within this cgroup* (not the global OOM killer).
  - `memory.high` — the **throttle-via-reclaim** watermark. There's *no OOM kill*; instead the kernel throttles the offending tasks and aggressively reclaims to push usage back down. Overshooting `high` makes you slow, not dead. This is the knob for graceful degradation.
  - `memory.low` / `memory.min` — **protection** (reclaim mostly/entirely skips this cgroup down to this size). `min` is a hard guarantee; `low` is best-effort.
  - `memory.current`, `memory.stat` (anon vs file vs slab vs sock breakdown), `memory.events` (counts of `high`/`max`/`oom`/`oom_kill` events — watch these).

- **io** — `io.max` per-device throttling (`MAJ:MIN rbps=… wbps=… riops=… wiops=…`), `io.weight` for proportional bandwidth (works with the BFQ/blk-mq cost model), `io.latency` for latency-based protection (a target latency; cgroups exceeding it get others throttled), and `io.stat` for per-device accounting. Note io throttling is on the *block* layer, so it accounts buffered writeback correctly only with the memory controller co-enabled (writeback is attributed back to the cgroup that dirtied the page).

- **pids** — `pids.max` caps the number of tasks; `pids.current` reads the count. The fork-bomb containment primitive.

**Pressure Stall Information (PSI).** Every cgroup exposes `cpu.pressure`, `memory.pressure`, `io.pressure`. Each reports `some` (fraction of wall time ≥1 task was stalled waiting for the resource) and, for memory/io, `full` (fraction of time *all* runnable tasks were stalled — pure lost work), averaged over 10s/60s/300s plus a running `total` microsecond counter. PSI is the correct signal for "is this cgroup starved?" because it measures *stall*, not utilization. 100% CPU utilization with zero `cpu.pressure` = healthy saturation; 60% utilization with rising `some` = contention hurting you. This is the modern replacement for guessing from load average.

### Delegation and the systemd relationship

**Delegation** hands an unprivileged user (or a container) ownership of a *subtree* so they can create and manage their own cgroups without root. You delegate by `chown`ing the subtree directory *and* the specific files `cgroup.procs`, `cgroup.subtree_control`, `cgroup.threads` to the target user. The delegatee can then build cgroups below, but the kernel enforces **containment**: they cannot move processes *into or out of* the delegated subtree (that would let them escape their limits), and the parent still caps everything.

The **`nsdelegate`** mount option makes cgroup *namespaces* into automatic delegation boundaries: with it set, a process cannot move itself outside its cgroup-namespace root even if permissions would otherwise allow it. This is a system-wide option settable only from the init namespace.

systemd is the practical owner of the cgroup tree on any modern distro. It runs as the sole writer at the root and expects everyone else to ask it (via the D-Bus API / transient units) rather than scribble on cgroupfs directly — the "single-writer rule." Its resource-control directives map straight onto the controllers: `CPUWeight=`→`cpu.weight`, `CPUQuota=`→`cpu.max`, `MemoryHigh=`/`MemoryMax=`→`memory.high`/`memory.max`, `IOWeight=`→`io.weight`, `TasksMax=`→`pids.max`. For rootless containers, systemd delegates `user@UID.service` to the user, which is *why* rootless Podman can set cgroup limits at all.

### Failure modes and scale behavior

- **Mount propagation leaks**: forget to make the container root `MS_SLAVE`/`MS_PRIVATE` and container mounts pin host resources; unmounts fail with `EBUSY`, disks won't detach, shutdown hangs.
- **PID 1 signal trap**: shell or app as PID 1 with no signal handlers ignores `SIGTERM` → slow, `SIGKILL`-based shutdowns; zombies pile up if PID 1 doesn't reap (why runtimes inject a tiny init like `tini`/`catatonit`).
- **uid_map / setgroups ordering**: writing `gid_map` before `setgroups=deny` fails as unprivileged; getting the range wrong vs `/etc/subuid` makes `newuidmap` refuse and the container won't start.
- **CFS throttling masquerading as healthy**: covered above — the canonical "the metric is lying" case. Watch `cpu.stat throttled_usec`.
- **memory.high thrash**: setting `high` too low sends a workload into permanent reclaim — it "runs" but at a fraction of speed with high `memory.pressure full`, looking alive but useless.
- **cgroup churn at scale**: per-cgroup memory/PSI accounting has overhead; creating/destroying thousands of cgroups/sec (heavy container churn) shows up as kernel CPU in `css_free`/rstat flushing. cgroup v2's rstat aggregation is lazy but reading `*.stat` forces a flush.
- **Net namespace creation cost**: dominates cold-start container latency at scale; each is a full stack allocation.
- **PID exhaustion is namespace-global to the host**: `pids.max` limits per cgroup, but total PIDs are a host resource; a runaway namespace without `pids.max` can still exhaust `kernel.pid_max` for everyone.

---

## Hands-on labs

> All labs assume a **throwaway Linux VM** (any distro with kernel ≥ 5.6 for the time-namespace lab; ≥ 5.2 otherwise). Everything is distro-agnostic. Install the tooling first:
>
> ```bash
> # Debian/Ubuntu
> sudo apt-get update && sudo apt-get install -y util-linux iproute2 uidmap strace stress-ng cgroup-tools
> # Fedora/Rocky/RHEL
> sudo dnf install -y util-linux iproute strace stress-ng libcgroup-tools shadow-utils
> ```
>
> Confirm cgroup v2 is the active hierarchy (systemd unified mode):
> ```bash
> stat -fc %T /sys/fs/cgroup    # must print: cgroup2fs
> ```
> If it prints `tmpfs`, you're on hybrid/v1 — boot with `systemd.unified_cgroup_hierarchy=1` on the kernel cmdline and reboot.

### Lab 1 — Watch namespaces come into existence

**Objective.** Make the invisible visible: prove that namespaces are per-process kernel objects with inode identities, and that `unshare` swaps exactly one while leaving the rest shared.

**Setup.** Two terminals on the VM. Nothing else needed.

**Steps.**

1. Baseline: record your shell's namespace inodes.
   ```bash
   ls -l /proc/$$/ns/
   ```
   Note the inode numbers in the `-> net:[4026531840]` targets. Every process on the host shares these (the "initial" namespaces).

2. In terminal A, unshare a UTS namespace and change the hostname only inside it:
   ```bash
   sudo unshare --uts bash
   hostname container-a
   hostname            # -> container-a
   readlink /proc/$$/ns/uts   # a NEW inode number
   readlink /proc/$$/ns/net   # SAME as host — only uts changed
   ```

3. In terminal B (still on the host), check the host hostname and the shell's uts inode:
   ```bash
   hostname                   # unchanged host name
   readlink /proc/$$/ns/uts   # the original inode
   ```

4. Now trace what `unshare` actually does at the syscall level:
   ```bash
   sudo strace -f -e trace=unshare,clone,clone3,setns unshare --uts --pid --fork --mount-proc bash -c 'echo pid1 is $$; ps -e'
   ```
   Read the trace: you'll see one `unshare(CLONE_NEWUTS|CLONE_NEWPID|...)`, then a `clone`/`clone3` for the `--fork` child that becomes PID 1, and `ps` reporting a nearly empty process table because `--mount-proc` mounted a fresh procfs bound to the new PID namespace.

**Prove it.**
```bash
# From the host, confirm the unshared shell has a different uts ns but same net ns:
PID_A=$(pgrep -f 'unshare --uts bash' | head -1)   # or note the bash pid in terminal A
sudo readlink /proc/$PID_A/ns/uts        # differs from host
sudo readlink /proc/$PID_A/ns/net        # equals: readlink /proc/1/ns/net
```
If uts differs and net matches, you've proven namespaces are independently swappable per-process objects.

---

### Lab 2 — Rootless from scratch: user namespaces and UID mapping

**Objective.** Become "root" with zero host privilege, and understand exactly why rootless containers work — including the `setgroups`/`gid_map` ordering trap and the `subuid` range mechanism.

**Setup.** An **unprivileged** login user (do *not* sudo). Ensure a subuid/subgid range exists:
```bash
grep "^$(id -un):" /etc/subuid /etc/subgid || \
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$(id -un)"
```

**Steps.**

1. As the unprivileged user, create a user namespace and map *only yourself* to uid 0 (the single-mapping case, no helpers):
   ```bash
   unshare --user --map-root-user bash
   id                       # uid=0(root) gid=0(root) — inside the userns
   cat /proc/self/uid_map   #          0       <youruid>          1
   ```
   You are root *inside*, but check what you can actually touch:
   ```bash
   cat /etc/shadow          # Permission denied — host root's files are owned by host uid 0, not you
   id -u                    # 0 inside; but on the host this process is still your uid
   ```

2. Prove the `setgroups` trap. Open a *second* userns manually and try to write `gid_map` first:
   ```bash
   unshare --user bash -c '
     echo "0 $(id -u) 1" > /proc/self/uid_map
     echo "0 $(id -g) 1" > /proc/self/gid_map   # <-- this FAILS: Operation not permitted
   '
   ```
   Now do it in the correct order (`setgroups=deny` first):
   ```bash
   unshare --user bash -c '
     echo deny > /proc/self/setgroups
     echo "0 $(id -u) 1" > /proc/self/uid_map
     echo "0 $(id -g) 1" > /proc/self/gid_map
     id
   '
   ```

3. Now the *range* case using the setuid helpers (what real runtimes do). Rocky 9.7 ships util-linux 2.37.4, whose `unshare` has **no** one-shot range-mapping flags: `--map-users`/`--map-groups` were added upstream in util-linux 2.38, so they exist on Rocky 10 but *not* on Rocky 9. On Rocky 9 you drive the `newuidmap`/`newgidmap` setuid helpers against the unshared PID from a second shell, which is exactly what rootless Podman does under the hood.

   In terminal A, create the user namespace plus the nested namespaces (these normally need root) and leave the shell sitting at its prompt. Until the maps are written the process is still your uid (it shows up as `nobody`/overflow inside), so don't run privileged ops yet:
   ```bash
   # terminal A:
   unshare --user --mount --pid --fork --mount-proc --uts bash
   ```
   In terminal B (still the unprivileged user), find that PID and apply the mapping. The rootless idiom maps inside-uid 0 to *your own* host uid (one id) and inside-uids 1..65535 to your delegated subuid range, validated against `/etc/subuid`/`/etc/subgid`:
   ```bash
   # terminal B:
   UPID=$(pgrep -f 'unshare --user --mount')
   newuidmap "$UPID" 0 "$(id -u)" 1  1 100000 65535
   newgidmap "$UPID" 0 "$(id -g)" 1  1 100000 65535
   ```
   Back in terminal A, the shell is now uid 0 inside the userns:
   ```bash
   # terminal A:
   id                       # uid 0
   cat /proc/self/uid_map   #   0  <youruid>      1
                            #   1     100000  65535   (a full range, via newuidmap)
   hostname rootless        # allowed: we hold CAP_SYS_ADMIN in THIS userns
   ps -e                    # tiny table: private PID namespace
   ```

4. From the host (another terminal), see the truth — that "root" is your unprivileged uid:
   ```bash
   ps -o pid,uid,cmd -C bash        # the rootless bash runs as YOUR host uid, not 0
   ```

**Prove it.**
```bash
# Inside the rootless namespace, you are uid 0 and can create nested namespaces;
# on the host the same process is unprivileged. Show both truths at once:
# (inside)
grep Cap /proc/self/status        # CapEff shows a full-ish mask (effective in this userns)
readlink /proc/self/ns/user       # a non-initial userns inode
# (host)
awk '{print $1}' /proc/$(pgrep -f 'bash' | tail -1)/uid_map   # inside-id 0 maps to a host subuid
```
Full capabilities inside + unprivileged host uid = you understand rootless.

**Teardown.** Exit any rootless shells (their namespaces disappear with the last member process). If the setup step *added* the subuid/subgid range (it skips when one already exists, so only do this if `usermod` actually ran), remove it to leave `/etc/subuid` and `/etc/subgid` as you found them:
```bash
pkill -u "$(id -un)" -f 'unshare --user' 2>/dev/null || true
sudo usermod --del-subuids 100000-165535 --del-subgids 100000-165535 "$(id -un)"
```

---

### Lab 3 — Drive the cgroup v2 controllers by hand and catch the throttling lie

**Objective.** Create cgroups directly on cgroupfs, enable controllers through the subtree, and *observe CFS throttling while utilization looks moderate* — the canonical senior diagnostic.

**Setup.** Root on the VM (writing raw cgroupfs). `stress-ng` installed. Pick a scratch cgroup under a delegated-safe location. We'll create our own branch under the root.

**Steps.**

1. Create a cgroup and enable the cpu controller down to it. Respect the no-internal-processes rule: put the load in a *leaf*.
   ```bash
   cd /sys/fs/cgroup
   sudo mkdir -p demo.slice/work
   # enable cpu+memory+pids from root down to demo.slice, then down to the leaf:
   echo '+cpu +memory +pids' | sudo tee cgroup.subtree_control
   echo '+cpu +memory +pids' | sudo tee demo.slice/cgroup.subtree_control
   cat demo.slice/work/cgroup.controllers    # cpu memory pids now available in the leaf
   ```

2. Set a hard CPU cap of half a core and launch a CPU hog *inside the leaf*:
   ```bash
   echo '50000 100000' | sudo tee demo.slice/work/cpu.max      # 50ms per 100ms = 0.5 core
   # launch a one-core burner and drop it into the leaf:
   stress-ng --cpu 1 --timeout 60s &
   HOG=$!
   echo $HOG | sudo tee demo.slice/work/cgroup.procs
   cat demo.slice/work/cgroup.procs           # confirm the pid is in the leaf
   ```

3. In another terminal, watch the *two contradictory views* simultaneously:
   ```bash
   # View 1: top says ~50% of a core — looks like a healthy half-core workload
   top -p $HOG
   # View 2: the cgroup tells the truth — throttling is piling up
   watch -n1 'cat /sys/fs/cgroup/demo.slice/work/cpu.stat; echo ---; \
              cat /sys/fs/cgroup/demo.slice/work/cpu.pressure'
   ```
   Watch `nr_throttled` and `throttled_usec` climb every second, and `cpu.pressure some` rise. The task *wants* a full core; it's frozen for half of every period. Utilization (50%) hides a workload that is being actively starved and would show tail-latency spikes in any real service.

4. Now the memory controller. Show `high` (throttle) vs `max` (kill):
   ```bash
   sudo mkdir -p /sys/fs/cgroup/demo.slice/mem
   echo '64M' | sudo tee /sys/fs/cgroup/demo.slice/mem/memory.high    # throttle here
   echo '96M' | sudo tee /sys/fs/cgroup/demo.slice/mem/memory.max     # OOM here
   # allocate 200M inside the leaf and watch it get throttled then killed:
   ( echo $BASHPID | sudo tee /sys/fs/cgroup/demo.slice/mem/cgroup.procs >/dev/null
     stress-ng --vm 1 --vm-bytes 200M --vm-keep --timeout 30s )
   # in another terminal:
   watch -n1 'cd /sys/fs/cgroup/demo.slice/mem; \
              echo current=$(cat memory.current); cat memory.events; echo ---; cat memory.pressure'
   ```
   You'll see `memory.current` stall near `high` with `memory.pressure full` rising (throttle-via-reclaim), and if it pushes past `max`, `memory.events` `oom_kill` increments — the *cgroup* OOM killer, not the global one.

**Prove it.**
```bash
# The proof that "50% CPU" was a lie: throttling was nonzero the whole time.
cat /sys/fs/cgroup/demo.slice/work/cpu.stat | grep -E 'nr_throttled|throttled_usec'
# nr_throttled and throttled_usec should both be large and > 0.

# cleanup
sudo bash -c 'kill '"$HOG"' 2>/dev/null; \
  rmdir /sys/fs/cgroup/demo.slice/work /sys/fs/cgroup/demo.slice/mem /sys/fs/cgroup/demo.slice 2>/dev/null'
```
Nonzero `nr_throttled` while `top` showed 50% is the whole lesson.

---

### Lab 4 (Capstone) — Build a container from scratch, no runtime

**Objective.** Assemble a working "container" — isolated pid/mount/uts/net + resource limits — using only `unshare`, `ip`, `pivot_root`, and cgroupfs. When you finish this, `docker run` holds no mysteries.

**Setup.** Root on the VM (this version uses full namespaces; a rootless variant is noted at the end). Build a minimal rootfs. If you have `debootstrap`/`dnf --installroot` use them; otherwise a busybox rootfs is enough and fast:
```bash
sudo mkdir -p /tmp/rootfs/{bin,proc,sys,dev,oldroot}
# Static busybox gives us a shell + coreutils in one binary:
which busybox || sudo apt-get install -y busybox-static || sudo dnf install -y busybox
cp "$(command -v busybox)" /tmp/rootfs/bin/busybox
for a in sh ls ps mount hostname ip cat sleep; do sudo ln -sf busybox /tmp/rootfs/bin/$a; done
```

**Steps.**

1. **Create the cgroup that will bound the container** (before launch, so PID 1 is born constrained):
   ```bash
   cd /sys/fs/cgroup
   echo '+cpu +memory +pids' | sudo tee cgroup.subtree_control >/dev/null
   sudo mkdir -p scratch-container
   echo '20000 100000' | sudo tee scratch-container/cpu.max >/dev/null   # 0.2 core
   echo '128M'         | sudo tee scratch-container/memory.max >/dev/null
   echo '64'           | sudo tee scratch-container/pids.max >/dev/null
   ```

2. **Launch the isolated process.** `unshare` creates mount+uts+ipc+pid+net namespaces; `--fork` makes the child PID 1; we'll finish the rootfs pivot and cgroup join inside:
   ```bash
   sudo unshare --mount --uts --ipc --pid --net --fork --mount-proc=/tmp/rootfs/proc \
     /bin/bash -c '
       set -e
       # join our cgroup as the very first thing (PID 1 of the new ns):
       echo $$ > /sys/fs/cgroup/scratch-container/cgroup.procs
       hostname scratch-container

       # make mount propagation private so nothing leaks back to the host:
       mount --make-rprivate /

       # bind the rootfs onto itself so it becomes a mount point (pivot_root needs this):
       mount --bind /tmp/rootfs /tmp/rootfs
       cd /tmp/rootfs

       # pivot into the new root, tuck the old root under ./oldroot, then detach it:
       pivot_root . oldroot
       cd /
       mount -t proc proc /proc
       mount -t sysfs sys /sys 2>/dev/null || true
       umount -l /oldroot
       rmdir /oldroot 2>/dev/null || true

       export PATH=/bin
       echo "=== inside container ==="; hostname; echo "PID of shell: $$"
       exec /bin/sh
     '
   ```
   You're now in a shell where `ps` (run `mount -t proc proc /proc` already done) shows only container processes, `hostname` is `scratch-container`, and the filesystem is the busybox rootfs. `$$` is 1 or close to it.

3. **Prove the isolation from inside** (in the container shell):
   ```bash
   ps                  # only your shell + ps — private PID namespace
   hostname            # scratch-container — private UTS
   ip link             # only 'lo' (down) — private, empty net namespace
   ls /                # the busybox rootfs, not the host's /
   ```

4. **Wire up networking** with a veth pair (from the *host*, in another terminal). Find the container PID and plumb a cable:
   ```bash
   CPID=$(pgrep -f 'unshare --mount --uts' )   # the unshare; find the child pid1 via /proc
   # the actual namespaced init is the child of that unshare:
   CPID=$(pgrep -P "$CPID" | head -1)
   sudo ip link add veth-h type veth peer name veth-c
   sudo ip link set veth-c netns "$CPID"
   sudo ip addr add 10.77.0.1/24 dev veth-h
   sudo ip link set veth-h up
   # inside the container's netns, bring up its end:
   sudo nsenter -t "$CPID" -n ip addr add 10.77.0.2/24 dev veth-c
   sudo nsenter -t "$CPID" -n ip link set veth-c up
   sudo nsenter -t "$CPID" -n ip link set lo up
   ```
   Back in the container shell: `ip addr` now shows `veth-c` with `10.77.0.2`, and `ping 10.77.0.1` reaches the host. You built container networking by hand.

5. **Prove the resource cap holds.** Inside the container, try to blow the pids limit and the memory limit:
   ```bash
   # pids: this fork bomb hits the 64-task ceiling and fails to grow further, host unaffected
   :(){ : | : & };:            # (ctrl-c after a moment; it cannot exceed pids.max=64)
   ```

**Prove it.** From the host:
```bash
CPID=$(pgrep -P "$(pgrep -f 'unshare --mount --uts')" | head -1)
# 1. Distinct namespaces vs host:
for n in pid net mnt uts; do
  echo "$n: host=$(sudo readlink /proc/1/ns/$n)  container=$(sudo readlink /proc/$CPID/ns/$n)"
done
# 2. The process is inside our cgroup and pids.current respected the cap:
cat /sys/fs/cgroup/scratch-container/cgroup.procs         # contains $CPID
cat /sys/fs/cgroup/scratch-container/pids.current         # <= 64
cat /sys/fs/cgroup/scratch-container/cpu.stat | grep throttled   # throttling under load
```
All four namespace inodes differ from PID 1's, the pid is accounted in your cgroup, and `pids.current` never exceeded 64. That is a container — no Docker involved.

**Cleanup.**
```bash
# exit the container shell, then:
sudo ip link del veth-h 2>/dev/null
sudo rmdir /sys/fs/cgroup/scratch-container 2>/dev/null
sudo rm -rf /tmp/rootfs
```

**Rootless variant (stretch).** Redo step 2 wrapping everything in `unshare --user --map-root-user` *first* (and use `newuidmap` ranges as in Lab 2). You'll find you can create the mount/pid/uts namespaces without host root — but the veth plumbing needs either a privileged helper or slirp4netns, which is exactly why rootless Podman ships `slirp4netns`/`pasta` for userspace networking. That gap is a real architectural lesson, not a lab failure.

---

## Curated resources

**Primary references (the ABI is the source of truth):**

- **[namespaces(7)](https://man7.org/linux/man-pages/man7/namespaces.7.html)** — the overview page. Read it as an essay, then read the per-type pages. Each namespace type has its own dense man7 page:
  - **[user_namespaces(7)](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)** — the keystone. The uid_map/gid_map algorithm, the setgroups rule, capability semantics across userns boundaries, nesting limits. Read this twice; it's the highest-leverage single page in the module.
  - **[mount_namespaces(7)](https://man7.org/linux/man-pages/man7/mount_namespaces.7.html)** — the propagation-type state machine (shared/slave/private/unbindable) that no blog gets fully right.
  - **[pid_namespaces(7)](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html)** — init/reaping/signal semantics and the unshare-doesn't-move-you rule.
  - **[cgroup_namespaces(7)](https://man7.org/linux/man-pages/man7/cgroup_namespaces.7.html)** and **[time_namespaces(7)](https://man7.org/linux/man-pages/man7/time_namespaces.7.html)** — the two newest, view-virtualization and CLOCK offsets respectively.
- **[clone(2)](https://man7.org/linux/man-pages/man7/namespaces.7.html), [unshare(2)](https://man7.org/linux/man-pages/man2/unshare.2.html), [setns(2)](https://man7.org/linux/man-pages/man2/setns.2.html)** — the three syscalls. Note the flag caveats (unshare+PID timing, setns+userns rules).
- **[Control Group v2 — kernel.org admin-guide](https://docs.kernel.org/admin-guide/cgroup-v2.html)** — *the* spec. The no-internal-processes rule, the delegation model, per-controller interface files, and the crucial `memory.high` (throttle) vs `memory.max` (OOM) distinction plus PSI. When a blog disagrees with this page, this page wins.
- **[cgroups(7)](https://man7.org/linux/man-pages/man7/cgroups.7.html)** — the man7 companion; good on the v1↔v2 differences and why v2 exists.
- **[capabilities(7)](https://man7.org/linux/man-pages/man7/capabilities.7.html)** — required background: capabilities are namespaced, and the file-cap transformation is what makes `newuidmap` and rootless work.
- **rockyman.org** — https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here. Relevant to this module because the `unshare`/`newuidmap`/`usermod` syntax drifts between Rocky 9 (util-linux 2.37.4, no `--map-users`/`--map-groups`) and Rocky 10 (util-linux 2.38+).

**Landmark long-form (the "why it works this way"):**

- **[LWN: "Namespaces in operation" (Kerrisk, 7-part series)](https://lwn.net/Articles/531114/)** — the definitive from-scratch build-up of every namespace type by the man-pages maintainer. Part 1 links the rest. This is the conceptual backbone; if you read one external thing, read this.
- **[LWN: "Mount namespaces and shared subtrees"](https://lwn.net/Articles/689856/)** and **["Mount namespaces, mount propagation, and unbindable mounts"](https://lwn.net/Articles/690679/)** — the two articles that finally make propagation types click, with the diagrams the man page lacks.
- **[Control Group APIs and Delegation — systemd.io](https://systemd.io/CGROUP_DELEGATION/)** — the single-writer rule, why you don't scribble on cgroupfs behind systemd's back, how delegation and `nsdelegate` actually work in practice, and the `.slice`/`.scope`/`.service` model. Essential for anything running under systemd (i.e. everything).

**Rootless containers (the applied user-namespace endgame):**

- **[rootlesscontaine.rs — User Namespaces](https://rootlesscontaine.rs/how-it-works/userns/)** and the **[subuid/subgid page](https://rootlesscontaine.rs/getting-started/common/subuid/)** — the clearest explanation of the `newuidmap`/`/etc/subuid` range mechanism and the single-mapping limitation, straight from the rootless-containers project.

**Books:**

- **The Linux Programming Interface (Kerrisk), ch. on process creation, credentials, and the namespace chapters** — [man7.org/tlpi](https://man7.org/tlpi/). The syscall-boundary grounding for clone/fork/exec and the full credential model that user namespaces virtualize.
- **[BPF Performance Tools (Gregg)](https://www.brendangregg.com/bpf-performance-tools-book.html)** — the observability endgame; use `bpftrace` to watch namespace/cgroup transitions live (`kprobe:cgroup_attach_task`, tracepoints on cgroup migration) when a runtime misbehaves.

**Source (read alongside the tree open):**

- `include/linux/nsproxy.h`, `kernel/nsproxy.c` — the `nsproxy` struct and copy-on-unshare logic.
- `kernel/pid_namespace.c`, `kernel/user_namespace.c` — init/reaping and the uid-map validation you triggered in Lab 2.
- `kernel/time/namespace.c` — VDSO offset application for the time namespace ([torvalds/linux](https://github.com/torvalds/linux/blob/master/kernel/time/namespace.c)).
- `kernel/cgroup/` — the whole cgroup core; `cgroup.c` for the hierarchy and the no-internal-processes enforcement, `rstat.c` for the lazy stat aggregation that shows up as CPU under churn.

---

## Senior signal

- **Can articulate what a container *is* in terms of syscalls** — "a process born via `clone`/`unshare` with `CLONE_NEW*`, accounted by a cgroup subtree, with a pivoted root and dropped caps" — rather than "a lightweight VM." They know there is no `struct container` and can build one by hand (Lab 4), so no runtime is a black box to them.
- **Reasons about the namespace/cgroup seam, not each in isolation.** Knows namespaces live in `nsproxy` (visibility) while the user namespace lives in `cred` (privilege), and that cgroups are orthogonal to all of it. Can explain why a cgroup namespace changes the *view* but not the *limits*, and why the user namespace is the keystone that unlocks all the others for unprivileged users.
- **Distrusts the utilization metric and reaches for `cpu.stat`/PSI.** Immediately checks `nr_throttled`/`throttled_usec` and `cpu.pressure` when a "50% CPU" service has latency spikes, because they know CFS quota throttling hides behind a healthy-looking average. Uses `memory.pressure full` to distinguish a throttling workload (alive but useless) from a healthy saturated one.
- **Knows `memory.high` vs `memory.max` cold** — throttle-via-reclaim vs the cgroup-local OOM boundary — and uses `high` deliberately for graceful degradation instead of only setting a hard cap and getting surprise OOM kills. Reads `memory.events` for `oom_kill` counts rather than grepping `dmesg`.
- **Gets mount propagation right by default.** Sets container roots `MS_SLAVE`/`MS_PRIVATE` deliberately and can diagnose the `EBUSY`-on-unmount / disk-won't-detach / shutdown-hang class of bugs as a propagation leak, not a hardware problem.
- **Understands the uid-mapping mechanics that break rootless setups** — the write-once maps, the single-mapping-vs-range distinction, `/etc/subuid` ranges via `newuidmap`, and the mandatory `setgroups=deny`-before-`gid_map` ordering (and the CVE that ordering fixes). Can debug "container won't start as non-root" from first principles.
- **Respects the systemd single-writer rule and the delegation model.** Sets limits via unit directives / transient units and delegates subtrees properly (chowning `cgroup.procs` + `cgroup.subtree_control`) rather than fighting systemd by writing raw cgroupfs, and understands `nsdelegate` and the no-internal-processes rule that shapes the whole tree.
- **Thinks about scale behavior**: net-namespace creation cost dominating cold starts, rstat flush CPU under cgroup churn, and host-global PID exhaustion despite per-cgroup `pids.max`. Knows which costs are per-container and which are shared, which is the difference between a runtime that scales and one that melts at 10k containers.

---

## See also

- [[01 - Permissions and Access Control]] — the user namespace virtualizes UID/GID and *capability* space; the caps, setuid-helper, and `/etc/subuid` mechanics that make rootless work build directly on the access-control model covered there.
- [[03 - Processes, Scheduling and Signals]] — PID-namespace init semantics (reaping, PID 1 signal handling) and the `cpu.weight`/`cpu.max` EEVDF/CFS throttling behavior are the process-and-scheduler concepts applied inside a cgroup.
- [[06 - Networking Deep]] — the network namespace, `veth` pairs, and per-namespace routing/netfilter state are the substrate under every container network; that module goes deep on the stack a fresh net-ns gives you.
- [[07 - systemd]] — systemd is the single writer of the cgroup v2 tree; its `.slice`/`.scope`/`.service` model, resource-control directives, and delegation of `user@UID.service` are what make the hand-rolled cgroups in these labs production-real.
- [[03 - Containers from the Ground Up]] — this module is the kernel substrate ("a container is not a kernel object"); that module builds runc/crun/containerd-style runtimes and OCI images on top of the exact `unshare`/`pivot_root`/cgroup calls in the capstone.
- [[04 - Kubernetes Control-Plane Internals]] — pods are orchestrated collections of these namespaces + cgroups; the kubelet and CRI drive the same syscalls, and the CFS-throttling-vs-utilization lie is the canonical K8s "slow pod, low CPU" incident.
- [[02 - GPUs in Containers]] — exposing a GPU to a container is device-cgroup allowlisting plus namespace/mount plumbing built directly on the controllers and mount-propagation rules here.
- [[06 - Apptainer for HPC Containers]] — Apptainer is rootless-first: the user-namespace + `/etc/subuid` + `newuidmap` + `setgroups=deny` mechanics from Lab 2 are exactly why it runs unprivileged on HPC login nodes.
- [[06 - Kubernetes Security (CKS-level)]] — namespace and cgroup isolation, user namespaces, and seccomp/caps are the pod security boundary; the seams-between-mechanisms failures here are the container-escape surface that module defends.
