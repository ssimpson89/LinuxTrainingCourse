---
title: Track Overview
type: moc
track: linux-internals
tags: [moc, linux-internals, track-index, training, kernel, systems]
status: reviewed
created: 2026-07-08
module_count: 14
lab_count: 62
---

# 00 - Track Overview

Backlink: [[00 - Program Overview]]

> Track 1: Linux Internals. Fourteen mechanism-first modules that build a coherent vertical model of a running Linux system, from the DAC access check the kernel runs on every `open()` up through namespaces, cgroups, and the eBPF tooling you use to watch it all happen. Each module is written to a staff-engineer bar: it walks the actual kernel path (with source references), then backs it with hands-on labs you run in a throwaway VM, a curated primary-source reading list, and a "senior signal" checklist that names what separates a mid-level answer from a senior one.

Every module follows the same shape: **Concept deep-dive → Hands-on labs (Objective / Setup / Steps / Prove it) → Curated resources → Senior signal.** Do the labs. Reading the deep-dive without running the labs gets you recognition, not recall.

Every module also carries a "See also" section cross-linking related modules, and every command shown has been rockyman-verified against Rocky 9.

---

## Recommended study order

The modules are numbered in the intended sequence, and later modules lean on earlier ones. If you are working straight through, go 01 → 14.

1. **Foundations of identity and access (01–03).** Permissions, credentials, PAM, and the process/scheduling/signal model. This is the subject side of everything that follows: who a task is and what it may do.
2. **The storage and I/O vertical (04–05).** The VFS and the filesystem/block/device-mapper stack. Module 04 (VFS) is the on-ramp to 05 (Storage/LVM); do them as a pair.
3. **System services and lifecycle (06–08).** Networking, systemd, and boot/init. systemd (07) references cgroups, so if you jump around, skim module 10's cgroup section first.
4. **The kernel and isolation (09–10).** Kernel internals, then namespaces and cgroups v2, the primitives behind containers. Module 10 assumes the credential model from 01 and the process model from 03.
5. **Observability and defense (11–12).** eBPF-based tracing and SELinux/hardening. Module 11 is the capstone toolset (it re-uses subjects from nearly every prior module); 12 closes the loop on the MAC layer that sits above the DAC checks introduced in 01.

Shortcut paths: for a **containers** focus, prioritize 01 → 03 → 10 → 07 → 11. For a **storage/data-integrity** focus, prioritize 04 → 05 → 09. For a **security/hardening** focus, prioritize 01 → 02 → 12 → 11. For a **file-services** focus, prioritize 04 → 06 → 13.

---

## Modules

| # | Module | Focus | Labs |
|---|--------|-------|------|
| 01 | [[01 - Permissions and Access Control]] | DAC internals: mode bits, setuid/setgid/sticky, POSIX ACLs, capabilities, `chattr` flags, the `generic_permission()` path | 4 |
| 02 | [[02 - Users, Authentication and PAM]] | Identity stores (NSS), authentication stack (PAM), sessions, credential lifecycle | 4 |
| 03 | [[03 - Processes, Scheduling and Signals]] | Process lifecycle, the scheduler, signal delivery and semantics | 4 |
| 04 | [[04 - Filesystems and the VFS]] | VFS objects (dentry/inode/file/address_space), path walk, page cache, ext4/XFS, xattrs | 6 |
| 05 | [[05 - Storage and LVM]] | Block layer (blk-mq), device-mapper, LVM, thin/snapshots, md/RAID, LUKS2, NVMe | 4 |
| 06 | [[06 - Networking Deep]] | Network stack from NIC to socket: netdev, sk_buff, netfilter, routing, namespaces | 4 |
| 07 | [[07 - systemd]] | Unit model, the transaction/job engine, cgroup integration, socket activation, journald | 5 |
| 08 | [[08 - Boot and Init]] | Firmware → bootloader → initramfs → PID 1 handoff, the early-userspace pivot | 4 |
| 09 | [[09 - The Kernel]] | Kernel architecture, syscalls, memory management, modules, the build/config surface | 4 |
| 10 | [[10 - Namespaces and cgroups v2]] | The six+ namespace types, cgroup v2 unified hierarchy, the container primitives | 4 |
| 11 | [[11 - Observability and Tracing with eBPF]] | Tracepoints/kprobes/uprobes, bcc/bpftrace, building a coherent observability workflow | 5 |
| 12 | [[12 - SELinux and Hardening]] | The MAC layer (LSM hooks), type enforcement, policy, and system hardening | 4 |
| 13 | [[13 - Samba and SMB]] | SMB/CIFS, smbd/nmbd/winbind, smb.conf, shares, passdb, AD membership, and the POSIX/NT ACL permission model | 5 |
| 14 | [[14 - Early Userspace - dracut Hooks, udev and the initqueue]] | Inside the initramfs: dracut modules and hook points, udev rules and property gates, the initqueue loop, and the early-boot debugging workflow | 5 |

---

## Consolidated lab index

**62 hands-on labs across 14 modules.** All labs run in a disposable VM and clean up after themselves (loop devices, scratch dirs, throwaway units). Nothing touches real hardware or persistent state.

| Module | Labs | Lab focus (short) |
|--------|:---:|-------------------|
| [[01 - Permissions and Access Control]] | 4 | Kernel DAC decision made visible; fcaps vs setuid (`ping`); ACL mask foot-gun; immutable-vs-root |
| [[02 - Users, Authentication and PAM]] | 4 | NSS/PAM stack tracing, session and credential lifecycle |
| [[03 - Processes, Scheduling and Signals]] | 4 | Process/scheduler/signal behavior under observation |
| [[04 - Filesystems and the VFS]] | 6 | VFS path walk, page cache, filesystem internals; xattr namespaces + copy footgun |
| [[05 - Storage and LVM]] | 4 | LVM COW snapshot death; thin-pool ENOSPC cliff; blk-mq latency attribution; LUKS2 by hand |
| [[06 - Networking Deep]] | 4 | Packet path, netfilter, routing, network namespaces |
| [[07 - systemd]] | 5 | Job/transaction engine; socket activation fd-passing; CPU quota throttling; journald sealing; service sandboxing |
| [[08 - Boot and Init]] | 4 | Bootloader → initramfs → PID 1 handoff |
| [[09 - The Kernel]] | 4 | Syscalls, memory management, module and build surface |
| [[10 - Namespaces and cgroups v2]] | 4 | Building a container by hand from namespaces + cgroups |
| [[11 - Observability and Tracing with eBPF]] | 5 | tracepoints/kprobes/uprobes, bcc/bpftrace workflows |
| [[12 - SELinux and Hardening]] | 4 | LSM hooks, type enforcement, policy authoring, hardening |
| [[13 - Samba and SMB]] | 5 | standalone share; passdb two-account model; permissions and ACLs (create mask, POSIX ceiling); testparm/smbstatus/log troubleshooting; AD-join dry run |
| [[14 - Early Userspace - dracut Hooks, udev and the initqueue]] | 5 | initramfs inventory without booting; hook-point order traced live; `rd.debug` attribution to a script line; gate vs late retrigger; stacked-device hang triage |
| **Total** | **62** | |

---

## Progress checklist

Mark a module done only after the labs are run and each "Prove it" check passes.

### Modules
- [ ] 01 — [[01 - Permissions and Access Control]] (deep-dive + 4 labs)
- [ ] 02 — [[02 - Users, Authentication and PAM]] (deep-dive + 4 labs)
- [ ] 03 — [[03 - Processes, Scheduling and Signals]] (deep-dive + 4 labs)
- [ ] 04 — [[04 - Filesystems and the VFS]] (deep-dive + 6 labs)
- [ ] 05 — [[05 - Storage and LVM]] (deep-dive + 4 labs)
- [ ] 06 — [[06 - Networking Deep]] (deep-dive + 4 labs)
- [ ] 07 — [[07 - systemd]] (deep-dive + 5 labs)
- [ ] 08 — [[08 - Boot and Init]] (deep-dive + 4 labs)
- [ ] 09 — [[09 - The Kernel]] (deep-dive + 4 labs)
- [ ] 10 — [[10 - Namespaces and cgroups v2]] (deep-dive + 4 labs)
- [ ] 11 — [[11 - Observability and Tracing with eBPF]] (deep-dive + 5 labs)
- [ ] 12 — [[12 - SELinux and Hardening]] (deep-dive + 4 labs)
- [ ] 13 — [[13 - Samba and SMB]] (deep-dive + 5 labs)
- [ ] 14 — [[14 - Early Userspace - dracut Hooks, udev and the initqueue]] (deep-dive + 5 labs)

### Track milestones
- [ ] Foundations block complete (01–03)
- [ ] Storage/I/O vertical complete (04–05)
- [ ] Services and lifecycle complete (06–08)
- [ ] Kernel and isolation complete (09–10)
- [ ] Observability and defense complete (11–12)
- [ ] Can answer the "Senior signal" checklist for every module from memory
- [ ] Track 1 complete → return to [[00 - Program Overview]]
