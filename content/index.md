---
title: Home
---

<div class="intro" markdown>
  <span class="intro__eyebrow">Linux Internals · Track 1</span>
  <h1>Linux Training Course</h1>
  <p>
    Fourteen mechanism-first modules that build a coherent vertical model of a
    running Linux system, from the DAC access check the kernel runs on every
    <code>open()</code> up through namespaces, cgroups, and the eBPF tooling
    you use to watch it all happen. 62 hands-on labs, curated primary sources,
    and a "senior signal" checklist per module.
  </p>
  <div class="intro__actions" markdown>
[Start the track](00-track-overview/){ .md-button .md-button--primary }
[Browse modules](#modules){ .md-button }
  </div>
</div>

Every module follows the same shape: **concept deep-dive → hands-on labs (Objective / Setup / Steps / Prove it) → curated resources → senior signal.** Do the labs. Reading without running them gets you recognition, not recall.

## Modules

<div class="syllabus-grid">
  <a class="syllabus-card" href="01-permissions-and-access-control/">
    <span class="syllabus-card__index">Module 01</span>
    <span class="syllabus-card__title">Permissions and Access Control</span>
    <span class="syllabus-card__description">DAC internals: mode bits, setuid/setgid, POSIX ACLs, capabilities.</span>
  </a>
  <a class="syllabus-card" href="02-users-authentication-and-pam/">
    <span class="syllabus-card__index">Module 02</span>
    <span class="syllabus-card__title">Users, Authentication and PAM</span>
    <span class="syllabus-card__description">Identity stores (NSS), the PAM stack, sessions, credential lifecycle.</span>
  </a>
  <a class="syllabus-card" href="03-processes-scheduling-and-signals/">
    <span class="syllabus-card__index">Module 03</span>
    <span class="syllabus-card__title">Processes, Scheduling and Signals</span>
    <span class="syllabus-card__description">Process lifecycle, the scheduler, signal delivery and semantics.</span>
  </a>
  <a class="syllabus-card" href="04-filesystems-and-the-vfs/">
    <span class="syllabus-card__index">Module 04</span>
    <span class="syllabus-card__title">Filesystems and the VFS</span>
    <span class="syllabus-card__description">VFS objects, path walk, page cache, ext4/XFS, extended attributes.</span>
  </a>
  <a class="syllabus-card" href="05-storage-and-lvm/">
    <span class="syllabus-card__index">Module 05</span>
    <span class="syllabus-card__title">Storage and LVM</span>
    <span class="syllabus-card__description">Block layer, device-mapper, LVM, snapshots, md/RAID, LUKS2, NVMe.</span>
  </a>
  <a class="syllabus-card" href="06-networking-deep/">
    <span class="syllabus-card__index">Module 06</span>
    <span class="syllabus-card__title">Networking Deep</span>
    <span class="syllabus-card__description">NIC to socket: netdev, sk_buff, netfilter, routing, namespaces.</span>
  </a>
  <a class="syllabus-card" href="07-systemd/">
    <span class="syllabus-card__index">Module 07</span>
    <span class="syllabus-card__title">systemd</span>
    <span class="syllabus-card__description">Unit model, job engine, cgroup integration, socket activation, journald.</span>
  </a>
  <a class="syllabus-card" href="08-boot-and-init/">
    <span class="syllabus-card__index">Module 08</span>
    <span class="syllabus-card__title">Boot and Init</span>
    <span class="syllabus-card__description">Firmware → bootloader → initramfs → PID 1, the early-userspace pivot.</span>
  </a>
  <a class="syllabus-card" href="09-the-kernel/">
    <span class="syllabus-card__index">Module 09</span>
    <span class="syllabus-card__title">The Kernel</span>
    <span class="syllabus-card__description">Kernel architecture, syscalls, memory management, modules, config.</span>
  </a>
  <a class="syllabus-card" href="10-namespaces-and-cgroups-v2/">
    <span class="syllabus-card__index">Module 10</span>
    <span class="syllabus-card__title">Namespaces and cgroups v2</span>
    <span class="syllabus-card__description">The isolation and resource-control primitives behind containers.</span>
  </a>
  <a class="syllabus-card" href="11-observability-and-tracing-with-ebpf/">
    <span class="syllabus-card__index">Module 11</span>
    <span class="syllabus-card__title">Observability and Tracing with eBPF</span>
    <span class="syllabus-card__description">Tracepoints, kprobes/uprobes, bcc and bpftrace workflows.</span>
  </a>
  <a class="syllabus-card" href="12-selinux-and-hardening/">
    <span class="syllabus-card__index">Module 12</span>
    <span class="syllabus-card__title">SELinux and Hardening</span>
    <span class="syllabus-card__description">LSM hooks, type enforcement, policy authoring, hardening.</span>
  </a>
  <a class="syllabus-card" href="13-samba-and-smb/">
    <span class="syllabus-card__index">Module 13</span>
    <span class="syllabus-card__title">Samba and SMB</span>
    <span class="syllabus-card__description">Shares, the passdb model, permissions and ACLs, troubleshooting, AD.</span>
  </a>
  <a class="syllabus-card" href="14-early-userspace-dracut-hooks-udev-and-the-initqueue/">
    <span class="syllabus-card__index">Module 14</span>
    <span class="syllabus-card__title">Early Userspace</span>
    <span class="syllabus-card__description">dracut hooks, udev and the initqueue; initramfs debugging and triage.</span>
  </a>
</div>

## Before you start

- You'll need a Rocky 9.x (or RHEL-compatible) throwaway VM for the labs
- 62 labs total across 14 modules; each module takes 2–4 hours
- The [Track Overview](00-track-overview/) has the recommended study order, shortcut paths, and a consolidated lab index
