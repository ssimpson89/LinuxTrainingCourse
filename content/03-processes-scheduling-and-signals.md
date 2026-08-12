---
title: Processes, Scheduling and Signals
type: module
track: linux-internals
tags: [linux-internals, processes, scheduler, eevdf, cfs, signals, cgroups, oom, proc, task_struct]
requires: ["Rocky 9.x VM with root", "kernel>=5.14 (task __state field, cgroup v2 default)", "kernel>=6.6 for EEVDF slice lab", "cgroup v2 (cgroup2fs) mounted"]
module_number: 3
status: reviewed
created: 2026-07-08
---

# 03 - Processes, Scheduling and Signals

Backlink: [[00 - Track Overview]]

> Scope: process lifecycle and states, `fork`/`exec`/`wait`, the `task_struct`, the CFS→EEVDF scheduler, nice/priority/RT classes, cgroup-aware scheduling and bandwidth throttling, signals (delivery, masks, realtime), `/proc/<pid>` internals, zombies/orphans, and the OOM killer. This is the module where "the box is busy" stops being a dashboard reading and becomes a claim you can prove or falsify with `perf sched`, `cpu.stat`, `/proc/<pid>/schedstat`, and bpftrace.

---

## Concept deep-dive

### 1. What a process *is*: `task_struct` and the thread model

There is no "process object" in the Linux kernel. There is only the **`struct task_struct`** (defined in `include/linux/sched.h`), and it represents a *schedulable entity* — what userspace calls a thread. A "process" is an emergent concept: a set of `task_struct`s that share a thread group ID (`tgid`).

Key identity fields:

```
task_struct
├── pid          // kernel-internal unique ID of THIS task (thread)
├── tgid         // thread group id == the userspace getpid() value
├── group_leader // pointer to the tgid's leader task
├── real_parent  // who forked me
├── parent       // who gets SIGCHLD / wait() (usually == real_parent, differs under ptrace)
├── children / sibling  // list heads for the process tree
├── thread_group // list of tasks sharing this tgid
├── __state      // TASK_RUNNING, TASK_INTERRUPTIBLE, ... (was `state` pre-5.14)
├── exit_state   // EXIT_ZOMBIE, EXIT_DEAD
├── flags        // PF_* : PF_KTHREAD, PF_EXITING, PF_WQ_WORKER, ...
├── mm           // struct mm_struct * : the address space (NULL for kernel threads)
├── active_mm    // borrowed mm for kernel threads / lazy TLB
├── files        // struct files_struct * : the fd table
├── fs           // struct fs_struct * : cwd, root, umask
├── sighand      // struct sighand_struct * : signal disposition table (shared in a thread group)
├── signal       // struct signal_struct * : per-thread-group signal state, rlimits, tty
├── nsproxy      // pointers to the 6 non-user namespaces (see Module on namespaces)
├── cred         // struct cred * : uids/gids/capabilities (RCU-protected)
├── se           // struct sched_entity : the CFS/EEVDF bookkeeping (vruntime, deadline, lag)
├── rt / dl      // sched_rt_entity / sched_dl_entity for RT and DEADLINE classes
├── sched_class  // vtable: fair_sched_class / rt_sched_class / dl_sched_class / ...
├── prio / static_prio / normal_prio / rt_priority
└── stack        // pointer to the kernel stack (holds thread_info on most arches)
```

The crucial insight for a staff-level mental model: **`getpid()` returns `tgid`, not `pid`.** The `gettid()` syscall returns the real per-task `pid`. When you see 400 "processes" in `top` that are really one JVM, you are seeing 400 `task_struct`s sharing one `tgid`, one `mm_struct`, one `files_struct`, one `sighand_struct`. `ps -eLf` or `ls /proc/<tgid>/task/` shows the truth.

Thread vs process is purely *which pointers are shared*, decided by the `CLONE_*` flags at creation time (see §3). A "thread" shares `mm`, `files`, `fs`, `sighand`, `signal`; a "process" gets private copies. There is one code path — `clone()` — and everything else is a preset of flags.

### 2. Process states — and why the state field lies to you

The runtime state lives in `task_struct.__state` (renamed from `state` in 5.14; still `state` in RHEL 8's 4.18). The `/proc/<pid>/stat` character (field 3) is produced by `fs/proc/array.c:get_task_state()`.

```
State char   Kernel constant            Meaning
  R          TASK_RUNNING               On a runqueue: running OR runnable (NOT the same thing!)
  S          TASK_INTERRUPTIBLE         Sleeping, will wake on signal or event
  D          TASK_UNINTERRUPTIBLE       Sleeping, will NOT wake on signal (in-kernel wait)
  T          TASK_STOPPED               Stopped by SIGSTOP/SIGTSTP or ptrace stop (t = tracing stop)
  t          (ptrace stop)              Traced/stopped under a debugger
  Z          EXIT_ZOMBIE                Dead, awaiting parent's wait()
  X          EXIT_DEAD                  Being torn down (rarely observable)
  I          TASK_IDLE                  Idle kernel thread — UNinterruptible but does NOT count to loadavg
```

Two traps that separate senior from mid-level:

**(a) `R` does not mean "running."** It means "on a CPU runqueue." A machine with load average 40 and one core has 39 tasks in `R` state *waiting for a CPU*, plus one actually executing. Runnable-but-not-running is invisible in the state char; you need scheduler latency instrumentation (`/proc/<pid>/schedstat` field 2, `perf sched latency`, or `runqlat` from bcc) to see it. "50% CPU" can coexist with brutal runqueue latency if you're pinned or throttled.

**(b) `D` state is the load-average liar.** Linux load average is `nr_running + nr_uninterruptible` (unlike classic Unix, which counts only runnable). So a load average of 30 on an idle-CPU box is almost always a pile of tasks in `D` blocked on I/O (or a dead NFS mount, or a stuck `dm` path). `TASK_UNINTERRUPTIBLE` tasks do not respond to signals — you cannot `kill -9` them — because they are mid-way through a kernel operation holding references that must complete. `TASK_KILLABLE` (a variant introduced to fix exactly the dead-NFS-hang problem) is `D`-like but wakes for a *fatal* signal only. `TASK_IDLE` (`I`) was added so idle kernel worker threads sleeping in `TASK_UNINTERRUPTIBLE` stop inflating load average — a decade of "why is my idle NAS at load 5?" confusion.

The canonical diagnostic: when load is high but `%us`+`%sy` is low, enumerate the `D`-state tasks and read their kernel stacks:

```
ps -eo pid,stat,wchan:32,comm | awk '$2 ~ /D/'
cat /proc/<pid>/stack        # requires CONFIG_STACKTRACE + root; shows where it's blocked
```

### 3. Creation: `fork`, `vfork`, `clone`, `clone3`, and copy-on-write

All process/thread creation funnels through **`kernel_clone()`** in `kernel/fork.c` (called `_do_fork()` before 5.10, `do_fork()` before that). The userspace entry points are thin wrappers:

```
fork()   ── clone(SIGCHLD, ...)                       // full COW copy, own address space
vfork()  ── clone(CLONE_VM|CLONE_VFORK|SIGCHLD, ...)  // share mm, suspend parent until exec/exit
pthread_create() ── clone(CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_SETTLS|...)
clone3(&args, size)  // modern extensible struct clone_args, adds set_tid, cgroup fd, etc.
```

The important `CLONE_*` flags and what sharing each toggles:

```
CLONE_VM        share mm_struct (address space)          → the thread/process line
CLONE_FS        share fs_struct (cwd, root, umask)
CLONE_FILES     share files_struct (the fd table)
CLONE_SIGHAND   share signal dispositions (implies grouping of handlers)
CLONE_THREAD    same thread group (same tgid); implies CLONE_SIGHAND
CLONE_PARENT    new task's parent is caller's parent (sibling, not child)
CLONE_NEWNS/NET/PID/UTS/IPC/CGROUP   new namespace of that type
CLONE_NEWUSER   new user namespace (the keystone for rootless containers)
CLONE_PIDFD     return a pidfd (race-free process handle; see below)
CLONE_VFORK     block parent until child execve()s or _exit()s
CLONE_SETTLS / CLONE_CHILD_SETTID / CLONE_CHILD_CLEARTID  TLS and futex-based join
```

**Copy-on-write is the whole trick.** `fork()` does *not* copy the parent's memory. `copy_mm()` → `dup_mm()` → `dup_mmap()` walks the parent's VMAs (`vm_area_struct`) and, for private writable pages, marks the PTEs **read-only in both parent and child** and bumps each page's refcount. The address spaces are now identical and shared. The first *write* by either side takes a page fault; `do_wp_page()` (`mm/memory.c`) sees a write to a read-only PTE whose page is shared, allocates a fresh page, copies the contents, and repoints that one PTE. This is why `fork()` of a 100 GB process is cheap — until the child touches everything. The residual cost that *is* proportional to size is copying the **page tables** themselves, which is why forking a huge-heap process still stalls and why `posix_spawn()` / `vfork()` exist.

`vfork()` shares the address space outright (`CLONE_VM`, no COW) and *suspends the parent* until the child `execve()`s or exits — so the child must not touch the stack or return. glibc's `posix_spawn()` was rewritten in 2016 to use `clone(CLONE_VM|CLONE_VFORK)` precisely to avoid COW page-table duplication for the fork-then-exec pattern. For a support engineer this explains a classic OOM: a large-RSS process calls plain `fork()`+`exec()` under an overcommit-restrictive policy and the *reservation* (not the actual copy) trips the allocator even though nothing gets copied. `MADV_WIPEONFORK`, `vfork`, or `posix_spawn` are the fixes.

**`pidfd` is the modern, race-free process handle.** PIDs are recycled; by the time you `kill(pid)` the pid may name a different process. `clone3(CLONE_PIDFD)` or `pidfd_open(pid)` gives a file descriptor that refers to a *specific* task; `pidfd_send_signal()` and `waitid(P_PIDFD, ...)` operate on it without the recycle race. `poll()` on a pidfd returns readable when the process dies. systemd and container runtimes use this everywhere now.

### 4. Termination, zombies, orphans, and reaping

`exit()` → `do_exit()` (`kernel/exit.c`): the task releases its `mm`, `files`, `fs`, closes fds, and transitions to `EXIT_ZOMBIE`. It is **not** fully freed — the `task_struct` and the exit status linger so the parent can retrieve it. A zombie holds essentially no resources except the PID slot and a small kernel struct. A screenful of zombies is not a memory problem; it's a *parent-not-reaping* problem (the parent isn't calling `wait()`), and the risk is **PID exhaustion**, not RAM.

The reaping contract:
- Child dies → kernel sends `SIGCHLD` to the parent and parks the child in `EXIT_ZOMBIE`.
- Parent calls `wait4()`/`waitid()` → kernel copies out `rusage` + exit status, frees the `task_struct`, releases the PID.
- If the parent explicitly sets `SIG_IGN` on `SIGCHLD` (or `SA_NOCLDWAIT`), the kernel auto-reaps and no zombie is ever created.

**Orphans** (parent dies first) are **re-parented**. Historically to PID 1. Modern nuance: a process can call `prctl(PR_SET_CHILD_SUBREAPER, 1)` to become the reaper for its descendants' orphans (systemd user managers and container init shims do this). In a PID namespace, the namespace's PID 1 is the reaper, and if *that* init dies the whole namespace is torn down (`SIGKILL` to all members). This is why a container's PID 1 must actually reap — a naive app-as-PID-1 that ignores `SIGCHLD` accumulates zombies inside the container forever. This is the reason `docker run --init` / tini exists.

```
        fork()                 exit()                    wait()
parent ────────► child ──────────────► ZOMBIE ───────────────────► freed
                          (SIGCHLD to parent)     (task_struct + PID reclaimed)

parent dies before child:
  child.real_parent ← nearest subreaper, else PID 1 of the pid namespace
```

### 5. The scheduler: from CFS to EEVDF

Every runnable task belongs to exactly one **scheduling class**, checked in strict priority order (`kernel/sched/`):

```
stop_sched_class     (highest — CPU stopper, migration, never for userspace)
dl_sched_class       SCHED_DEADLINE  (EDF/CBS, hard real-time-ish, bandwidth-reserved)
rt_sched_class       SCHED_FIFO / SCHED_RR  (POSIX real-time, priorities 1–99)
fair_sched_class     SCHED_OTHER / SCHED_BATCH / SCHED_IDLE  (CFS, now EEVDF)
idle_sched_class     (the swapper/idle task)
```

The scheduler core (`__schedule()` in `kernel/sched/core.c`) asks each class in order for a runnable task via `pick_next_task()`. An RT task always beats any fair task; a DEADLINE task beats RT. This is why a runaway `SCHED_FIFO` thread at priority 99 can wedge a core completely and starve everything below it (including kworkers) — the reason `sched_rt_runtime_us` exists as a safety valve (default: RT is capped at 950000/1000000 µs, i.e. 95% of each second, leaving 5% for the fair class to keep the box controllable).

**CFS (2007–2023, the default through 6.5; still what RHEL 8/9 ship).** CFS tracks per-task **`vruntime`** — virtual runtime that advances as the task runs, scaled *inversely* by weight (derived from nice). Low-nice (high-priority) tasks accumulate vruntime slower, so they're picked more often. The runqueue is a **red-black tree keyed by vruntime**; `pick_next_task_fair()` picks the leftmost node (smallest vruntime). Fairness = keep all vruntimes close. Nice values map to weights via the `sched_prio_to_weight[]` table (`kernel/sched/core.c`); each nice level is ~1.25× CPU share (nice 0 = weight 1024).

CFS's weakness: it optimizes *throughput fairness* but has no first-class notion of **latency**. A latency-sensitive task (audio, a request handler) that wakes briefly and often is treated the same as a CPU hog. The `sched_min_granularity`/`wakeup_granularity` knobs were blunt instruments.

**EEVDF (Earliest Eligible Virtual Deadline First) — default since 6.6 (torvalds/linux `Documentation/scheduler/sched-eevdf.rst`).** EEVDF keeps the vruntime/weight machinery, load balancing, and group scheduling largely intact, but changes *task selection*:

- **lag** = (fair share the task was owed) − (vruntime it actually got). Positive lag ⇒ under-served; negative ⇒ over-served.
- **eligibility**: a task is *eligible* only when its lag ≥ 0 (its virtual runtime has reached the runqueue's virtual "current time"). This stops a task that already got more than its share from cutting the line.
- **virtual deadline (VD)** = eligible-time + (requested slice scaled to virtual time). Among *eligible* tasks, EEVDF picks the **earliest virtual deadline**.
- **request/slice**: tasks can now ask for a specific time slice via `sched_setattr()` with `sched_runtime` (the `SCHED_FLAG_UTIL_CLAMP`/slice interface). A short requested slice ⇒ nearer deadline ⇒ scheduled sooner but for less time = the explicit latency knob CFS lacked.
- On sleep, a task isn't simply dropped; **deferred dequeue** keeps it queued so its (possibly negative) lag decays fairly over virtual time — this closes the CFS exploit where a task slept to reset its position and get an unfair burst on wake.

The staff-level takeaway: with EEVDF you can *reason about latency* ("this task keeps missing its deadline because higher-weight eligible tasks preempt it") rather than just twiddling nice. Know which scheduler your kernel runs: `SCHED_OTHER` behavior differs materially between a RHEL 9 (CFS) box and a 6.6+ (EEVDF) box, and benchmark results from one don't transfer.

**Priority arithmetic.** Userspace nice is −20..+19. Internally the kernel maps: RT priorities 0..99 → kernel `prio` 0..99; nice −20..+19 → `prio` 100..139. `chrt` shows/sets RT class and priority; `nice`/`renice` set the fair-class weight. `SCHED_BATCH` disables wakeup preemption (good for throughput batch jobs); `SCHED_IDLE` is weakest-possible fair scheduling (runs only when nothing else wants the CPU).

```
  policy            prio range     knob            preemption
  SCHED_DEADLINE    (below 0)      runtime/dl/period  EDF, bandwidth-enforced
  SCHED_FIFO        1..99          rt_priority      runs until it blocks/yields
  SCHED_RR          1..99          rt_priority      FIFO + round-robin timeslice among equals
  SCHED_OTHER       nice -20..19   nice/weight      EEVDF (was CFS)
  SCHED_BATCH       nice           nice/weight      like OTHER, no wakeup preempt
  SCHED_IDLE        (below nice)   —                only when idle
```

### 6. cgroup-aware scheduling: the throttling that hides in plain sight

This is the single highest-value diagnostic in the module because it is *invisible to CPU utilization*.

Group scheduling nests `sched_entity`s: a cgroup is itself a scheduling entity with a weight, and its tasks compete *within* the group's share. In cgroup v2 the knobs are `cpu.weight` (proportional share, 1–10000, default 100) and **`cpu.max`** (`"quota period"`, absolute bandwidth cap). In v1 they were split across `cpu.cfs_quota_us` / `cpu.cfs_period_us`.

**CFS bandwidth control** (`kernel/sched/core.c` + `fair.c`, `Documentation/scheduler/sched-bwc.rst`): within each `period` (default 100 ms) the group may consume up to `quota` µs of CPU across all CPUs. Quota is handed to per-CPU runqueues in slices; when a runqueue exhausts its slice and the global pool is empty, **every task in that group on that CPU is throttled** — dequeued and made unrunnable — until the next period refills the quota.

The failure mode that fools everyone: a container limited to `cpu.max = "100000 100000"` (1 CPU) running an 8-thread app. In the first ~12.5 ms of each 100 ms period the 8 threads burn the entire 100 ms quota in parallel, then get **throttled for the remaining ~87 ms**. Average utilization reads ~1.0 CPU = "looks healthy," but p99 latency is catastrophic because requests that land in the throttled window wait up to 87 ms for the CPU. `top` shows 100% of the limit used and lies about the pain.

**Prove it — read the throttle counters, not the utilization:**

```
cat /sys/fs/cgroup/<path>/cpu.stat
# nr_periods      — periods elapsed
# nr_throttled    — periods in which the group WAS throttled
# throttled_usec  — total wall time tasks spent throttled  (v2; throttled_time ns in v1)
```

`nr_throttled / nr_periods` climbing toward 1.0 with `throttled_usec` growing is the smoking gun. This is *the* canonical Kubernetes "my pod is slow but CPU isn't maxed" bug (see Indeed's "Unthrottled" and Dan Luu's container-throttling writeups). The classic mitigations: raise the limit, lower thread/pool concurrency to match the quota, or (kernel 5.14+) rely on the "burst" feature (`cpu.max.burst`) that lets a group bank unused quota to absorb spikes.

Other CPU-adjacent isolation to know: `isolcpus=` (boot param, removes CPUs from the general scheduler's balancing), `cpuset.cpus`/`cpuset.mems` (pin a cgroup to CPUs/NUMA nodes), `nohz_full=` + `rcu_nocbs=` (tickless isolated cores for latency-critical work), and IRQ affinity (`/proc/irq/*/smp_affinity`). NUMA balancing (`/proc/sys/kernel/numa_balancing`) silently migrates pages and can *cause* latency it was meant to fix.

### 7. Signals: delivery, masks, queuing, realtime

A signal is a per-task (or per-thread-group) software interrupt. The kernel tracks pending signals as a bitmap plus, for realtime signals, a queue.

**Data structures** (`include/linux/sched/signal.h`):
- `struct sighand_struct` — the array of `k_sigaction` (dispositions: handler, `SA_*` flags, mask). Shared across a thread group (`CLONE_SIGHAND`).
- `struct signal_struct` — thread-group-wide: `shared_pending` (signals sent to the *process*), the group exit state, rlimits, controlling tty.
- Per task: `task_struct.pending` (`struct sigpending`: a `sigset_t` bitmap + a queue of `sigqueue` entries), and `blocked` (the signal mask).

**Standard signals (1–31) vs realtime signals (`SIGRTMIN`..`SIGRTMAX`, 32/34–64):**

| | Standard | Realtime |
|---|---|---|
| Pending representation | single bit | queued entries |
| Coalescing | multiple sends while blocked collapse to **one** | each send **queued** separately |
| Ordering | unspecified among different signals | delivered **lowest-numbered first**; same-signal **FIFO** |
| Payload | none | `sigqueue()` carries a `sigval` (int/ptr) via `siginfo_t` |

If a standard signal arrives while it's blocked and one is already pending, the second is *dropped* — this is why "I sent SIGUSR1 twice but my handler ran once" is expected, not a bug. Realtime signals queue (bounded by `RLIMIT_SIGPENDING`), so no loss, and carry data. When both standard and RT signals are pending, **Linux delivers standard signals first** (POSIX leaves this unspecified).

**Delivery mechanics.** Signals aren't delivered instantly. They're marked pending; actual delivery happens at the **next return to userspace** from a syscall or interrupt (`do_signal()` / `handle_signal()` on the exit-to-user path). The kernel sets `TIF_SIGPENDING`. This is why a task spinning in a tight kernel loop, or stuck in `TASK_UNINTERRUPTIBLE`, doesn't run its handler until it returns to (or wakes into) userspace — the root of "why won't this `D`-state process die?"

**The mask and safe patterns.** `blocked` is the mask; `sigprocmask()` (or `pthread_sigmask()` for a thread) edits it. Blocked-and-pending signals sit in `pending` until unblocked. The correct modern pattern for signal-driven servers is **`signalfd()`** (read signals as file descriptors, integrates with epoll) or a self-pipe, not doing real work in the async handler — because inside a handler you may only call **async-signal-safe** functions (`signal-safety(7)`; `printf`/`malloc` are *not* safe, and the classic deadlock is a signal firing while the handler's `malloc` re-enters the allocator that already holds its lock). `SA_RESTART` controls whether an interrupted slow syscall auto-restarts or returns `EINTR` — get this wrong and you get spurious `EINTR` failures under load.

`SIGKILL` (9) and `SIGSTOP` (19) **cannot be caught, blocked, or ignored** — they're actioned by the kernel itself, not the target, which is why they still work on a wedged process *as long as it reaches a signal-check point*. A `D`-state (`TASK_UNINTERRUPTIBLE`) task ignores even SIGKILL until its kernel wait completes; `TASK_KILLABLE` waits were introduced to let fatal signals through for exactly the dead-mount case.

```
signal path:
  sender: kill()/tgkill()/sigqueue()/pidfd_send_signal()
     │
     ▼  set bit in target->pending (or queue sigqueue entry); set TIF_SIGPENDING
   [target keeps running / sleeping]
     │
     ▼  next return-to-user OR wake from interruptible sleep
  do_signal() → dequeue highest-priority deliverable, unblocked signal
     │
     ├─ default action (term/core/stop/ignore per signal)
     └─ handler: set up signal frame on user stack, switch to handler,
                 sigreturn() restores the interrupted context
```

### 8. `/proc/<pid>` as the forensic surface

`/proc` is a synthetic filesystem (`fs/proc/`) that materializes `task_struct` fields on read. For an L3/L4 engineer it is the primary live-forensics tool — no debugger, no restart. The high-value entries:

```
/proc/<pid>/stat      54 fields, one line: state, ppid, pgrp, utime, stime, priority,
                      nice, num_threads, starttime, vsize, rss, processor, rt_priority,
                      policy, delayacct_blkio_ticks, ...  (parse with proc_pid_stat(5))
/proc/<pid>/status    human-readable: State, Tgid, Pid, PPid, Uid/Gid (r/e/s/fs),
                      FDSize, VmPeak/VmRSS/VmSwap, Threads, SigQ, SigPnd/ShdPnd (pending),
                      SigBlk/SigIgn/SigCgt (masks as hex bitmaps), CapEff/CapBnd, Seccomp
/proc/<pid>/schedstat 3 numbers: time on CPU (ns), time WAITING on runqueue (ns), timeslices
                      → field 2 is your runqueue-latency ground truth
/proc/<pid>/sched     rich EEVDF/CFS stats: se.vruntime, se.avg, nr_switches,
                      nr_involuntary_switches (preemptions), wait_sum, sum_exec_runtime
/proc/<pid>/wchan     symbol the task is sleeping in (what it's blocked ON)
/proc/<pid>/stack     kernel stack trace (root; the D-state decoder)
/proc/<pid>/syscall   current syscall number + args (what it's doing right now)
/proc/<pid>/fd/       symlinks to every open fd (fd exhaustion, deleted-but-open files)
/proc/<pid>/fdinfo/<n>  per-fd offset, flags, and for epoll/inotify the watched set
/proc/<pid>/maps      VMA map: address ranges, perms, backing file (what's mapped)
/proc/<pid>/smaps     per-VMA RSS/PSS/Swap/dirty — the real memory accounting
/proc/<pid>/oom_score current OOM badness; oom_score_adj is the tunable
/proc/<pid>/limits    the RLIMIT_* soft/hard values actually in force
/proc/<pid>/cgroup    which cgroup(s) this task is in → jump to /sys/fs/cgroup/<path>/cpu.stat
/proc/<pid>/task/<tid>/  the same tree per-thread — where you catch one hot thread
```

Decoding the signal bitmaps in `status` (`SigBlk`/`SigCgt` are hex; bit N-1 = signal N) tells you whether a hung daemon has even *installed* a handler for `SIGTERM` or is blocking it — a 20-second answer to "why doesn't graceful shutdown work?"

### 9. The OOM killer

When the kernel cannot reclaim enough memory to satisfy an allocation (after `kswapd` and direct reclaim fail against the watermarks — see the memory module), it invokes the **OOM killer** (`mm/oom_kill.c`) to free memory by killing a task rather than failing the allocation. Two distinct triggers:

1. **Global OOM** — physical RAM + swap exhausted system-wide.
2. **cgroup (memcg) OOM** — a cgroup hit its `memory.max` and its own reclaim failed. This is *scoped*: the killer only considers tasks in that cgroup. This is why a container gets OOM-killed while the host has free RAM.

**Victim selection — the "badness" score** (`oom_badness()`): base score ≈ task RSS + swap + page-table size, i.e. roughly *how much memory freeing this task recovers*. It is then adjusted by **`oom_score_adj`** (`/proc/<pid>/oom_score_adj`, range −1000..+1000). The adj is added as a proportion of total memory: `-1000` effectively means "never pick me" (`OOM_SCORE_ADJ_MIN` immunizes a task); `+1000` biases strongly toward selection. The final 0..1000 value is readable at `/proc/<pid>/oom_score`. Biggest memory user usually dies — which is why the OOM killer notoriously kills your database first. Protect critical daemons with `oom_score_adj = -1000` (systemd: `OOMScoreAdjust=`).

**cgroup v2 refinements:** `memory.oom.group=1` makes the *entire cgroup* a kill unit — the killer takes down all tasks in the group together (correct for a pod where killing one thread leaves a broken half-app). `memory.high` is a *soft* throttle-via-reclaim limit (tasks are slowed by aggressive reclaim, not killed) while `memory.max` is the *hard* wall that triggers memcg OOM. Missing this distinction is a common misconfig: people set `high` expecting kills, or `max` expecting graceful slowdown.

**Overcommit** governs whether the allocation even reaches OOM: `vm.overcommit_memory` (0 = heuristic, 1 = always, 2 = strict `CommitLimit`) and `vm.overcommit_ratio`. Strict overcommit (`=2`) makes `malloc`/`fork` fail with `ENOMEM` up front instead of risking an OOM kill later — the trade is that fork-heavy or sparsely-allocating workloads break.

**PSI (Pressure Stall Information)** is the modern early-warning signal (`/proc/pressure/memory`, or per-cgroup `memory.pressure`): the fraction of wall-clock time tasks stalled waiting on memory. `some` = at least one task stalled; `full` = all non-idle tasks stalled. **`systemd-oomd`** watches PSI per-cgroup and kills a *cgroup* under sustained pressure *before* the kernel's hard OOM fires — a graceful-degradation mechanism. `earlyoom` is the userspace alternative. The senior move is to alert on PSI trending up, not to wait for the `Killed process` dmesg line, which is the post-mortem.

**Forensics of a kill:** `dmesg`/journal shows the "invoked oom-killer" banner, the memory state, a per-task table (with each candidate's RSS and `oom_score_adj`), and "`Out of memory: Killed process <pid> (<comm>) total-vm..anon-rss..`". `memory.events` (`oom`, `oom_kill` counters) in the cgroup records kills without needing dmesg.

### Failure modes and scale behavior (cross-subsystem)

- **PID exhaustion**: `pid_max` default 32768 (or 4M with the 64-bit expansion). Fork bombs, zombie floods, and thread-leaking apps hit it; symptom is `fork: Cannot allocate memory` / `Resource temporarily unavailable` with RAM free. Cap with `pids.max` in the cgroup — a fork-bomb blast-radius limiter.
- **Thundering herd on wake**: many tasks blocked on one event all become `R` at once and stampede the runqueue; `perf sched` shows the migration/latency spike.
- **RT starvation / priority inversion**: a high-prio RT task blocks on a lock held by a low-prio task the scheduler won't run. `SCHED_FIFO` without priority inheritance mutexes (`PTHREAD_PRIO_INHERIT`) is the classic latency-spike-then-watchdog-reboot on embedded/telco kernels.
- **Throttling under quota** (§6): the flagship "utilization looks fine, latency is on fire" scale bug.
- **Signal loss / storms**: standard-signal coalescing loses events under load; unbounded `sigqueue` RT signals hit `RLIMIT_SIGPENDING` and `sigqueue()` returns `EAGAIN`.
- **Zombie/orphan mishandling in containers**: app-as-PID-1 not reaping ⇒ zombie accumulation ⇒ PID exhaustion inside the namespace.

---

## Hands-on labs

> Assume a throwaway Linux VM (any distro with a 5.14+ kernel; a 6.6+ kernel is ideal for the EEVDF lab). Commands are distro-agnostic where possible; install notes call out `apt`/`dnf`. Run as a user who can `sudo`. Nothing here should be run on a box you care about.

### Lab 1 — Make process creation visible: COW, states, and reaping

**Objective:** Watch `fork()` do copy-on-write (no copy until write), catch a task in `D` state, and manufacture then reap a zombie — proving the lifecycle end to end.

**Setup:**

```bash
# tools
sudo dnf install -y strace procps-ng python3 || sudo apt install -y strace procps python3
```

**Steps:**

1. Trace what `fork` actually issues. A shell subshell forks:

```bash
strace -f -e trace=clone,clone3,execve,wait4,exit_group -- bash -c 'sleep 1 & wait' 2>&1 | head -40
```

Observe: the `clone(...)` call and its flags, the child's `execve("/usr/bin/sleep", ...)`, and the parent's `wait4()`. Note there is no `fork` syscall — it's `clone`.

2. Prove COW: a Python parent allocates a big buffer, forks, and the child reads (not writes) it. Watch RSS *not* double.

```bash
python3 - <<'PY'
import os, time, resource
buf = bytearray(200*1024*1024)      # 200 MB, touched (resident)
for i in range(0, len(buf), 4096): buf[i] = 1
def rss(pid='self'): 
    return int(open(f'/proc/{pid}/status').read().split('VmRSS:')[1].split()[0])
print("parent RSS KB:", rss())
pid = os.fork()
if pid == 0:
    s = sum(buf[::4096])            # READ only → pages stay shared (COW intact)
    time.sleep(2)
    print("child  RSS KB:", rss(), "(read-only child shares parent pages)")
    os._exit(0)
os.waitpid(pid, 0)
PY
```

The child's `VmRSS` reflects shared pages, not a fresh 200 MB copy. Change `buf[i]` to write in the child and re-run to watch RSS climb as COW faults fire.

3. Manufacture a `D`-state task. The reliable trick (per Chris Down): send a `SIGSTOP` to a task while it's inside an uninterruptible vfork wait — but a simpler observable is a task blocked on slow I/O. Start a process reading from a pipe that never gets data via a blocking mount is fragile; instead, freeze on disk sync of a huge dirty set, or use `vmtouch`. Easiest portable path — catch a kernel worker:

```bash
# Generate I/O and snapshot any D-state task's kernel stack:
( dd if=/dev/zero of=/tmp/ddtest bs=1M count=2000 oflag=direct 2>/dev/null & )
for i in $(seq 1 50); do
  ps -eo pid,stat,wchan:24,comm | awk '$2 ~ /D/ {print}' 
  sleep 0.1
done | sort -u | head
```

For any PID shown in `D`, read where it's blocked:

```bash
sudo cat /proc/<pid>/stack 2>/dev/null; cat /proc/<pid>/wchan; echo
rm -f /tmp/ddtest
```

4. Create a zombie and observe it, then reap it:

```bash
python3 - <<'PY'
import os, time
pid = os.fork()
if pid == 0:
    os._exit(42)                    # child dies immediately
time.sleep(0.2)                     # parent does NOT wait yet → child is a zombie
os.system(f"ps -o pid,ppid,stat,comm -p {pid}")   # look for Z / <defunct>
st = os.waitpid(pid, 0)             # reap
print("reaped, exit status:", os.waitstatus_to_exitcode(st[1]))
os.system(f"ps -o pid,stat -p {pid} 2>/dev/null || echo 'pid gone: reaped'")
PY
```

**Prove it:**

```bash
# The zombie window shows state Z (defunct); after wait() the PID is gone.
# Re-run step 4 and confirm you see 'Z' then 'pid gone: reaped'.
python3 -c "import os,time;p=os.fork();os._exit(0) if p==0 else (time.sleep(0.3), os.system(f'cat /proc/{p}/stat | cut -d\" \" -f3'), os.waitpid(p,0))" 
# expected output: Z
```

Understanding proven when: you can state that `getpid()` is the tgid, that COW keeps child RSS low until a write, and that a zombie holds a PID (not RAM) until the parent reaps.

**Teardown:**

```bash
rm -f /tmp/ddtest                     # remove the direct-I/O scratch file
pkill -f 'dd if=/dev/zero' 2>/dev/null # kill any stray background dd from step 3
pkill -f 'sum(buf' 2>/dev/null || true # any lingering python fork children
```

### Lab 2 — Scheduler in the raw: runqueue latency, nice, RT starvation, EEVDF slices

**Objective:** Separate "on CPU" from "waiting for CPU," show nice actually reshaping shares, watch an RT task starve fair tasks, and (6.6+) set an EEVDF slice.

**Setup:**

```bash
sudo dnf install -y perf util-linux stress-ng || sudo apt install -y linux-perf util-linux stress-ng
nproc   # note your core count; pin to 1 CPU to force contention
```

**Steps:**

1. Force runqueue contention on one CPU and read the *waiting* time, not just CPU%:

```bash
# 4 busy loops pinned to CPU 0 → 3 of 4 are always runnable-but-waiting
for i in 1 2 3 4; do taskset -c 0 bash -c 'while :; do :; done' & done
BUSY_PIDS=$(jobs -p)
sleep 2
for p in $BUSY_PIDS; do
  echo -n "pid $p schedstat (on_cpu_ns wait_ns slices): "; cat /proc/$p/schedstat
done
```

Field 2 (wait_ns) climbing fast while CPU shows ~25% each is the invisible latency. Confirm with:

```bash
sudo perf sched record -- sleep 3 2>/dev/null && sudo perf sched latency | head -20
```

2. Show nice reshaping CPU share. Renice half the loops and compare CPU time accrual:

```bash
renice -n 19 -p $(echo $BUSY_PIDS | awk '{print $1, $2}') >/dev/null
sleep 3
for p in $BUSY_PIDS; do
  awk -v p=$p '{print "pid",p,"utime+stime ticks:",$14+$15}' /proc/$p/stat
done
kill $BUSY_PIDS 2>/dev/null
```

The nice-19 pair should accumulate far fewer ticks than the nice-0 pair on the shared CPU.

3. RT starvation (⚠️ this pins a core at 100% and can make an under-provisioned VM briefly unresponsive; do it on a throwaway VM with ≥2 cores and be ready to `kill`):

```bash
taskset -c 0 chrt -f 90 bash -c 'while :; do :; done' &
RTPID=$!
sleep 2
# fair tasks on the same CPU get almost no time; watch this normal task starve:
taskset -c 0 nice -n 0 bash -c 'for i in $(seq 1 100000000); do :; done' &
VICTIM=$!
sleep 3
cat /proc/$VICTIM/schedstat   # huge wait_ns, tiny on_cpu — starved by the FIFO task
# the safety valve that keeps the box alive:
cat /proc/sys/kernel/sched_rt_runtime_us /proc/sys/kernel/sched_rt_period_us
kill -9 $RTPID $VICTIM 2>/dev/null
```

4. EEVDF slice (kernel 6.6+ only). Confirm scheduler, then request a short slice for latency:

```bash
grep -q EEVDF /sys/kernel/debug/sched/features 2>/dev/null && echo "features file present"
uname -r    # 6.6+ ⇒ EEVDF is the SCHED_OTHER engine
# chrt on new util-linux can show/set the deadline-ish attributes; inspect a task:
chrt -p $$
# set a task to SCHED_BATCH (no wakeup preempt) to see policy change take effect:
chrt -b 0 bash -c 'sleep 5 & echo policy for $!; chrt -p $!' 
```

**Prove it:**

```bash
# The differentiator: two tasks, equal CPU%, wildly different runqueue wait.
# After step 1, this shows on-CPU vs waiting nanoseconds side by side:
for p in $(pgrep -f 'while :; do :'); do
  read on wait slices < /proc/$p/schedstat
  echo "pid $p  on_cpu_ms=$((on/1000000))  waiting_ms=$((wait/1000000))"
done
# Understanding proven: you can point to waiting_ms and say "this is scheduler
# latency, invisible in top's CPU%, and here's the perf sched proof."
pkill -f 'while :; do :' 2>/dev/null
```

### Lab 3 — cgroup CPU throttling: the utilization liar

**Objective:** Build the exact "healthy CPU%, terrible latency" bug in a cgroup and read the throttle counters that expose it. This is the flagship lab.

**Setup:** (requires cgroup v2 — default on all modern distros; verify `stat -fc %T /sys/fs/cgroup` returns `cgroup2fs`.)

```bash
stat -fc %T /sys/fs/cgroup      # expect: cgroup2fs
sudo mkdir -p /sys/fs/cgroup/throttle-demo
# enable the cpu controller in the parent if needed:
echo +cpu | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null 2>&1 || true
```

**Steps:**

1. Cap the group at 1 full CPU (quota 100000 µs per 100000 µs period), then run many threads inside it:

```bash
echo "100000 100000" | sudo tee /sys/fs/cgroup/throttle-demo/cpu.max
# launch 8 busy loops, all placed into the cgroup:
for i in $(seq 1 8); do bash -c 'while :; do :; done' & echo $! | sudo tee -a /sys/fs/cgroup/throttle-demo/cgroup.procs >/dev/null; done
DEMO_PIDS=$(jobs -p)
```

2. Watch aggregate CPU: it will hover near 100% of ONE CPU (the cap), looking "fully but not over-utilized":

```bash
sleep 3
cat /sys/fs/cgroup/throttle-demo/cpu.stat
```

3. Sample the throttle counters over time and compute the throttle ratio:

```bash
for s in 1 2 3; do
  read _ np _ nt _ tt < <(tr '\n' ' ' < /sys/fs/cgroup/throttle-demo/cpu.stat | \
     sed -E 's/.*nr_periods ([0-9]+).*nr_throttled ([0-9]+).*throttled_usec ([0-9]+).*/x \1 x \2 x \3/')
  echo "periods=$np throttled=$nt throttled_usec=$tt  ratio=$(awk "BEGIN{print $nt/$np}")"
  sleep 1
done
```

`ratio` near 1.0 means the group is throttled in essentially every period: 8 threads burn the 100 ms quota in ~12.5 ms, then sit dead for ~87 ms. That dead time is p99 latency for any real request.

4. Fix it two ways and watch throttling drop. (a) Match concurrency to quota:

```bash
kill $DEMO_PIDS 2>/dev/null; sleep 1
# reset counters by recreating the cgroup:
sudo rmdir /sys/fs/cgroup/throttle-demo; sudo mkdir /sys/fs/cgroup/throttle-demo
echo "100000 100000" | sudo tee /sys/fs/cgroup/throttle-demo/cpu.max
for i in 1; do bash -c 'while :; do :; done' & echo $! | sudo tee -a /sys/fs/cgroup/throttle-demo/cgroup.procs >/dev/null; done
ONE=$!; sleep 3
cat /sys/fs/cgroup/throttle-demo/cpu.stat   # nr_throttled should be ~0 now
kill $ONE 2>/dev/null
```

(b) Or raise the cap. Restore and clean up:

```bash
kill $(jobs -p) 2>/dev/null
sudo rmdir /sys/fs/cgroup/throttle-demo
```

**Prove it:**

```bash
# Reproduce the smoking gun in one shot and assert the ratio is high:
sudo mkdir -p /sys/fs/cgroup/tg && echo "100000 100000" | sudo tee /sys/fs/cgroup/tg/cpu.max >/dev/null
for i in $(seq 1 8); do bash -c 'while :; do :; done' & echo $! | sudo tee -a /sys/fs/cgroup/tg/cgroup.procs >/dev/null; done
sleep 3; grep -E 'nr_periods|nr_throttled|throttled_usec' /sys/fs/cgroup/tg/cpu.stat
kill $(cat /sys/fs/cgroup/tg/cgroup.procs) 2>/dev/null; sudo rmdir /sys/fs/cgroup/tg
# Understanding proven: nr_throttled ≈ nr_periods with ~100%-of-one-CPU usage.
# You can now say "CPU utilization is a lie here; cpu.stat proves throttling."
```

**Teardown:** (removes the demo cgroups even if a step exited early, leaving them behind)

```bash
# kill any loops still parked in the demo cgroups, then remove the cgroup dirs
for cg in throttle-demo tg; do
  if [ -d /sys/fs/cgroup/$cg ]; then
    kill $(cat /sys/fs/cgroup/$cg/cgroup.procs 2>/dev/null) 2>/dev/null
    sudo rmdir /sys/fs/cgroup/$cg 2>/dev/null
  fi
done
```

### Lab 4 — Signals: coalescing vs queuing, masks, and the D-state that ignores SIGKILL

**Objective:** Prove standard signals coalesce while realtime signals queue, read pending/blocked bitmaps from `/proc`, and demonstrate that a `D`-state task ignores SIGKILL.

**Setup:**

```bash
sudo dnf install -y python3 procps-ng || sudo apt install -y python3 procps
```

**Steps:**

1. Standard-signal coalescing: block SIGUSR1, send it 5 times, unblock, count deliveries:

```bash
python3 - <<'PY'
import signal, os, time
count = {'n':0}
def h(s,f): count['n'] += 1
signal.signal(signal.SIGUSR1, h)
signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})
for _ in range(5): os.kill(os.getpid(), signal.SIGUSR1)   # 5 sends while blocked
# peek at the pending bitmap from /proc while blocked:
print("SigPnd/SigBlk:", [l for l in open(f'/proc/{os.getpid()}/status') if l[:3] in ('Sig',)])
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGUSR1})
time.sleep(0.2)
print("standard SIGUSR1 deliveries after 5 sends:", count['n'])   # expect 1
PY
```

2. Realtime-signal queuing: same experiment with SIGRTMIN, using `sigqueue` to attach values:

```bash
python3 - <<'PY'
import signal, os, time, ctypes
RT = signal.SIGRTMIN
got = []
def h(s,f): got.append(s)
signal.signal(RT, h)
signal.pthread_sigmask(signal.SIG_BLOCK, {RT})
libc = ctypes.CDLL("libc.so.6", use_errno=True)
class sigval(ctypes.Union): _fields_=[("i",ctypes.c_int),("p",ctypes.c_void_p)]
for v in range(5):
    libc.sigqueue(os.getpid(), RT, sigval(i=v))   # 5 QUEUED sends
print([l.strip() for l in open(f'/proc/{os.getpid()}/status') if l.startswith('SigQ')])
signal.pthread_sigmask(signal.SIG_UNBLOCK, {RT})
time.sleep(0.3)
print("realtime deliveries after 5 sends:", len(got))   # expect 5
PY
```

3. Read and decode signal masks of a running daemon. Pick any long-lived PID and see what it catches vs blocks:

```bash
PID=$(pgrep -n -x sshd || pgrep -n systemd | head -1)
grep -E 'Sig(Blk|Ign|Cgt|Pnd)' /proc/$PID/status
# The hex is a 64-bit mask; bit (N-1) set = signal N. E.g. bit 14 (0x...2000) = SIGTERM.
python3 - "$PID" <<'PY'
import sys
for line in open(f"/proc/{sys.argv[1]}/status"):
    if line[:3]=="Sig" and line.split(':')[0] in ("SigBlk","SigCgt","SigIgn"):
        k,v=line.split(); m=int(v,16)
        sigs=[n+1 for n in range(64) if m>>n & 1]
        print(k, "→ signals", sigs)
PY
```

4. Show a `D`-state task ignoring SIGKILL. Freeze a task uninterruptibly is kernel-dependent; a portable approximation uses a `vfork` child stuck pre-exec, but the cleanest observable is a process blocked on a stalled FUSE/NFS. Without one, demonstrate the principle with a stopped (`T`) task, which *also* won't run its handler until continued:

```bash
sleep 300 & P=$!
kill -STOP $P; sleep 0.2
cat /proc/$P/stat | cut -d' ' -f3        # T = stopped, not executing signals
kill -TERM $P                            # queued but NOT delivered while stopped
sleep 0.2; ps -o pid,stat -p $P          # still there (T); TERM is pending
kill -CONT $P                            # now it runs, delivers the pending TERM, dies
sleep 0.2; ps -o pid,stat -p $P 2>/dev/null || echo "delivered on CONT → gone"
```

**Prove it:**

```bash
# One assertion that captures the core distinction:
python3 - <<'PY'
import signal,os,time,ctypes
def run(rt):
    got=[0]; sig = signal.SIGRTMIN if rt else signal.SIGUSR1
    signal.signal(sig, lambda s,f: got.__setitem__(0,got[0]+1))
    signal.pthread_sigmask(signal.SIG_BLOCK,{sig})
    if rt:
        lib=ctypes.CDLL("libc.so.6")
        class sv(ctypes.Union):_fields_=[("i",ctypes.c_int)]
        for i in range(10): lib.sigqueue(os.getpid(),sig,sv(i=i))
    else:
        for _ in range(10): os.kill(os.getpid(),sig)
    signal.pthread_sigmask(signal.SIG_UNBLOCK,{sig}); time.sleep(0.2)
    return got[0]
print("standard deliveries:", run(False), "  realtime deliveries:", run(True))
# expect: standard 1, realtime 10
PY
# Understanding proven: standard signals coalesce (1), RT signals queue (10).
```

---

## Curated resources

Primary references (the ABI and the source of truth):

- **`proc_pid_stat(5)` and `proc(5)`** — https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html — the definitive field-by-field decode of `/proc/<pid>/stat` (all 54 fields) and the wider `/proc` surface. When a blog and this page disagree, this page wins. The state-char table and the `starttime`/`utime`/`stime` clock-tick semantics live here.
- **`signal(7)`** — https://man7.org/linux/man-pages/man7/signal.7.html — the complete signal model: the standard-vs-realtime distinction, the disposition/default-action table, delivery ordering, and which signals can't be caught. Read end to end; it's a dense essay, not a lookup.
- **`signal-safety(7)`** — https://man7.org/linux/man-pages/man7/signal-safety.7.html — the async-signal-safe function list. The reason your handler deadlocks in `malloc` is spelled out here.
- **`clone(2)` / `clone3(2)` and `fork(2)` / `vfork(2)`** — https://man7.org/linux/man-pages/man2/clone.2.html — every `CLONE_*` flag and exactly which resource each shares. This is where "a thread is just a clone with these flags" becomes concrete. Pair with `vfork(2)` for the suspend-parent semantics.
- **`credentials(7)`, `pid_namespaces(7)`, `wait(2)`, `pidfd_open(2)`** — https://man7.org/linux/man-pages/man2/wait.2.html — reaping semantics, `WNOHANG`/`WUNTRACED`, subreaper behavior, and the race-free `pidfd` handle model that replaced raw PID signalling.
- **EEVDF Scheduler — kernel.org** — https://docs.kernel.org/scheduler/sched-eevdf.html and the source doc https://github.com/torvalds/linux/blob/master/Documentation/scheduler/sched-eevdf.rst — the authoritative description of lag, eligibility, and virtual deadline. Read after `sched-design-CFS.rst` so you can see exactly what changed (selection) and what didn't (vruntime/weights/load balancing). Essential because the default scheduler changed at 6.6 and your RHEL boxes are still on CFS.
- **CFS Bandwidth Control — kernel.org** — https://docs.kernel.org/scheduler/sched-bwc.html — the mechanism behind quota/period throttling, slice distribution, and the `cpu.stat` counters (`nr_periods`, `nr_throttled`, `throttled_usec`) plus the 5.14+ burst feature. The primary source for Lab 3.
- **Control Group v2 — kernel.org** — https://docs.kernel.org/admin-guide/cgroup-v2.html — the CPU controller (`cpu.weight`/`cpu.max`), the memory controller's `memory.high` (throttle) vs `memory.max` (OOM) distinction, `memory.oom.group`, `memory.events`, and PSI (`*.pressure`). The mechanism systemd and every container runtime drive.
- **rockyman.org** — https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here (the `chrt`, `renice`, `taskset`, `ps`, and `dnf` invocations in the labs above were checked against it).

Books (canonical, mechanism-level):

- **The Linux Programming Interface (TLPI) — Michael Kerrisk** — https://man7.org/tlpi/ — chapters 24–27 (process creation/termination/monitoring, `fork`/`exec`/`wait`), 20–22 (signals fundamentals), and 33 (POSIX realtime signals) are the single best prose treatment of everything in this module. Written by the man-pages maintainer, so it's the ABI from the source. The ~200 example programs are the lab bench — build them, `strace` them, break them.
- **Linux Kernel Development, 3rd ed — Robert Love** — https://www.amazon.com/Linux-Kernel-Development-Robert-Love/dp/0672329468 — chapters 3 (process descriptor / `task_struct`), 4 (process scheduling, the CFS mechanics), and 10 (kernel synchronization, which explains *why* `TASK_UNINTERRUPTIBLE` exists). The most approachable on-ramp to the scheduler internals.
- **Understanding the Linux Kernel, 3rd ed — Bovet & Cesati** — https://www.oreilly.com/library/view/understanding-the-linux-kernel/0596005652/ — the structural counterpart: the actual runqueue data structures, `do_fork` code path, and signal delivery machinery. Dated to 2.6 but the architecture is intact.
- **Systems Performance, 2nd ed — Brendan Gregg** — https://www.brendangregg.com/systems-performance-2nd-edition-book.html — the CPU chapter reframes scheduling analysis into the USE method (utilization/saturation/errors) and, crucially, teaches *scheduler latency* as a first-class metric — the "runnable but waiting" concept Lab 2 makes visible.
- **Operating Systems: Three Easy Pieces (OSTEP)** — https://pages.cs.wisc.edu/~remzi/OSTEP/ — free. The scheduling chapters (MLFQ, lottery/stride, proportional share) are the theory EEVDF's virtual-deadline math implements. Read when you want *why* rather than *how Linux specifically*.

High-signal articles and talks:

- **LWN — "An EEVDF CPU scheduler for Linux" (Jonathan Corbet)** — https://lwn.net/Articles/925371/ — the landmark explainer of the EEVDF transition, written as the patches landed, with Peter Zijlstra's reasoning. LWN covered this before anyone else and in more depth.
- **LWN "Namespaces in operation" — PID namespaces part** — https://lwn.net/Articles/531419/ — the init/reaping semantics inside a PID namespace and why killing PID-1 tears down the namespace. Directly relevant to container zombie problems.
- **"Unthrottled: Fixing CPU Limits in the Cloud" — Indeed Engineering** — https://engineering.indeedblog.com/blog/2019/12/unthrottled-fixing-cpu-limits-in-the-cloud/ — the definitive real-world writeup of the CFS-throttling-hides-in-utilization bug (Lab 3) at scale, including the kernel bug they found and fixed. Read alongside Dan Luu's https://danluu.com/cgroup-throttling/.
- **"Reliably creating D-state processes on demand" — Chris Down** — https://chrisdown.name/2024/02/05/reliably-creating-d-state-processes-on-demand.html — a Meta kernel engineer's precise recipe for manufacturing `TASK_UNINTERRUPTIBLE`, which teaches exactly what forces a task into `D` and why it ignores signals.
- **"What /proc/[pid]/stat's process state means" — Chris Siebenmann** — https://utcc.utoronto.ca/~cks/space/blog/linux/ProcPidStatState — a careful, correct decoding of the state field and its edge cases (`I`, `K`, the `t` vs `T` distinction).
- **Julia Evans — jvns.ca** — https://jvns.ca/ — the best hands-on explainers for `strace`, `/proc` spelunking, and signals; the "How to send a signal to a process" and zines build the reflex of interrogating a live system.

Source and tooling:

- **`kernel/fork.c`, `kernel/exit.c`, `kernel/signal.c`, `kernel/sched/{core,fair,rt,deadline}.c`** — https://github.com/torvalds/linux/tree/master/kernel — read `kernel_clone()`, `do_exit()`, `__schedule()`, `pick_next_task_fair()`. The comments in `fair.c` on EEVDF eligibility are excellent.
- **BPF Performance Tools — Brendan Gregg (tools repo)** — https://github.com/brendangregg/bpf-perf-tools-book — `runqlat`, `runqlen`, `offcputime`, `oomkill`, and `killsnoop` are the production versions of every observation this module makes by hand.

---

## Senior signal

- **Distrusts CPU utilization; reaches for `cpu.stat` and `schedstat`.** A staff engineer, shown "50% CPU but slow," immediately checks `nr_throttled`/`throttled_usec` in the cgroup and the runqueue-wait field of `/proc/<pid>/schedstat` before touching the app. They know utilization is an average that hides both CFS throttling and runqueue latency, and they can name which counter to read to prove it.
- **Reads load average correctly.** They know Linux load = runnable + uninterruptible, so a high load with idle CPUs means enumerate the `D`-state tasks and read their kernel stacks (`/proc/<pid>/stack`, `wchan`) — the blocked-on-I/O or dead-mount diagnosis — instead of assuming CPU saturation.
- **Knows the scheduler changed under them.** They distinguish CFS (RHEL 8/9, ≤6.5) from EEVDF (≥6.6), can explain lag/eligibility/virtual-deadline, and won't transfer a latency benchmark from one to the other. They reason about *why* a latency-sensitive task is preempted, not just set a nice value.
- **Understands a "process" is a flag preset on `clone()`.** They can explain a thread vs a process in terms of shared `mm`/`files`/`sighand`, know `getpid()` returns `tgid`, and know that COW makes `fork()` cheap until the child writes — and that the residual cost is page-table duplication, which is why `posix_spawn`/`vfork` exist.
- **Treats zombies and orphans as a PID-exhaustion and reaping problem, not a memory problem.** They know app-as-PID-1 in a container that ignores `SIGCHLD` leaks zombies inside the namespace, that `--init`/tini exists to fix it, and that subreapers and pidfds are the modern reaping primitives.
- **Reasons about signals as pending state, not events.** They know standard signals coalesce and RT signals queue, that delivery happens at return-to-userspace (so a `D`-state task ignores even SIGKILL until its wait completes), and that handlers must be async-signal-safe — and they default to `signalfd`/self-pipe rather than doing work in a handler.
- **Handles the OOM killer as a scoped, tunable mechanism.** They distinguish global vs memcg OOM, know victim selection is RSS-driven and biased by `oom_score_adj`, protect critical daemons with `OOMScoreAdjust=-1000`, know `memory.high` throttles while `memory.max` kills, and alert on PSI (`/proc/pressure`, `systemd-oomd`) *before* the kill rather than reading the dmesg banner after.
- **Contains blast radius before root-causing.** Faced with a runaway `SCHED_FIFO` thread or a fork bomb, they reach first for the bounding mechanism (`sched_rt_runtime_us`, `pids.max`, `cpu.max`, `oom_score_adj`) to stabilize, then diagnose — mitigation-first sequencing rather than diving into root cause while the box burns.

---

## See also

- [[07 - systemd]] — systemd is the userspace front end to this module's kernel mechanisms: it sets `OOMScoreAdjust=`, drives `cpu.max`/`cpu.weight` per unit, handles `SIGCHLD` reaping as PID 1, and `systemd-oomd` acts on the PSI signals covered in §9.
- [[10 - Namespaces and cgroups v2]] — expands the `CLONE_NEW*` flags from §3 and the cgroup v2 CPU/memory controllers (`cpu.stat` throttling, memcg OOM, `pids.max`) that Labs 3 and the OOM section depend on.
- [[11 - Observability and Tracing with eBPF]] — the production tooling (`runqlat`, `offcputime`, `oomkill`, `killsnoop`) that measures the runqueue latency, off-CPU waits, and OOM kills this module observes by hand through `/proc` and `perf sched`.
- [[03 - Slurm Architecture and Scheduling]] — the cluster-scale scheduler: Slurm allocates jobs to nodes/CPUs the way EEVDF allocates runnable tasks to a core, and enforces per-job limits through the same cgroup cpu/memory controllers.
- [[03 - GPU Scheduling on Kubernetes]] — pod scheduling and CPU/memory requests-and-limits are built directly on the cgroup `cpu.max`/`cpu.weight` throttling and OOM behavior in §6/§9.
- [[09 - Observability and SRE]] — load average, runqueue latency, and OOM kills as first-class SRE signals; the "utilization is lying" story here is a core SRE golden-signal lesson.
- [[08 - Observability and Efficiency for ML Infrastructure]] — CFS throttling and cgroup OOM tuning are exactly the failure modes that starve or kill long-running training jobs.
