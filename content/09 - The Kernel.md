---
title: The Kernel
type: module
track: linux-internals
tags: [linux-internals, kernel, modules, sysfs, procfs, sysctl, ftrace, perf, kaslr, lockdown, secure-boot]
requires: [Rocky 9.x VM with root, "kernel-devel matching $(uname -r) for the module-build lab", "perf + trace-cmd packages and tracefs at /sys/kernel/tracing for the tracing lab", "stress-ng and util-linux (unshare) for the /proc and sysctl labs", "Secure Boot + enrolled MOK only if exercising the module-signing path in §7"]
module_number: 9
status: reviewed
created: 2026-07-08
---

# 09 - The Kernel

Backlink: [[00 - Track Overview]]

> Prior modules taught you the subsystems (scheduler, memory, cgroups, namespaces, block, net, VFS) as separate stories. This module is about the *thing that contains them all*: the kernel as a single deployable artifact and a single running address space. You will learn to read the kernel like a map, load and unload code into a live kernel, tune it through `/proc/sys` and `/sys`, control it from the command line before it even mounts root, build and patch your own, understand the hardening (KASLR, lockdown, Secure Boot, module signing) that constrains what you can do to a production box, and attach live tracers (ftrace, perf) to answer arbitrary questions about a running system with nothing pre-installed. The through-line: everything the kernel exposes to userspace is a *file*, a *syscall*, or a *boot-time decision*, and a staff engineer knows which one they're touching and what it costs.

---

## Concept deep-dive

### 1. What the kernel actually is on disk and in memory

There are two artifacts and one running image, and conflating them is a classic mid-level mistake.

- **`vmlinux`** — the raw, uncompressed, statically-linked ELF executable of the kernel, with full symbols. This is what you feed to `gdb`, `crash`, `pahole`, and `objdump`. It is *not* what boots. On RHEL/Rocky it ships (stripped) in `kernel-debuginfo`; the build tree leaves it at the top of the source dir.
- **`vmlinuz` / `bzImage`** — the *bootable* image: `vmlinux` stripped, then compressed (gzip/xz/zstd, chosen by `CONFIG_KERNEL_*`), wrapped in a small self-decompressing stub plus the real-mode/EFI setup code. On x86 this is the `bzImage` ("big zImage"). The bootloader loads this; the stub decompresses the payload into memory (into a KASLR-chosen slot, see below) and jumps to it.
- **The running image** — after decompression the kernel lives in kernel virtual address space (on x86-64, the top of the 64-bit canonical range, e.g. `0xffffffff80000000+` for the kernel text with the default mapping). It is *never swapped*, its text is normally read-only (`CONFIG_STRICT_KERNEL_RWX`), and userspace can only touch it through the syscall boundary, the trap/fault handlers, or the pseudo-filesystems.

```
 on-disk boot artifact                     running kernel (single address space)
 ┌────────────────────────────┐            ┌───────────────────────────────────┐
 │ bzImage / vmlinuz          │            │  .text (RO+X)  syscalls, subsystems │
 │  ┌──────────────────────┐  │  decomp    │  .rodata(RO)                        │
 │  │ setup / EFI stub     │  │ ───────►   │  .data / .bss (RW)                  │
 │  │ compressed payload ──┼──┼──►vmlinux  │  percpu areas                       │
 │  └──────────────────────┘  │  (KASLR    │  vmalloc region  ← modules live here│
 └────────────────────────────┘  slot)     │  direct map (all phys RAM)          │
                                            │  fixmap / vsyscall / vDSO           │
 initramfs (separate cpio.gz) ─────────────► unpacked into a tmpfs rootfs first  │
                                            └───────────────────────────────────┘
```

The kernel is a **monolithic** kernel with **loadable modules**: subsystems are compiled in (`y`) or built as `.ko` objects (`m`) that are linked into the *same address space* at load time. There is no protection boundary between a module and core kernel: a buggy module can corrupt anything. "Monolithic" is the architecture; "modular" is a deployment convenience, not an isolation mechanism.

The **System.map** (and the in-memory `/proc/kallsyms`) is the symbol table: name → virtual address. This is the "map" you read the kernel with. `/proc/kallsyms` shows `0000000000000000` for every address unless you are root *and* `kptr_restrict` allows it (see §5) — that zeroing is a KASLR/info-leak defense, not a bug.

### 2. Loadable modules: the mechanism

A `.ko` is a **relocatable ELF object** (not a shared library, not an executable) plus special sections the kernel's loader understands:

- `.modinfo` — a blob of NUL-separated `key=value` strings: `vermagic`, `depends`, `author`, `license`, `parm=...`, `alias=...`. Read it with `modinfo foo.ko`.
- `__versions` (when `CONFIG_MODVERSIONS=y`) — CRCs of every symbol the module imports, for ABI checking.
- `.gnu.linkonce.this_module` — the `struct module` template.
- Appended module signature (see §7) — PKCS#7 blob glued *after* the ELF, with a magic marker `~Module signature appended~\n` at the very end.

**Load path (the syscalls):**

- `init_module(2)` — takes the module image already in a userspace buffer. Legacy.
- `finit_module(2)` — takes an *fd* to the `.ko` file plus flags. This is what modern `modprobe`/`insmod` use, because it lets the kernel read the file directly (needed for IMA appraisal and signature checking against the on-disk bytes, and it avoids a userspace copy). `strace insmod` on any modern distro shows `finit_module`, not `init_module`.

Inside the kernel, `load_module()` (in `kernel/module/main.c`, formerly `kernel/module.c`) does: copy in → sanity-check the ELF → **check vermagic** (kernel version, SMP, preemption, module-versioning flags must match — this is why a module built for `6.6.0` refuses to load on `6.6.1` unless MODVERSIONS smooths it) → **verify signature** if required → **resolve symbols** against the kernel's exported symbol table (`__ksymtab`, populated by `EXPORT_SYMBOL`/`EXPORT_SYMBOL_GPL`) → apply ELF relocations to place the code in the `vmalloc` region → run the module's `init` function → add to the global module list.

`insmod` is dumb: it loads exactly the file you name, no dependency resolution. `modprobe` is smart: it reads `/lib/modules/$(uname -r)/modules.dep` (generated by `depmod` from each module's `depends=` modinfo) and loads the dependency closure in order. `modules.alias` maps PCI/USB/etc. device IDs and `MODULE_ALIAS()` strings to module names — this is how udev autoloads a driver when a device appears (`modprobe` gets called with an alias like `pci:v00008086d...`).

**Unloading** (`delete_module(2)`, i.e. `rmmod`) only succeeds if the module refcount is zero. Refcounts are bumped by `try_module_get()` (e.g. an open fd to a device the module owns, a mounted filesystem of that type, another module depending on it). `lsmod`'s third column *is* that refcount; the fourth is the list of users. A module can also be `[permanent]` (no exit function) and never removable.

**Failure modes worth internalizing:**
- `Invalid module format` + `dmesg` shows `vermagic` mismatch → built against wrong headers.
- `Unknown symbol in module` → it imports a symbol the running kernel doesn't export (or a GPL-only symbol from a proprietary module).
- `Required key not available` → signature enforcement is on and the key isn't in the kernel keyring (see §7). *This is the single most common Secure Boot support ticket.*
- `Module ... is in use` → nonzero refcount; find the user in `lsmod`'s last column.
- Taints the kernel (`/proc/sys/kernel/tainted`) — an out-of-tree (`O`), unsigned (`E`), or proprietary (`P`) module sets taint bits that engineering will ask about on any bug report. `cat /proc/sys/kernel/tainted` decoded via the bitmask in `Documentation/admin-guide/tainted-kernels.rst`.

**Module parameters** live at `/sys/module/<mod>/parameters/<param>`. Set at load (`modprobe foo debug=1`), persistently via `/etc/modprobe.d/*.conf` (`options foo debug=1`), or on the kernel cmdline as `foo.debug=1`. Whether a param is writable at runtime depends on the permission mask passed to `module_param()` (e.g. `0644` → world-readable, root-writable via sysfs). Not all params are runtime-mutable; many are `0444`.

### 3. procfs, sysfs, and the rest of the pseudo-filesystem zoo

These are **not real filesystems**; they are kernel data structures projected as files. Reads/writes are `->read`/`->write` callbacks that run kernel code. Understanding *which* interface owns *what* is a real senior differentiator.

| Mount | Backing | Purpose | ABI stability |
|---|---|---|---|
| `/proc` (`procfs`) | per-process + global | Process state (`/proc/PID/*`), global tunables under `/proc/sys`, legacy dumping ground (`/proc/meminfo`, `/proc/interrupts`, `/proc/kallsyms`, `/proc/cmdline`) | Mostly stable, but a historical grab-bag |
| `/sys` (`sysfs`) | kobject tree | Device model, module info, per-device/-driver attributes, `/sys/fs/cgroup` (cgroup v2), power, firmware | **Documented ABI** in `Documentation/ABI/{stable,testing,obsolete}` — one attribute per file |
| `/sys/kernel/tracing` (`tracefs`) | ftrace | The tracing control plane (§8) | Interface stable |
| `/sys/kernel/debug` (`debugfs`) | ad-hoc | Developer debugging, *no ABI guarantee*, blocked under lockdown | **None** — can change any release |
| `/proc/sys` (`sysctl`) | ctl_table tree | Tunable knobs (§4) | Stable-ish |

**sysfs is the projection of the driver model.** The unit is the **kobject** (`struct kobject`: a name, a refcount `kref`, a parent pointer, a `kobj_type`). A directory in `/sys` *is* a kobject. A file in it is a **kobject attribute** whose show/store ops are defined by the kobject's `kobj_type->sysfs_ops`. A **kset** is a collection of kobjects that also emits **uevents** (the netlink messages udev listens to). Source of truth: `docs.kernel.org/core-api/kobject.html` and `Documentation/filesystems/sysfs.rst`. The rule "one value per file" is enforced by convention and is *why* sysfs is scriptable and greppable in a way `/proc/meminfo` (many values, one file) is not.

The symlink web in `/sys` encodes the same object graph from multiple views: `/sys/bus/pci/devices/<addr>` → `../../../devices/pci0000:00/...` (physical topology), `/sys/class/net/eth0/device` → the PCI device, `/sys/block/sda/queue/scheduler` (the I/O scheduler knob you met in the storage module). Following symlinks in `/sys` is reading the kobject parent/child and bus/class/device relationships.

`/proc/PID/` is the forensics goldmine: `status` (state, caps, `NSpid`, `VmRSS`), `stat` (the raw scheduler/mm fields), `maps`/`smaps` (VMA layout), `fd/` (open descriptors — count them to find fd leaks), `cgroup` (which cgroups this task is in), `stack` (kernel stack if `CONFIG_STACKTRACE`), `wchan` (what kernel function a D-state task is blocked in), `environ`, `limits`. A task stuck in `D` (uninterruptible sleep) with `wchan` pointing into the I/O path is the "healthy load average hides blocked-on-I/O tasks" senior tell from the track intro.

### 4. sysctl and the ctl_table tree

`sysctl` knobs are the same objects viewed two ways: `sysctl net.ipv4.tcp_syncookies` and `cat /proc/sys/net/ipv4/tcp_syncookies` hit the identical `ctl_table` entry (`.` ↔ `/`). The registration lives in each subsystem (`net/ipv4/sysctl_net_ipv4.c`, `kernel/sysctl.c`, `mm/`, etc.).

Precedence and persistence are where people get burned:
- Runtime: `sysctl -w key=val` or `echo val > /proc/sys/...` — **not persistent**.
- Persistent: files in a *strict load order* — `/etc/sysctl.d/*.conf`, `/run/sysctl.d/*.conf`, `/usr/lib/sysctl.d/*.conf`, then `/etc/sysctl.conf` last. `systemd-sysctl.service` applies these at boot. Within a directory, files load in lexical order; a later file wins. `sysctl --system` shows the exact order and which file set each value.
- **Namespaced sysctls**: many `net.*` knobs are *per-network-namespace*. Setting `net.ipv4.ip_forward` inside a container's netns does not touch the host. `kernel.*` and most `vm.*` are global (not namespaced), which is why a container can't set `vm.max_map_count` for itself on older kernels — a real production gotcha for Elasticsearch-in-a-container.

`sysctl -a` dumps everything; grep it. `sysctl -w` failing with `permission denied` on a `net.*` key inside a container is usually a read-only `/proc/sys` mount (the runtime masked it), not a capability problem.

### 5. Kernel command line: controlling the kernel before it can defend itself

`/proc/cmdline` shows what you booted with. The bootloader (GRUB2 on RHEL/Rocky) hands this string to the kernel; some params are consumed by the kernel core, some by subsystems, some are `module.param=value` forms (§2), and anything the kernel doesn't recognize is passed to PID 1 as environment/args (`systemd.*` params, or `init=`).

High-value params a staff engineer reaches for:

- `root=`, `rootflags=`, `ro`/`rw` — where and how the real root mounts (after initramfs pivots).
- `rd.break`, `rd.break=pre-mount`, `rd.debug`, `rd.shell` — drop to the **dracut/initramfs emergency shell** at a chosen hook. `rd.break` (root password not yet needed) is the canonical "I locked myself out / broke `/etc/fstab` / need to reset root password" recovery.
- `systemd.unit=rescue.target` / `emergency.target`, or the bare `1`/`single` — bring up minimal userspace.
- `nokaslr` — disable KASLR (§6), required to use fixed-address kernel debugging or to correlate a crash address across boots.
- `lsm=...` — order and selection of LSMs including `lockdown` (§7).
- `mitigations=off` / `=auto` / `=auto,nosmt` — master switch for CPU-vuln mitigations (Spectre/Meltdown/MDS/etc.). `mitigations=off` is a huge perf lever and a huge security foot-gun; know the tradeoff cold.
- `isolcpus=`, `nohz_full=`, `rcu_nocbs=` — CPU isolation for latency-sensitive/HPC workloads (ties to the scheduler module).
- `crashkernel=` — reserve memory for the kdump capture kernel (§ forensics; ties to the crash module).
- `kptr_restrict`, `slab_nomerge`, `init_on_alloc=1`, `page_poison=1`, `debugfs=off` — hardening knobs.
- `console=ttyS0,115200 earlyprintk=/earlycon=` — get log output *before* the console driver is up; indispensable when the kernel dies during early boot.
- `panic=N` — reboot N seconds after a panic (with `0` = hang forever, the default; set to e.g. `10` in prod so a panicked node reboots).

The mental model: the cmdline is your only lever *before* any config file, any service, any filesystem is available. It's the layer you debug boot failures from.

### 6. KASLR

`CONFIG_RANDOMIZE_BASE` (on by default since 4.12; also `CONFIG_RANDOMIZE_MEMORY` randomizes the direct map / vmalloc / vmemmap base offsets). At boot the decompression stub picks a random slot for the kernel image from the available physical memory (constrained by alignment and by avoiding reserved regions), so the kernel text base differs every boot. Defeats exploits that hardcode kernel symbol addresses (ROP/ret2kernel).

Consequences you must know:
- `/proc/kallsyms` addresses change every boot; with `kptr_restrict=1` non-root sees zeros, `=2` everyone sees zeros. A crash dump address is meaningless without the *KASLR offset for that boot* — `crash` and `dmesg` record it (`Kernel Offset: 0x... from 0xffffffff81000000`), and you must feed it to symbol resolution.
- KASLR entropy on x86-64 is limited (a few hundred slots historically) and has been the subject of many side-channel breaks (TLB timing, prefetch, EntryBleed against KPTI). It raises cost, it is not a wall.
- Disable with `nokaslr` when you need reproducible addresses for live `gdb`/`crash` work against a known kernel, or when a hypervisor/debug setup requires it.
- `kexec`/kdump: the capture kernel is a *separate* image and can be loaded with `nokaslr` for predictable analysis.

### 7. Lockdown, Secure Boot, and module signing (the production hardening stack)

These three are separate mechanisms that are usually deployed together, and support engineers must be able to disentangle them.

**Secure Boot** is a *firmware/UEFI* feature: the firmware verifies the bootloader's signature against keys in the platform's `db` (allowed) / `dbx` (revoked) key databases. On RHEL/Rocky the chain is `shim` (signed by Microsoft's UEFI CA, the near-universal trust anchor) → `GRUB2` → kernel. shim also introduces the **MOK** (Machine Owner Key) list, which lets a local admin enroll their own signing key via `mokutil` + a reboot-time MokManager prompt, *without* touching firmware keys.

**Module/kernel signature verification** (kernel feature, `CONFIG_MODULE_SIG*`): the kernel keeps keyrings — the built-in `.builtin_trusted_keys` (compiled into `vmlinux`), `.secondary_trusted_keys`, and on UEFI the `.platform` keyring populated from firmware `db` + enrolled MOKs. A module's appended PKCS#7 signature (§2) is verified against these. `CONFIG_MODULE_SIG_FORCE=y` (or the `module.sig_enforce=1` cmdline) makes an unsigned/badly-signed module fail with `Required key not available`. This is why a third-party or self-built driver (NVIDIA, a patched NIC driver) won't load on a Secure Boot box until you sign it with an enrolled MOK — the fix is `/usr/src/kernels/.../scripts/sign-file sha256 MOK.priv MOK.der module.ko` after `mokutil --import MOK.der`.

**Lockdown** (`CONFIG_SECURITY_LOCKDOWN_LSM`, an LSM enabled via `lsm=...,lockdown` and/or auto-activated when Secure Boot is on) closes the *userspace-to-kernel* back doors that would let root modify or read the running kernel and thereby bypass the signature chain. Two modes:

- **`integrity`** — blocks anything that lets userspace *modify* the running kernel: unsigned module load, `kexec` of unsigned images, unencrypted hibernation, `/dev/mem` `/dev/kmem` `/dev/kcore` `/dev/ioports`, direct PCI BAR access, `ioperm`/`iopl`, MSR writes, raw ACPI table override, and certain `debugfs`/BPF/kprobe operations that can write kernel memory.
- **`confidentiality`** — everything integrity blocks, *plus* things that let userspace *read* kernel secrets (which could leak the KASLR offset or signing material): further restricts `bpf`, `perf`, kprobes, and kernel-memory reads.

Runtime behavior: lockdown can only be *tightened* at runtime (`echo confidentiality > /sys/kernel/security/lockdown`), **never loosened** without a reboot. The log line is `Lockdown: <prog>: <feature> is restricted; see man kernel_lockdown.7`. The senior implication: on a Secure Boot + lockdown box, `bpftrace`, `perf probe`, `/dev/mem` tools, and unsigned modules may *silently* be off the table for live debugging — you need to know this *before* an incident, and you need the alternative (signed tools, ftrace which is generally still allowed, or a maintenance-window reboot with lockdown off).

### 8. Live tracing entry points: ftrace and perf

The kernel is instrumented from the factory. You do not need to rebuild or restart it to watch it work.

**ftrace** is the in-kernel tracer, driven entirely through **tracefs** at `/sys/kernel/tracing` (older path `/sys/kernel/debug/tracing`). No tools required — it's all `echo`/`cat`. Core mechanism: the compiler emits a `mcount`/`__fentry__` call at the start of (almost) every kernel function (`CONFIG_FUNCTION_TRACER`); ftrace patches these NOPs at runtime to detour into the tracer. The important files:

- `available_tracers` / `current_tracer` — select `function`, `function_graph` (shows call nesting + per-function duration), `wakeup`/`wakeup_rt` (scheduler latency), `irqsoff`/`preemptoff` (longest IRQ/preempt-disabled region), `nop`.
- `set_ftrace_filter` / `set_ftrace_notrace` — restrict to functions matching a glob (e.g. `echo 'ext4_*' > set_ftrace_filter`), because tracing *every* function is a firehose.
- `trace` (snapshot) / `trace_pipe` (draining stream), `tracing_on` (master switch).
- `available_events` + the `events/` tree — the hundreds of **static tracepoints** (stable, kernel-defined hook points: `sched:sched_switch`, `block:block_rq_issue`, `syscalls:sys_enter_openat`). Enable one with `echo 1 > events/sched/sched_switch/enable`. Tracepoints are the *stable* substrate; kprobes (dynamic, patched-in via `int3`) reach anything but can break across versions.
- `kprobe_events` / `uprobe_events` — define dynamic probes from userspace text.

ftrace is the tracer you can always use on a locked-down box with nothing installed. That property alone makes it worth mastering.

**perf** (`tools/perf` in the tree, `perf_event_open(2)` under the hood) is the sampling/counting profiler and the front door to hardware PMU counters, software events, tracepoints, and dynamic probes:
- `perf stat` — count events (cycles, instructions, cache-misses, context-switches, page-faults) for a command or system-wide. IPC (instructions/cycle) instantly tells you compute-bound vs. stalled.
- `perf record -g` / `perf report` — sampled call-graph profiling → flame graphs. `-g` needs frame pointers or DWARF/LBR unwinding.
- `perf sched record` / `perf sched latency` — scheduler runqueue latency, the tool that proves CFS/cgroup throttling from the intro ("50% CPU hiding throttling").
- `perf probe` — create a dynamic tracepoint at an arbitrary function/line/variable, then record it (subject to lockdown).
- `perf top` — live sampling profile.

The relationship: tracepoints are shared substrate; ftrace and perf and eBPF/bpftrace all consume them. eBPF (bpftrace/bcc, covered in the observability module) is the programmable layer on top. The discipline is *hypothesis-driven*: pick the tool that will confirm or falsify a specific claim, and state the expected output beforehand.

### 9. Building and patching a kernel

The workflow, mechanism-first:

1. **Get a config.** Never start from `make defconfig` on a real machine. Start from your running config (`/proc/config.gz` if `CONFIG_IKCONFIG_PROC`, or `/boot/config-$(uname -r)`), then `make olddefconfig` to fill new symbols with defaults, or `make localmodconfig` to *prune* to only the modules currently loaded (`lsmod`) — cutting build time from hours to minutes by not building thousands of unused drivers. `make menuconfig`/`nconfig` for interactive edits; the result is `.config`, and Kconfig dependency resolution (`select`/`depends on`) is why you can't just set a symbol without its prerequisites.
2. **Build.** `make -j$(nproc)` builds `vmlinux` + `bzImage` + modules. `make modules_install` drops `.ko`s into `/lib/modules/$(uname -r)/` and runs `depmod`. `make install` copies the image to `/boot` and (via the distro's kernel-install hooks) regenerates the initramfs and GRUB entries. Distro-packaged builds: `make bindeb-pkg` (Debian `.deb`) or `make binrpm-pkg`/`make rpm-pkg` (RPM) produce installable packages instead — the *correct* way to deploy a custom kernel to a fleet, because it's tracked by the package manager (ties to the "don't edit package-owned files" rule; a package-built kernel is upgradeable and removable).
3. **Patch.** `patch -p1 < fix.patch` (or `git am` on a git tree). `-p1` strips the leading `a/`,`b/` path component that `git diff` emits — the single most common `patch` mistake. Rebuild only the touched objects (make is incremental). For a targeted fix, `git bisect` between a known-good and known-bad tag is how you find *which commit* introduced a regression, and it's a genuine staff-level skill.
4. **`LOCALVERSION`** (or `CONFIG_LOCALVERSION`) tags your build (`6.6.0-mytest`) so `uname -r`, the modules dir, and GRUB entries don't collide with the distro kernel.

Scale/failure notes: a full allmodconfig build is ~50GB and can take an hour+; `localmodconfig` + `ccache` is how you iterate. `vermagic` (§2) means modules and vmlinux are a matched set — you cannot mix a distro module into your custom kernel. The `Module.symvers` file carries the symbol CRCs for MODVERSIONS across builds.

---

## Hands-on labs

> All labs assume a **throwaway VM** you can crash and rebuild (a cloud instance, `multipass launch`, `vagrant`, or a local VM). Commands are shown for a Debian/Ubuntu base and a RHEL/Rocky base where they diverge; pick the ones matching your VM. Run as root or with `sudo`. **Do not run these on a machine you care about** — several intentionally taint the kernel and one deliberately breaks module loading.

### Lab 1 — Author, load, break, and introspect a kernel module

**Objective.** Build a minimal `.ko`, watch the exact syscalls `insmod`/`modprobe` use, drive it via a runtime-writable module parameter through `/sys/module/...`, observe the taint and refcount mechanics, and trigger the two canonical load failures (`vermagic` mismatch and unknown symbol).

**Setup.**

```bash
# Debian/Ubuntu
sudo apt-get update
sudo apt-get install -y build-essential linux-headers-$(uname -r) strace kmod
# RHEL/Rocky
sudo dnf install -y gcc make kernel-devel-$(uname -r) strace kmod

mkdir -p ~/lab_mod && cd ~/lab_mod
```

**Steps.**

1. Write the module. It exposes a runtime-writable parameter and logs on load/unload:

```bash
cat > hello.c <<'EOF'
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/moduleparam.h>

static int loudness = 1;
module_param(loudness, int, 0644);        /* 0644 => writable via sysfs by root */
MODULE_PARM_DESC(loudness, "how loud to be");

static int __init hello_init(void)
{
    pr_info("lab_mod: loaded, loudness=%d\n", loudness);
    return 0;
}
static void __exit hello_exit(void)
{
    pr_info("lab_mod: unloaded\n");
}
module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("lab");
MODULE_DESCRIPTION("throwaway lab module");
EOF

cat > Makefile <<'EOF'
obj-m := hello.o
KDIR  := /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

make
```

2. Inspect the artifact before loading. Note the `vermagic`, the `parm`, and the license:

```bash
modinfo hello.ko
```

3. Load it while tracing the syscall. Confirm it uses `finit_module`, not `init_module`:

```bash
sudo strace -e trace=init_module,finit_module,delete_module insmod hello.ko loudness=5
sudo dmesg | tail -3
```

4. Observe it in the running kernel and drive its parameter through sysfs at runtime:

```bash
lsmod | grep hello                       # refcount (col 3) is 0, no users
cat /sys/module/hello/parameters/loudness # => 5
echo 42 | sudo tee /sys/module/hello/parameters/loudness
cat /sys/module/hello/parameters/loudness # => 42, live-changed, no reload
cat /sys/module/hello/taint 2>/dev/null; cat /proc/sys/kernel/tainted
```

5. Break it two ways. First, an **unknown symbol** — add a call to a non-exported function, rebuild, load, and read the precise dmesg reason:

```bash
sed -i 's|return 0;\n}|extern void this_symbol_does_not_exist(void);\n    this_symbol_does_not_exist();\n    return 0;\n}|' hello.c 2>/dev/null || \
  perl -0pi -e 's/return 0;\n\}/extern void this_symbol_does_not_exist(void);\n    this_symbol_does_not_exist();\n    return 0;\n}/' hello.c
make 2>&1 | tail -5     # note: WARNING: "this_symbol_does_not_exist" undefined
sudo rmmod hello 2>/dev/null
sudo insmod hello.ko ; echo "exit=$?"
sudo dmesg | tail -3    # => "Unknown symbol this_symbol_does_not_exist"
```

6. Now a **vermagic mismatch**: hand-corrupt the vermagic and watch the format rejection (this proves the version-gate is a string compare, not magic):

```bash
# revert the symbol break first
perl -0pi -e 's/extern void this_symbol_does_not_exist\(void\);\n    this_symbol_does_not_exist\(\);\n//' hello.c
make
# forge the vermagic string inside the .ko
cp hello.ko hello_bad.ko
CUR=$(modinfo -F vermagic hello.ko | awk '{print $1}')
python3 - <<PY
data=open("hello_bad.ko","rb").read()
data=data.replace(b"vermagic=$CUR", b"vermagic=0.0.0-fake")
open("hello_bad.ko","wb").write(data)
PY
sudo insmod hello_bad.ko ; echo "exit=$?"
sudo dmesg | tail -2    # => "version magic ... should be ..." / Invalid module format
```

**Prove it.** The following one-liner shows the module loaded, its refcount, and that its parameter is the value you last wrote through sysfs — confirming you controlled a live kernel data structure from userspace without a reload:

```bash
sudo rmmod hello 2>/dev/null; sudo insmod hello.ko loudness=7
echo 99 | sudo tee /sys/module/hello/parameters/loudness >/dev/null
printf 'loaded=%s refcnt=%s param=%s\n' \
  "$(lsmod | awk '/^hello/{print "yes"}')" \
  "$(lsmod | awk '/^hello/{print $3}')" \
  "$(cat /sys/module/hello/parameters/loudness)"
# expected: loaded=yes refcnt=0 param=99
sudo rmmod hello
```

**Teardown.** Unload any lab module still resident and remove the build tree. The taint bit set by loading an out-of-tree module only clears on reboot, so reboot the throwaway VM if you need a clean `/proc/sys/kernel/tainted`.

```bash
sudo rmmod hello 2>/dev/null; sudo rmmod hello_bad 2>/dev/null
rm -rf ~/lab_mod
cat /proc/sys/kernel/tainted   # nonzero until reboot if a module was loaded
```

### Lab 2 — Read the kernel like a map: /proc, /sys, kallsyms, and the D-state hunt

**Objective.** Use the pseudo-filesystems as a forensic surface: resolve a running symbol from `/proc/kallsyms`, walk the sysfs kobject/device graph by following symlinks, and reproduce the "healthy load average hides blocked-on-I/O tasks" scenario by manufacturing a D-state task and reading *where in the kernel* it is stuck via `/proc/PID/wchan` and `/proc/PID/stack`.

**Setup.**

```bash
# tools available on any base image
command -v stress-ng || sudo apt-get install -y stress-ng || sudo dnf install -y stress-ng
```

**Steps.**

1. Confirm what you booted with and the KASLR offset in play:

```bash
cat /proc/cmdline
sudo dmesg | grep -i 'kernel offset' || echo "no offset line (nokaslr or not logged)"
```

2. Read the symbol map. See kptr_restrict censor it, then (as root) resolve a real address:

```bash
grep ' sys_call_table\| commit_creds\|T do_sys_openat2' /proc/kallsyms | head
cat /proc/sys/kernel/kptr_restrict
# as non-root many addresses show as 0000000000000000; as root they resolve
```

3. Walk the device model by following sysfs symlinks. Pick your root disk and traverse from the block device up to the physical bus:

```bash
DISK=$(lsblk -ndo pkname $(findmnt -no SOURCE /) 2>/dev/null || echo sda)
ls -l /sys/class/block/$DISK/device 2>/dev/null
readlink -f /sys/class/block/$DISK 2>/dev/null
cat /sys/block/$DISK/queue/scheduler        # the I/O scheduler knob, one-value-per-file
cat /sys/block/$DISK/queue/rotational        # 0=SSD/NVMe, 1=spinning — a kobject attribute
```

4. Manufacture the invisible failure. Create heavy uninterruptible I/O and observe that load average climbs while these tasks are *not* consuming CPU:

```bash
# Run background I/O that spends time in D-state
stress-ng --hdd 4 --hdd-bytes 1G --timeout 60s &
sleep 5
uptime                                   # load average is high
# Find D-state tasks and where in the kernel they are blocked:
ps -eo pid,stat,wchan:32,comm | awk '$2 ~ /D/'
```

5. For one blocked PID, read its kernel-side blocking point precisely:

```bash
DPID=$(ps -eo pid,stat --no-headers | awk '$2 ~ /D/ {print $1; exit}')
echo "D-state pid: $DPID"
cat /proc/$DPID/wchan; echo
sudo cat /proc/$DPID/stack 2>/dev/null | head    # kernel stack: the exact call chain
cat /proc/$DPID/status | grep -E 'State|VmRSS'
```

**Prove it.** Show simultaneously that CPU is *not* the bottleneck (idle time is high) while load average is elevated *because* of D-state tasks — the exact reading a senior gives that a "CPU is only 30%, we're fine" mid-level misses:

```bash
NR_D=$(ps -eo stat --no-headers | grep -c '^D')
LOAD=$(cut -d' ' -f1 /proc/loadavg)
IDLE=$(grep 'cpu ' /proc/stat | awk '{print $5/($2+$3+$4+$5+$6+$7+$8)*100}')
printf 'loadavg=%s  D-state tasks=%s  cpu_idle=%.0f%%\n' "$LOAD" "$NR_D" "$IDLE"
# expected while stress-ng runs: load high, several D tasks, idle still substantial
kill %1 2>/dev/null; wait 2>/dev/null
```

### Lab 3 — sysctl and kernel cmdline: layered config, namespaces, and reboot-time levers

**Objective.** Prove the `/proc/sys` ↔ `sysctl` identity, demonstrate the drop-in load-order precedence, show that a `net.*` sysctl is *per-network-namespace* (so a container can't see the host's value), and read the runtime-vs-persistent distinction that causes "it worked until reboot" tickets.

**Setup.**

```bash
sudo sysctl --version
command -v unshare || sudo apt-get install -y util-linux || true
```

**Steps.**

1. Prove the two views are one object:

```bash
sysctl net.ipv4.ip_forward
cat /proc/sys/net/ipv4/ip_forward
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null
sysctl net.ipv4.ip_forward            # => 1, same object, changed via the /proc face
```

2. Demonstrate drop-in precedence and the exact apply order:

```bash
echo 'net.ipv4.ip_forward = 0' | sudo tee /etc/sysctl.d/10-lab.conf >/dev/null
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-lab.conf >/dev/null
sudo sysctl --system 2>&1 | grep -A0 'ip_forward\|lab.conf'
sysctl net.ipv4.ip_forward            # 99- file wins over 10- (lexical, later wins) => 1
```

3. Show a `net.*` sysctl is namespaced. Enter a fresh network namespace and see it revert to the kernel default, independent of the host value you set:

```bash
sysctl net.ipv4.ip_forward                       # host: 1 (from step 2)
sudo unshare --net sysctl net.ipv4.ip_forward     # new netns: 0 (default), host unaffected
# and setting it inside the ns does NOT change the host:
sudo unshare --net sh -c 'sysctl -w net.ipv4.ip_forward=1 >/dev/null; sysctl net.ipv4.ip_forward'
sysctl net.ipv4.ip_forward                        # host still 1, untouched by the ns
```

4. Contrast with a **global** (non-namespaced) sysctl to feel the difference:

```bash
sudo unshare --net cat /proc/sys/vm/swappiness    # same as host — vm.* is global
cat /proc/sys/vm/swappiness
```

5. Read the reboot-time levers without rebooting (inspection only, so the lab stays non-destructive). Identify how you *would* drop to an emergency shell and what KASLR/lockdown state you're in:

```bash
grep -o 'crashkernel=[^ ]*\|mitigations=[^ ]*\|nokaslr\|lsm=[^ ]*' /proc/cmdline || echo "none of those set"
cat /sys/kernel/security/lockdown 2>/dev/null || echo "lockdown LSM not active"
# The bracketed value in that file is the CURRENT mode; others are selectable-tighter-only.
```

**Prove it.** One block that demonstrates the namespace isolation and the persistence layering together, which is the combination behind most sysctl support tickets:

```bash
HOST=$(sysctl -n net.ipv4.ip_forward)
NS=$(sudo unshare --net sysctl -n net.ipv4.ip_forward)
WINNER=$(sudo sysctl --system 2>&1 | grep -o '/etc/sysctl.d/[0-9]*-lab.conf' | tail -1)
printf 'host_ip_forward=%s  fresh_netns_ip_forward=%s  last_applied_dropin=%s\n' "$HOST" "$NS" "$WINNER"
# expected: host_ip_forward=1  fresh_netns_ip_forward=0  last_applied_dropin=/etc/sysctl.d/99-lab.conf
sudo rm -f /etc/sysctl.d/10-lab.conf /etc/sysctl.d/99-lab.conf
```

**Teardown.** Remove the drop-in files (idempotent with the prove-it step) and reset the runtime value you changed on the host back to the kernel default. The netns changes were ephemeral and vanished with the namespace.

```bash
sudo rm -f /etc/sysctl.d/10-lab.conf /etc/sysctl.d/99-lab.conf
echo 0 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null   # back to default; reapply your real config with: sudo sysctl --system
```

### Lab 4 — Live tracing with ftrace and perf: make the invisible visible, no rebuild

**Objective.** Use only in-kernel machinery to watch the kernel work: enable a static tracepoint through raw tracefs, capture a function-graph trace of a real syscall path, and use `perf` to prove a workload's IPC and to catch scheduler wakeups. This is the "answer arbitrary questions on a locked box" skill.

**Setup.**

```bash
# Debian/Ubuntu
sudo apt-get install -y linux-perf trace-cmd || sudo apt-get install -y linux-tools-$(uname -r) trace-cmd
# RHEL/Rocky
sudo dnf install -y perf trace-cmd
sudo mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
cd /sys/kernel/tracing
```

**Steps.**

1. Survey what the running kernel already exposes. No module, no rebuild:

```bash
wc -l available_events                 # hundreds of static tracepoints
cat available_tracers                  # function, function_graph, wakeup, irqsoff, nop, ...
```

2. Enable the `sched_switch` static tracepoint the raw way and watch context switches live, then turn it off:

```bash
echo 1 | sudo tee events/sched/sched_switch/enable >/dev/null
sudo cat trace_pipe | head -20         # ctrl-C or it streams; each line is a real switch
echo 0 | sudo tee events/sched/sched_switch/enable >/dev/null
```

3. Function-graph trace the `openat` path, filtered so it's not a firehose. This shows call nesting and per-function timing inside the kernel:

```bash
echo function_graph | sudo tee current_tracer >/dev/null
echo 'do_sys_openat2' | sudo tee set_graph_function >/dev/null
echo 1 | sudo tee tracing_on >/dev/null
cat /etc/hostname >/dev/null            # trigger an openat
echo 0 | sudo tee tracing_on >/dev/null
sudo head -40 trace                     # the kernel-side call tree of open(2)
# reset
echo nop | sudo tee current_tracer >/dev/null
echo | sudo tee set_graph_function >/dev/null
```

4. Switch to perf. Measure IPC to distinguish compute-bound from stalled — the reading a senior gives instead of "CPU is busy":

```bash
perf stat -- dd if=/dev/zero of=/dev/null bs=1M count=200000 2>&1 | \
  grep -E 'instructions|cycles|insn per cycle|task-clock'
```

5. Catch scheduler behavior with perf's sched tooling (proves runqueue latency, the throttling tell):

```bash
sudo perf sched record -- sleep 3 2>/dev/null
sudo perf sched latency 2>/dev/null | head -20   # per-task avg/max scheduling delay
rm -f perf.data*
```

**Prove it.** Show that you drove a specific kernel code path with ftrace (the trace names the in-kernel functions of `open(2)`) and that perf attributes real hardware counters to a workload — both without loading a module or restarting anything:

```bash
cd /sys/kernel/tracing
echo function | sudo tee current_tracer >/dev/null
echo 'vfs_open' | sudo tee set_ftrace_filter >/dev/null
echo 1 | sudo tee tracing_on >/dev/null; cat /etc/hostname >/dev/null; echo 0 | sudo tee tracing_on >/dev/null
HIT=$(sudo grep -c vfs_open trace)
IPC=$(perf stat -- sleep 0.2 2>&1 | awk '/insn per cycle/{print $4}')
echo nop | sudo tee current_tracer >/dev/null; echo | sudo tee set_ftrace_filter >/dev/null
printf 'ftrace_saw_vfs_open=%s_times  measured_ipc=%s\n' "$HIT" "$IPC"
# expected: a nonzero hit count and a real IPC figure, proving live introspection with zero rebuild
```

**Teardown.** Return the global tracing state to idle. tracefs settings persist for the life of the boot, so a box left with a tracer active and events enabled keeps paying the overhead until you reset it (or reboot).

```bash
cd /sys/kernel/tracing
echo 0 | sudo tee tracing_on >/dev/null
echo nop | sudo tee current_tracer >/dev/null
echo | sudo tee set_ftrace_filter >/dev/null
echo | sudo tee set_graph_function >/dev/null
echo 0 | sudo tee events/sched/sched_switch/enable >/dev/null
sudo tee /sys/kernel/tracing/trace >/dev/null </dev/null   # clear the ring buffer
rm -f ~/perf.data* perf.data*
```

---

## Curated resources

**Primary kernel documentation (the source of truth)**

- [The Linux Kernel documentation — docs.kernel.org](https://docs.kernel.org/) — The canonical, versioned docs. For this module, read `admin-guide/README` (build), `admin-guide/kernel-parameters` (the exhaustive cmdline reference — bookmark it), `admin-guide/module-signing`, `admin-guide/tainted-kernels`, `admin-guide/sysctl/`, and `admin-guide/LSM/`. When a blog and this disagree, this wins.
- [kernel-parameters.txt / admin-guide/kernel-parameters](https://docs.kernel.org/admin-guide/kernel-parameters.html) — Every boot parameter the kernel core and subsystems accept, authoritatively. This is the reference behind §5; you will return to it constantly for real incidents (`mitigations=`, `isolcpus=`, `crashkernel=`, `rd.*`).
- [Everything you never wanted to know about kobjects, ksets, and ktypes](https://docs.kernel.org/core-api/kobject.html) — The mechanism *under* sysfs. Explains why `/sys` is shaped the way it is and why "one value per file" is a rule. Read before treating `/sys` as more than a curiosity.
- [sysfs — The filesystem for exporting kernel objects](https://docs.kernel.org/filesystems/sysfs.html) + the `Documentation/ABI/` tree — The sysfs ABI contract (stable/testing/obsolete). Knowing an attribute is `ABI/stable` vs `ABI/testing` tells you whether you can build tooling on it.
- [ftrace — Function Tracer (kernel.org)](https://docs.kernel.org/trace/ftrace.html) — The definitive tracefs reference for Lab 4. Covers `function_graph`, filters, triggers, the events tree, and the per-CPU ring buffers. The substrate perf and eBPF sit on; master the raw interface so you can trace a locked-down box with nothing installed.
- [kernel_lockdown(7) — man7](https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html) — Authoritative list of what integrity vs confidentiality mode restrict (§7). The reference to cite when a customer's `bpftrace`/`perf probe`/`/dev/mem` tool "mysteriously" fails on a Secure Boot box.
- [rockyman.org](https://rockyman.org/) — https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here (the `mokutil`, `sysctl`, `kmod` (`modinfo`/`insmod`/`modprobe`), `lsblk`, `findmnt`, and `unshare` invocations in the labs above were checked against the 9.x pages here).

**Module signing / Secure Boot / lockdown (production hardening)**

- [Red Hat: Signing a kernel and modules for Secure Boot (RHEL 8/9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/managing_monitoring_and_updating_the_kernel/signing-a-kernel-and-modules-for-secure-boot_managing-monitoring-and-updating-the-kernel) — The exact MOK + `sign-file` workflow you will actually run on RHEL/Rocky to make a self-built or third-party driver load under Secure Boot. Directly relevant to CIQ support tickets ("Required key not available").
- [rodsbooks: Signing Kernel Modules for Secure Boot](https://rodsbooks.com/efi-bootloaders/sb-modules.html) — The clearest independent explanation of the shim→MOK→kernel-keyring trust chain, disentangling the three overlapping mechanisms (firmware Secure Boot vs `MODULE_SIG_FORCE` vs lockdown) that people conflate.
- [Debian Wiki: SecureBoot](https://wiki.debian.org/SecureBoot) — The non-RHEL view of the same chain (shim, `sbsign`, MOK), useful for cross-distro fluency.

**KASLR**

- [linux-insides: Kernel load address randomization (0xAX)](https://0xax.gitbooks.io/linux-insides/content/Booting/linux-bootstrap-6.html) — Source-level walk of where in the decompression stub the random slot is actually chosen. This is the "how it works" behind §6, not just "it randomizes the base."

**Building / configuring**

- [Debian Kernel Handbook — Common kernel tasks](https://kernel-team.pages.debian.net/kernel-handbook/ch-common-tasks.html) — The `make bindeb-pkg` / `localmodconfig` workflow done the packaged (fleet-correct) way. Pairs with the "don't edit package-owned files; deploy as a package" principle.
- [kernel.org admin-guide/README (Linux 6.x release notes)](https://www.kernel.org/doc/html/latest/admin-guide/README.html) — The upstream build instructions and config-target reference (`olddefconfig`, `localmodconfig`, `menuconfig`), always current for the tip.

**Books (deep, durable)**

- [Linux Kernel Development, 3rd ed — Robert Love](https://www.amazon.com/Linux-Kernel-Development-Robert-Love/dp/0672329468) — The best on-ramp to kernel architecture: process descriptor, the module system, memory, VFS, and the synchronization rules. Read the modules and "kernel data structures" chapters for this module.
- [Understanding the Linux Kernel, 3rd ed — Bovet & Cesati](https://www.oreilly.com/library/view/understanding-the-linux-kernel/0596005652/) — The structural counterpart: actual data structures and code paths. Dated to 2.6 but the architecture (how a subsystem is wired, how the module loader relocates code) is still the best paper explanation.
- [Linux Device Drivers, 3rd ed (LDD3, free)](https://lwn.net/Kernel/LDD3/) — Even if you never ship a driver, chapters 2 (building/running a module) and 14 (the device model/sysfs/kobjects) are exactly this module's mechanism, hands-on. Use [martinezjavier/ldd3](https://github.com/martinezjavier/ldd3) for examples that build on modern kernels.
- [linux-insides — 0xAX (free)](https://0xax.gitbooks.io/linux-insides/content/) — Source-level tour of boot, decompression, and early init; the resource that ties abstract stages to specific functions in `arch/x86`.

**Ongoing (stay current — the kernel moves)**

- [LWN.net Kernel Index](https://lwn.net/Kernel/Index/) — The one subscription worth paying for. Module-loader changes, the `kernel/module.c` → `kernel/module/` split, lockdown evolution, KASLR side-channel breaks, and tracing/BPF changes are all explained here first, with the actual reasoning. Reading it weekly is how your knowledge avoids going silently stale.
- [Bootlin training materials](https://bootlin.com/docs/) — Continuously updated, CC-licensed slides on the kernel build, the driver/device model, and sysfs against *current* kernels (unlike the 2.6-era books). Good for refreshing book material against reality.

---

## Senior signal

- **Distinguishes the three artifacts and reasons about each.** Knows `vmlinux` (debug/symbols), `vmlinuz`/`bzImage` (bootable, compressed, self-decompressing, KASLR-placed), and the running image are different things — and that a crash address is meaningless without the boot's KASLR offset, which they know to pull from `dmesg`/`crash`.
- **Disentangles Secure Boot vs `module.sig_enforce` vs lockdown on sight.** When a self-built or NVIDIA driver won't load, a senior immediately reads `dmesg` for `Required key not available`, checks `mokutil --sb-state` and the loaded keyrings, and reaches for `sign-file` + MOK enrollment — rather than telling the customer to disable Secure Boot (the mid-level "fix" that fails the security posture).
- **Knows which tracer survives lockdown.** On a Secure Boot + confidentiality-lockdown box, `bpftrace`/`perf probe`/`/dev/mem` may be off the table; ftrace via raw tracefs generally is not. A senior plans the debugging approach around the box's actual lockdown mode *before* the incident, and knows the only way to loosen lockdown is a reboot.
- **Treats `/proc` and `/sys` as a forensic instrument, not a curiosity.** Reads `/proc/PID/wchan` and `/proc/PID/stack` to find *where in the kernel* a D-state task is blocked, counts `/proc/PID/fd/` for fd leaks, and follows `/sys` symlinks to walk the device/bus/driver graph — proving I/O saturation while a mid-level stares at a "healthy" CPU graph.
- **Understands sysctl precedence and namespacing cold.** Knows the `/etc/sysctl.d` → `/run` → `/usr/lib` → `sysctl.conf` load order (later file wins), that `net.*` is per-netns while `vm.*`/`kernel.*` are global, and that "it worked until reboot" means a runtime `-w` that was never persisted. Diagnoses the container-can't-set-`vm.max_map_count` class of bug from first principles.
- **Uses `vermagic` and taint flags as diagnostic signal.** Reads `/proc/sys/kernel/tainted` and decodes the bitmask before filing a bug, knows an out-of-tree/unsigned/proprietary module taints the kernel and that engineering will discount reports from a tainted kernel, and explains "Invalid module format" as a version-string gate rather than corruption.
- **Deploys custom kernels as packages, not `make install` on a live box.** Reaches for `binrpm-pkg`/`bindeb-pkg` + `localmodconfig` + `LOCALVERSION` so the kernel is package-manager-tracked, upgradeable, and removable — and uses `git bisect` to pin a regression to a single commit rather than guessing.
- **Commands the boot-time levers.** Knows `rd.break` to recover a box that won't boot, `mitigations=off` as an explicit perf-vs-security decision (not a default), `panic=N` so prod nodes reboot instead of hanging, and `earlycon`/`console=ttyS0` to get output when the kernel dies before the console is up.
- **Practices hypothesis-driven tracing.** States what output would confirm or falsify a theory, then picks ftrace `function_graph` vs `perf sched latency` vs a specific tracepoint accordingly — instead of running `top` and guessing.

---

## See also

- [[10 - Namespaces and cgroups v2]] — This module treated the kernel as one address space; that module drills into the namespace/cgroup machinery that carves it into isolated views, and picks up the per-netns sysctl thread (Lab 3) and the `unshare` mechanics.
- [[11 - Observability and Tracing with eBPF]] — The programmable layer above the ftrace/perf tracepoint substrate introduced in §8/Lab 4; also where the lockdown-vs-BPF restrictions from §7 bite hardest.
- [[06 - Networking Deep]] — Expands the `net.*` sysctl knobs and per-network-namespace behavior seen in Lab 3 into the full networking stack.
- [[01 - The GPU Stack on Linux]] — NVIDIA/GPU drivers are out-of-tree modules: the module-signing, MOK enrollment, lockdown, and taint mechanics (§2/§7) are precisely what a GPU driver install hits on a Secure Boot box, and the #1 "Required key not available" support ticket.
- [[06 - Apptainer for HPC Containers]] — Apptainer depends on kernel features gated here (user namespaces, module availability, lockdown constraints); knowing which cmdline/sysctl toggles govern them is what unblocks rootless HPC containers.
- [[05 - EC2 and Compute Internals]] — cloud instance kernels: KASLR, `mitigations=`, the boot cmdline, and per-instance sysctl tuning are the same levers, and the tainted-kernel/module story governs custom drivers on cloud VMs.
