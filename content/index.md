---
title: Home
description: An easy-to-follow, hands-on deep dive into how Rocky Linux really works.
hide:
  - toc
---

<div class="intro" markdown>
  <span class="intro__eyebrow">Rocky Linux 10 · Hands-on</span>
  <h1>Rocky Linux Deep Dive</h1>
  <p>
    Learn how Rocky Linux actually works, from the moment you press the power
    button to the packets leaving your network card. Plain English, real
    commands, interactive diagrams, and labs you run on your own VM. No kernel
    source code required.
  </p>
  <div class="intro__actions" markdown>
[Start here](00-start-here.md){ .md-button .md-button--primary }
[Browse modules](#modules){ .md-button }
  </div>
</div>

<div class="course-progress" hidden>
  <div class="course-progress__track"><span class="course-progress__fill"></span></div>
  <p class="course-progress__text"></p>
</div>

## How this course works

Every module follows the same rhythm: **why it matters → how it works (with a picture) → what it looks like on a real system → try it yourself.** You'll find:

<div class="feature-grid" markdown>

<div class="feature" markdown>
:material-cursor-default-click-outline: **Interactive diagrams**

Step through the boot process, click through the storage stack, and play with permission bits.
</div>

<div class="feature" markdown>
:material-flask-outline: **80+ hands-on labs**

Safe, self-cleaning exercises for a throwaway VM. Every lab tells you how to check your work.
</div>

<div class="feature" markdown>
:material-head-question-outline: **Checkpoints**

Quick quizzes in every module so you know you've got it before moving on.
</div>

<div class="feature" markdown>
:material-tools: **Troubleshooting first**

Interactive decision trees and a capstone break-fix playbook for when things go wrong.
</div>

</div>

## Modules { #modules }

### Getting grounded

<div class="syllabus-grid">
  <a class="syllabus-card" href="00-start-here/">
    <span class="syllabus-card__index">00</span>
    <span class="syllabus-card__title">Start Here</span>
    <span class="syllabus-card__description">What Rocky Linux is, how to use this course, and building your lab VM.</span>
  </a>
  <a class="syllabus-card" href="01-how-linux-works/">
    <span class="syllabus-card__index">01</span>
    <span class="syllabus-card__title">How Linux Works</span>
    <span class="syllabus-card__description">The big picture: kernel vs user space, system calls, and "everything is a file".</span>
  </a>
  <a class="syllabus-card" href="02-shell-and-filesystem/">
    <span class="syllabus-card__index">02</span>
    <span class="syllabus-card__title">The Shell and the Filesystem</span>
    <span class="syllabus-card__description">How bash runs commands, pipes and redirection, and a tour of the directory tree.</span>
  </a>
</div>

### Running the system

<div class="syllabus-grid">
  <a class="syllabus-card" href="03-users-groups-and-sudo/">
    <span class="syllabus-card__index">03</span>
    <span class="syllabus-card__title">Users, Groups and sudo</span>
    <span class="syllabus-card__description">Identities, passwords, sudo, and what really happens when you log in (PAM).</span>
  </a>
  <a class="syllabus-card" href="04-permissions-and-acls/">
    <span class="syllabus-card__index">04</span>
    <span class="syllabus-card__title">Permissions and ACLs</span>
    <span class="syllabus-card__description">rwx, special bits, ACLs, attributes, and capabilities. With a live calculator.</span>
  </a>
  <a class="syllabus-card" href="05-software-rpm-and-dnf/">
    <span class="syllabus-card__index">05</span>
    <span class="syllabus-card__title">Software: RPM and DNF</span>
    <span class="syllabus-card__description">Packages, repositories, EPEL, updates, history, and rollback.</span>
  </a>
  <a class="syllabus-card" href="06-processes-and-signals/">
    <span class="syllabus-card__index">06</span>
    <span class="syllabus-card__title">Processes and Signals</span>
    <span class="syllabus-card__description">fork and exec, process states, /proc, signals, priorities, and the OOM killer.</span>
  </a>
  <a class="syllabus-card" href="07-systemd-and-services/">
    <span class="syllabus-card__index">07</span>
    <span class="syllabus-card__title">systemd and Services</span>
    <span class="syllabus-card__description">Units, dependencies, targets, timers, writing your own services, sandboxing.</span>
  </a>
  <a class="syllabus-card" href="08-logging-and-the-journal/">
    <span class="syllabus-card__index">08</span>
    <span class="syllabus-card__title">Logging and the Journal</span>
    <span class="syllabus-card__description">journalctl like a pro, rsyslog, log rotation, and reading logs in an incident.</span>
  </a>
</div>

### Storage and networking

<div class="syllabus-grid">
  <a class="syllabus-card" href="09-disks-and-filesystems/">
    <span class="syllabus-card__index">09</span>
    <span class="syllabus-card__title">Disks and Filesystems</span>
    <span class="syllabus-card__description">Block devices, partitions, XFS and ext4, inodes, links, mounting, fstab, swap.</span>
  </a>
  <a class="syllabus-card" href="10-lvm-raid-and-encryption/">
    <span class="syllabus-card__index">10</span>
    <span class="syllabus-card__title">LVM, RAID and Encryption</span>
    <span class="syllabus-card__description">Flexible volumes, snapshots, thin pools, mdadm RAID, and LUKS2.</span>
  </a>
  <a class="syllabus-card" href="11-networking/">
    <span class="syllabus-card__index">11</span>
    <span class="syllabus-card__title">Networking</span>
    <span class="syllabus-card__description">IP, subnets, routing, DNS, NetworkManager, and the life of a packet.</span>
  </a>
  <a class="syllabus-card" href="12-firewalld/">
    <span class="syllabus-card__index">12</span>
    <span class="syllabus-card__title">Firewalls with firewalld</span>
    <span class="syllabus-card__description">Zones, services, rich rules, forwarding, and nftables underneath.</span>
  </a>
  <a class="syllabus-card" href="13-nfs-and-samba/">
    <span class="syllabus-card__index">13</span>
    <span class="syllabus-card__title">File Sharing: NFS and Samba</span>
    <span class="syllabus-card__description">Share files with Linux and Windows clients, securely.</span>
  </a>
</div>

### Under the hood

<div class="syllabus-grid">
  <a class="syllabus-card" href="14-the-boot-process/">
    <span class="syllabus-card__index">14</span>
    <span class="syllabus-card__title">The Boot Process</span>
    <span class="syllabus-card__description">UEFI, GRUB2, the kernel, dracut and the initramfs, systemd, and rescue mode.</span>
  </a>
  <a class="syllabus-card" href="15-the-kernel/">
    <span class="syllabus-card__index">15</span>
    <span class="syllabus-card__title">The Kernel</span>
    <span class="syllabus-card__description">System calls, modules, /proc and /sys, sysctl, memory, and kdump.</span>
  </a>
  <a class="syllabus-card" href="16-selinux/">
    <span class="syllabus-card__index">16</span>
    <span class="syllabus-card__title">SELinux</span>
    <span class="syllabus-card__description">Labels, type enforcement, booleans, and fixing denials without turning it off.</span>
  </a>
  <a class="syllabus-card" href="17-security-hardening/">
    <span class="syllabus-card__index">17</span>
    <span class="syllabus-card__title">Security Hardening</span>
    <span class="syllabus-card__description">Patching, SSH, crypto policies, auditd, AIDE, and OpenSCAP compliance scans.</span>
  </a>
  <a class="syllabus-card" href="18-containers/">
    <span class="syllabus-card__index">18</span>
    <span class="syllabus-card__title">Containers from the Ground Up</span>
    <span class="syllabus-card__description">Namespaces, cgroups v2, then Podman, rootless containers, and Quadlet.</span>
  </a>
  <a class="syllabus-card" href="19-performance-and-observability/">
    <span class="syllabus-card__index">19</span>
    <span class="syllabus-card__title">Performance and Observability</span>
    <span class="syllabus-card__description">The USE method, sar, tuned, perf, and eBPF tools made approachable.</span>
  </a>
</div>

### Putting it together

<div class="syllabus-grid">
  <a class="syllabus-card" href="20-troubleshooting-playbook/">
    <span class="syllabus-card__index">20</span>
    <span class="syllabus-card__title">Troubleshooting Playbook</span>
    <span class="syllabus-card__description">A method plus real break-fix scenarios that tie every module together.</span>
  </a>
  <a class="syllabus-card" href="cheat-sheet/">
    <span class="syllabus-card__index">Ref</span>
    <span class="syllabus-card__title">Command Cheat Sheet</span>
    <span class="syllabus-card__description">Every command from the course, grouped by task.</span>
  </a>
  <a class="syllabus-card" href="glossary/">
    <span class="syllabus-card__index">Ref</span>
    <span class="syllabus-card__title">Glossary</span>
    <span class="syllabus-card__description">Plain-English definitions for every term you'll meet.</span>
  </a>
</div>

## Deep cuts (advanced electives) { #deep-cuts }

The topics most Linux guides skip. Take them after the core track, in any order.

<div class="syllabus-grid">
  <a class="syllabus-card syllabus-card--elective" href="21-inside-rocky-linux/">
    <span class="syllabus-card__index">21</span>
    <span class="syllabus-card__title">Inside Rocky Linux</span>
    <span class="syllabus-card__description">How Rocky is built from source, signed, mirrored and delivered, and how to verify every step.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="22-building-rpms/">
    <span class="syllabus-card__index">22</span>
    <span class="syllabus-card__title">Building RPM Packages</span>
    <span class="syllabus-card__description">Spec files, rpmbuild, mock, patching an SRPM, and running your own signed repo.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="23-automated-installs/">
    <span class="syllabus-card__index">23</span>
    <span class="syllabus-card__title">Automated Installs</span>
    <span class="syllabus-card__description">Kickstart, PXE boot, Image Builder, cloud-init, and image mode with bootc.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="24-debugging-crashes/">
    <span class="syllabus-card__index">24</span>
    <span class="syllabus-card__title">Debugging Crashes</span>
    <span class="syllabus-card__description">Core dumps, coredumpctl, debuginfo, gdb, and kernel crash analysis with kdump.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="25-memory-deep-dive/">
    <span class="syllabus-card__index">25</span>
    <span class="syllabus-card__title">Memory Deep Dive</span>
    <span class="syllabus-card__description">Virtual memory, reclaim, swap and zram, NUMA, huge pages, and pressure stall info.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="26-centralized-identity/">
    <span class="syllabus-card__index">26</span>
    <span class="syllabus-card__title">Centralized Identity</span>
    <span class="syllabus-card__description">SSSD, Kerberos, FreeIPA, and joining Active Directory.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="27-virtualization-kvm/">
    <span class="syllabus-card__index">27</span>
    <span class="syllabus-card__title">Virtualization with KVM</span>
    <span class="syllabus-card__description">KVM, QEMU and libvirt: build, network, snapshot and tune virtual machines.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="28-high-availability/">
    <span class="syllabus-card__index">28</span>
    <span class="syllabus-card__title">High Availability</span>
    <span class="syllabus-card__description">Pacemaker and Corosync clusters, fencing, and resources that fail over.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="29-secure-boot-and-drivers/">
    <span class="syllabus-card__index">29</span>
    <span class="syllabus-card__title">Secure Boot and Drivers</span>
    <span class="syllabus-card__description">The UEFI trust chain, shim and MOK, signing kernel modules, DKMS vs kmods, and NVIDIA done right.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="30-network-bound-encryption/">
    <span class="syllabus-card__index">30</span>
    <span class="syllabus-card__title">Clevis, Tang and TPM2</span>
    <span class="syllabus-card__description">Encrypted servers that unlock themselves safely, plus measured boot and PCR policy.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="31-disaster-recovery-and-migration/">
    <span class="syllabus-card__index">31</span>
    <span class="syllabus-card__title">Disaster Recovery and Migration</span>
    <span class="syllabus-card__description">ReaR bare-metal recovery, and planning major-version moves when there's no in-place upgrade.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="32-ansible-and-system-roles/">
    <span class="syllabus-card__index">32</span>
    <span class="syllabus-card__title">Ansible and System Roles</span>
    <span class="syllabus-card__description">Idempotent fleet management with ansible-core and the RHEL System Roles.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="33-tls-and-crypto-policies/">
    <span class="syllabus-card__index">33</span>
    <span class="syllabus-card__title">TLS and Crypto Policies</span>
    <span class="syllabus-card__description">Crypto policies, your own CA, web TLS, debugging handshakes, and post-quantum crypto.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="34-nftables-and-traffic-control/">
    <span class="syllabus-card__index">34</span>
    <span class="syllabus-card__title">nftables and Traffic Control</span>
    <span class="syllabus-card__description">Raw nftables, packet tracing, and shaping traffic with tc and netem.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="35-enterprise-storage/">
    <span class="syllabus-card__index">35</span>
    <span class="syllabus-card__title">Enterprise Storage</span>
    <span class="syllabus-card__description">SAN storage over iSCSI and NVMe/TCP, multipathing, I/O schedulers, and fio.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="36-time-synchronization/">
    <span class="syllabus-card__index">36</span>
    <span class="syllabus-card__title">Time Synchronization</span>
    <span class="syllabus-card__description">Why time breaks everything, chrony internals, authenticated NTP, and precision PTP.</span>
  </a>
  <a class="syllabus-card syllabus-card--elective" href="37-real-time-and-low-latency/">
    <span class="syllabus-card__index">37</span>
    <span class="syllabus-card__title">Real-Time and Low Latency</span>
    <span class="syllabus-card__description">kernel-rt, CPU isolation, IRQ affinity, tuned profiles, and measuring jitter.</span>
  </a>
</div>

## Suggested paths

Working straight through (00 → 20) is the best way to learn. If you have a specific goal, these shortcuts work too:

| If you want to… | Take these modules |
|---|---|
| Become a capable Rocky admin fast | 00 → 02 → 03 → 04 → 05 → 07 → 08 → 09 → 11 → 12 |
| Run containers in production | 01 → 06 → 07 → 16 → 18 → 19 |
| Pass a security review | 03 → 04 → 12 → 16 → 17 → 29 → 30 → 33 |
| Get good at fixing broken servers | 07 → 08 → 14 → 19 → 20 → 24 |
| Go deep on how Rocky itself works | 05 → 14 → 21 → 22 → 23 |
