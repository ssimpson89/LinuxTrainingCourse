---
title: "Early Userspace: dracut Hooks, udev and the initqueue"
type: module
track: linux-internals
tags: [linux-internals, boot, initramfs, dracut, udev, initqueue, systemd, generators, debugging, storage]
requires: ["Modules 07 (systemd units and jobs) and 08 (the boot chain) first", "Rocky 9.x VM you can snapshot and destroy", "console access, not SSH", "root"]
module_number: 14
status: draft
created: 2026-08-11
---

# 14 - Early Userspace: dracut Hooks, udev and the initqueue

Backlink: [[00 - Track Overview]]

> Module 08 walks the boot chain end to end and hands off at the initramfs. This module lives *inside* that handoff. Early userspace is a small self-contained Linux system whose only job is to assemble enough of a machine to mount the real root and then get out of the way. It is also the one environment where the usual debugging reflexes fail: no persistent logs, no package manager, a shell that may not exist, and a failure mode that presents as a cursor blinking beside a message about a device you have never heard of. The staff-level skill is answering three questions fast: *which component was supposed to do this, did it run, and what is it waiting for.*

## Before you start

**Prerequisites.** [[08 - Boot and Init]] for the chain, firmware, and `rd.break` recovery workflow. [[07 - systemd]] for units, jobs, targets, and generators. [[05 - Storage and LVM]] helps, because stacked storage supplies most of the devices early userspace waits on.

**What you will be able to do afterwards.**

- Enumerate what is in an initramfs, and what *can* run in it, without booting anything.
- Attribute an early-boot behaviour to a specific script and line.
- Explain why re-triggering device events cannot defeat a property gate.
- Diagnose a boot that is waiting, by reading what it is waiting for rather than guessing.
- Name which component mounts the real root, and it is not a dracut hook.

**Time.** Deep-dive about 90 minutes. Labs 1 and 3 are 20 minutes each. Labs 2, 4 and 5 involve building images and rebooting; budget an hour each. Lab 5 deliberately breaks bootability, so snapshot first.

**Six terms the rest of this module assumes.**

| Term | Meaning |
|---|---|
| hook | a shell script in `/lib/dracut/hooks/<point>/`, run by the systemd unit owning that point |
| coldplug | the moment a synthetic `add` event is replayed for every device already present, so rules that would have fired at plug-in fire now |
| settled | the udev event queue is empty; every event dispatched so far has been processed |
| gate | a rule-level early exit keyed on a udev property, meaning "the operator did not ask for this" |
| initqueue | a retry loop that re-runs queued work until every exit condition is satisfied |
| `$initdir` / `$moddir` | inside `module-setup.sh`: the staging tree being assembled into the image, and the module's own source directory |

---

## The shape of early userspace

Two layers do the work, and conflating them is the most common source of confusion. **systemd generators and units** own the structure. **dracut hooks** are shell scripts bolted onto that structure at defined points.

```
dracut-cmdline.service        → hooks/cmdline/*.sh        parse /proc/cmdline + /etc/cmdline.d/
                                                          (also: check root= and rootok are set)
dracut-pre-udev.service       → hooks/pre-udev/*.sh       load modules, act on the final root
systemd-udevd.service                                     udevd starts
dracut-pre-trigger.service    → hooks/pre-trigger/*.sh    LAST chance to set udev state
systemd-udev-trigger.service                              COLDPLUG: every device replays now
dracut-initqueue.service      → hooks/initqueue/*.sh      the retry loop, default 180s
                              → initqueue/settled/*       when udev has settled
                              → initqueue/online/*         when an interface comes up
                              → initqueue/timeout/*        at HALF of rd.retry, loop continues
                              → initqueue/finished/*       all return 0 → loop ends
sysroot.mount                                             ← systemd-fstab-generator, NOT a hook
dracut-mount.service          → hooks/mount/*.sh
initrd-parse-etc.service                                  re-reads /sysroot/etc/fstab
dracut-pre-pivot.service      → hooks/pre-pivot/*.sh
                              → hooks/cleanup/*.sh
initrd-switch-root.target                                 PID 1 re-execs into the real root
```

Three properties of that diagram drive almost every early-boot bug:

1. **Everything before the coldplug is setup; everything after is reaction.** A hook that wants to influence how device events are *processed* must run before `systemd-udev-trigger.service`. A hook that wants to react to devices that *appeared* must run at or after the initqueue.
2. **The initqueue is a loop, not a sequence.** It runs until every `finished/` hook returns 0. If one never does, the boot does not fail. It waits, and by default it waits forever.
3. **The thing that mounts root is a generator, not a hook.** If you go looking for the hook that mounts `/sysroot`, you will not find one.

---

## Concept deep-dive

### 1. Reading an initramfs

An initramfs is a compressed cpio archive the kernel unpacks into a tmpfs and executes `/init` from. On a systemd distro `/init` is systemd, so early userspace is a real systemd instance with its own unit tree, running from RAM.

Do not guess at contents. Read them:

```bash
IMG=/boot/initramfs-$(uname -r).img

lsinitrd -m "$IMG"                    # which dracut modules are in it
lsinitrd "$IMG"                       # full file listing
lsinitrd -f etc/fstab "$IMG"          # print one file straight out, no unpacking
lsinitrd --unpack "$IMG"              # extract the main archive here
lsinitrd --unpackearly "$IMG"         # extract the early (microcode) archive instead
```

`lsinitrd -f` is the command you will reach for most often. Most early-boot arguments are settled by reading the file that is actually in the image, which is frequently *not* the one on disk in `/usr/lib/dracut/modules.d/` (see §7).

On x86 the image is two concatenated archives: an uncompressed early cpio holding CPU microcode, then the compressed main archive. `lsinitrd` and `--unpack` operate on the main archive and skip the early one, which is why an unpacked tree contains no `kernel/x86/microcode`. That is not a failed extraction. `early_microcode` defaults to `yes` and can be disabled, so two archives is a default rather than a law. [[08 - Boot and Init]] §4 covers the on-disk format properly; this is the working summary.

**Is this even the image that booted?** Compare the image's kernel version against `uname -r`, and its mtime against your last change. An initramfs edited after the last boot is not the one you are running.

### 2. The systemd skeleton the hooks hang on

This section exists because the hook-centric mental model is incomplete in a way that strands people. On a stock Rocky 9 boot with a plain LVM root, *most* dracut hooks are no-ops and the boot is essentially generators, udev, and device units.

**Generators run first, before unit loading, and synthesise units from non-unit configuration.**

| Generator | What it produces |
|---|---|
| `systemd-fstab-generator` | **`sysroot.mount`**, from `root=`, `rootfstype=`, `rootflags=` on the cmdline |
| `systemd-cryptsetup-generator` | `systemd-cryptsetup@.service` instances, from `rd.luks.*` and `/etc/crypttab` |
| `systemd-gpt-auto-generator` | discovers root by GPT partition type UUID, with no `root=` at all |

So `root=` is consumed by a generator. No dracut hook mounts the root filesystem.

**The target chain**, documented in `dracut.bootup(7)`:

```
initrd-root-device.target → sysroot.mount → initrd-root-fs.target
  → dracut-mount.service → initrd-parse-etc.service → initrd-fs.target
  → initrd.target → initrd-cleanup.service → initrd-switch-root.target
```

`sysinit.target` and `basic.target` also exist inside the initramfs, which is what makes the unit and job model from [[07 - systemd]] transfer directly.

**`initrd-parse-etc.service` is the one to remember.** After root is mounted it re-reads `/sysroot/etc/fstab` and pulls in mounts for entries carrying the `x-initrd.mount` option. That option is what promotes an ordinary fstab line into something the initramfs must satisfy before switch-root, which is why adding it can convert a working boot into a hang. Lab 5 uses exactly this.

### 3. The dracut module system

A dracut module is a directory under `/usr/lib/dracut/modules.d/` named `NNname`, where `NN` orders installation. Each contains `module-setup.sh` with up to four functions:

| Function | Purpose | Returns |
|---|---|---|
| `check()` | should this module be included? | 0 = yes, 1 = no, 255 = only if another module requires it |
| `depends()` | echo module names this one needs | pulled in automatically |
| `install()` | install userspace: binaries, scripts, rules, hooks | |
| `installkernel()` | install kernel modules | |

The helpers:

```bash
inst_multiple cryptsetup awk              # binaries plus their library deps
inst /etc/crypttab                        # one file, same path in the image
inst_hook pre-trigger 30 "$moddir/parse-crypt.sh"   # place a hook at a point, with a priority
inst_rules 10-dm.rules                    # pull a rule from the system rules dirs
inst_rules "$moddir/99-mine.rules"        # or ship your own
instmods '=drivers/md'                    # a whole kernel driver subtree
```

`inst_hook <point> <priority> <file>` places a script at `hooks/<point>/<priority><name>.sh`. **The priority is a two-digit string sorted lexically. There is no dependency resolution between hooks.** Ordering within a point is entirely that number, and a module author choosing `01` over `30` is making a load-bearing decision nothing validates.

Choosing your own priority: list what is already there for that point (`ls hooks/<point>/` in an unpacked image) and place yourself relative to it deliberately. By convention `01`–`09` is for things that must precede all parsing; parsers cluster at `30`.

`check()` returning 255 is why a module you did not ask for appears in the image: something else `depends()` on it.

### 4. Hook points

Each hook point is executed by a systemd unit. `dracut.modules(7)` is authoritative; the practical mapping:

| Hook | Driven by | Use it for |
|---|---|---|
| `cmdline` | `dracut-cmdline.service` | parsing kernel args; writing rules that depend on them |
| `pre-udev` | `dracut-pre-udev.service` | loading modules; runs after `root`/`rootok` are checked |
| `pre-trigger` | `dracut-pre-trigger.service` | **last chance to set udev state before the coldplug** |
| `initqueue` and its `settled`/`online`/`timeout`/`finished` subdirs | `dracut-initqueue.service` | see §8 |
| `pre-mount` | `dracut-pre-mount.service` | just before `/sysroot` is mounted |
| `mount` | `dracut-mount.service` | mounting the real root |
| `pre-pivot`, `cleanup` | `dracut-pre-pivot.service` | final actions before switch-root |
| `shutdown` | the shutdown pivot | see §11 |

Two traps:

**`pre-mount` is later than you think.** If the boot is blocked waiting on a device, `pre-mount` may never run, because the mount it precedes is the thing that is stuck. Debug hooks placed there are useless for diagnosing a device that never appears. Use `pre-trigger` or `initqueue`.

**`pre-trigger` is a cliff edge.** After it the coldplug fires and every device replays its `add` event. Anything that changes how those events are interpreted must already be in place.

> Note: [[08 - Boot and Init]] §5 describes `pre-mount` as where LUKS unlock and array assembly happen. That is the common case when those devices appear promptly; it is not where the *waiting* happens. When a device never arrives, the boot blocks before `pre-mount`.

### 5. How a hook executes

Hooks are **sourced, not forked**, by the hook runner, so they inherit the dracut shell environment. Two consequences: you get the `dracut-lib.sh` helpers for free, and `$0` is the *sourcing* shell, not your script — so a hook cannot identify itself from `$0`. A hook that calls `exit` can also take down more than itself.

Standard preamble:

```sh
type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh
```

| Function | Behaviour |
|---|---|
| `getarg foo=` | first value of `foo=`; non-zero if absent |
| `getargs foo=` | *all* values, space separated (repeatable options) |
| `getargbool <default> foo` | boolean with a default; handles `foo=0`, `foo=1`, bare `foo` |
| `udevproperty KEY=value` | set a global udev property on the running udevd |
| `wait_for_dev <path>` | register a wait on a device path (see §8) |
| `info` / `warn` | log to console and the dracut log |

`getargbool <default> name` is where subtle logic lives: an option can be absent (take the default), present bare, or explicitly `=0`/`=1`. Reading a `parse-*.sh` correctly means reading those defaults, because "absent" and "set to 0" often take different branches.

### 6. Where the kernel command line comes from

The effective command line is **not** just `/proc/cmdline`. Dracut concatenates it with configuration inside the image. All the surfaces, in the order you should check them:

| Surface | Notes |
|---|---|
| the bootloader entry | on BLS, `/boot/loader/entries/*.conf`, the `options` line |
| `/proc/cmdline` | what the kernel actually received |
| `/etc/cmdline.d/*.conf` **inside the image** | shipped in the initramfs; see §9 for what generates these |
| `/etc/cmdline` inside the image | single file, deprecated, still parsed |
| `/etc/conf.d/*` inside the image | *sourced*, so it sets shell variables directly |
| `/etc/kernel/cmdline` | on BLS, what a kernel update rebuilds the entry from |

That last one is the operational trap: an argument present in the running `/proc/cmdline` but absent from `/etc/kernel/cmdline` disappears at the next kernel install, and the failure surfaces at a reboot long after the change that caused it.

`dracut --print-cmdline` prints the *storage and root* arguments dracut would bake in for this host's current root stack (`root=`, `rd.lvm.lv=`, `rd.luks.uuid=`, `rd.md.uuid=`). It is not a general "expected cmdline", so do not diff it against `/proc/cmdline` and expect a match.

### 7. udev in the initramfs, and build-time rule surgery

Rules are read from four directories: `/etc/udev/rules.d`, `/run/udev/rules.d`, `/usr/local/lib/udev/rules.d`, and `/usr/lib/udev/rules.d`.

**All rules files are collectively sorted and processed in lexical order, regardless of which directory they live in.** So `10-foo.rules` in `/etc` runs *before* `60-bar.rules` in `/usr/lib`. Files with identical filenames replace each other, and for that replacement `/etc` wins over `/run`, which wins over `/usr`.

That replacement rule gives you the supported override: **a symlink in `/etc/udev/rules.d/` with the same name as a shipped rule, pointing at `/dev/null`, disables it entirely.** Prefer that to editing anything package-owned.

`/run/udev/rules.d/` matters here more than its usual obscurity suggests: it is where a hook can write a rule at runtime.

**Dracut may modify a rule as it installs it.** A `module-setup.sh` can `sed` the copy it just placed in `$initdir`, so the rule inside the image can differ from the one on your running system. A module that intends to replace a stock behaviour will often strip the stock rule out of its own copy, and that is invisible unless you look inside the image.

```bash
# Read the copy that is actually in the image, not the one on disk
lsinitrd -f usr/lib/udev/rules.d/10-dm.rules "$IMG"

# Which shipped modules do this?
grep -rl 'sed .*\$initdir' /usr/lib/dracut/modules.d/*/module-setup.sh

# Enumerate everything in the image that can invoke a program
mkdir -p /var/tmp/ir && cd /var/tmp/ir && lsinitrd --unpack "$IMG"
grep -rn 'RUN+=\|IMPORT{program}' etc/udev/rules.d usr/lib/udev/rules.d
```

If the tool you expect to run appears in no `RUN+=` or `IMPORT{program}=` line inside the image, no amount of triggering events will make it run. That check ends a lot of speculation in five minutes.

### 8. Properties as gates, and why ordering decides everything

`udevadm control --property=KEY=value` sets a **global property applied to every subsequent event**. Rules match it with `ENV{KEY}`:

```
ENV{rd_NO_LVM}=="?*", GOTO="lvm_end"
...
RUN+="/sbin/lvm vgchange -ay ..."
LABEL="lvm_end"
```

This is the standard dracut idiom for "the operator did not ask for this, so skip it". A `parse-*.sh` decides, sets the property, and every event processed *after that point* is gated.

The real instances, so the pattern is not abstract:

| Disable | Positive assertion |
|---|---|
| `rd.lvm=0`, `rd.md=0`, `rd.dm=0`, `rd.luks=0`, `rd.multipath=0` | `rd.lvm.lv=`, `rd.md.uuid=`, `rd.luks.uuid=` |
| | `rd.auto` (enable autoassembly generally; off by default since dracut 024) |
| | `rd.driver.pre=`, `rd.driver.post=`, `rd.driver.blacklist=`, `rd.modules-load=` |

Three consequences that generalise well beyond storage:

**Global properties are applied to events, not written to the udev database.** `udevadm info --query=property --name=/dev/sda` will not show one. Its absence there proves nothing. Observe it with `udevadm monitor --property`, or by having a rule act on it.

**A property set after an event was processed cannot retroactively affect that event.**

**Therefore re-triggering events later does not undo a gate.** A `udevadm trigger --action=add` at initqueue time replays events straight back into the same gate. Re-triggering only helps if the *state* changed between the original event and the replay.

The failure pattern to watch for is a hook that triggers device events before the `parse-*.sh` meant to gate them. Anything that probes hardware or calls `udevadm trigger` early has this effect, and the ordering that decides it is nothing but two-digit hook priorities in modules that never reference each other. It is invisible in normal operation and timing-sensitive: adding a `udevadm settle` elsewhere can change the outcome. Lab 4 constructs this deliberately.

### 9. hostonly, and where `/etc/cmdline.d/` comes from

`hostonly` defaults to **yes**. So your `/boot` image is host-specific unless something overrode that.

| Setting | Effect |
|---|---|
| `hostonly="yes"` (default) | install only what this host needs |
| `hostonly_mode="sloppy"` / `"strict"` | how aggressively to prune drivers; `strict` is minimal and least survivable across hardware change |
| `hostonly_cmdline` | defaults to `no`, but is forced to `yes` when `hostonly=yes` unless set explicitly |

That last row closes a loop §6 left open. **`hostonly_cmdline=yes` is what generates the `/etc/cmdline.d/*.conf` files inside the image**, derived from the host's actual storage stack. A generic image (`-N` / `--no-hostonly`) has no such file, which is why it needs `rd.lvm.lv=` / `rd.luks.uuid=` / `rd.md.uuid=` supplied on the bootloader entry instead.

[[08 - Boot and Init]] §5 covers the clone-to-new-hardware failure mode this creates.

### 10. The initqueue, and the `initqueue` command

`dracut-initqueue.service` runs a loop. Each pass it executes `initqueue/*.sh`; when udev settles it runs `initqueue/settled/*.sh`; then it evaluates `initqueue/finished/*.sh`. **When every finished hook returns 0, the loop exits and boot proceeds.**

Work gets *into* the queue with the `initqueue` command. This is the mechanism connecting §7's rules to this loop, and it is why a `RUN+=` rule does not do the work itself — udev rule execution must not block:

```sh
initqueue --settled --onetime --unique --name=lvm_scan lvm vgchange -ay
```

| Flag | Meaning |
|---|---|
| `--settled` / `--finished` / `--timeout` / `--online` | which subdirectory to land in |
| `--onetime` | self-delete after running once |
| `--unique` | do not queue a duplicate |
| `--name <n>` | the filename to use, so you can find it later |

So the full story is three parts: **a udev rule defers, the initqueue executes, a `finished/` hook decides.**

`wait_for_dev <path>` is sugar that does more than register a condition: it writes a `finished/` test for that path, a `timeout/` warning, an `emergency/` hook, and on systemd initramfses the corresponding `.device` unit dependency. That last part is the bridge to §12 — the initqueue wait and the "start job is running" message are two faces of one call.

The two knobs, both in `dracut.cmdline(7)`:

- **`rd.retry=<seconds>`, default 180.** How long the loop retries. **`initqueue/timeout/*.sh` fires when the loop counter reaches *half* of this**, so about 90 seconds by default, and the loop then keeps running for the remaining half. Timeout hooks are a mid-flight fallback whose job is to *change the state* the `finished/` hooks are testing, so the second half of the budget can succeed. They are not a death rattle.
- **`rd.timeout=<seconds>`, default 0, meaning forever.** How long dracut waits for devices to appear. This is why a missing device produces an indefinite hang rather than an error. [VERIFY: on Rocky 9 this is plumbed through systemd's device job timeout; the man page states only the wait semantics.]

Find what the loop is waiting for directly:

```bash
ls /lib/dracut/hooks/initqueue/finished/
cat /lib/dracut/hooks/initqueue/finished/*.sh
```

Those filenames are frequently self-documenting: a `devexists-\x2fdev\x2fdisk\x2fby-uuid\x2f...` script names precisely the path that is missing.

### 11. Network root, and the shutdown pivot

**Network root is why the initqueue is a loop.** A link takes seconds to come up and DHCP can fail and be retried, so a *sequence* would not work. `initqueue/online/*.sh` runs whenever an interface comes up. `rd.neednet=1` brings up networking even without a network root. `root=iscsi:...` / `root=nfs:...` name a network root, and the `ip=` option configures the interface (`dracut.cmdline(7)` has the full grammar; do not memorise it).

**The `rootok` contract.** `pre-udev` runs after a check that `root` and `rootok` are set. A `parse-*.sh` that handles a root type must set `rootok=1` to claim the root spec. Failing to is the cause of `dracut: FATAL: Don't know how to handle 'root=...'`. This is the one gate that aborts the boot outright rather than silently skipping work. Diskless HPC provisioning is the CIQ-relevant instance.

**The shutdown pivot.** `dracut-shutdown.service` unpacks the initramfs into `/run/initramfs` during normal boot, so that at shutdown systemd can pivot *back* into it to unmount and deactivate the root stack it cannot otherwise release: detach LUKS, deactivate the VG, stop the array. There are `shutdown` and `shutdown-emergency` hook points for this. It is the answer to "boots fine, hangs on reboot" and "failed to unmount /oldroot", and it is also why `/run/initramfs` exists at all, which matters for §13.

### 12. Device units and the "start job is running" message

systemd in the initramfs turns udev devices into `.device` units. A `.mount` or `.service` that `Requires=` one blocks until udev tags that device ready. So:

```
A start job is running for /dev/disk/by-uuid/… (1min 30s / no limit)
```

is a device unit that has not appeared. `no limit` is `rd.timeout=0`. The device is not slow; nothing will change unless it appears.

Two failure shapes look identical on the console:

- The device does not exist because whatever would create it never ran: a gated rule, a missing kernel module, a rule not present in the image.
- The device does not exist because its *backing* device never appeared: a LUKS volume on an array that was never assembled, an LV in a VG whose PV is missing.

Distinguishing them is the whole game, which is why the workflow in §13 starts by enumerating what *did* appear rather than staring at what did not.

### 13. The troubleshooting toolkit

**Start here.** After a failed boot, dracut writes `/run/initramfs/rdsosreport.txt` — a packaged snapshot of the cmdline, `dmesg`, udev state, `/proc/mdstat`, dm tables, mounts, and the hook inventory. It survives switch-root, so it is also readable after a boot that merely went slowly.

Getting it off a broken box: `/run` is a tmpfs and will not survive the reboot, so mount something writable and copy it out, or scrape the console.

```bash
mkdir /mnt/x && mount /dev/sdX1 /mnt/x && cp /run/initramfs/rdsosreport.txt /mnt/x/
```

> It contains the full kernel command line and device topology, including UUIDs. Sanitise before attaching to a ticket.

Boot arguments, in the order you should reach for them:

| Argument | Effect |
|---|---|
| `rd.info` | informational messages from dracut scripts |
| `rd.debug` | `set -x` tracing of every dracut shell script; the highest-value flag |
| `rd.udev.info` / `rd.udev.log_level=<level>` | udev's own logging |
| `rd.break=<stage>` | shell at a named stage: `cmdline`, `pre-udev`, `pre-trigger`, `initqueue`, `pre-mount`, `mount`, `pre-pivot`, `cleanup` |
| `rd.break` | shell just before switch-root |
| `rd.shell` | shell on failure instead of emergency |
| `rd.emergency=reboot\|poweroff\|halt` | what to do on critical failure instead of waiting at a prompt (needs `rd.shell=0`) |

**Choosing the break stage is the skill.** For a device that never appears, break at `pre-trigger` or `initqueue`. Breaking at `pre-mount` will not fire, per §4. [[08 - Boot and Init]] owns the `rd.break` recovery workflow; this module owns which stage to pick.

`rd.debug` output attributes behaviour to an exact line:

```
///lib/dracut/hooks/pre-trigger/30-parse-crypt.sh@12(source): udevproperty rd_NO_LUKS=1
```

That format — file, line, expanded command — is what makes the noise worth it.

Runtime interrogation, once you have a shell:

```bash
cat /proc/cmdline                                   # what the kernel got
ls /lib/dracut/hooks/*/                             # every installed hook, in order
ls /lib/dracut/hooks/initqueue/finished/            # what the loop is waiting for
udevadm monitor --property --udev                   # events as they are processed
udevadm info --query=property --name=/dev/sda       # the database view of one device
udevadm test /sys/class/block/sda                   # replay rule evaluation, no state change
udevadm trigger --action=add --subsystem-match=block
journalctl -b -o short-monotonic                    # after the fact, with timings
```

`udevadm test` is underused: it replays rule evaluation for one device and prints which rules matched, without touching anything. When the question is "why did no rule create this symlink", it answers directly.

The initramfs journal is flushed into the main journal at switch-root, so `journalctl -b` sees `rd.debug` output after a *successful* boot. After a failed one, `rdsosreport.txt` is the fallback.

### 14. When the image is inside a UKI

A Unified Kernel Image packs kernel, initramfs and cmdline into one signed PE binary in `EFI/Linux/`. Two things this module relies on stop working:

- **There is no `/boot/initramfs-*.img` to read.** Extract with `objcopy -O binary --only-section=.initrd <uki>.efi initrd.img`, or `ukify inspect`. Then `lsinitrd` the result.
- **The command line may be immutable.** It lives in the signed `.cmdline` section, so appending `rd.debug` at the boot menu may be impossible, ignored, or permitted only where `systemd-boot` cmdline editing is explicitly enabled. That affects Labs 3 and 4 directly.

Fallback: build a debug UKI carrying `rd.debug` in `.cmdline`, or boot a non-UKI rescue entry. [[08 - Boot and Init]] §7 teaches UKI itself.

### 15. Building and regenerating the image

The labs build to scratch paths. Shipping a fix means regenerating the real image, and the distinction matters.

```bash
dracut -f                          # rebuild the RUNNING kernel's image, in place
dracut -f --kver 5.14.0-570.el9    # a specific kernel
dracut -f --regenerate-all         # EVERY installed kernel
```

**Use `--regenerate-all`.** A fix applied with bare `dracut -f` leaves every other installed kernel unfixed, and the next incident reboots into an older entry where the bug is still present.

**What rebuilds it automatically.** `kernel-install(8)` and the drop-ins in `/usr/lib/kernel/install.d/*.install`, invoked by the kernel RPM scriptlets. So a `dnf update kernel` picks up your module change for the *new* kernel only.

**Config precedence** (`dracut.conf(5)`), later wins: `/etc/dracut.conf`, then `/usr/lib/dracut/dracut.conf.d/*.conf`, then `/etc/dracut.conf.d/*.conf`, then `/run/initramfs/dracut.conf.d/`. Same-name files in `/etc` replace those in `/usr/lib`. **CLI options override all config files** — which is why a drop-in setting `hostonly="yes"` is silently defeated by `--no-hostonly` on the command line.

Two traps worth internalising:

**The padding spaces are load-bearing.** `add_dracutmodules+=" lvm "` — `+=` is naive string concatenation, so omitting the spaces welds two module names into one nonexistent name, silently.

**`dracutmodules=` / `-m` replaces the entire module set**; `add_dracutmodules+=` / `--add` extends it. Reaching for `-m mymodule` to test the module you just wrote produces an unbootable image and no clue why.

### 16. kdump has its own initramfs

Not an edge case; a frequent support issue. kdump builds and maintains a **separate** image, conventionally `/boot/initramfs-<kver>kdump.img`, rebuilt by `kdumpctl` rather than `dracut -f`, using its own argument set from `dracut_args` in `/etc/kdump.conf`.

Consequences:

- Fixing the primary initramfs does **not** fix kdump's.
- A kdump initramfs failure does not look like a boot failure. It looks like `kdump.service` failing, or worse, a crash that produces no vmcore, discovered during the incident you needed the vmcore for.
- It must reach the dump target, so network and remote storage are in scope even on a local-root machine.

[VERIFY: exact image naming and whether `kdumpctl rebuild` or `kdumpctl restart` is current on your Rocky 9 minor.]

### Cross-subsystem coupling (the staff lens)

- **[[08 - Boot and Init]]** owns the chain, firmware, UKI, and the `rd.break` recovery workflow. This module owns what happens inside the initramfs and which stage to break at.
- **[[07 - systemd]]** owns units, jobs, targets and generators. "Start job is running" is a systemd job; the generators in §2 are the initramfs instance of what 07 teaches.
- **[[05 - Storage and LVM]]** supplies most of the devices being waited on. Stacked storage means one missing layer presents as a missing device several layers up, and the console names only the top.
- **[[12 - SELinux and Hardening]]** matters because the initramfs runs before policy loads, so an emergency shell here is an unconfined root shell on the console with no auditd. On a machine that unlocks storage from the initramfs, `rd.shell` is a security control, not a convenience.
- The generalisable lesson is **ordering coupling between modules sharing a flat namespace.** Hook priorities, udev rule filenames, and unit ordering are all flat namespaces with no dependency checking. Two components that never reference each other can be tightly coupled through them, and the coupling surfaces only as a timing-dependent bug.

---

## Hands-on labs

**The VM.** All labs need a disposable Rocky 9 VM with console access, not SSH. Labs 4 and 5 change boot behaviour; Lab 5 deliberately breaks bootability.

```bash
# Snapshot before Labs 2, 4 and 5. Revert instead of repairing.
virsh snapshot-create-as <vm> pre-lab --atomic
virsh snapshot-revert  <vm> pre-lab
```

Every lab builds test images to `/var/tmp/`, never to `/boot`, except Lab 5 which must use the real image to be realistic.

**Booting a test image.** Labs 2 and 4 need this, so here it is once. Copy the running BLS entry and point it at your image:

```bash
cp /boot/initramfs-test.img /boot/                     # must be under /boot for GRUB to read it
E=$(ls /boot/loader/entries/*.conf | head -1)
cp "$E" /boot/loader/entries/zz-test.conf
sed -i 's/^title .*/title TEST IMAGE/; s|^initrd .*|initrd /initramfs-test.img|' \
    /boot/loader/entries/zz-test.conf
grubby --info=ALL | grep -A2 'TEST IMAGE'              # confirm it registered
# Reboot and pick "TEST IMAGE" at the menu. Remove zz-test.conf when finished.
```

`/var/tmp` is frequently a separate LV that GRUB cannot read, which is why the image is copied to `/boot` first.

### Lab 1 — Inventory an image and prove what can run

**Objective.** Build the habit of reading the image rather than the running system, and learn to answer "can this tool even be invoked here" without booting.

**Setup.** Any Rocky 9 VM. No snapshot needed; read-only.

**Steps.**

```bash
IMG=/boot/initramfs-$(uname -r).img
lsinitrd -m "$IMG"                       # modules
mkdir -p /var/tmp/ir && cd /var/tmp/ir && lsinitrd --unpack "$IMG"
for d in usr/lib/dracut/hooks/*/; do echo "== $d"; ls "$d"; done
grep -rn 'RUN+=\|IMPORT{program}' etc/udev/rules.d usr/lib/udev/rules.d | head -40

# Find a module that edits a rule as it installs it, then diff that rule
grep -rl 'sed .*\$initdir' /usr/lib/dracut/modules.d/*/module-setup.sh
```

Pick one module from that last list, identify which rule file its `sed` targets, and diff the image copy against the on-disk copy:

```bash
diff <(lsinitrd -f usr/lib/udev/rules.d/<rule> "$IMG") /usr/lib/udev/rules.d/<rule>
```

**Prove it.** You can state, for one named rule, what dracut removed and why, citing the `sed` in that module's `install()`. If `lsinitrd -f` returns nothing, that rule's module is not in your image — which is itself the §9 hostonly lesson. Rebuild generically and try again:

```bash
dracut --force --no-hostonly /var/tmp/l1.img "$(uname -r)"
lsinitrd -m /var/tmp/l1.img | tr ' ' '\n' | sort > /var/tmp/generic.mods
lsinitrd -m "$IMG"          | tr ' ' '\n' | sort > /var/tmp/host.mods
diff /var/tmp/host.mods /var/tmp/generic.mods && echo "SAME" || echo "hostonly pruned the above"
```

**Teardown.** `rm -rf /var/tmp/ir /var/tmp/l1.img /var/tmp/*.mods`

### Lab 2 — Instrument every hook point and observe the real order

**Objective.** Replace this module's diagram with output you generated. Also see first-hand why `$0` cannot identify a sourced hook.

**Setup.** Snapshot. You will build a module and one test image.

**Steps.** Note the loop writes one script *per hook point* with the name baked in, because a sourced hook cannot learn its own path from `$0` (§5).

```bash
M=/usr/lib/dracut/modules.d/99hooktrace
mkdir -p "$M"
cat > "$M/module-setup.sh" <<'EOF'
#!/bin/bash
check()   { return 0; }
depends() { return 0; }
install() {
    for h in cmdline pre-udev pre-trigger initqueue initqueue/settled pre-mount pre-pivot cleanup; do
        tag=$(echo "$h" | tr '/' '_')
        printf '#!/bin/sh\necho "HOOKTRACE $(cut -d" " -f1 /proc/uptime) %s" > /dev/kmsg 2>/dev/null\n' \
            "$tag" > "$initdir/trace-$tag.sh"
        chmod +x "$initdir/trace-$tag.sh"
        inst_hook "$h" 99 "$initdir/trace-$tag.sh"
        rm -f "$initdir/trace-$tag.sh"
    done
}
EOF
chmod +x "$M/module-setup.sh"
dracut --force --no-hostonly /boot/initramfs-test.img "$(uname -r)"
lsinitrd /boot/initramfs-test.img | grep trace-
```

Add the `zz-test.conf` BLS entry from the lab preamble, reboot into it, then:

```bash
dmesg | grep HOOKTRACE
```

**Prove it.**

```bash
dmesg | grep HOOKTRACE | awk '{print $3}' | head -3 | tr '\n' ' '
# Must begin: cmdline pre-udev pre-trigger
[ "$(dmesg | grep -c HOOKTRACE)" -ge 5 ] && echo "SUCCESS: hook order captured"
```

Uptimes must increase monotonically and place `pre-trigger` before `initqueue`. Note where `initqueue_settled` lands relative to plain `initqueue`. If `pre-mount` never appears, explain it using §4.

**Teardown.** `rm -rf "$M" /boot/initramfs-test.img /boot/loader/entries/zz-test.conf` then revert the snapshot if anything is odd.

### Lab 3 — Read an `rd.debug` trace and attribute behaviour to a line

**Objective.** Move from "I think that ran" to "it ran, at that line, with that value".

**Setup.** Any VM you can reboot with an edited command line. No snapshot needed; nothing is persisted.

**Steps.** At the GRUB menu press `e` and append `rd.debug rd.info rd.lvm=0` to the `linux` line. The `rd.lvm=0` guarantees a parse hook takes its gating branch, so there is something to find. Boot, then:

```bash
journalctl -b -o short-monotonic | grep 'hooks/' | head -40
journalctl -b | grep -i 'udevproperty'
journalctl -b | grep 'parse-.*\.sh@'
```

**Prove it.**

```bash
journalctl -b | grep -m1 'parse-lvm.*udevproperty' && echo "SUCCESS: attributed to a line"
```

Produce the single line showing a `parse-*.sh` taking a branch, with file, line number and expanded command. Then read the surrounding conditional with `lsinitrd -f` and state, in one sentence, what would have had to differ on the command line for the other branch.

**Teardown.** None; the edit was not persisted.

### Lab 4 — Build a gate, then prove a late trigger cannot defeat it

**Objective.** Construct §8's failure deliberately: prove that a late `udevadm trigger` replays events straight back into an existing gate.

**Setup.** Snapshot. You will build **two** images that differ by one line.

**Steps.**

```bash
M=/usr/lib/dracut/modules.d/99gatelab
mkdir -p "$M"
cat > "$M/99-gate.rules" <<'EOF'
ACTION!="add", GOTO="gate_end"
SUBSYSTEM!="block", GOTO="gate_end"
ENV{rd_NO_GATELAB}=="?*", GOTO="gate_end"
RUN+="/bin/sh -c 'echo $env{DEVNAME} >> /run/gatelab.hits'"
LABEL="gate_end"
EOF
cat > "$M/setgate.sh" <<'EOF'
#!/bin/sh
type udevproperty > /dev/null 2>&1 || . /lib/dracut-lib.sh
getargbool 0 gatelab.off && udevproperty rd_NO_GATELAB=1
EOF
cat > "$M/retrigger.sh" <<'EOF'
#!/bin/sh
udevadm trigger --action=add --subsystem-match=block
udevadm settle
EOF
cat > "$M/module-setup.sh" <<'EOF'
#!/bin/bash
check()   { return 0; }
depends() { echo udev-rules; return 0; }
install() {
    inst_rules "$moddir/99-gate.rules"
    inst_hook pre-trigger 30 "$moddir/setgate.sh"
    [ -n "$GATELAB_RETRIGGER" ] && inst_hook initqueue 01 "$moddir/retrigger.sh"
}
EOF
chmod +x "$M"/*.sh

# Image A: gate only.  Image B: gate plus a late retrigger.
dracut --force --no-hostonly /boot/initramfs-gateA.img "$(uname -r)"
GATELAB_RETRIGGER=1 dracut --force --no-hostonly /boot/initramfs-gateB.img "$(uname -r)"
lsinitrd /boot/initramfs-gateB.img | grep retrigger    # present
lsinitrd /boot/initramfs-gateA.img | grep retrigger    # absent
```

Three boots, using the BLS-entry recipe from the preamble, adding `rd.break=pre-mount` so you get a shell:

| Run | Image | Command line adds |
|---|---|---|
| 1 | A | (nothing) |
| 2 | A | `gatelab.off=1` |
| 3 | B | `gatelab.off=1 rd.debug` |

At each shell: `cat /run/gatelab.hits`

**Prove it.**

```bash
# Run 1
[ -s /run/gatelab.hits ] && echo "SUCCESS: ungated, rule fired"
# Runs 2 and 3
[ ! -s /run/gatelab.hits ] && echo "SUCCESS: gate held"
# Run 3 only, proving the retrigger really executed
grep -q 'retrigger.sh' /run/initramfs/rdsosreport.txt && echo "SUCCESS: retrigger ran anyway"
```

Run 3 is the point: the retrigger hook demonstrably executed and the gate still held. Write one sentence explaining why, in terms of when the property was set relative to when the events were processed.

**Extension.** Move `setgate.sh` from `pre-trigger 30` to `pre-trigger 01`, and add a hook at `pre-trigger 05` running `udevadm trigger --action=add; udevadm settle`. Predict the outcome before booting. That is the ordering-coupling failure from §8, built on purpose.

**Teardown.** `rm -rf "$M" /boot/initramfs-gate[AB].img /boot/loader/entries/zz-test.conf`

### Lab 5 — Diagnose a hang from first principles

**Objective.** Practise the three questions against a failure you built, so the workflow is muscle memory when it is someone else's.

> ⚠️ **This lab intentionally makes the current kernel unbootable.** Snapshot first. Recovery is in the teardown and depends on the previous kernel's BLS entry existing, which on a freshly installed VM it may not. Do not skip the snapshot.

**Setup.**

```bash
virsh snapshot-create-as <vm> pre-lab5 --atomic     # from the host, not the guest
```

**Steps.** No placeholders; every value is derived.

```bash
truncate -s 512M /var/tmp/lab5.img
LOOP=$(losetup -f --show /var/tmp/lab5.img); echo "using $LOOP"
head -c 64 /dev/urandom > /var/tmp/lab5.key; chmod 600 /var/tmp/lab5.key
cryptsetup luksFormat --batch-mode "$LOOP" /var/tmp/lab5.key
cryptsetup open --key-file /var/tmp/lab5.key "$LOOP" lab5
mkfs.xfs -q /dev/mapper/lab5
UUID=$(blkid -s UUID -o value /dev/mapper/lab5); echo "uuid $UUID"
mkdir -p /mnt/lab5

# x-initrd.mount promotes this into a mount the initramfs must satisfy (see §2)
echo "UUID=$UUID /mnt/lab5 xfs defaults,x-initrd.mount 0 0" >> /etc/fstab
dracut -f            # rebuilds the REAL image for the running kernel
reboot
```

The loop device does not exist in the initramfs, so the mount cannot be satisfied. After roughly 90 seconds the device job fails and you land in the emergency shell. If you instead sit at "a start job is running… no limit", reboot and add `rd.shell rd.timeout=60`.

**Prove it.** Answer all three questions with evidence, not inference.

1. **What is it waiting for?** `ls /lib/dracut/hooks/initqueue/finished/` and read the filenames. Name the exact device path.
2. **Which layer is actually missing?** `losetup -a`, `dmsetup ls`, `lsblk`, `cat /proc/mdstat`. The console named the top of the stack; identify the lowest absent layer.
3. **Did the responsible component run?** Reboot with `rd.debug` and either find the hook that should have created that layer, or prove with `lsinitrd` that nothing in the image could have.

Then state which of §12's two failure shapes this was.

**Teardown.** From the emergency shell, repair the real root before rebooting:

```bash
mount -o remount,rw /sysroot
sed -i '/lab5/d' /sysroot/etc/fstab
exit                      # continue boot, or reboot and pick the previous kernel
```

Then, from the booted system:

```bash
dracut -f --regenerate-all
cryptsetup close lab5 2>/dev/null || true      # no-op after a reboot; loops do not persist
losetup -j /var/tmp/lab5.img | cut -d: -f1 | xargs -r losetup -d
rm -f /var/tmp/lab5.img /var/tmp/lab5.key
```

If any of that fails, `virsh snapshot-revert <vm> pre-lab5` is the answer. Note the `cryptsetup close` and `losetup -d` are expected to be no-ops after a reboot, because loop devices and dm mappings do not survive one — a silent failure there is not a problem.

---

## Curated resources

**Primary**

- `dracut.bootup(7)` — https://man7.org/linux/man-pages/man7/dracut.bootup.7.html — the unit and target ordering tree. This is the authoritative source for the diagram at the top of this module.
- `dracut.modules(7)` — https://man7.org/linux/man-pages/man7/dracut.modules.7.html — hook points, the `check`/`depends`/`install` contract, and the half-of-`rd.retry` timeout behaviour.
- `dracut.cmdline(7)` — https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html — every `rd.*` option, the eight `rd.break` stages, and the defaults (`rd.retry` 180, `rd.timeout` 0).
- `dracut.conf(5)` — https://man7.org/linux/man-pages/man5/dracut.conf.5.html — config precedence, `hostonly`, `hostonly_mode`, `hostonly_cmdline`, and the `+=` padding convention.
- `dracut(8)` — https://man7.org/linux/man-pages/man8/dracut.8.html — `--regenerate-all`, `--print-cmdline`, `-m` vs `--add`.
- `lsinitrd(1)` — section 1, not 8. `-f`, `-m`, `--unpack`, `--unpackearly`.
- `udev(7)` — https://man7.org/linux/man-pages/man7/udev.7.html — rule syntax, the four rules directories, collective lexical sorting, and the `/dev/null` symlink masking idiom.
- `udevadm(8)` — https://man7.org/linux/man-pages/man8/udevadm.8.html — `monitor`, `trigger`, `info`, `control`, `settle`, `test`.
- `systemd.generator(7)`, `systemd-fstab-generator(8)`, `systemd-cryptsetup-generator(8)` — what actually creates `sysroot.mount`.
- `bootup(7)` — the systemd-side counterpart; read its initrd section alongside `dracut.bootup(7)`.

**Source, when the man page is not enough**

- `/usr/lib/dracut/modules.d/98dracut-systemd/dracut-initqueue.sh` — the loop body. Settles the half-of-`rd.retry` question in a dozen lines.
- `/usr/lib/dracut/modules.d/99base/initqueue.sh` — the `initqueue` command.
- `/usr/lib/dracut/modules.d/99base/dracut-lib.sh` — `getarg`, `getargbool`, `udevproperty`, `wait_for_dev`.
- `/usr/lib/dracut/modules.d/90crypt/` and `90lvm/` — worked examples of the gate idiom with real `rd_NO_*` properties.
- Upstream moved to `dracut-ng`; RHEL/Rocky 9 tracks the older line. Behaviour you read in dracut-ng may not match your box.

**Practical**

- Fedora wiki, "How to debug Dracut problems" — the canonical `rd.debug` / `rdsosreport.txt` companion to §13.
- https://rockyman.org — verify exact flags and config keys against your Rocky version before trusting them in a recovery on a live box. Several claims in this module are dracut-version-specific; `udevadm control` uses `--log-level` on Rocky 9, where older material says `--log-priority`.

---

## Senior signal

- **Mid:** "the initramfs didn't assemble it." **Senior:** "no rule in the image can invoke that tool, here is the `lsinitrd` output, so triggering will not help."
- **Mid:** reaches for `rd.break` first. **Senior:** reaches for `lsinitrd -m` and the hook listing first, because half of these are answered without booting.
- **Mid:** treats a hang as a crash and looks for an error. **Senior:** knows the boot is waiting correctly, goes to `initqueue/finished/`, and reads the device path out of the filename.
- **Mid:** "it's a race." **Senior:** names the two things racing, the hook priorities that order them, and whether the ordering is deterministic.
- **Mid:** debugs the running system's `/usr/lib/udev/rules.d/`. **Senior:** debugs the copy inside the image, knowing modules edit rules at install time.
- **Mid:** looks for the hook that mounts root. **Senior:** knows a generator produced `sysroot.mount` from `root=`, and goes to `systemctl cat sysroot.mount`.
- **Mid:** fixes it with `dracut -f`. **Senior:** uses `--regenerate-all`, because the next incident may reboot into a different kernel.
- **Mid:** compares package versions across releases. **Senior:** diffs the *built images*, because the same package set can produce different hook ordering.
- **Mid:** enables `rd.shell` fleet-wide for convenience. **Senior:** treats it as a security control on any machine that unlocks storage from the initramfs, and reaches for `rd.emergency` instead.

---

## See also

- [[08 - Boot and Init]] — the boot chain, firmware, UKI, and the `rd.break` recovery workflow
- [[07 - systemd]] — units, jobs, targets, and `systemd.generator(7)`; the generators in §2 are its initramfs instance
- [[05 - Storage and LVM]] — the stacked storage early userspace waits on
- [[04 - Filesystems and the VFS]] — what `sysroot.mount` is actually doing
- [[12 - SELinux and Hardening]] — why an early-boot shell is a hardening concern
- [[11 - Observability and Tracing with eBPF]] — the post-boot half of the same instinct
