---
title: systemd
type: module
track: linux-internals
tags: [linux-internals, systemd, cgroups, init, journald, socket-activation, resource-control]
requires: [Rocky 9.x VM with root, systemd v250+, cgroup v2 unified hierarchy]
module_number: 7
status: reviewed
created: 2026-07-08
---

# 07 - systemd

Backlink: [[00 - Track Overview]]

> Scope: the unit model (service/socket/target/slice/scope/timer/mount/path/automount/device/swap), dependency + ordering semantics and the transaction/job engine, cgroup integration and resource control, journald internals, socket/path activation, `systemd-analyze`, drop-ins/overrides and the load path, user vs system managers, and the supervision mechanism that made systemd win. This is a mechanism module: we care about the D-Bus API surface, the syscalls PID 1 makes, the cgroupfs writes, the fd-passing ABI, and the on-disk journal format, not the "how do I enable a service" surface.

---

## Concept deep-dive

### What systemd actually is, and why it won

systemd is not "an init system." It is a **manager of a dependency graph of typed objects (units), backed by cgroups, driven over a D-Bus API, that happens to also be PID 1.** The init part is the least interesting part. Three design decisions won the argument against SysV init and Upstart, and you should be able to defend each at the mechanism level:

1. **Aggressive parallelization via socket activation removes ordering as a boot bottleneck.** SysV boot was a topologically-sorted shell-script pipeline: service B could not start until service A's script returned, because B connected to A's socket and A had to be listening first. systemd inverts this. It creates *all* listening sockets up front (in PID 1, before any daemon runs), then starts every service in parallel. If B connects to A's socket before A is ready, the connection just sits in the kernel's socket buffer (the accept queue), and the kernel blocks the reader until A drains it. **The kernel's socket buffer becomes the synchronization primitive**, so explicit ordering between A and B is unnecessary. This is the same trick launchd used on macOS, and it is the single biggest reason boot went from sequential to parallel. (See socket activation below.)

2. **cgroups give reliable process tracking that PID-based supervision never had.** A classic SysV daemon double-forks and reparents to PID 1 to "daemonize," which severs the parent's knowledge of it. PID files lie (stale PIDs, recycled PIDs). systemd puts every service in its own cgroup, so *every* process a service spawns, no matter how many times it forks or how it tries to escape, stays in that cgroup. `systemctl stop` kills the cgroup, not a PID. This is why systemd always knows the exact process set of a service, and why `KillMode=`, `MemoryMax=`, and `systemctl status` showing the full process tree all just work. Process tracking and resource control are the same mechanism.

3. **A declarative dependency graph with a transaction engine replaces imperative ordering.** Instead of numbered symlinks (`S20foo`, `K80bar`), units declare relationships (`Wants=`, `After=`), and systemd computes a transaction (a consistent set of jobs) and executes it respecting ordering while maximizing parallelism. Ordering and requirement are **orthogonal axes**, which is the thing mid-level admins get wrong most often.

PID 1 responsibilities in the kernel sense: it is the ancestor that reaps all orphaned zombies (`wait()` on reparented children), it receives `SIGCHLD` for the whole orphan pool, it must never crash (a PID 1 crash panics the kernel), and it is the D-Bus endpoint `org.freedesktop.systemd1` on the system bus. `systemctl` is just a D-Bus client. `busctl` lets you talk to that API raw.

```
                 org.freedesktop.systemd1  (D-Bus system bus)
                              ▲
      systemctl / busctl ─────┘
                              │  (StartUnit, StopUnit, GetUnit, SetUnitProperties…)
                              ▼
   ┌─────────────────────────────────────────────────────────┐
   │  systemd (PID 1)                                          │
   │   ┌──────────────┐   ┌───────────────┐   ┌────────────┐  │
   │   │ Unit table   │   │ Job / Trans-  │   │ Event loop │  │
   │   │ (typed objs) │──▶│ action engine │──▶│ sd-event   │  │
   │   └──────────────┘   └───────────────┘   └─────┬──────┘  │
   │           writes cgroupfs, opens sockets, fork/exec       │
   └────────────────────────────────────────────────┼─────────┘
                                                     ▼
              /sys/fs/cgroup/…    listening sockets (fd 3+)    child procs
```

### The unit model: typed objects, not scripts

A unit is a named, typed state machine. The type suffix selects the C implementation and the set of legal directives. The eleven types you must know:

| Type | Purpose | Contains procs? | Key mechanism |
|------|---------|-----------------|---------------|
| `.service` | A daemon or one-shot job systemd forks | yes (leaf cgroup) | `ExecStart=`, `Type=`, readiness protocol |
| `.socket` | A listening socket systemd owns on behalf of a service | no | socket activation, fd passing |
| `.target` | A synchronization / grouping point (no exec) | no | replaces SysV runlevels; pure dependency anchor |
| `.slice` | Inner node of the cgroup tree for resource partitioning | **no** (v2 rule) | `-.slice`→`system.slice`/`user.slice`/`machine.slice` |
| `.scope` | Externally-forked procs adopted into a cgroup (transient only) | yes (leaf) | created via D-Bus by session/container managers |
| `.timer` | Time- or calendar-based activation | no | monotonic + realtime (`OnCalendar=`), persistence |
| `.mount` | A mount point (mirrors an fstab entry) | no | generated from `/etc/fstab` by a generator |
| `.automount` | Lazy autofs-backed mount | no | kernel autofs, mounts on first access |
| `.path` | Activation on filesystem events | no | inotify-driven |
| `.device` | A udev device exposed as a unit | no | udev tags (`SYSTEMD_WANTS=`) create ordering edges |
| `.swap` | A swap area | no | generated from fstab |

`.scope` vs `.service` is the crucial distinction: a **service** encapsulates processes *systemd itself* fork/exec'd; a **scope** encapsulates processes some *other* process forked and then handed to systemd via the D-Bus `StartTransientUnit` call (this is how `systemd-logind` wraps every login session as `session-42.scope`, and how `machined`/container runtimes wrap payloads). Scopes are always transient (never on-disk unit files). This is the mechanism answer to "what is a container, in systemd terms": a scope (or a delegated service) whose cgroup has `Delegate=yes`.

Targets are worth internalizing: `multi-user.target`, `graphical.target`, `basic.target`, `sysinit.target`, `network-online.target` are not "runlevels with names." They are units with no `ExecStart`; they exist purely to be depended-upon. `graphical.target` `Requires=multi-user.target` and `After=multi-user.target`; the display manager `WantedBy=graphical.target`. The "default target" (`systemctl get-default`, a symlink `/etc/systemd/system/default.target`) is the root of the boot transaction.

### The load path and drop-in precedence (where a unit actually comes from)

When you reference `foo.service`, systemd searches a **fixed, layered set of directories**, highest priority first, and the *first* full unit file found wins for the main file. This is straight out of `systemd.unit(5)`:

```
/etc/systemd/system/       ← admin, highest priority (survives package updates)
/run/systemd/system/       ← runtime, volatile (generators, transient units)
/usr/lib/systemd/system/   ← package-shipped (RPM-owned; do NOT edit here)
```

Two mechanisms override without editing the package-owned file, and this maps directly onto the CLAUDE.md "never modify package-owned files" rule:

- **Full replacement**: a `foo.service` in `/etc/systemd/system/` shadows the `/usr/lib` one entirely.
- **Drop-ins (the right answer)**: a directory `foo.service.d/` containing `*.conf` fragments. systemd loads the main unit, then applies every drop-in `.conf` alphabetically on top. Drop-ins can be in `/etc`, `/run`, or `/usr/lib`, and they stack by directory priority *then* filename. `systemctl edit foo.service` creates `/etc/systemd/system/foo.service.d/override.conf`. This is the canonical, update-safe override, equivalent to a config drop-in directory for any RPM-owned file.

Precedence gotcha that bites people: for **list-valued** directives (`ExecStart=`, `After=`, `Environment=`), a drop-in *appends*. To *replace* a list you must first clear it with an empty assignment (`ExecStart=` with nothing) then set the new value. For scalar directives the last assignment wins. `systemctl cat foo.service` shows the fully-merged effective unit with source-file comments; `systemd-delta` shows every override/masked/extended relationship system-wide. `mask` is the nuclear option: symlink the unit to `/dev/null` so it can never be started, even as a dependency.

**Generators** (`systemd.generator(7)`) run *before* unit loading, very early in boot, and synthesize units into `/run/systemd/generator*`. `systemd-fstab-generator` turns `/etc/fstab` into `.mount`/`.swap` units; `systemd-gpt-auto-generator` discovers root/ESP by GPT partition type UUID; `systemd-getty-generator` spawns gettys. This is why there is no `.mount` file on disk for your root filesystem: it is generated every boot.

### Dependency vs ordering: the two orthogonal axes

This is the highest-frequency conceptual error. **Requirement dependencies decide *which* units get pulled into the transaction. Ordering dependencies decide *when* they run relative to each other. Neither implies the other.** If you write `Requires=b.service` with no `After=b.service`, systemd will start both, *in parallel, in undefined order*. That is almost never what you meant.

Requirement / pull-in directives:

| Directive | Semantics |
|-----------|-----------|
| `Wants=` | Pull in the target; if it fails, we don't care. The soft, preferred form. |
| `Requires=` | Pull in the target; if it fails *to start*, we fail too. Does **not** by itself react to later runtime failure. |
| `Requisite=` | Like Requires, but does **not** start the target; requires it to be *already active*, else fail immediately. |
| `BindsTo=` | Like Requires, but also tracks *runtime* state: if the bound unit stops for any reason (even a crash or a device unplug), we stop too. The strong coupling. |
| `PartOf=` | One-directional propagation of stop/restart only: stopping/restarting the parent propagates to us, but not vice versa. |
| `Conflicts=` | Negative dependency: starting us stops the other, and vice versa (mutual exclusion, e.g. `emergency.target` vs everything). |
| `Upholds=` | Continuously restart the target as long as we're active (stronger than Wants, added later). |

Ordering directives: `Before=` / `After=` (mirror images), plus `Requires=`+`After=` is the common "start it and wait for it" combo. The relationships expressed in `[Install]` (`WantedBy=`, `RequiredBy=`) are not live dependencies; they are instructions for what `systemctl enable` should create as symlinks in the *reverse* dependency's `.wants/` directory. Enabling is just symlink management.

**The transaction / job engine.** When you `systemctl start graphical.target`, systemd does not walk and exec. It:

1. Builds a **transaction**: the set of **jobs** (a job = "bring unit U to state S", e.g. `start`, `stop`, `restart`, `verify-active`) implied by the requested job plus all its requirement dependencies, recursively.
2. **Merges** jobs: if two paths both request `start dbus.service`, they collapse to one job. Conflicting jobs in one transaction (start X and stop X) are resolved or the transaction is refused as inconsistent.
3. **Orders** jobs using the `After/Before` edges, and **detects ordering cycles**. On a cycle, systemd tries to break it by dropping a job that is not strictly required (logging `Found ordering cycle… breaking cycle by deleting job X`). If it can't, the whole transaction is refused. A cycle involving a `Requires` edge can leave the system unbootable, dropped to emergency mode.
4. Executes jobs, running non-ordered jobs concurrently, gated only by the ordering edges. Ordering also implicitly controls **shutdown**: stop ordering is the reverse of start ordering, computed from the same `After/Before` graph, which is why you almost never write explicit stop ordering.

Two default dependencies you must remember (`DefaultDependencies=yes`, on unless disabled): normal service units get `Requires=sysinit.target After=sysinit.target` and `After=basic.target`, plus `Conflicts=shutdown.target Before=shutdown.target` so they're cleanly torn down. Setting `DefaultDependencies=no` (common for early-boot units) removes these; get it wrong and you create a cycle with `sysinit.target`.

### Service types and the readiness protocol (the supervision core)

`Type=` tells systemd *when a service is considered "started"* (the "up" edge that satisfies `After=` for later units). Getting this wrong is the classic "my service reports active but the thing depending on it starts too early" bug.

| `Type=` | "Started" means… | Notes |
|---------|-------------------|-------|
| `simple` | the moment `fork()`+`execve()` returns (immediately) | default if `ExecStart` set and no `Type`/`BusName`. systemd does *not* know when the daemon is actually ready. Downstream `After=` fires too early. |
| `exec` | `execve()` has succeeded in the child | slightly stronger than simple: catches exec failures synchronously. Good default for modern units. |
| `forking` | the *parent* exits after fork'ing the real daemon | the classic SysV double-fork daemon. Needs `PIDFile=` to track the child. Fragile; avoid for new code. |
| `oneshot` | the process **exits successfully** | for one-shot setup jobs. Combine with `RemainAfterExit=yes` so the unit stays "active" after the process is gone. |
| `dbus` | the service acquires its `BusName=` on the bus | readiness = D-Bus name ownership. |
| `notify` / `notify-reload` | the daemon sends `READY=1` via `sd_notify()` | **the correct readiness contract.** Downstream units start only after the daemon says it's ready. `notify-reload` adds reload signaling. |
| `idle` | delayed until other jobs are dispatched | cosmetic (avoids interleaving console output); do not use for real ordering. |

`sd_notify(3)` is the mechanism worth knowing cold. The daemon writes newline-separated `KEY=value` datagrams to a `AF_UNIX`/`SOCK_DGRAM` socket whose path systemd passes in `$NOTIFY_SOCKET`. Messages: `READY=1` (I'm up), `RELOADING=1` + `MONOTONIC_USEC=…` (reload started) then `READY=1` (reload done), `STOPPING=1` (going down), `STATUS=…` (free-text status shown in `systemctl status`), `WATCHDOG=1` (pet the watchdog), `MAINPID=…`, and `FDSTORE=1` for the fd store. It's a plain `sendmsg()`; you can emulate it with `systemd-notify` from a shell for testing.

**The watchdog** (`WatchdogSec=`) turns readiness into liveness: systemd expects a `WATCHDOG=1` datagram at least every `WatchdogSec`; miss it and systemd considers the service hung and applies `Restart=`/`WatchdogSignal=`. Combined with a hardware watchdog (`RuntimeWatchdogSec=` in `system.conf`), a hung PID 1 or hung critical service can hard-reboot the box. This is how you build a self-healing appliance.

`Restart=` (`no`/`on-failure`/`on-abnormal`/`on-watchdog`/`on-abort`/`always`) plus `RestartSec=`, and the **start-limit rate limiter** (`StartLimitIntervalSec=`/`StartLimitBurst=` in `[Unit]`): if a service restarts more than `burst` times within the interval, systemd gives up and enters `failed` with "start request repeated too quickly." This is a common production trap: the fix flaps, hits the limit, and stays down until `systemctl reset-failed`.

### cgroup integration and resource control (v2)

systemd is the **single writer** to the cgroup v2 unified hierarchy (`/sys/fs/cgroup`). It builds the tree from slices:

```
/sys/fs/cgroup/                      (root; -.slice)
├── init.scope/                      (PID 1 itself)
├── system.slice/                    (all system services)
│   ├── sshd.service/
│   │   └── cgroup.procs             (every pid of sshd, forks included)
│   ├── nginx.service/
│   └── …
├── user.slice/
│   └── user-1000.slice/
│       ├── user@1000.service/       (the per-user systemd --user manager)
│       └── session-3.scope/         (a login session; procs adopted by logind)
└── machine.slice/                   (nspawn/libvirt VMs & containers)
```

The slice name encodes the path with `-` as separator: `user-1000.slice` lives at `/user.slice/user-1000.slice/`. Resource control directives (`systemd.resource-control(5)`) map directly onto cgroup v2 controller interface files, and setting any of them **auto-enables** the controller for that unit (systemd writes `+cpu`/`+memory`/`+io` to the parent's `cgroup.subtree_control` up the chain):

| Directive | cgroup v2 file | Mechanism |
|-----------|----------------|-----------|
| `CPUWeight=` (1–10000, default 100) | `cpu.weight` | proportional share under contention (EEVDF/CFS). *Weight*, not a cap. |
| `CPUQuota=` (e.g. `20%`) | `cpu.max` (quota period) | **hard cap**: `quota_us period_us`. Exceeding it gets you throttled: the task is dequeued until the next period even if CPUs are idle. |
| `MemoryHigh=` | `memory.high` | soft limit: throttle-via-reclaim. Over it, the cgroup is aggressively reclaimed and processes stalled, but not killed. |
| `MemoryMax=` | `memory.max` | hard limit: the **cgroup-local OOM boundary**. Over it and unreclaimable → cgroup OOM kill (independent of global OOM). |
| `MemoryMin=`/`MemoryLow=` | `memory.min`/`memory.low` | reclaim protection (guaranteed / best-effort). |
| `IOWeight=` / `IODeviceWeight=` | `io.weight` | proportional I/O (needs bfq or the cost model). |
| `IOReadBandwidthMax=` etc. | `io.max` | absolute I/O bandwidth/IOPS caps per device. |
| `TasksMax=` | `pids.max` | fork-bomb containment (pids controller). |
| `AllowedCPUs=`/`AllowedMemoryNodes=` | `cpuset.cpus`/`cpuset.mems` | CPU/NUMA pinning via the cpuset controller. |

The senior insight (straight from the shared research): **`CPUQuota` throttling shows up as latency while CPU utilization looks low.** A service capped at `CPUQuota=50%` on an 8-core box uses at most 0.5 cores; if its bursty workload wants 4 cores for 10ms, it runs for that quota then gets **throttled** for the rest of the period, so a request that should take 10ms takes 100ms+ while `top` shows the box 90% idle. The evidence is in `cpu.stat`: `nr_throttled` and `throttled_usec` climb. Dashboards showing "50% CPU, healthy" are lying; the cgroup `cpu.stat` throttle counters are the truth. This is the canonical "the metric is lying" story.

**PSI (Pressure Stall Information)** is the modern signal: `cpu.pressure`, `memory.pressure`, `io.pressure` per cgroup (and system-wide in `/proc/pressure/`) report the % of time tasks were stalled waiting for that resource. `some avg10=…` (some tasks stalled) vs `full avg10=…` (all tasks stalled) distinguishes contention from starvation. `systemd-oomd` uses memory+swap PSI to kill cgroups *proactively* before the kernel OOM killer engages, which gives you predictable victims instead of the kernel's heuristic pick.

**Delegation** (`Delegate=yes`, service/scope only, never slices) is how you hand a subtree to another manager (container runtime, a `systemd --user`). systemd then stops touching that subtree's attributes. Two mechanism traps: (1) the cgroup v2 **"no processes in inner nodes"** rule means once your delegated cgroup gains children it must not itself hold processes, so a delegated manager must migrate its own PID into a leaf sub-cgroup before creating children; (2) systemd makes the controllers *available* but does **not** enable them in your subtree, so you must write `+cpu +memory` to your own `cgroup.subtree_control` yourself. The nesting asymmetry (systemd insists on managing the top-level attributes of trees it delegates) is why a container manager running a full systemd payload needs an extra hierarchy level.

### Socket and path activation (the parallelization engine)

A `.socket` unit makes **systemd** create and `listen()` on the socket during early boot, holding the listening fd in PID 1. The matching service is started **on demand** (first incoming connection) and inherits the fd. The wire protocol between systemd and the daemon (`sd_listen_fds(3)`):

- systemd passes the listening fds starting at **fd 3** (`SD_LISTEN_FDS_START`), consecutively (3, 4, 5, …).
- `$LISTEN_FDS` = the count. `$LISTEN_PID` = the PID that should own them (the daemon checks `getpid() == $LISTEN_PID` to avoid a forked child grabbing them). `$LISTEN_FDNAMES` = colon-separated names (from `FileDescriptorName=`) so a daemon with multiple sockets can tell them apart.
- The daemon calls `sd_listen_fds()` which parses these, sets `FD_CLOEXEC`, and returns the count. It then just `accept()`s on fd 3.

```
Boot:   systemd socket() + bind() + listen()  → holds fd in PID 1, service NOT running
        │
Client connects ──▶ kernel queues SYN/data in the accept queue
        │
systemd sees POLLIN via its event loop ──▶ fork/exec the .service
        │  passes the listening fd as fd 3, sets LISTEN_FDS=1, LISTEN_PID=<child>
        ▼
daemon: sd_listen_fds() → accept(3) → serves the already-queued connection
```

`Accept=` selects the model. `Accept=no` (default, "inetd-in-listen-mode"): systemd passes the *listening* socket, one long-lived service instance handles all connections (nginx, most daemons). `Accept=yes` ("inetd per-connection"): systemd `accept()`s itself and spawns a **templated** instance `foo@<conn>.service` per connection, passing the *connected* socket as fd 3. `Accept=yes` scales terribly (a process per connection) and is mostly for legacy inetd-style tools.

Consequences you should be able to state: (1) socket activation enables **zero-downtime restarts**, because systemd holds the socket across the service restart, so connections queue in the kernel instead of getting refused; (2) it enables **lazy start** of rarely-used daemons (CUPS, D-Bus services), cutting boot time and idle memory; (3) it's why boot ordering mostly disappears (any client of a socket-activated service can start before it). The **file descriptor store** (`FDSTORE=1` via `sd_notify`, `FileDescriptorStoreMax=`) lets a daemon *stash* fds in PID 1 across its own restart/crash so it can resume with live connections and no state loss, the mechanism behind crash-resilient stateful daemons.

`.path` units are the inotify analog: activate a service when a path appears/changes (`PathExists=`, `PathChanged=`, `DirectoryNotEmpty=`), driven by `inotify`. `.timer` units are the cron replacement: `OnCalendar=` (realtime, uses `systemd-analyze calendar` to validate), `OnUnitActiveSec=`/`OnBootSec=` (monotonic), `Persistent=yes` to run missed jobs after downtime (stores last-run timestamps under `/var/lib/systemd/timers/`), and `RandomizedDelaySec=` to de-thundering-herd fleets.

### journald internals and the on-disk format

`systemd-journald` receives log records from four sources and stores them in an **append-only, indexed, binary** format: (1) the classic `/dev/log` `AF_UNIX` datagram socket (syslog compat), (2) the kernel ring buffer `/dev/kmsg`, (3) stdout/stderr of every service (systemd wires each service's stdout to a journald socket, tagged with the unit name automatically, which is why service output "just appears" in `journalctl -u`), and (4) the native protocol (`sd_journal_send`, structured key=value fields).

The structured model: each entry is a set of `FIELD=value` pairs. Fields with a leading underscore (`_PID`, `_UID`, `_SYSTEMD_UNIT`, `_BOOT_ID`, `_SELINUX_CONTEXT`, `_CMDLINE`) are **trusted** metadata that journald appends itself from `/proc` and the socket credentials (`SO_PEERCRED`) so they cannot be forged by the logging process; fields without the underscore came from the application. This trust boundary is why journald forensics are credible: `_PID`/`_UID`/`_SELINUX_CONTEXT` were stamped by PID-1's logger, not the sender.

On-disk (`man journald.conf`; files in `/var/log/journal/<machine-id>/` for persistent, `/run/log/journal/` for volatile). Each `.journal` file:

```
"LPKSHHRH"  (8-byte signature)
Header {
  file_id, machine_id, boot_id           (128-bit IDs)
  state: OFFLINE(0)/ONLINE(1)/ARCHIVED(2)
  header_size, arena_size
  n_objects, n_entries, n_data, n_fields
  data_hash_table_offset/size            ← direct pointer to the DATA hash table
  field_hash_table_offset/size
  tail_object_offset, entry_array_offset
  head/tail_entry_seqnum, *_realtime, tail_entry_monotonic
}
Objects (each: {type, flags, size} header):
  DATA        "field=value" payload (may be XZ/LZ4/ZSTD compressed)
  FIELD       a field name ("_SYSTEMD_UNIT")
  ENTRY       one log record: binds DATA offsets + timestamps + seqnum
  DATA_HASH_TABLE / FIELD_HASH_TABLE
  ENTRY_ARRAY sorted array of entry offsets (chained, doubling size)
  TAG         Forward Secure Sealing HMAC
```

Mechanism that matters:

- **De-duplication.** Identical field values (e.g. `_SYSTEMD_UNIT=sshd.service` on thousands of entries) are stored **once** as a single DATA object; each ENTRY just references its offset. This is why journals are far smaller than the equivalent text logs, and why field-value queries are fast.
- **Two-level hashing for O(1) field lookup.** The FIELD hash table maps a field name to its object; each DATA object chains into a per-value hash bucket via `next_hash_offset`. Hashing is **keyed siphash24** (keyed by `file_id`) on modern files, Jenkins lookup3 on old ones. So `journalctl _SYSTEMD_UNIT=sshd.service` is a hash lookup + a walk of that value's entry-array, not a scan.
- **Entry arrays for O(log n) time seeking.** Entries are ordered by seqnum; the chained, size-doubling ENTRY_ARRAY structure lets `journalctl --since` bisect by timestamp. Each DATA object *also* has its own entry-array chain (the entries mentioning that value), which is what makes filtered queries fast.
- **Single-writer / multiple-reader, no locking.** journald is the only writer; readers (`journalctl`, `sd_journal_*`) mmap the file and validate offsets. Consistency across a crash relies on `fdatasync()` bracketing the `state` field flip and on the append-only arena. A file is `ONLINE` while written, `ARCHIVED` when rotated (then never mutated), `OFFLINE` when cleanly closed. Crash-truncated files are detected and the tail is discarded on next open.
- **Rotation & retention.** Files rotate on size/time (`SystemMaxUse=`, `SystemMaxFileSize=`, `MaxFileSec=`); old files are `ARCHIVED` and vacuumed by total size / age / count (`SystemKeepFree=`, `MaxRetentionSec=`). `journalctl --disk-usage`, `--vacuum-size=`, `--vacuum-time=`.
- **Forward Secure Sealing (FSS).** With `journalctl --setup-keys` and `Seal=yes`, journald periodically writes a TAG object: a SHA-256 HMAC over all objects since the last tag, keyed by an epoch key derived from FSPRG (a forward-secure PRG). The key **evolves** (one-way) each fixed time epoch, and the old key is destroyed. Consequence: an attacker who compromises the box at time T cannot forge or silently alter entries written *before* T, because the key that would sign them is gone. `journalctl --verify` checks the chain. This is tamper-*evidence*, not tamper-*prevention*.

Query mechanics: `journalctl` is a client over the same files. `-o verbose` dumps all fields (including the trusted `_` ones); `-o json`/`json-pretty` for machine parsing; `-u`, `_PID=`, `_UID=`, `PRIORITY=`, `--boot`/`-b -1` (per-boot indexing via `_BOOT_ID`), `-k` (kernel), `-f` (follow), `--grep`, `-p err`. `journalctl --list-boots` uses the boot-id index. Forwarding: journald can relay to a classic syslog (`ForwardToSyslog=`) or you run `systemd-journal-remote`/`-upload` for centralization.

### user vs system managers

There are two kinds of systemd manager. The **system manager** is PID 1. Each logged-in user also gets a **user manager**: `systemd --user`, running as `user@<UID>.service` inside `user-1000.slice`, managing that user's own unit tree from `~/.config/systemd/user/` and `/usr/lib/systemd/user/`. It has its own bus (the session/user bus), its own targets (`default.target` for a user is usually `graphical-session.target`), and its own drop-in/override rules. Key mechanism: user units normally die at logout unless **lingering** is enabled (`loginctl enable-linger <user>`), which keeps the user manager alive at boot so user services (a rootless container, a syncthing) run without an active session. `systemctl --user` talks to your user manager; `systemctl` (or `--system`) talks to PID 1. `logind` (`systemd-logind`) is the piece that tracks sessions/seats, creates the `session-*.scope` units, and handles `HandlePowerKey=`, `KillUserProcesses=`, and inhibitor locks.

### Failure modes and behavior at scale

- **Ordering cycle → dropped job or unbootable.** systemd breaks cycles by deleting a non-essential job (logged), but a cycle through a `Requires` edge on a boot-critical unit lands you in `emergency.target`. `systemd-analyze verify foo.service` catches these offline; `systemctl list-jobs` shows a stuck transaction.
- **`Type=simple` premature-ready.** Downstream units start before the daemon is listening → connection-refused races that "only happen on fast boots." Fix is `Type=notify` + `sd_notify`, or a `.socket` unit.
- **Start-limit lockout.** A crash-looping service hits `StartLimitBurst` and stops retrying; looks "failed, not restarting" until `systemctl reset-failed`. At fleet scale a bad config push flaps every node into this state simultaneously.
- **`CPUQuota` throttling masquerading as idle** (covered above): latency with low utilization; read `cpu.stat` throttle counters and PSI.
- **cgroup memory limits vs global OOM.** A service under `MemoryMax=` gets a *cgroup-local* OOM kill (only its own tasks are candidates), which is often more surgical than the global killer, but a too-tight limit turns a memory spike into a kill-loop. `oom_score_adj` still applies within the cgroup. `systemd-oomd` + PSI kills the whole offending cgroup earlier and more predictably.
- **journald backpressure & rate limiting.** Under a log storm journald rate-limits per service (`RateLimitIntervalSec=`/`RateLimitBurst=`) and drops with a "Suppressed N messages" marker; if `/dev/log` fills, a synchronous-logging service can *block on its own log write*. A runaway service can also blow the journal disk budget and force premature vacuuming of everyone else's logs (noisy-neighbor logging).
- **Generator failures are silent-ish.** A broken generator (or a malformed `/etc/fstab`) fails very early, before most logging is up; you find it in `journalctl -b` from `systemd-fstab-generator` or dropped to the dracut/emergency shell.
- **Scale of the graph.** Thousands of units (per-connection `Accept=yes` templates, transient scopes from a busy login/container host) make the transaction graph large; `systemctl daemon-reload` re-parses everything and can briefly stall PID 1. Transient units (`systemd-run`) avoid on-disk churn but still live in the graph until they exit.

---

## Hands-on labs

> All labs assume a **throwaway VM** running a systemd distro with cgroup v2 unified hierarchy (any current Rocky/RHEL/Fedora/Debian/Ubuntu/Arch). Run as root (`sudo -i`) unless noted. Verify the baseline first:
>
> ```bash
> systemctl --version | head -1          # expect v250+; note EEVDF vs CFS is kernel-side
> stat -fc %T /sys/fs/cgroup             # expect "cgroup2fs" (unified). If "tmpfs", you're on v1/hybrid.
> mount | grep -w cgroup2                # confirm the v2 mount
> ```
>
> If you see `tmpfs` for `/sys/fs/cgroup`, boot with `systemd.unified_cgroup_hierarchy=1` on the kernel cmdline before doing the cgroup lab.

### Lab 1 — The transaction/job engine: pull-in vs ordering, and breaking a cycle

**Objective.** Make the orthogonality of requirement vs ordering *visible*, watch systemd merge jobs into a transaction, and deliberately create an ordering cycle to watch the cycle-breaker fire.

**Setup.**
```bash
mkdir -p /etc/systemd/system
cat >/etc/systemd/system/lab-a.service <<'EOF'
[Unit]
Description=Lab A
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo A started at $(date +%s.%N); sleep 2'
EOF

cat >/etc/systemd/system/lab-b.service <<'EOF'
[Unit]
Description=Lab B
Requires=lab-a.service
# NOTE: deliberately NO ordering here
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo B started at $(date +%s.%N)'
EOF
systemctl daemon-reload
```

**Steps.**
1. Start B and observe that A is pulled in but ordering is undefined. Because there is no `After=`, B's echo can fire *before* A finishes its `sleep 2`:
   ```bash
   systemctl reset-failed lab-a lab-b 2>/dev/null; systemctl stop lab-a lab-b 2>/dev/null
   systemctl start lab-b
   journalctl -u lab-a -u lab-b -o short-precise --no-pager | grep 'started at'
   ```
   Note the timestamps: B likely started *at or before* A. Requirement pulled A in, but did not order it.
2. Add ordering via a drop-in (the update-safe override mechanism), *without* editing the unit file. On Rocky 9 (systemd 252), `systemctl edit` has no `--stdin`, so write the drop-in directly (this is exactly what `systemctl edit lab-b.service` would create interactively):
   ```bash
   mkdir -p /etc/systemd/system/lab-b.service.d
   cat >/etc/systemd/system/lab-b.service.d/order.conf <<'DROP'
[Unit]
After=lab-a.service
DROP
   systemctl daemon-reload
   systemctl cat lab-b.service        # observe the merged unit + drop-in source comment
   ```
3. Re-run and confirm ordering now holds (B strictly after A's 2s sleep):
   ```bash
   systemctl stop lab-a lab-b; systemctl reset-failed lab-a lab-b 2>/dev/null
   systemctl start lab-b
   journalctl -u lab-a -u lab-b -o short-precise --no-pager | grep 'started at'
   ```
4. Inspect the transaction the manager would compute, and the live job queue:
   ```bash
   systemctl stop lab-a lab-b
   systemctl start lab-b &        # background so we can peek
   systemctl list-jobs           # see the start jobs and their "waiting"/"running" states
   wait
   ```
5. Now deliberately build an **ordering cycle** and watch the cycle-breaker:
   ```bash
   mkdir -p /etc/systemd/system/lab-a.service.d
   cat >/etc/systemd/system/lab-a.service.d/cycle.conf <<'EOF'
[Unit]
After=lab-b.service
EOF
   # lab-b has After=lab-a (from step 2), lab-a now has After=lab-b  → cycle
   systemctl daemon-reload
   systemctl start lab-b
   journalctl -b -u init.scope --no-pager | tail    # or:
   journalctl -b _PID=1 --no-pager | grep -i 'cycle' | tail
   ```
   systemd logs something like `Found ordering cycle on lab-b.service/start … Job lab-a.service/start deleted to break ordering cycle`.
6. Catch the same problem *offline*, the way you'd want to in CI before shipping a unit:
   ```bash
   systemd-analyze verify /etc/systemd/system/lab-b.service
   ```

**Prove it.**
```bash
# The offline verifier flags the ordering cycle without starting anything:
systemd-analyze verify lab-a.service lab-b.service 2>&1 | grep -i cycle
```
Non-empty output naming the cycle proves you understand that ordering edges (not requirement edges) create the cycle, and that the verifier catches it statically.

Cleanup: `systemctl stop lab-a lab-b; rm -rf /etc/systemd/system/lab-{a,b}.service*; systemctl daemon-reload`.

### Lab 2 — Socket activation from scratch: prove the fd-passing ABI

**Objective.** Build a socket-activated service with no real daemon, and *prove* that systemd hands the listening socket to the service as fd 3 with `LISTEN_FDS`/`LISTEN_PID` set, and that connections queue in the kernel before the service exists.

**Setup.**
```bash
cat >/etc/systemd/system/lab-echo.socket <<'EOF'
[Unit]
Description=Lab echo socket
[Socket]
ListenStream=127.0.0.1:9999
Accept=no
[Install]
WantedBy=sockets.target
EOF

# A "daemon" that does nothing but report its inherited environment and fds,
# then serves one line via socat-on-fd-3-free bash /dev/tcp trickery is awkward,
# so we introspect instead of serving:
cat >/etc/systemd/system/lab-echo.service <<'EOF'
[Unit]
Description=Lab echo service (introspection only)
Requires=lab-echo.socket
After=lab-echo.socket
[Service]
Type=simple
ExecStart=/usr/local/bin/lab-echo.sh
EOF

cat >/usr/local/bin/lab-echo.sh <<'EOF'
#!/bin/sh
echo "PID=$$ LISTEN_PID=$LISTEN_PID LISTEN_FDS=$LISTEN_FDS LISTEN_FDNAMES=$LISTEN_FDNAMES"
echo "--- my fds ---"
ls -l /proc/$$/fd
# Confirm fd 3 is a socket bound to our port:
ss -lntp "sport = :9999" || true
sleep 60
EOF
chmod +x /usr/local/bin/lab-echo.sh
systemctl daemon-reload
```

**Steps.**
1. Start *only the socket*. The service is not running, yet the port is already listening, owned by PID 1:
   ```bash
   systemctl start lab-echo.socket
   systemctl status lab-echo.socket --no-pager
   ss -lntp 'sport = :9999'        # LISTEN, users:(("systemd",pid=1,...))  ← PID 1 holds it
   systemctl is-active lab-echo.service   # inactive: the daemon does NOT exist yet
   ```
2. Fire a connection. This is the trigger. The kernel queues it; systemd wakes and forks the service, passing the fd:
   ```bash
   ( exec 3<>/dev/tcp/127.0.0.1/9999; echo hi >&3 ) 2>/dev/null &
   sleep 1
   systemctl is-active lab-echo.service   # now active — activation happened on demand
   ```
3. Read what the service inherited:
   ```bash
   journalctl -u lab-echo.service -o cat --no-pager | head -20
   ```
   You should see `LISTEN_FDS=1`, `LISTEN_PID=<the service's PID>`, and in the fd listing **fd 3 is a socket** (`3 -> socket:[…]`), while fd 0/1/2 are journald streams. The `ss` line inside confirms fd 3 is bound to `:9999`.

**Prove it.**
```bash
# fd 3 of the running service is the listening socket, and the count matches LISTEN_FDS:
svc_pid=$(systemctl show -p MainPID --value lab-echo.service)
ls -l /proc/$svc_pid/fd/3          # -> socket:[inode]
grep -a . /proc/$svc_pid/environ | tr '\0' '\n' | grep -E '^LISTEN_(FDS|PID)='
```
Seeing `LISTEN_FDS=1`, `LISTEN_PID=$svc_pid`, and `/proc/$svc_pid/fd/3 -> socket:[…]` proves the activation ABI end to end: systemd created and held the socket, passed it as fd 3, and told the child via env vars.

Bonus (understand `Accept=yes`): change the socket to `Accept=yes`, `daemon-reload`, and connect twice; observe templated per-connection instances `lab-echo@<n>.service` in `systemctl list-units 'lab-echo@*'` and that fd 3 is now the *connected* socket, not the listener.

Cleanup: `systemctl stop lab-echo.socket lab-echo.service; rm -f /etc/systemd/system/lab-echo.* /usr/local/bin/lab-echo.sh; systemctl daemon-reload`.

### Lab 3 — CPU quota throttling: make "the metric is lying" visible

**Objective.** Reproduce the canonical senior scenario: a CPU-bound workload capped by `CPUQuota=` shows low utilization while suffering latency, and prove it with the cgroup `cpu.stat` throttle counters and PSI, not with `top`.

**Setup.** Need a busy-loop. Use `systemd-run` to launch a transient scope/service so systemd owns the cgroup:
```bash
nproc                              # note core count
# baseline: an unconstrained burner, see it eat a full core
systemd-run --unit=burn-free --scope /bin/sh -c 'while :; do :; done' &
sleep 3
cat /sys/fs/cgroup/system.slice/burn-free.scope/cpu.stat 2>/dev/null \
  || cat /sys/fs/cgroup/burn-free.scope/cpu.stat
systemctl stop burn-free.scope 2>/dev/null; kill %1 2>/dev/null
```

**Steps.**
1. Launch the same burner but hard-capped to 20% of one core, and let it run:
   ```bash
   systemd-run --unit=burn-capped -p CPUQuota=20% \
     /bin/sh -c 'while :; do :; done'
   sleep 5
   ```
2. Look at `top`/utilization: the process is pinned at ~20% of a core, the box looks nearly idle. That is the lie.
   ```bash
   top -b -n1 | grep -E 'Cpu|burn|sh' | head
   systemd-cgtop --iterations=1        # see burn-capped's CPU% capped
   ```
3. Now read the truth from the cgroup. Find the path and dump `cpu.stat`:
   ```bash
   cg=/sys/fs/cgroup/system.slice/burn-capped.service
   cat $cg/cpu.max          # e.g. "20000 100000"  = 20ms quota per 100ms period
   cat $cg/cpu.stat         # nr_throttled and throttled_usec are climbing
   ```
4. Watch the throttle counters increase over time (this is the smoking gun a dashboard hides):
   ```bash
   for i in 1 2 3; do
     awk '/nr_throttled|throttled_usec/{print}' $cg/cpu.stat; echo ---; sleep 2
   done
   ```
5. Read the pressure signal, the modern way to see "this cgroup is being starved of CPU":
   ```bash
   cat $cg/cpu.pressure    # some avg10=... rising = tasks stalled waiting for CPU
   ```

**Prove it.**
```bash
cg=/sys/fs/cgroup/system.slice/burn-capped.service
before=$(awk '/nr_throttled/{print $2}' $cg/cpu.stat); sleep 3
after=$(awk '/nr_throttled/{print $2}' $cg/cpu.stat)
echo "throttle events in 3s: $((after-before))"
```
A count clearly > 0 (typically ~30, i.e. one per 100ms period) while `top` shows the process at ~20% proves the point: **utilization looked fine, but the workload was throttled tens of times a second.** That gap is where the senior diagnosis lives.

Cleanup: `systemctl stop burn-capped.service 2>/dev/null; systemctl reset-failed burn-capped.service 2>/dev/null`.

### Lab 4 — journald: trusted fields, structured queries, and tamper-evident sealing

**Objective.** Emit structured native journal fields, see journald stamp *trusted* metadata you cannot forge, exploit the indexed binary format for a field-value query, and set up Forward Secure Sealing and verify it.

**Setup.**
```bash
# Ensure persistent storage so sealing and per-boot indexing have somewhere to live:
mkdir -p /var/log/journal && systemctl restart systemd-journald
journalctl --disk-usage
```

**Steps.**
1. Emit a native structured entry with a custom field and a *fake* PID field, then read it back verbosely:
   ```bash
   systemd-cat -t labtest --priority=info <<'EOF'
Structured line one
EOF
   # native fields via the socket-level tool:
   logger --journald <<'EOF'
MESSAGE=native structured entry
PRIORITY=5
WIDGET_ID=42
_PID=999999
EOF
   journalctl -t labtest -o verbose --no-pager | tail -30
   journalctl WIDGET_ID=42 -o verbose --no-pager | tail -40
   ```
2. Note the trust boundary: your injected `_PID=999999` is **ignored/overridden**; the real `_PID`, `_UID`, `_SELINUX_CONTEXT`, `_COMM`, `_CMDLINE` shown are the ones journald stamped from the socket credentials and `/proc`. Application fields (`WIDGET_ID`, `MESSAGE`, `PRIORITY`) are honored. Confirm:
   ```bash
   journalctl WIDGET_ID=42 -o export --no-pager | grep -E '^_?PID='
   ```
3. Exploit the index: a field-value query is a hash lookup + entry-array walk, not a scan. Compare a unit filter to a full dump:
   ```bash
   journalctl _SYSTEMD_UNIT=systemd-journald.service --no-pager | wc -l
   journalctl -o json _SYSTEMD_UNIT=systemd-journald.service | head -1 | tr ',' '\n' | head
   ```
4. Inspect boots via the `_BOOT_ID` index, and disk/rotation state:
   ```bash
   journalctl --list-boots --no-pager
   journalctl --header --no-pager | grep -E 'File Path|State|Sequential' | head
   ```
   `State: ONLINE` = currently-written file; rotated files show `ARCHIVED`.
5. Set up Forward Secure Sealing. Generate the sealing key pair (prints a secret verification key / QR you'd store offline):
   ```bash
   journalctl --setup-keys --force
   # Turn on sealing and restart:
   mkdir -p /etc/systemd/journald.conf.d
   printf '[Journal]\nSeal=yes\nStorage=persistent\n' \
     > /etc/systemd/journald.conf.d/seal.conf
   systemctl restart systemd-journald
   logger "sealed entry $(date)"
   sleep 2
   ```
6. Verify the seal chain:
   ```bash
   journalctl --verify
   ```

**Prove it.**
```bash
# The trusted _PID differs from the forged one, proving journald stamps identity:
journalctl WIDGET_ID=42 -o export --no-pager | grep -E '^_?PID=' | sort -u
# FSS verification passes (PASS / no tampering) across the sealed files:
journalctl --verify 2>&1 | tail -3
```
Seeing a real `_PID=` that is *not* 999999 proves the trusted-vs-untrusted field boundary; a clean `--verify` proves the FSS tag chain is intact and would flag any post-hoc alteration.

Cleanup: `rm -f /etc/systemd/journald.conf.d/seal.conf; systemctl restart systemd-journald`.

### (Optional) Lab 5 — Sandboxing a service and scoring it, no SELinux required

**Objective.** Harden a unit purely with systemd's namespace/seccomp directives and quantify it with `systemd-analyze security`, demonstrating that `SystemCallFilter=` is seccomp-bpf and `ProtectSystem=`/`PrivateTmp=` are mount-namespace tricks.

**Setup & steps.**
```bash
systemd-run --unit=sbx -p Type=exec /usr/bin/sleep 300
systemd-analyze security sbx.service    # high "exposure" score, unhardened

# Harden via drop-in-style properties on a fresh run:
systemctl stop sbx.service; systemctl reset-failed sbx.service 2>/dev/null
systemd-run --unit=sbx -p Type=exec \
  -p ProtectSystem=strict -p ProtectHome=yes -p PrivateTmp=yes \
  -p NoNewPrivileges=yes -p PrivateDevices=yes \
  -p 'SystemCallFilter=@system-service' -p 'CapabilityBoundingSet=' \
  /usr/bin/sleep 300
systemd-analyze security sbx.service    # exposure score drops sharply
```
`PrivateTmp=yes` gives the service its **own mount-namespace** `/tmp` (prove it: `ls /tmp` on the host vs the service's private one via `nsenter`). `SystemCallFilter=@system-service` installs a **seccomp-bpf** allowlist filter (a program in the classic BPF VM) that the kernel evaluates on every syscall entry; a blocked syscall gets `SIGSYS`/`EPERM`.

**Prove it.**
```bash
systemd-analyze security sbx.service | tail -3   # overall exposure/score improved
pid=$(systemctl show -p MainPID --value sbx.service)
grep Seccomp /proc/$pid/status                   # Seccomp: 2  (filter mode active)
readlink /proc/$pid/ns/mnt                        # differs from PID 1's mnt namespace
```
`Seccomp: 2` proves a seccomp-bpf filter is loaded; a distinct mount namespace inode proves the `Protect*`/`Private*` isolation is namespace-based. Cleanup: `systemctl stop sbx.service; systemctl reset-failed sbx.service`.

---

## Curated resources

**Primary docs / specifications (the definitive statements of behavior)**

- **`systemd.unit(5)`, `systemd.service(5)`, `systemd.socket(5)`, `systemd.exec(5)`, `systemd.resource-control(5)`** — https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html — The core reference set. `systemd.unit` is the dependency/ordering algebra and the load-path/drop-in precedence rules; `systemd.service` is the `Type=` readiness matrix and `Restart=`/start-limit; `systemd.exec` is the sandboxing knobs (namespaces, seccomp); `systemd.resource-control` maps every directive onto a cgroup v2 file. Read these as essays, not lookups.
- **`sd_notify(3)` and `sd_listen_fds(3)`** — https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html and https://www.man7.org/linux/man-pages/man3/sd_listen_fds.3.html — The two ABIs that define modern supervision and socket activation. `sd_notify` is the readiness/watchdog/fdstore protocol; `sd_listen_fds` is the fd-3/`LISTEN_FDS`/`LISTEN_PID` contract. These are the wire formats behind `Type=notify` and `.socket` units.
- **systemd.io — CGROUP_DELEGATION** — https://systemd.io/CGROUP_DELEGATION/ — The authoritative mechanism doc for the service/scope/slice split, the single-writer rule, the "no processes in inner nodes" consequence, and the `cgroup.subtree_control`-you-must-enable-it-yourself gotcha. Essential for anyone reasoning about containers on systemd.
- **systemd.io — CONTROL_GROUP_INTERFACE and FILE_DESCRIPTOR_STORE** — https://systemd.io/CONTROL_GROUP_INTERFACE/ and https://systemd.io/FILE_DESCRIPTOR_STORE/ — How systemd drives cgroup v2, and the fd-store mechanism behind crash-resilient stateful daemons.
- **Journal File Format (upstream doc)** — https://github.com/systemd/systemd/blob/main/docs/JOURNAL_FILE_FORMAT.md — The on-disk spec: `LPKSHHRH` header, DATA/FIELD/ENTRY/ENTRY_ARRAY/HASH_TABLE/TAG objects, siphash24 keyed hashing, entry-array bisection, compression flags, and the FSS TAG/HMAC chain. This is why journals are small (dedup) and queries are fast (indexed).
- **Control Group v2 — kernel admin-guide** — https://docs.kernel.org/admin-guide/cgroup-v2.html — The kernel side of everything systemd's resource control drives: `cpu.max` vs `cpu.weight`, `memory.high` (throttle-via-reclaim) vs `memory.max` (OOM boundary), `io.max`/`io.weight`, `pids.max`, and PSI (`*.pressure`). The `nr_throttled`/`throttled_usec` in `cpu.stat` (Lab 3) are specified here.

**Author's design rationale (the "why it works this way")**

- **Lennart Poettering — "systemd for Administrators" series (I–XXI)** — http://0pointer.de/blog/projects/systemd-for-admins-3.html — The designer explaining the decisions: socket/bus activation removing ordering, cgroup-based tracking vs SysV double-fork, the unit dependency graph, drop-ins. The single best source for the parallelization-and-supervision argument. Read the whole series (each part links the rest).
- **"Rethinking PID 1"** — http://0pointer.de/blog/projects/systemd.html — The original manifesto. Why launchd-style socket activation and cgroups justify a new PID 1. Dated in specifics but the argument is the canonical "why systemd won."

**Reference material and staying current**

- **`systemd-analyze(1)`** — https://www.man7.org/linux/man-pages/man1/systemd-analyze.1.html — `blame`, `critical-chain` (and why both mislead under parallelism/socket-activation), `verify` (offline cycle/typo detection), `security` (per-unit exposure scoring against the sandboxing directives), `calendar`/`timestamp` (validate `OnCalendar=`), `dump`, `dot` (graphviz of the dependency graph). Your primary boot-and-unit debugging surface.
- **`journald.conf(5)` / `journalctl(1)`** — https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html — Storage/rotation/retention (`SystemMaxUse=`, `MaxRetentionSec=`), rate limiting (`RateLimitBurst=`), sealing (`Seal=`), forwarding. The query flags (`-u`, `-b`, `_BOOT_ID`, `-o verbose/json`, `--verify`, `--vacuum-*`) are the forensics toolkit.
- **Fedora Magazine — "systemd unit dependencies and order"** — https://fedoramagazine.org/systemd-unit-dependencies-and-order/ — The clearest short treatment of the requirement-vs-ordering orthogonality with worked examples. Good calibration before the man page.
- **Arch Wiki — systemd and cgroups pages** — https://wiki.archlinux.org/title/Systemd and https://wiki.archlinux.org/title/Cgroups — The best-maintained practical reference: drop-in mechanics, user vs system managers, lingering, transient units, cgroup v2 verification. Distro-agnostic enough to trust.
- **How Linux Works, 3rd ed — Brian Ward (Ch. on systemd and boot)** — https://nostarch.com/howlinuxworks3 — Situates systemd in the full boot chain (firmware → GRUB → initramfs → PID 1 → targets), connecting this module to the boot module. Good structural glue.
- **LWN.net kernel index** — https://lwn.net/Kernel/Index/ — For cgroup v2, PSI, and systemd-oomd coverage as it evolved. How you keep this knowledge from going stale (the EEVDF scheduler change under `CPUWeight`, MGLRU under memory reclaim).
- **rockyman.org** — https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here. This is where you confirm, for example, that `systemctl edit --stdin` does not exist on Rocky 9's systemd 252 before you put it in a runbook.

---

## Senior signal

- **Treats requirement and ordering as independent axes and never conflates them.** A mid-level writes `Requires=db.service` and assumes their service waits for it; a senior knows that without `After=db.service` both start in parallel, and reaches for `Wants=`+`After=` (soft) or `BindsTo=`+`After=` (hard, runtime-coupled) deliberately per the failure semantics they actually want.
- **Reads `cpu.stat` throttle counters and PSI instead of trusting utilization.** They know a `CPUQuota=`'d service can be crippled by CFS/EEVDF throttling while `top` shows the box idle, and they prove it with `nr_throttled`/`throttled_usec` and `cpu.pressure`. Same instinct for `memory.high` (reclaim stall) vs `memory.max` (cgroup OOM) vs the global OOM killer.
- **Never edits package-owned unit files; overrides with drop-ins.** They use `systemctl edit`/`.d/*.conf` fragments, know the list-append-vs-scalar-replace rule (empty assignment to clear), and use `systemctl cat`/`systemd-delta` to audit the merged result. This is the systemd-specific expression of the "don't modify RPM-owned files" rule.
- **Chooses `Type=` from the readiness contract, not by habit.** They reach for `Type=notify` + `sd_notify(READY=1)` (or a `.socket` unit) to eliminate premature-ready races, and they know `Type=simple` marks a service "up" the instant `execve` returns, before it can possibly be listening.
- **Can explain a container in systemd terms and reason about delegation.** Scope vs service, `Delegate=yes` on scopes/services only (never slices), the v2 "no processes in inner nodes" rule forcing self-migration to a leaf, and having to enable controllers yourself via `cgroup.subtree_control`. They know the single-writer rule is why you don't hand-create cgroups under a systemd-managed root.
- **Understands socket activation as the parallelization mechanism, not just a feature.** They can state that the kernel accept queue is the synchronization primitive that made boot parallel, that the fd arrives as fd 3 with `LISTEN_FDS`/`LISTEN_PID`, and that holding the socket in PID 1 is what enables zero-downtime restarts and the fd store enables crash-resilient stateful daemons.
- **Does journald forensics with the trust boundary in mind.** They know `_`-prefixed fields (`_PID`, `_UID`, `_SELINUX_CONTEXT`) are stamped by PID 1 from socket credentials and can't be forged, that field-value queries are indexed (siphash + entry arrays, not a grep), that FSS makes the log tamper-*evident* not tamper-proof, and they check `journalctl --verify` and rate-limit/vacuum behavior under a log storm.
- **Debugs the transaction, not the symptom.** Ordering cycles caught with `systemd-analyze verify` before shipping; stuck boots read via `systemctl list-jobs` and `journalctl _PID=1`; crash-loops diagnosed as start-limit lockout (`reset-failed`) rather than "the service is broken"; and they know `critical-chain`/`blame` mislead under parallelism and socket activation.

---

## See also

- [[03 - Processes, Scheduling and Signals]] — systemd is PID 1: the process/signal mechanics here (fork/exec, `SIGCHLD` reaping of reparented orphans, the CFS/EEVDF scheduler that `CPUWeight=`/`CPUQuota=` steer) are exactly what the unit model and cgroup resource control sit on top of.
- [[08 - Boot and Init]] — where PID 1 comes from: the firmware → GRUB → initramfs → PID 1 → default target chain, generators running before unit load, and `sysinit.target`/`basic.target` ordering are the boot-side context for this module's transaction engine.
- [[10 - Namespaces and cgroups v2]] — the kernel primitives underneath systemd: the cgroup v2 unified hierarchy, controllers, and PSI that resource control writes to, plus the mount/PID/network namespaces and seccomp that `ProtectSystem=`/`PrivateTmp=`/`SystemCallFilter=` (Lab 5) are built from.
- [[03 - Containers from the Ground Up]] — container runtimes register their payloads as systemd scopes with `Delegate=yes`; the single-writer rule and the "no processes in inner nodes" constraint here directly shape how a runtime lays out its cgroup subtree.
- [[04 - Kubernetes Control-Plane Internals]] — the kubelet's systemd cgroup driver and the unit-based node components (kubelet, containerd) build on this unit/cgroup model; `CPUQuota` throttling is the pod-limit throttling that pages SREs.
- [[09 - Observability and SRE]] — journald's structured/indexed logs, `Restart=` policies, the start-limit rate limiter, and `WatchdogSec=` are the supervision and telemetry substrate SRE builds alerting and self-healing on.
- [[02 - Warewulf Stateless Provisioning]] — stateless HPC nodes boot straight into this target/unit/socket-activation model; understanding generators and `sysinit.target` is what lets you debug a node that provisions but won't reach `multi-user.target`.
