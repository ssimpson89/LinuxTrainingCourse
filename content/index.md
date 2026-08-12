# Linux Training Course

<div class="course-hero" markdown>
  <span class="course-hero__eyebrow">Linux Internals · Track 1</span>
  <p>
    Fourteen mechanism-first modules that build a coherent vertical model of a
    running Linux system, from the DAC access check the kernel runs on every
    <code>open()</code> up through namespaces, cgroups, and the eBPF tooling
    you use to watch it all happen. 62 hands-on labs, curated primary sources,
    and a "senior signal" checklist per module.
  </p>
  <div class="course-hero__actions" markdown>
[Start the track](00%20-%20Track%20Overview/){ .md-button .md-button--primary }
[Browse modules](#modules){ .md-button }
  </div>
</div>

Every module follows the same shape: **concept deep-dive → hands-on labs (Objective / Setup / Steps / Prove it) → curated resources → senior signal.** Do the labs. Reading without running them gets you recognition, not recall.

## Modules

<div class="module-grid">
  <a class="module-card" href="01%20-%20Permissions%20and%20Access%20Control/">
    <span class="module-card__index">Module 01</span>
    <span class="module-card__title">Permissions and Access Control</span>
    <span class="module-card__desc">DAC internals: mode bits, setuid/setgid, POSIX ACLs, capabilities.</span>
  </a>
  <a class="module-card" href="02%20-%20Users%2C%20Authentication%20and%20PAM/">
    <span class="module-card__index">Module 02</span>
    <span class="module-card__title">Users, Authentication and PAM</span>
    <span class="module-card__desc">Identity stores (NSS), the PAM stack, sessions, credential lifecycle.</span>
  </a>
  <a class="module-card" href="03%20-%20Processes%2C%20Scheduling%20and%20Signals/">
    <span class="module-card__index">Module 03</span>
    <span class="module-card__title">Processes, Scheduling and Signals</span>
    <span class="module-card__desc">Process lifecycle, the scheduler, signal delivery and semantics.</span>
  </a>
  <a class="module-card" href="04%20-%20Filesystems%20and%20the%20VFS/">
    <span class="module-card__index">Module 04</span>
    <span class="module-card__title">Filesystems and the VFS</span>
    <span class="module-card__desc">VFS objects, path walk, page cache, ext4/XFS, extended attributes.</span>
  </a>
  <a class="module-card" href="05%20-%20Storage%20and%20LVM/">
    <span class="module-card__index">Module 05</span>
    <span class="module-card__title">Storage and LVM</span>
    <span class="module-card__desc">Block layer, device-mapper, LVM, snapshots, md/RAID, LUKS2, NVMe.</span>
  </a>
  <a class="module-card" href="06%20-%20Networking%20Deep/">
    <span class="module-card__index">Module 06</span>
    <span class="module-card__title">Networking Deep</span>
    <span class="module-card__desc">NIC to socket: netdev, sk_buff, netfilter, routing, namespaces.</span>
  </a>
  <a class="module-card" href="07%20-%20systemd/">
    <span class="module-card__index">Module 07</span>
    <span class="module-card__title">systemd</span>
    <span class="module-card__desc">Unit model, job engine, cgroup integration, socket activation, journald.</span>
  </a>
  <a class="module-card" href="08%20-%20Boot%20and%20Init/">
    <span class="module-card__index">Module 08</span>
    <span class="module-card__title">Boot and Init</span>
    <span class="module-card__desc">Firmware → bootloader → initramfs → PID 1, the early-userspace pivot.</span>
  </a>
  <a class="module-card" href="09%20-%20The%20Kernel/">
    <span class="module-card__index">Module 09</span>
    <span class="module-card__title">The Kernel</span>
    <span class="module-card__desc">Kernel architecture, syscalls, memory management, modules, config.</span>
  </a>
  <a class="module-card" href="10%20-%20Namespaces%20and%20cgroups%20v2/">
    <span class="module-card__index">Module 10</span>
    <span class="module-card__title">Namespaces and cgroups v2</span>
    <span class="module-card__desc">The isolation and resource-control primitives behind containers.</span>
  </a>
  <a class="module-card" href="11%20-%20Observability%20and%20Tracing%20with%20eBPF/">
    <span class="module-card__index">Module 11</span>
    <span class="module-card__title">Observability and Tracing with eBPF</span>
    <span class="module-card__desc">Tracepoints, kprobes/uprobes, bcc and bpftrace workflows.</span>
  </a>
  <a class="module-card" href="12%20-%20SELinux%20and%20Hardening/">
    <span class="module-card__index">Module 12</span>
    <span class="module-card__title">SELinux and Hardening</span>
    <span class="module-card__desc">LSM hooks, type enforcement, policy authoring, hardening.</span>
  </a>
  <a class="module-card" href="13%20-%20Samba%20and%20SMB/">
    <span class="module-card__index">Module 13</span>
    <span class="module-card__title">Samba and SMB</span>
    <span class="module-card__desc">Shares, the passdb model, permissions and ACLs, troubleshooting, AD.</span>
  </a>
  <a class="module-card" href="14%20-%20Early%20Userspace%20-%20dracut%20Hooks%2C%20udev%20and%20the%20initqueue/">
    <span class="module-card__index">Module 14</span>
    <span class="module-card__title">Early Userspace</span>
    <span class="module-card__desc">dracut hooks, udev and the initqueue; initramfs debugging and triage.</span>
  </a>
</div>

## Before you start

- You'll need a Rocky 9.x (or RHEL-compatible) throwaway VM for the labs
- 62 labs total across 14 modules; each module takes 2–4 hours
- The [Track Overview](00%20-%20Track%20Overview/) has the recommended study order, shortcut paths, and a consolidated lab index
