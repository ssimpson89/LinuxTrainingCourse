---
title: Observability and Tracing with eBPF
type: module
track: linux-internals
tags: [linux-internals, observability, ebpf, bpftrace, bcc, perf, ftrace, strace, tracepoints, kprobes, uprobes, usdt, flamegraphs, verifier, btf, co-re]
requires: ["kernel>=5.8 (BPF_MAP_TYPE_RINGBUF, ordered ring buffer)", "BTF/CO-RE (/sys/kernel/btf/vmlinux, CONFIG_DEBUG_INFO_BTF=y) for eBPF labs", "root in a throwaway Rocky 9.x VM", "systemtap-sdt-dtrace (provides sys/sdt.h) for the hand-placed USDT probe in Lab 5"]
module_number: 11
status: reviewed
created: 2026-07-08
---

# 11 — Observability and Tracing with eBPF

Backlink: [[00 - Track Overview]]

Every other module in this track teaches you a subsystem: the scheduler, the VFS, the block layer, cgroups. This module teaches you how to *interrogate all of them on a live production box without a debugger, without a restart, and without shipping a patch*. That is the actual staff-level differentiator. A mid-level engineer reads dashboards and greps logs, which only shows you what someone already decided to instrument. A staff engineer reaches into the running kernel and asks a question nobody pre-baked a metric for: "what is the off-CPU stack of the thread that's stalling this request," "which process is calling `fsync` in a tight loop," "what's the distribution of block-I/O latency broken down by device and by whether it was a read or a write," "who is sending SIGKILL to my daemon." The invisible becomes visible.

The mental model to install first: **there are two families of instrumentation, static and dynamic, and two places to run your logic, in the kernel or in userspace.** Static instrumentation (tracepoints, USDT) is a stable hook a developer placed on purpose. Dynamic instrumentation (kprobes, uprobes) patches a live instruction to divert into your probe — no source change, no recompile, works on functions nobody thought to expose. eBPF is the modern engine that runs a small verified program *at* any of those hook points, aggregates in-kernel, and hands you back a histogram instead of a firehose of events. The genius, and the thing that separates it from the old `strace`/`tcpdump` "copy every event to userspace" model, is that summarization happens in the kernel, so overhead scales with *distinct results*, not with *event count*. That's what makes it safe to run against a million-events-per-second path in production.

This module walks the whole toolchain bottom to top: `strace`/`ltrace` (the ptrace-based blunt instrument you already know, and why it's dangerous in prod), `ftrace`/`trace-cmd` (the in-kernel tracer that needs nothing installed), `perf` (sampling, `perf sched`, flame graphs), then `bpftrace` and BCC as the eBPF frontends, USDT probes, and the eBPF machine model itself — verifier, maps, ring buffer, CO-RE/BTF — at a working level. It ends with a *method*: how to go from a vague "it's slow" to a proven root cause using the USE method and off-CPU analysis, choosing the right tool to falsify a specific hypothesis.

---

## Concept deep-dive

### The layer cake: where a probe actually fires

Everything in this module bottoms out in a handful of kernel mechanisms. Understanding *where* each hook lives tells you its cost and its stability.

```
                         userspace program
   uprobe / uretprobe  ─────►│  (dynamic: patch a userspace instruction with int3)
   USDT (SDT note)     ─────►│  (static: a nop the dev placed; tracer patches it)
─────────────────────────────────────────── syscall boundary ───────────
   syscall tracepoints ─────►│  sys_enter_* / sys_exit_* (stable)
   ptrace (strace)     ─────►│  (stop the whole task on every syscall — heavy)
─────────────────────────────────────────── kernel ─────────────────────
   kprobe / kretprobe  ─────►│  any kernel instruction (dynamic, int3 patch)
   tracepoints         ─────►│  static markers in kernel source (stable ABI)
   perf PMU events     ─────►│  hardware counters + timed sampling (NMI)
                             │
        all of the above can attach an eBPF program which:
          - reads args/regs/context
          - filters in-kernel (drop uninteresting events cheaply)
          - aggregates into a MAP (histogram, count, stack table)
          - optionally emits a record to a RING BUFFER for userspace
```

The cost gradient, cheapest to most expensive per event: **tracepoint ≈ USDT nop < kprobe/uprobe (int3 trap) < ptrace stop**. Sampling (`perf record -F`) is different — its cost is fixed per-sample-per-CPU regardless of workload event rate, which is why 99 Hz profiling is nearly free.

### kprobes: how dynamic kernel tracing physically works

A kprobe is not magic. When you register a kprobe on kernel symbol `vfs_read`, the kprobes machinery (`kernel/kprobes.c`) saves the original instruction bytes at that address and overwrites the first byte with a breakpoint instruction — `int3` (0xCC) on x86. When any CPU executes that address, it traps into the `do_int3` handler, which recognizes the address as a kprobe, runs your pre-handler (your eBPF program), single-steps the saved original instruction out-of-line, and returns. On modern kernels with `CONFIG_KPROBES_ON_FTRACE`, if the probe point coincides with the `fentry` `__fentry__` hook that the compiler already inserted for ftrace, the kprobe uses the ftrace trampoline instead of an `int3` trap, which is significantly cheaper (no exception, just a call). This is why probing at function *entry* is faster than probing an arbitrary offset into a function.

A **kretprobe** is trickier: there is no single instruction at "function return." The kernel installs an entry kprobe that, when hit, saves the real return address and *rewrites the return address on the stack* to point at a trampoline (`kretprobe_trampoline`). When the function returns, it lands in the trampoline, which runs your return handler and then jumps to the saved real return address. The consequence you must know: kretprobes have a fixed pool of "return instances" (`maxactive`). Under deep recursion or a flood of concurrent calls, that pool exhausts and you *silently miss returns* — you'll see it as `kretprobe: nmissed` in `/sys/kernel/debug/kprobes/list` or as fewer return events than entries. That asymmetry is a classic footgun when computing function latency.

The modern replacement for entry/exit kprobes is **fentry/fexit** (BTF-based `BPF_TRACE_FENTRY`/`BPF_TRACE_FEXIT`, kernel 5.5+). These attach directly to the compiler's `fentry` hook using a BPF trampoline and have access to typed arguments *and* the return value with far less overhead than a kretprobe, and no `maxactive` limit. If your kernel and bpftrace are recent, prefer `fexit` over `kretprobe`.

The stability caveat is load-bearing: **kprobes attach to whatever the compiler emitted.** Function names, arguments, inlining, and calling convention change between kernel versions. A one-liner that works on 5.14 can attach to nothing (or the wrong thing) on 6.6 because the function got inlined or renamed. This is *the* reason tracepoints exist.

### Tracepoints: the stable ABI

A tracepoint is a static hook the kernel developers placed in source (`trace_sched_switch()`, `trace_block_rq_issue()`, etc.) via the `TRACE_EVENT()` macro. Each compiles to a patched-out `nop` plus an out-of-line block; when disabled it's a single untaken branch (via a "jump label"/static key), so a disabled tracepoint is effectively free. When you enable it, the static key flips the `nop` to a jump into the trace code. Crucially, tracepoints have a **documented, versioned argument format** exposed at `/sys/kernel/tracing/events/<subsystem>/<event>/format`. That format is treated as kernel ABI — it changes rarely and carefully. So `tracepoint:block:block_rq_issue` gives you named fields (`args->bytes`, `args->sector`, `args->comm`) that are stable across kernels in a way kprobe args never are. **Rule: prefer a tracepoint if one exists; fall back to kprobe/fentry only when it doesn't.**

You can enumerate them:

```
ls /sys/kernel/tracing/events/                 # subsystems
cat /sys/kernel/tracing/events/syscalls/sys_enter_openat/format
bpftrace -l 'tracepoint:*'                      # via bpftrace
```

### uprobes and USDT: reaching into userspace

A **uprobe** is the userspace analogue of a kprobe: the kernel patches an `int3` at a virtual address in an executable/library file (keyed by inode + offset, so it fires for *every* process mapping that file). When hit, it traps into the kernel, runs your eBPF program, single-steps the original instruction, and returns to userspace. You can probe any function in `libc`, `libssl`, a Go binary, the Python interpreter — no source, no recompile. The catch: symbol resolution and ABI. You need symbols (or you supply raw offsets), and you must know the calling convention to read arguments. Optimized/inlined functions may not exist as distinct symbols.

A **USDT probe** (User Statically-Defined Tracing) is the userspace analogue of a tracepoint: the developer placed a marker on purpose using the `DTRACE_PROBE`/`SDT` macros from `sys/sdt.h`. At compile time this emits a `nop` instruction plus an entry in an ELF note section (`.note.stapsdt`) describing the probe's provider, name, and the register/memory locations of its arguments. When no tracer is attached it's a single `nop` — genuinely zero overhead, which is why projects like the JVM, Python, Node, PostgreSQL, MySQL, and libc ship them enabled in production builds. When you attach, the tracer reads the note, finds the `nop`, and patches a uprobe there. So USDT is "a uprobe at a location and with argument descriptors the developer promised to keep stable." Inspect the notes with:

```
readelf -n /usr/lib64/libc.so.6 | grep -A3 stapsdt
bpftrace -l 'usdt:/usr/lib64/libc.so.6:*'
```

The senior insight: USDT is a *contract*. The `libc:setjmp` or `python:function__entry` markers are semantic events the developer curated, far more meaningful and stable than reverse-engineering which internal function to uprobe.

### eBPF the machine: verifier, JIT, maps, ring buffer

eBPF is a 64-bit RISC-like virtual machine (11 registers, a 512-byte stack, its own instruction set) that runs *inside* the kernel. You load a program with the `bpf(2)` syscall (`BPF_PROG_LOAD`). Before it runs, the **verifier** (`kernel/bpf/verifier.c`) statically proves the program is safe, because a bug in kernel context is a kernel bug. The verifier does a symbolic-execution walk of every reachable path and enforces:

- **Termination.** Historically no loops at all; since 5.3, bounded loops the verifier can prove terminate; since 5.17, `bpf_loop()` helper for larger bounded iteration. It rejects anything it can't prove halts.
- **Memory safety.** Every pointer is tracked with a type and bounds. You cannot read past a map value, dereference a possibly-null pointer without checking it, or touch arbitrary kernel memory except through helpers like `bpf_probe_read_kernel()` (which does a fault-tolerant copy).
- **A complexity ceiling.** The verifier refuses to inspect more than **one million instructions** across all path permutations. This is not your program's size — it's the total states explored, which explodes with branches. A program with a modest instruction count but many nested conditionals can blow the budget. The number "felt big in 2019" and programs now routinely hit it ([LWN, 2025](https://lwn.net/Articles/1017116/)). Mitigations: use **global functions** (5.6+) which the verifier checks once in isolation rather than re-inlining, keep loops bounded via `bpf_loop`, and reduce branching.

After verification the program is **JIT-compiled** to native machine code (on all major arches), so it runs at roughly native speed — there's no interpreter in the hot path on production kernels.

Programs are typed (`BPF_PROG_TYPE_KPROBE`, `_TRACEPOINT`, `_PERF_EVENT`, `_XDP`, `_SCHED_CLS`, `_TRACING` for fentry, etc.). The type determines the context struct you get and which helpers are legal — a networking program can't call tracing helpers and vice versa.

**Maps** are the only way an eBPF program keeps state and the only way it talks to userspace for anything other than streamed events. A map is a kernel-resident key/value store created via `BPF_MAP_CREATE`, referenced by fd. Types you must know:

- **`BPF_MAP_TYPE_HASH` / `PERCPU_HASH`** — the workhorse for aggregation keyed by pid, stack id, device, etc. Per-CPU variants give each CPU its own slot so there's no cross-CPU locking/cache-line bouncing on update; userspace sums them at read. Per-CPU is how you count millions of events with near-zero contention.
- **`ARRAY` / `PERCPU_ARRAY`** — fixed integer-indexed, preallocated.
- **`LRU_HASH`** — evicts least-recently-used on overflow, so it can't grow unbounded (essential for keying on something unbounded like flows).
- **`STACK_TRACE`** — stores captured stacks, returns an id you use as a histogram key (this is how flame-graph aggregation works in-kernel).
- **`LPM_TRIE`** — longest-prefix-match, for IP routing/ACL style lookups.
- **`RINGBUF`** (5.8+) and the older **`PERF_EVENT_ARRAY`** — the event pipe to userspace, discussed next.

The distinction that trips people up: for aggregation, you **update a map in-kernel and read it once at the end** (cheap, bounded). For per-event detail you **stream records to userspace**, which is inherently more expensive and can drop events under load.

**Ring buffer vs perf buffer.** The old `PERF_EVENT_ARRAY` (perf buffer) is *per-CPU*: N separate ring buffers. That means (a) memory scales with CPU count even if traffic is uneven, and (b) events from different CPUs arrive out of order, so a userspace consumer must re-sort by timestamp. `BPF_MAP_TYPE_RINGBUF` (5.8+) is a **single MPSC ring shared across all CPUs**, so ordering is preserved globally and memory is one buffer sized to actual traffic. It uses producer/consumer position counters into a mmap'd region; the eBPF side reserves space (`bpf_ringbuf_reserve`), fills it, and commits (`bpf_ringbuf_submit`) — the reserve/commit split means a partially-written record is never visible. `max_entries` is the byte size and **must be a power of two and a multiple of the page size** ([eBPF docs](https://docs.ebpf.io/linux/map-type/BPF_MAP_TYPE_RINGBUF/)). Modern tools default to ringbuf; reach for the perf buffer only on kernels older than 5.8.

### CO-RE and BTF: compile once, run everywhere

The original BCC model shipped Clang/LLVM *on the target machine* and compiled the eBPF program at runtime against the running kernel's headers. That's why BCC tools have a fat dependency footprint and a compile pause on first run. It "worked" because struct layouts differ between kernels — `task_struct` field offsets move — so you needed the local headers to get offsets right.

**BTF** (BPF Type Format) is a compact description of all kernel types, embedded in the kernel image itself (`/sys/kernel/btf/vmlinux`) when built with `CONFIG_DEBUG_INFO_BTF=y` (default on RHEL 8.2+/Rocky, modern Ubuntu, etc.). **CO-RE** (Compile Once, Run Everywhere) uses BTF plus compiler relocations: you compile your program *once* on your dev box against a generated `vmlinux.h`, and the compiler emits relocation records for every kernel-struct field access ("the offset of `task_struct->pid`"). At load time, libbpf reads the target kernel's BTF and *patches the offsets* to match the running kernel. The result: a single small pre-compiled `.o` that runs across kernel versions with no Clang, no headers, no runtime compile. This is the mechanism behind libbpf-based tools, `bpftool gen skeleton`, and modern BCC's `libbpf-tools/` rewrite. Understand it because it's *the* reason production eBPF tooling became deployable at scale ([ebpf.io](https://ebpf.io/get-started/)).

### Why strace is a trap in production

`strace` uses `ptrace(2)`. For every syscall the traced process makes, the tracer is stopped-and-resumed *twice* (entry and exit), each a context switch, and the tracee is fully halted in between. Overhead is commonly **100x–500x** on syscall-heavy workloads. Worse, it changes timing enough to mask or move races, and on a production service it can push latency past SLA or trip watchdogs. It's an outstanding tool for a single process on a dev box and a *loaded gun* on a busy production daemon. The eBPF equivalent — `trace-cmd`, `bpftrace -e 'tracepoint:syscalls:sys_enter_* /pid == X/ {...}'`, or BCC's `syscount`/`trace` — hooks the syscall tracepoints, filters in-kernel, and adds a tiny bounded per-event cost with no ptrace stop. The senior move is to *know* the difference and reach for the tracepoint on anything live.

### Failure modes and scale behavior

- **Event storms and drops.** Streaming per-event to userspace via ring/perf buffer will *drop* events when the consumer can't keep up (you'll see a lost-events counter). The fix is almost always to aggregate in-kernel (map/histogram) instead of streaming. If you truly need every event, size the buffer up and minimize per-event work.
- **kretprobe missed returns.** As above — `maxactive` exhaustion silently undercounts. Prefer `fexit`.
- **Verifier rejections at scale.** Complex programs hit the 1M-instruction/state ceiling. Split into global functions, bound loops, simplify branching.
- **Symbol/stack resolution gaps.** JITed runtimes (Java, Node) and stripped/`-fomit-frame-pointer` binaries give broken stacks. Fixes: frame pointers (`-fno-omit-frame-pointer`), DWARF-based unwinding (`perf record --call-graph dwarf`, heavier), or LBR (`--call-graph lbr`), and per-runtime symbol maps (`perf-<pid>.map` for JITs). This is why so many "why is my flame graph a wall of `[unknown]`" tickets exist.
- **Tracepoint absence.** Not every interesting event has a tracepoint; you fall back to kprobe/fentry and inherit version fragility.
- **Overhead on ultra-hot paths.** Even a few-nanosecond probe on a path taken tens of millions of times per second adds up. Sample instead of trace, or filter to the narrowest predicate.
- **Locked-down kernels.** `kernel.perf_event_paranoid`, `kptr_restrict`, lockdown mode, and missing `CAP_BPF`/`CAP_PERFMON` (or root) will block attach. On a hardened box, ftrace via raw tracefs may be the only thing available.

---

## Hands-on labs

> All labs assume a throwaway VM (any modern distro on kernel ≥ 5.8; Rocky 9, Ubuntu 22.04+, Fedora all work). Run as root (`sudo -i`) unless noted. Install the toolchain up front:
>
> ```
> # Debian/Ubuntu
> apt-get update && apt-get install -y bpftrace bcc-tools linux-tools-$(uname -r) trace-cmd strace ltrace git
> # RHEL/Rocky/Fedora
> dnf install -y bpftrace bcc-tools perf trace-cmd strace ltrace git
> ```
>
> Sanity check the kernel has what we need:
>
> ```
> uname -r
> ls /sys/kernel/btf/vmlinux && echo "BTF present (CO-RE ready)"
> mount | grep tracefs || mount -t tracefs nodev /sys/kernel/tracing
> bpftrace --version
> ```

### Lab 1 — strace overhead vs. tracepoints: prove why we don't strace prod

**Objective:** Measure, with a stopwatch, the multi-hundred-x slowdown `ptrace` imposes, then reproduce the same visibility with an eBPF tracepoint at negligible cost. This installs the reflex for why the rest of the module exists.

**Setup:** a syscall-heavy microbenchmark.

```
cat > /tmp/hammer.c <<'EOF'
#include <unistd.h>
int main(void){ for (long i=0;i<2000000;i++){ getpid(); } return 0; }
EOF
cc -O2 -o /tmp/hammer /tmp/hammer.c
```

**Steps:**

1. Baseline — no tracer:
   ```
   time /tmp/hammer
   ```
2. Under strace (counting mode, still ptrace under the hood):
   ```
   time strace -f -c /tmp/hammer
   ```
3. Under strace with full per-syscall printing to see the truly pathological case:
   ```
   time strace -f -e trace=getpid /tmp/hammer >/dev/null 2>/tmp/strace.out
   wc -l /tmp/strace.out
   ```
4. Now the eBPF equivalent. In one terminal, count `getpid` calls system-wide via the syscall tracepoint (in-kernel aggregation, no ptrace):
   ```
   bpftrace -e 'tracepoint:syscalls:sys_enter_getpid { @[comm] = count(); }' &
   BT=$!
   time /tmp/hammer
   kill -INT $BT
   ```
5. Compare the wall-clock numbers from steps 1, 2, 3, and 4.

**Prove it:** the ratio is the lesson. Compute it explicitly:

```
# Fill in the 'real' seconds you observed:
python3 -c 'base=<step1>; st=<step3>; print(f"strace slowdown: {st/base:.0f}x")'
```

You should see strace step 3 running one to several hundred times slower than baseline, while the bpftrace run in step 4 is within a few percent of baseline *and* still produced an accurate per-process count. That gap — same visibility, ~0 vs ~300x overhead — is the entire argument for eBPF over ptrace in production.

**Teardown:**

```
kill $BT 2>/dev/null            # if the background bpftrace is still up
rm -f /tmp/hammer /tmp/hammer.c /tmp/strace.out
```

### Lab 2 — ftrace with nothing installed: function_graph and the raw tracefs interface

**Objective:** Trace kernel function execution and latency using only the kernel's built-in ftrace via `/sys/kernel/tracing`, no external tools. This is your fallback on a locked-down box where you can't install anything, and it's the substrate `perf` and much of eBPF tracing sit on.

**Setup:**

```
cd /sys/kernel/tracing
cat available_tracers      # expect: function function_graph ... nop
```

**Steps:**

1. Watch which kernel functions fire when a file is opened, using `function_graph` (shows call nesting and per-function duration). Filter to the VFS open path so you don't drown:
   ```
   echo function_graph > current_tracer
   echo 'do_sys_openat2 vfs_open do_filp_open path_openat' > set_ftrace_filter
   echo 1 > tracing_on
   cat /etc/hostname > /dev/null            # trigger some opens
   echo 0 > tracing_on
   head -40 trace
   ```
   Read the `DURATION` column — that's wall-clock time in each function, with `+`/`!` markers flagging functions that ran unusually long.
2. Reset, then use the event/tracepoint interface instead of function tracing. Trace every `openat` syscall system-wide and see the filename argument:
   ```
   echo nop > current_tracer
   echo > set_ftrace_filter
   echo 1 > events/syscalls/sys_enter_openat/enable
   echo 1 > tracing_on ; sleep 2 ; echo 0 > tracing_on
   grep -m5 openat trace
   echo 0 > events/syscalls/sys_enter_openat/enable
   ```
3. Same thing with the friendlier `trace-cmd` wrapper, and record for later analysis:
   ```
   trace-cmd record -p function_graph -l vfs_read -O funcgraph-tail sleep 1
   trace-cmd report | head -30
   ```
4. Turn on a latency tracer to find the longest time interrupts were disabled (a real-time / jitter tool):
   ```
   cat available_tracers | tr ' ' '\n' | grep irqsoff && {
     echo irqsoff > current_tracer; echo 1 > tracing_on; sleep 3; echo 0 > tracing_on
     grep -A2 "latency:" trace | head
   }
   echo nop > current_tracer
   ```

**Prove it:** you captured kernel-internal timing with zero installed tooling. Confirm the tracefs pipeline actually recorded functions and durations:

```
trace-cmd report 2>/dev/null | grep -c vfs_read && echo "ftrace captured events with no eBPF, no perf"
```

Nonzero count means you traced the kernel through the raw interface. The point to internalize: `/sys/kernel/tracing` is always there.

**Teardown:** reset the tracer state you changed so tracefs is back to idle (leaving a tracer armed or events enabled keeps adding overhead system-wide).

```
cd /sys/kernel/tracing
echo nop > current_tracer
echo > set_ftrace_filter
echo 0 > events/syscalls/sys_enter_openat/enable 2>/dev/null
echo 0 > tracing_on
echo > trace                    # clear the ring buffer
rm -f /sys/kernel/tracing/trace.dat trace.dat   # trace-cmd output, if written to cwd
```

### Lab 3 — perf: from a "slow" symptom to a CPU flame graph and an off-CPU flame graph

**Objective:** Do real performance forensics. Sample on-CPU stacks to see where CPU time goes, then do off-CPU analysis to see where *blocked* time goes — the half that on-CPU profiling structurally cannot show. This is the single most valuable performance skill in the module.

**Setup:** grab the FlameGraph scripts and make a workload with both a hot CPU loop and a blocking sleep/IO component.

```
git clone https://github.com/brendangregg/FlameGraph /opt/FlameGraph
# CPU burner + periodic disk sync (mixes on-CPU and off-CPU time)
cat > /tmp/mixed.sh <<'EOF'
#!/bin/bash
burn(){ local x=0; for ((i=0;i<50000000;i++)); do x=$((x+i)); done; }
while true; do burn; dd if=/dev/zero of=/tmp/blob bs=1M count=64 oflag=dsync status=none; sleep 0.2; done
EOF
chmod +x /tmp/mixed.sh; /tmp/mixed.sh & WL=$!
```

**Steps:**

1. First triage with `perf top` — live sampled function hotlist:
   ```
   perf top -F 99          # q to quit; note the top symbols
   ```
2. On-CPU flame graph. Sample all CPUs at 99 Hz with call graphs for 15 s, then fold and render:
   ```
   perf record -F 99 -a -g -- sleep 15
   perf script | /opt/FlameGraph/stackcollapse-perf.pl | /opt/FlameGraph/flamegraph.pl > /tmp/cpu.svg
   ```
   Open `/tmp/cpu.svg` — width = CPU time. The `burn` loop should dominate. Note what you *don't* see: the time spent blocked in `dd`'s `fsync`.
3. Off-CPU flame graph via a scheduler tracepoint (where does blocked/waiting time go). Use bpftrace to aggregate off-CPU stacks by the time between a task going off-CPU and coming back:
   ```
   bpftrace -e '
   tracepoint:sched:sched_switch { @off[args->prev_pid] = nsecs; }
   tracepoint:sched:sched_switch /@off[args->next_pid]/ {
       $delta = nsecs - @off[args->next_pid];
       @us[kstack, comm] = hist($delta / 1000);
       delete(@off[args->next_pid]);
   }
   interval:s:15 { exit(); }' > /tmp/offcpu.txt
   head -60 /tmp/offcpu.txt
   ```
   (For the canonical version use BCC's `offcputime-bpfcc -df 15 > /tmp/off.folded && /opt/FlameGraph/flamegraph.pl --color=io /tmp/off.folded > /tmp/offcpu.svg`.)
4. Use `perf sched` to quantify scheduler latency (run-queue wait) directly:
   ```
   perf sched record -- sleep 5
   perf sched latency | head -20      # per-task avg/max scheduling delay
   perf sched timehist | head         # per-wakeup timeline with wait + run
   ```

**Prove it:** you can now point at *both* halves of the time budget. Verify the CPU flame graph is dominated by your burn loop and the off-CPU data captured the `dd`/sync blocking:

```
/opt/FlameGraph/stackcollapse-perf.pl < <(perf script) 2>/dev/null | grep -c mixed || true
grep -Ei 'dd|sync|blk|io_schedule' /tmp/offcpu.txt | head
```

Seeing your burn function wide in `cpu.svg` *and* `io_schedule`/sync stacks in `offcpu.txt` proves you measured on-CPU and off-CPU time as two separate axes — the thing a naive "CPU is only 60%, must not be CPU-bound" reading gets wrong.

**Teardown:** kill the workload and remove the artifacts (the perf sampling and bpftrace probes detach when their processes exit; nothing persists in the kernel).

```
kill $WL 2>/dev/null
rm -f /tmp/mixed.sh /tmp/blob /tmp/cpu.svg /tmp/offcpu.txt /tmp/off.folded /tmp/offcpu.svg
rm -rf /opt/FlameGraph            # only if you cloned it just for this lab
```

### Lab 4 — bpftrace as a scalpel: block-I/O latency histogram and a syscall-latency breakdown

**Objective:** Answer production questions with one-liners: what's the *distribution* (not the average) of disk I/O latency, broken down by device and direction, and which processes are causing the slowest `read`s. Averages lie; histograms tell the truth about tail latency.

**Setup:** generate mixed disk I/O.

```
dd if=/dev/zero of=/tmp/io.bin bs=1M count=512 oflag=direct status=none &
fio_or_dd(){ while true; do dd if=/tmp/io.bin of=/dev/null bs=64k iflag=direct status=none; done; }
fio_or_dd & IOPID=$!
```

**Steps:**

1. Block-I/O latency histogram, keyed by device and R/W, using the `block` tracepoints (stable ABI — this works across kernels):
   ```
   bpftrace -e '
   tracepoint:block:block_rq_issue { @start[args->dev, args->sector] = nsecs; }
   tracepoint:block:block_rq_complete /@start[args->dev, args->sector]/ {
       $lat = (nsecs - @start[args->dev, args->sector]) / 1000;
       @usecs[args->rwbs] = hist($lat);
       delete(@start[args->dev, args->sector]);
   }
   interval:s:10 { exit(); }'
   ```
   Read the power-of-two histogram buckets. The width of the high buckets is your tail latency. `rwbs` tells you read vs write vs flush.
2. Which processes issue the most/slowest reads — attach at the syscall tracepoints and time the interval per-thread:
   ```
   bpftrace -e '
   tracepoint:syscalls:sys_enter_read  { @t[tid] = nsecs; }
   tracepoint:syscalls:sys_exit_read  /@t[tid]/ {
       @read_us[comm] = hist((nsecs - @t[tid]) / 1000);
       delete(@t[tid]);
   }
   interval:s:10 { exit(); }'
   ```
3. Prove the in-kernel aggregation story: count *all* syscalls system-wide for 5 s and see that the tool returns a compact summary, not a firehose:
   ```
   bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[probe] = count(); } interval:s:5 { exit(); }' | sort -t, -k2 | tail
   ```
4. Now switch from static to *dynamic* instrumentation to make the tracepoint/kprobe distinction concrete. Time `vfs_read` via a kprobe/kretprobe pair (fragile across kernels), then note bpftrace's preference for tracepoints:
   ```
   bpftrace -e '
   kprobe:vfs_read { @t[tid] = nsecs; }
   kretprobe:vfs_read /@t[tid]/ { @ns = hist(nsecs - @t[tid]); delete(@t[tid]); }
   interval:s:5 { exit(); }'
   ```

**Prove it:** the histogram is the deliverable. Capture it to a file and confirm you have a real distribution with distinct buckets, not a single average:

```
bpftrace -e '
tracepoint:block:block_rq_issue { @s[args->dev,args->sector]=nsecs; }
tracepoint:block:block_rq_complete /@s[args->dev,args->sector]/ {
  @us[args->rwbs]=hist((nsecs-@s[args->dev,args->sector])/1000);
  delete(@s[args->dev,args->sector]); }
interval:s:8 { exit(); }' | tee /tmp/iolat.txt
grep -c '@us' /tmp/iolat.txt && grep -Ec '\[[0-9K, )]+' /tmp/iolat.txt
```

Multiple bucket lines under `@us[...]` proves you measured the *shape* of latency per device/direction entirely in-kernel. If a customer says "disk is slow," this histogram tells you whether it's a uniformly slow device or a small tail of pathological outliers — a distinction the average completely hides.

**Teardown:** stop the I/O generator and clean up its scratch file (all bpftrace probes here exit with the one-liner, so no bpf programs are left loaded).

```
kill $IOPID 2>/dev/null
jobs -p | xargs -r kill 2>/dev/null    # catch the background dd from Setup
rm -f /tmp/io.bin /tmp/iolat.txt
```

### Lab 5 (stretch) — USDT and the eBPF machine: trace libc/runtime markers and watch a map fill

**Objective:** Attach to a user statically-defined tracepoint (a semantic event a developer curated), and separately observe eBPF's in-kernel map aggregation directly, tying the abstract "verifier + map" model to something you can watch.

**Setup:**

```
readelf -n /usr/lib64/libc.so.6 2>/dev/null || readelf -n /lib/x86_64-linux-gnu/libc.so.6 | grep -A3 -i stapsdt | head -30
bpftrace -l 'usdt:/usr/lib64/libc.so.6:*' 2>/dev/null || bpftrace -l 'usdt:/lib/x86_64-linux-gnu/libc.so.6:*'
```

**Steps:**

1. Trace a libc USDT marker if present (glibc ships markers like `libc:memory_*` / `lll_lock_wait`; the exact set varies). List and attach to whatever your libc exposes:
   ```
   LIBC=$(bpftrace -l 'usdt:/usr/lib64/libc.so.6:*' 2>/dev/null | head -1 | cut -d: -f1-3)
   [ -n "$LIBC" ] && bpftrace -e "usdt:${LIBC#usdt:} { @[comm] = count(); } interval:s:5 { exit(); }"
   ```
2. If your libc has no useful USDT, use a guaranteed one: build a tiny program with a hand-placed USDT probe.
   ```
   dnf install -y systemtap-sdt-dtrace 2>/dev/null || apt-get install -y systemtap-sdt-dev
   cat > /tmp/usdt.c <<'EOF'
   #include <sys/sdt.h>
   #include <unistd.h>
   int main(void){ for(int i=0;;i++){ DTRACE_PROBE1(demo, loop, i); usleep(200000);} }
   EOF
   cc -o /tmp/usdt /tmp/usdt.c && /tmp/usdt & UP=$!
   bpftrace -e 'usdt:/tmp/usdt:demo:loop { printf("iter=%d comm=%s\n", arg0, comm); }' &
   sleep 3; kill %2 %1 2>/dev/null; kill $UP 2>/dev/null
   ```
   You just consumed a static userspace marker and read its argument (`arg0`) — the same contract a JVM/Python/Postgres exposes.
3. Watch the eBPF map/verifier machinery with `bpftool`. In one shell, start a bpftrace that maintains a map; in another, enumerate loaded programs and maps:
   ```
   bpftrace -e 'kprobe:vfs_read { @reads[comm] = count(); }' & BT=$!
   sleep 1
   bpftool prog show | tail -5          # your loaded program, its type + JITed bytes
   bpftool map show | tail -5           # the @reads hash map
   MAPID=$(bpftool map show | awk '/hash/{id=$1} END{gsub(":","",id); print id}')
   bpftool map dump id $MAPID | head    # the live key/value pairs, dumped from kernel
   kill $BT
   ```
4. Force a verifier rejection to see the safety boundary. Try to read arbitrary kernel memory unsafely / write an unbounded loop and read the verifier's complaint:
   ```
   bpftrace -e 'kprobe:vfs_read { $p = (int8 *)0; @ = *$p; }' 2>&1 | head -20 || true
   ```

**Prove it:** you observed the machine, not just the frontend. Confirm the map is a real kernel object holding live state:

```
bpftrace -e 'kprobe:vfs_read { @reads[comm] = count(); } interval:s:3 { exit(); }' & sleep 1
bpftool map show | grep -c hash && echo "eBPF map is a live kernel object"; wait
```

A nonzero hash-map count while your program runs, plus a successful `bpftool map dump`, proves the aggregation lives in the kernel and is dumpable out-of-band — the concrete reality behind "eBPF summarizes in-kernel and you read the map once."

**Teardown:** kill any bpftrace/USDT processes still running so no bpf programs or maps stay resident, then remove the build artifacts. Optionally drop the packages you installed just for this lab.

```
pkill -f 'bpftrace' 2>/dev/null
kill $UP $BT 2>/dev/null ; jobs -p | xargs -r kill 2>/dev/null
rm -f /tmp/usdt /tmp/usdt.c
bpftool prog show | grep -q . && echo "check: some bpf programs still loaded, re-run pkill"
# Optional, if this VM is not throwaway and you want the packages gone:
# dnf remove -y systemtap-sdt-dtrace     # Rocky 9.x
```

---

## Curated resources

**Primary docs (authoritative, read as essays not lookups)**

- [bpftrace One-Liner Tutorial](https://bpftrace.org/tutorial-one-liners) and the [reference guide](https://github.com/bpftrace/bpftrace/blob/master/docs/reference_guide.md) — the 12 escalating one-liners are the fastest path from "I know `perf top`" to answering arbitrary live-kernel questions. The reference guide is the definitive language spec (probe types, builtins like `arg0`/`kstack`/`comm`, `hist()`/`lhist()`, map semantics). Start here; everything else builds on this vocabulary.
- [ftrace — Function Tracer, kernel.org](https://docs.kernel.org/trace/ftrace.html) — the built-in tracer driven entirely through `/sys/kernel/tracing`, needing nothing installed. Teaches `function_graph`, the event/tracepoint system, filters and triggers, per-CPU ring buffers. This is the substrate perf and eBPF tracing sit on; knowing the raw tracefs interface means you can trace on a locked-down box.
- [Control Group v2 / eBPF docs — docs.ebpf.io](https://docs.ebpf.io/linux/concepts/verifier/) and the [ringbuf map type page](https://docs.ebpf.io/linux/map-type/BPF_MAP_TYPE_RINGBUF/) — the clearest current reference on the verifier's complexity model and on map types. The ringbuf page states the power-of-two/page-multiple sizing rule and the single-ring-vs-per-CPU ordering guarantee that the perf buffer lacks.
- [BPF and XDP Reference Guide — Cilium](https://docs.cilium.io/en/stable/reference-guides/bpf/) — the best single reference on the eBPF machine model itself: instruction set, why the verifier rejects what it rejects, map types and their locking/memory tradeoffs, tail calls, the tc-vs-XDP hook placement, and the bpffs object-pinning model. Written by the team that pushes eBPF hardest in production.
- [ebpf.io — get started + ecosystem](https://ebpf.io/get-started/) — the community front door; the clearest articulation of programs/maps/helpers/verifier/JIT and specifically the **CO-RE + BTF** portability mechanism (relocations against the running kernel's type info) that made eBPF tooling deployable.
- [man7: strace(1)](https://man7.org/linux/man-pages/man1/strace.1.html), [perf(1) wiki](https://perfwiki.github.io/main/), and the `bpftrace.8` man page — the ABI-level truth for each tool.

**Books (canonical)**

- [BPF Performance Tools — Brendan Gregg](https://www.brendangregg.com/bpf-performance-tools-book.html) (+ the [tools repo](https://github.com/brendangregg/bpf-perf-tools-book)) — 150+ ready-to-run bcc/bpftrace tools organized by subsystem, each with the *methodology* for when to reach for it. The staff-level value is the diagnostic thinking (USE method, off-CPU analysis, symptom→exact-kprobe). This is the observability endgame; live in it.
- [Systems Performance, 2nd ed — Brendan Gregg](https://www.brendangregg.com/systems-performance-2nd-edition-book.html) — the methodology bible. USE method (Utilization/Saturation/Errors per resource), workload characterization, drill-down, and per-subsystem internals. This is the *method*; BPF Performance Tools is the *toolkit*. Read the CPU, memory, and disk chapters alongside labs 3–4.
- [Learning eBPF — Liz Rice](https://github.com/lizrice/learning-ebpf) — the gentlest rigorous on-ramp to *writing* eBPF (not just running tools): hello-world kprobe → maps → tail calls → CO-RE → tc/XDP, with a ready VM config. The bridge to take before the Cilium reference's density.
- [Learning eBPF / BPF internals via the kernel BPF docs](https://docs.kernel.org/bpf/index.html) — the primary source for program types, map types, the verifier, and BTF/CO-RE as the kernel documents them.

**Landmark talks, blog posts, and hubs**

- [Brendan Gregg — Linux Performance hub](https://www.brendangregg.com/linuxperf.html) — the master index tying together his perf examples, ftrace tools, eBPF page, and flame graphs. Use as the map; bookmark the sub-pages ([perf.html](https://www.brendangregg.com/perf.html), [ebpf.html](https://www.brendangregg.com/ebpf.html)) separately.
- [Off-CPU Analysis](https://www.brendangregg.com/offcpuanalysis.html) and [Off-CPU Flame Graphs](https://www.brendangregg.com/FlameGraphs/offcpuflamegraphs.html) — the concept behind Lab 3's second half: measuring blocked time, the half on-CPU profiling can't see. Non-negotiable for latency work.
- [A thorough introduction to bpftrace — Brendan Gregg](https://www.brendangregg.com/blog/2019-08-19/bpftrace.html) — the narrative companion to the one-liner tutorial, with the design rationale for why bpftrace looks like awk.
- [FlameGraph repo — Brendan Gregg](https://github.com/brendangregg/FlameGraph) — the `stackcollapse-*`/`flamegraph.pl` scripts used in Lab 3. Read `stackcollapse-perf.pl` once to understand the folded-stack intermediate format; every profiler now emits it.
- [Full-system dynamic tracing using eBPF and bpftrace — Joyful Bikeshedding](https://www.joyfulbikeshedding.com/blog/2019-01-31-full-system-dynamic-tracing-on-linux-using-ebpf-and-bpftrace.html) — an unusually clear from-first-principles walk of kprobes/uprobes/tracepoints/USDT and how bpftrace wires to each.
- [Taking BPF programs beyond one-million instructions — LWN (2025)](https://lwn.net/Articles/1017116/) — current reporting on the verifier complexity ceiling and the global-functions mitigation; exactly the kind of "your knowledge is going stale" update LWN exists to give.
- [Julia Evans — jvns.ca](https://jvns.ca/) and her strace/tcpdump/perf zines — unmatched for building the reflex of interrogating a live system with standard tools. The [strace zine](https://jvns.ca/blog/2015/04/14/strace-zine/) pairs perfectly with Lab 1.

**Source and tooling**

- [BCC repo](https://github.com/iovisor/bcc) — especially `tools/` and the newer `libbpf-tools/` (CO-RE, no runtime compile). `biolatency`, `offcputime`, `funclatency`, `execsnoop`, `opensnoop`, `tcpconnect`, `runqlat` are the ones to memorize. Read a `libbpf-tools/*.bpf.c` to see a real CO-RE program.
- [bpftrace repo docs](https://github.com/bpftrace/bpftrace/tree/master/docs) — the `tools/` directory is a second library of production one-liners-turned-scripts.
- `bpftool` (ships with `linux-tools`) — `prog show`, `map show/dump`, `btf dump`, `gen skeleton`. The out-of-band window into what's loaded, used in Lab 5.
- [rockyman.org](https://rockyman.org/) — Rocky Linux man-page index. Fast way to confirm which package ships a given tool (`perf`, `trace-cmd`, `strace`, `bpftool`, `bcc-*`) and to check the exact flags for the Rocky release you're on before running any of these labs against a real box.

---

## Senior signal

- **Reaches for the right instrument to falsify a specific hypothesis, and states the expected output first.** "If it's fsync latency I'll see `io_schedule` dominate the off-CPU flame graph; if it's lock contention I'll see `futex`/`mutex` wait stacks. Let me run `offcputime` and check." That's structured, hypothesis-driven troubleshooting versus command-guessing. Mid-level runs `top`, sees 60% CPU, and stops.
- **Knows the average is a lie and instinctively asks for the distribution.** Reflexively produces a latency *histogram* (`hist()`, `biolatency`) and reads the tail, because p99 pain hides inside a healthy mean. Knows that "50% CPU" can conceal severe CFS throttling and that a benign load average can mask a pile of D-state tasks blocked on I/O — and knows which counter is lying.
- **Owns the tracepoint-vs-kprobe stability tradeoff.** Prefers tracepoints and USDT (stable ABI) and understands that a kprobe one-liner is version-fragile because it attaches to whatever the compiler emitted; knows `fexit` beats `kretprobe` (no `maxactive` missed-returns) on 5.5+ kernels.
- **Refuses to `strace` a production daemon.** Understands ptrace's per-syscall double-stop is 100x+ overhead that moves timing and can trip SLAs, and substitutes an in-kernel tracepoint that filters and aggregates with bounded cost.
- **Understands why eBPF is safe and cheap enough for production, mechanically.** Can explain the verifier (memory safety, termination, the ~1M-instruction/state ceiling and how global functions mitigate it), the JIT, per-CPU maps for lock-free aggregation, ring-buffer vs perf-buffer ordering/memory tradeoffs, and CO-RE/BTF as the reason a single pre-built `.o` runs across kernels. Aggregates in-kernel and reads the map once instead of streaming a firehose.
- **Does off-CPU analysis, not just on-CPU profiling.** Knows that CPU flame graphs structurally cannot show blocked/waiting time, and pairs them with scheduler-tracepoint off-CPU flame graphs and `perf sched latency` to account for the *whole* time budget — the difference between "the CPU is busy here" and "the request is slow because it's waiting here."
- **Diagnoses broken stacks instead of trusting a wall of `[unknown]`.** Recognizes missing frame pointers, JIT runtimes without symbol maps, and stripped binaries, and fixes them (`--call-graph dwarf/lbr`, `-fno-omit-frame-pointer`, per-runtime symbol files) rather than concluding "the profiler doesn't work."
- **Traces across subsystem boundaries.** Follows a symptom from syscall → VFS → block layer → device with one coherent set of tools, and reads the coupling (a scheduler stall showing up as I/O latency, a cgroup throttle showing up as run-queue wait) rather than treating each layer as a black box. Knows the raw `/sys/kernel/tracing` interface as the always-available fallback on a hardened host where nothing can be installed.

---

## See also

- [[06 - Networking Deep]] — where XDP/tc eBPF hooks and socket-level tracepoints live; the networking counterpart to the tracing hooks covered here.
- [[09 - The Kernel]] — kprobes, tracepoints, and the `int3`/ftrace trampoline machinery that this module attaches to; the subsystem internals you're interrogating.
- [[03 - Processes, Scheduling and Signals]] — the `sched_switch` tracepoint and run-queue concepts behind Lab 3's off-CPU analysis and `perf sched latency`.
- [[09 - Observability and SRE]] — the SRE methodology (USE method, golden signals, SLOs, latency distributions over averages) that consumes these tracing primitives; this module is the low-level toolkit, that one is the practice.
- [[08 - Observability and Efficiency for ML Infrastructure]] — GPU/training observability and efficiency tuning build on these same tracepoints, histograms, and off-CPU analysis to find data-pipeline stalls and throttling.
- [[08 - Logging Auditing and Detection]] — eBPF as a security-detection sensor (syscall/exec tracing, tamper-evident telemetry) is the cloud-detection counterpart to the tracing hooks here.
- [[05 - Kubernetes Networking and Workloads]] — Cilium's eBPF/XDP dataplane is this machine model (verifier, maps, CO-RE) applied to pod networking and observability.
