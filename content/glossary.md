---
title: Glossary
description: Plain-English definitions of the Linux and Rocky Linux terms used in this course, each linked to the module that covers it.
---

# Glossary

Plain-English definitions of the terms used across the course, in alphabetical order. Each entry links to the module that explains it in depth. Use your browser's find (++ctrl+f++) or the site search to jump to a term.

This glossary has 246 terms.

## A

**ACL (Access Control List)**
:   Extra permission entries on a file that grant or deny access to specific users or groups beyond the owner/group/other bits. Managed with `getfacl` and `setfacl`. See [module 04](04-permissions-and-acls.md).

**ACME**
:   The protocol a certificate authority such as Let's Encrypt uses to issue and renew certificates automatically, after proving you control the name (HTTP-01 or DNS-01 challenge). `certbot` is the usual client. See [module 33](33-tls-and-crypto-policies.md).

**ALUA (Asymmetric Logical Unit Access)**
:   A SCSI feature where a storage array tells the host which paths to a LUN are optimal and which are slower fallbacks, so multipath sends I/O the right way. See [module 35](35-enterprise-storage.md).

**ANA (Asymmetric Namespace Access)**
:   The NVMe equivalent of ALUA: each path to an NVMe namespace reports whether it is optimized, non-optimized or inaccessible. Used by native NVMe multipath. See [module 35](35-enterprise-storage.md).

**Anaconda**
:   The Rocky Linux installer (shared with RHEL and Fedora). It runs from a small live environment in RAM and can be driven interactively or by a kickstart file. See [module 23](23-automated-installs.md).

**Ansible**
:   An agentless configuration management tool: it connects over SSH, runs small Python modules on each machine, and brings it to the state you describe in YAML. Rocky ships `ansible-core` in AppStream. See [module 32](32-ansible-and-system-roles.md).

**Ansible Vault**
:   Ansible's built-in encryption for variable files and strings, so passwords and keys can live in Git safely. Managed with `ansible-vault`. See [module 32](32-ansible-and-system-roles.md).

**AppStream**
:   The Rocky Linux repository holding applications, languages and tools, alongside BaseOS. It is updated alongside BaseOS with every minor release. See [module 05](05-software-rpm-and-dnf.md).

**Audit log**
:   The kernel audit system's record of security events, including SELinux denials, logins and `sudo` use, in `/var/log/audit/audit.log`. Searched with `ausearch`. See [module 16](16-selinux.md).

**authselect**
:   The Rocky tool that writes the NSS and PAM configuration from a named profile (`sssd`, `winbind`, `local`) plus features such as `with-mkhomedir`, so you never hand-edit `/etc/pam.d`. See [module 26](26-centralized-identity.md).

**AVC denial**
:   An SELinux "access vector cache" message saying the policy blocked an action. Each one names the process (source context), the object (target context) and the permission. See [module 16](16-selinux.md).

## B

**Backing file**
:   A read-only base disk image that a qcow2 overlay records changes against. Many VMs can share one backing file, each with its own small overlay. See [module 27](27-virtualization-kvm.md).

**BaseOS**
:   The core Rocky Linux repository: the kernel, systemd, core libraries and tools that every system needs. See [module 05](05-software-rpm-and-dnf.md).

**Bind mount**
:   Mounting an existing directory at a second location so the same files appear in both places. Containers use bind mounts for volumes. See [module 18](18-containers.md).

**Blueprint**
:   A short TOML file describing the image Image Builder should make: packages, users, services, customizations. See [module 23](23-automated-installs.md).

**Boot Loader Specification (BLS)**
:   A standard where each boot menu entry is a small file in `/boot/loader/entries/`. Rocky's GRUB reads these, and `grubby` edits them. See [module 14](14-the-boot-process.md).

**bootc (image mode)**
:   A way to run Rocky where the whole operating system is a bootable container image built from a `Containerfile`. `bootc` installs the image and later updates the host by pulling a newer one, keeping the previous version for rollback. See [module 23](23-automated-installs.md).

**bpftrace**
:   A small scripting language for writing eBPF tracing one-liners, such as counting system calls per process. See [module 19](19-performance-and-observability.md).

**Build ID**
:   A unique hash the linker embeds in every ELF binary and library. Debuggers use it to match a core dump with exactly the right debuginfo. Shown by `readelf -n`. See [module 24](24-debugging-crashes.md).

## C

**Capability**
:   One slice of root's power, such as `CAP_NET_BIND_SERVICE` (bind low ports) or `CAP_SYS_ADMIN`. Lets a process have some root powers without all of them. See [module 17](17-security-hardening.md).

**Certificate authority (CA)**
:   An entity that signs certificates, vouching that a public key belongs to a name. Clients trust a site if its certificate chains up to a CA in their trust store. See [module 33](33-tls-and-crypto-policies.md).

**cgroup (control group)**
:   A kernel feature that groups processes so their CPU, memory, I/O and process count can be measured and limited together. Rocky 10 uses only cgroup v2, a single tree under `/sys/fs/cgroup`. See [module 18](18-containers.md).

**chrony**
:   Rocky's NTP implementation: the `chronyd` daemon keeps the clock synchronised, and `chronyc` inspects and controls it. It can also serve time and NTS to other machines. See [module 36](36-time-synchronization.md).

**chroot**
:   Changing a process's idea of the root directory `/`. Used in recovery (`chroot /sysroot`) and as one of the ideas behind containers. See [module 20](20-troubleshooting-playbook.md).

**CIB (Cluster Information Base)**
:   Pacemaker's configuration and state, an XML document replicated to every cluster node. `pcs` edits it for you. See [module 28](28-high-availability.md).

**Clevis**
:   A framework that unlocks LUKS volumes automatically using a policy ("pin"): `tang` (a network server), `tpm2` (the machine's TPM) or `sss` (a threshold combination of others). It adds its own keyslot and keeps your passphrase working. See [module 30](30-network-bound-encryption.md).

**cloud-init**
:   The first-boot agent in cloud images. It reads **user-data** from a **datasource** (the cloud's metadata service, or a NoCloud seed ISO) and sets the hostname, users, SSH keys, packages and more. See [module 23](23-automated-installs.md).

**Cockpit**
:   A web-based admin console for Rocky (port 9090) showing metrics, services, logs, storage and more. See [module 19](19-performance-and-observability.md).

**Collection (Ansible)**
:   A distributable bundle of Ansible modules, roles and plugins with a namespace, such as `ansible.posix` or `redhat.rhel_system_roles`. Installed with `ansible-galaxy collection install`. See [module 32](32-ansible-and-system-roles.md).

**Configuration drift**
:   The slow divergence of servers that should be identical, through manual fixes and one-off changes. Configuration management tools detect and correct it. See [module 32](32-ansible-and-system-roles.md).

**conntrack (connection tracking)**
:   The kernel's table of every network flow it has seen, with both directions recorded. It makes stateful rules (`ct state established`) and NAT work. Inspected with the `conntrack` tool. See [module 34](34-nftables-and-traffic-control.md).

**Container**
:   A normal process isolated with namespaces, limited with cgroups, given its own filesystem image and restricted by SELinux, seccomp and capabilities. It shares the host's kernel. See [module 18](18-containers.md).

**Context (SELinux)**
:   The label on every process and file, written `user:role:type:level`, e.g. `system_u:object_r:httpd_sys_content_t:s0`. The type part drives most decisions. See [module 16](16-selinux.md).

**Core dump**
:   A file containing a crashed program's memory at the moment it died, used to debug the crash. On Rocky, `systemd-coredump` stores them and `coredumpctl` lists them. See [module 24](24-debugging-crashes.md).

**Corosync**
:   The cluster messaging and membership layer under Pacemaker. It tracks which nodes are alive and counts votes for quorum. See [module 28](28-high-availability.md).

**CPU isolation**
:   Splitting CPUs into **housekeeping** CPUs (the OS, daemons, interrupts) and **isolated** CPUs reserved for latency-critical work, using kernel arguments such as `isolcpus`, `nohz_full` and `rcu_nocbs`, usually set by a tuned profile. See [module 37](37-real-time-and-low-latency.md).

**CRB (CodeReady Builder)**
:   A Rocky repository of extra development packages, disabled by default, that many EPEL packages depend on. See [module 05](05-software-rpm-and-dnf.md).

**crun**
:   The low-level OCI container runtime Podman uses on Rocky. It creates the namespaces and cgroups and starts the container's first process. See [module 18](18-containers.md).

**Crypto policy**
:   A system-wide setting (`DEFAULT`, `FUTURE`, `LEGACY`, `FIPS`) that controls which ciphers and protocols every library allows. Set with `update-crypto-policies`. See [module 17](17-security-hardening.md) and, for subpolicies and post-quantum settings, [module 33](33-tls-and-crypto-policies.md).

**C-state**
:   A CPU idle (power-saving) state. Deeper C-states save more power but take longer to wake from, which adds latency. See [module 37](37-real-time-and-low-latency.md).

**cyclictest**
:   The standard tool for measuring scheduling latency: it wakes threads at fixed intervals and records how late they actually run. The maximum is the number that matters. See [module 37](37-real-time-and-low-latency.md).

## D

**D state (uninterruptible sleep)**
:   A process waiting inside the kernel, usually for disk or NFS I/O, that ignores signals, even `kill -9`, until the I/O completes (NFS waits use a "killable" variant that `SIGKILL` can end). Counts toward load average. See [module 06](06-processes-and-signals.md).

**Daemon**
:   A background program with no terminal, usually started by systemd, such as `sshd` or `chronyd`. See [module 07](07-systemd-and-services.md).

**Debranding**
:   Replacing Red Hat trademarks (logos, names, URLs) in RHEL's sources while changing nothing functional, which lets Rocky redistribute the result. See [module 21](21-inside-rocky-linux.md).

**debuginfo**
:   Separate packages (`foo-debuginfo`, `foo-debugsource`) holding the symbols and source that were stripped from a binary, needed for readable backtraces. They come from Rocky's debug repositories, which are disabled by default. See [module 24](24-debugging-crashes.md).

**Direct reclaim**
:   When a process needing memory has to free pages itself, because the background reclaimer (`kswapd`) couldn't keep up. It shows up as latency spikes and `allocstall` counts in `/proc/vmstat`. See [module 25](25-memory-deep-dive.md).

**DKMS (Dynamic Kernel Module Support)**
:   A framework that keeps the source of an out-of-tree kernel module and rebuilds it automatically for each new kernel you install. Under Secure Boot the result must be signed with a key you enrolled as a MOK. See [module 29](29-secure-boot-and-drivers.md).

**DNF**
:   The Rocky Linux package manager. It resolves dependencies, downloads RPMs from repositories, and records every transaction in `dnf history`. See [module 05](05-software-rpm-and-dnf.md).

**DNS (Domain Name System)**
:   The service that turns names like `rockylinux.org` into IP addresses. Rocky's resolver settings are written to `/etc/resolv.conf` by NetworkManager. See [module 11](11-networking.md).

**dracut**
:   The tool that builds the initramfs, the small early-boot filesystem that finds and mounts the real root filesystem. See [module 14](14-the-boot-process.md).

**Drop-in**
:   A small `.conf` file in a `UNIT.d/` directory that overrides part of a unit file without editing the original. Created with `systemctl edit`. See [module 07](07-systemd-and-services.md).

## E

**eBPF**
:   A kernel feature that runs small, verified programs on kernel events, used for safe low-overhead tracing (bcc-tools, bpftrace) and networking. See [module 19](19-performance-and-observability.md).

**Emergency mode**
:   A minimal systemd target with only a root shell, entered when boot fails badly, most often because of a bad `/etc/fstab` entry. See [module 20](20-troubleshooting-playbook.md).

**EPEL**
:   Extra Packages for Enterprise Linux: a community repository of additional software built for Rocky and RHEL. Install with `dnf install epel-release`. See [module 05](05-software-rpm-and-dnf.md).

**Errata (advisories)**
:   Rocky's published update notices: **RLSA** (security), **RLBA** (bug fix) and **RLEA** (enhancement), each listing CVEs and fixed packages. Queried with `dnf updateinfo`. See [module 21](21-inside-rocky-linux.md).

**EVR (Epoch, Version, Release)**
:   The three parts RPM compares to decide which package is newer, written `epoch:version-release`. See [module 22](22-building-rpms.md).

**Exit code**
:   The number a program returns when it ends: 0 for success, anything else for failure. systemd also reports its own codes such as `203/EXEC`. See [module 07](07-systemd-and-services.md).

## F

**Fencing**
:   See STONITH. See [module 28](28-high-availability.md).

**FHS (Filesystem Hierarchy Standard)**
:   The convention for where things live: `/etc` for config, `/var` for changing data, `/usr` for programs, and so on. See [module 02](02-shell-and-filesystem.md).

**File descriptor**
:   A small number a process uses to refer to an open file, socket or pipe. 0, 1 and 2 are standard input, output and error. See [module 01](01-how-linux-works.md).

**firewalld**
:   Rocky's firewall service. It organises rules into zones and services and programs the kernel's nftables underneath. See [module 12](12-firewalld.md).

**Forward secrecy**
:   A property of TLS key exchange: session keys are ephemeral, so stealing the server's private key later cannot decrypt traffic recorded earlier. See [module 33](33-tls-and-crypto-policies.md).

**FreeIPA (IdM)**
:   An integrated identity system bundling an LDAP directory, a Kerberos KDC, a CA, DNS and central policy (HBAC, sudo rules). Red Hat calls it Identity Management (IdM). See [module 26](26-centralized-identity.md).

**fstab**
:   The file `/etc/fstab` listing filesystems to mount at boot. A mistake here can drop the system into emergency mode. See [module 09](09-disks-and-filesystems.md).

## G

**GID (Group ID)**
:   The number that identifies a group. Files store GIDs, not names. See [module 03](03-users-groups-and-sudo.md).

**GPG key**
:   A public key used to verify that packages were signed by a trusted publisher. DNF refuses unsigned or wrongly signed packages. See [module 05](05-software-rpm-and-dnf.md).

**GRUB2**
:   The boot loader on Rocky. It shows the boot menu, loads the kernel and initramfs, and passes kernel arguments. See [module 14](14-the-boot-process.md).

## H

**Hard link**
:   A second directory entry pointing to the same inode. Both names are equally real; the data is freed when the last link is removed. See [module 02](02-shell-and-filesystem.md).

**HBAC (Host-Based Access Control)**
:   FreeIPA rules saying which users may log in to which hosts through which services. SSSD enforces them on each client; `ipa hbactest` simulates them. See [module 26](26-centralized-identity.md).

**Huge pages**
:   Memory pages larger than the normal 4 KiB (usually 2 MiB or 1 GiB), which cut TLB misses for large-memory workloads. Reserved explicitly (HugeTLB) or used automatically (THP). See [module 25](25-memory-deep-dive.md).

## I

**Idempotence**
:   Running the same automation twice gives the same result, and the second run changes nothing. In Ansible a clean second run reports `changed=0`. See [module 32](32-ansible-and-system-roles.md).

**Image Builder**
:   Rocky's tool (`osbuild-composer`, driven by `composer-cli` or Cockpit) for building disk images (qcow2, ISO, cloud formats) from a blueprint. See [module 23](23-automated-installs.md).

**Initiator**
:   The client side of a SAN protocol such as iSCSI or NVMe-oF: the host that sends storage commands to a target. See [module 35](35-enterprise-storage.md).

**Initramfs**
:   A compressed temporary root filesystem loaded with the kernel. It contains just enough tools and drivers to find, unlock and mount the real root. See [module 14](14-the-boot-process.md).

**Inode**
:   The filesystem record that holds a file's metadata (owner, mode, size, block locations) but not its name. A filesystem can run out of inodes before it runs out of space. See [module 09](09-disks-and-filesystems.md).

**Inventory (Ansible)**
:   The list of machines Ansible manages, organised into groups, with per-group and per-host variables. See [module 32](32-ansible-and-system-roles.md).

**I/O scheduler**
:   The kernel layer that orders and merges block requests before they reach a device: `none`, `mq-deadline`, `kyber` or `bfq`, set per device in `/sys/block/DEV/queue/scheduler`. See [module 35](35-enterprise-storage.md).

**IQN (iSCSI Qualified Name)**
:   The unique name of an iSCSI initiator or target, such as `iqn.2026-10.test.lab:storage1`. See [module 35](35-enterprise-storage.md).

**iSCSI**
:   A protocol that carries SCSI disk commands over TCP/IP, so a server can use remote block storage as if it were a local disk. Managed with `iscsiadm` on the client. See [module 35](35-enterprise-storage.md).

**isolcpus**
:   A kernel boot argument that removes CPUs from the scheduler's general load balancing, so only tasks pinned there run on them. One of the tools of CPU isolation. See [module 37](37-real-time-and-low-latency.md).

## J

**Journal**
:   systemd's structured, indexed log store, read with `journalctl`. Persistent under `/var/log/journal/`. See [module 08](08-logging-and-the-journal.md).

## K

**KDC (Key Distribution Center)**
:   The Kerberos server that checks your password once and issues tickets. FreeIPA servers and AD domain controllers are KDCs. See [module 26](26-centralized-identity.md).

**kdump**
:   A mechanism that boots a second, small kernel when the main kernel crashes, to save a memory dump (vmcore) for analysis. See [module 24](24-debugging-crashes.md).

**Kerberos**
:   A network authentication protocol based on tickets, used by FreeIPA and Active Directory so users log in once and are trusted across services. See [module 26](26-centralized-identity.md).

**Kernel**
:   The core of the operating system. It manages hardware, memory, processes, filesystems and networking, and everything else asks it for services through system calls. See [module 01](01-how-linux-works.md).

**Kernel module**
:   A piece of kernel code, usually a driver, that can be loaded and unloaded while the system runs (`modprobe`, `lsmod`). See [module 15](15-the-kernel.md).

**kernel-rt**
:   Rocky's real-time kernel package, built with PREEMPT_RT, from the disabled-by-default `rt` repository. See [module 37](37-real-time-and-low-latency.md).

**kexec**
:   A mechanism for booting a new kernel directly from a running one, skipping firmware. kdump uses it to start the capture kernel after a crash. See [module 24](24-debugging-crashes.md).

**Keytab**
:   A file holding a Kerberos principal's long-term keys, so a host or service can authenticate without a typed password. The host's keytab is `/etc/krb5.keytab`; protect it like a password. See [module 26](26-centralized-identity.md).

**Kickstart**
:   A text file that answers every installer question, so Rocky can be installed automatically and identically on many machines. See [module 23](23-automated-installs.md).

**Koji**
:   The RPM build system used by Fedora and CentOS, which schedules builds in clean `mock` buildroots and tracks every build's inputs. Rocky has used both Koji and its own Peridot. See [module 21](21-inside-rocky-linux.md).

**KSM (Kernel Samepage Merging)**
:   A kernel feature that finds identical memory pages in different processes (typically VMs) and keeps one shared copy. See [module 25](25-memory-deep-dive.md).

**KVM**
:   The Linux kernel's built-in hypervisor, which turns Rocky into a host for virtual machines, managed with libvirt and `virsh`. See [module 27](27-virtualization-kvm.md).

## L

**Leap second**
:   An extra second occasionally inserted into UTC. chrony can step, slew or "smear" it; a mismatched approach across machines causes brief clock disagreements. See [module 36](36-time-synchronization.md).

**libvirt**
:   The management layer for KVM virtual machines: it stores VM definitions as XML, starts QEMU, sets up networks and storage, and applies SELinux labels and cgroups. `virsh`, `virt-install`, `virt-manager` and Cockpit all use it. See [module 27](27-virtualization-kvm.md).

**LIO**
:   The Linux kernel's built-in SCSI target, which lets a Rocky server export disks over iSCSI. Configured with `targetcli`. See [module 35](35-enterprise-storage.md).

**Live migration**
:   Moving a running VM to another host with only a brief pause, by copying its memory while it runs and re-copying pages it dirties. See [module 27](27-virtualization-kvm.md).

**Load average**
:   The average number of tasks running, waiting for a CPU, or in uninterruptible sleep over about 1, 5 and 15 minutes. Compare it with the number of CPUs. See [module 19](19-performance-and-observability.md).

**Lockdown (kernel)**
:   A kernel mode, enabled automatically under Secure Boot, that stops even root from modifying the running kernel: no unsigned modules, no raw `/dev/mem` writes, no hibernation. Shown in `/sys/kernel/security/lockdown`. See [module 29](29-secure-boot-and-drivers.md).

**Logical volume (LV)**
:   A flexible virtual partition carved from an LVM volume group. It can be resized, snapshotted and moved between disks. See [module 10](10-lvm-raid-and-encryption.md).

**LUKS**
:   Linux Unified Key Setup, the standard for full-disk encryption on Linux, managed with `cryptsetup`. See [module 10](10-lvm-raid-and-encryption.md).

**LUN (Logical Unit Number)**
:   One addressable disk exported by a SCSI or iSCSI target. A single target can expose several LUNs. See [module 35](35-enterprise-storage.md).

**LVM**
:   Logical Volume Manager: a layer that pools disks into volume groups and carves flexible logical volumes from them. See [module 10](10-lvm-raid-and-encryption.md).

## M

**Magic SysRq**
:   Kernel key combinations (or writes to `/proc/sysrq-trigger`) that act even when the system is hung: dump blocked tasks (`w`), sync, reboot, or force a crash (`c`) for kdump. See [module 24](24-debugging-crashes.md).

**MCS (Multi-Category Security)**
:   The category part of an SELinux label (`s0:c214,c739`). Podman gives each container different categories so containers cannot read each other's files. See [module 18](18-containers.md).

**ML-DSA**
:   A post-quantum digital signature algorithm (FIPS 204, formerly Dilithium) that can replace RSA and ECDSA in certificates. See [module 33](33-tls-and-crypto-policies.md).

**ML-KEM**
:   A post-quantum key encapsulation mechanism (FIPS 203, formerly Kyber). TLS uses it as a hybrid with X25519 (`X25519MLKEM768`), so the connection stays safe if either algorithm holds. See [module 33](33-tls-and-crypto-policies.md).

**mock**
:   A tool that builds RPMs inside a clean, throwaway chroot containing only the declared build dependencies, so builds are reproducible. From EPEL. See [module 22](22-building-rpms.md).

**MOK (Machine Owner Key)**
:   A key you enroll yourself (with `mokutil` and a confirmation at the console on next boot) so shim and the kernel trust modules or boot files you signed. See [module 29](29-secure-boot-and-drivers.md).

**Mount**
:   Attaching a filesystem to a directory (the mount point) so its files appear there. See [module 09](09-disks-and-filesystems.md).

**Multipath (dm-multipath)**
:   Combining several paths (cables, switches, controllers) to the same SAN disk into one device in `/dev/mapper`, with failover and load balancing. Managed by `multipathd`; inspected with `multipath -ll`. See [module 35](35-enterprise-storage.md).

## N

**Namespace**
:   A kernel feature that gives a process a private view of one global resource, such as process IDs, network interfaces, hostname or mounts. The basis of containers. See [module 18](18-containers.md).

**NBDE (Network-Bound Disk Encryption)**
:   Unlocking encrypted disks automatically at boot only while the machine can reach a trusted Tang server on its own network. Implemented with Clevis and Tang. See [module 30](30-network-bound-encryption.md).

**netem**
:   A queueing discipline that emulates bad networks by adding delay, jitter, loss, duplication or reordering to an interface. Applied with `tc`. See [module 34](34-nftables-and-traffic-control.md).

**Netfilter**
:   The packet-filtering hooks inside the kernel's network stack. nftables (and therefore firewalld) and conntrack are built on it. See [module 34](34-nftables-and-traffic-control.md).

**NetworkManager**
:   The service that manages all network configuration on Rocky. Configure it with `nmcli`, `nmtui` or keyfiles in `/etc/NetworkManager/system-connections/`. See [module 11](11-networking.md).

**NFS**
:   Network File System, the standard Unix way to share directories over the network. See [module 13](13-nfs-and-samba.md).

**nftables**
:   The kernel's packet filtering framework, which replaced iptables. firewalld generates nftables rules for you. See [module 12](12-firewalld.md).

**nohz_full**
:   A kernel boot argument that stops the periodic scheduler tick on the listed CPUs when only one task runs there, removing a source of jitter. See [module 37](37-real-time-and-low-latency.md).

**NQN (NVMe Qualified Name)**
:   The unique name of an NVMe subsystem or host, the NVMe-oF counterpart of an iSCSI IQN. See [module 35](35-enterprise-storage.md).

**NSS (Name Service Switch)**
:   The system configured in `/etc/nsswitch.conf` that decides where lookups for users, groups and hosts go: local files, DNS, SSSD and so on. See [module 03](03-users-groups-and-sudo.md).

**NTP (Network Time Protocol)**
:   The protocol computers use to synchronise their clocks over a network, measuring offset and round-trip delay to each server. See [module 36](36-time-synchronization.md).

**NTS (Network Time Security)**
:   An extension that authenticates NTP using a TLS key exchange (RFC 8915), so an attacker can't forge time replies. Enabled per server with the `nts` option in chrony. See [module 36](36-time-synchronization.md).

**NUMA (Non-Uniform Memory Access)**
:   A machine design where each CPU socket has its own local memory; reaching another socket's memory is slower. Inspected with `numactl --hardware` and `numastat`. See [module 25](25-memory-deep-dive.md).

**NVMe-oF (NVMe over Fabrics)**
:   The NVMe protocol carried over a network (TCP, RDMA or Fibre Channel) instead of PCIe, giving remote flash storage with low overhead. Managed with `nvme-cli`. See [module 35](35-enterprise-storage.md).

## O

**OOM killer**
:   The kernel mechanism that kills a process when memory runs out completely, leaving an `Out of memory: Killed process` message in the kernel log. See [module 25](25-memory-deep-dive.md).

**Oops**
:   The kernel detecting a serious error in itself and printing a report (registers, call trace, taint flags). It may kill the offending task and keep running, or escalate to a panic. See [module 24](24-debugging-crashes.md).

**Overcommit**
:   The kernel promising processes more virtual memory than physically exists, betting that not all of it will be used. Controlled by `vm.overcommit_memory`; when the bet fails, the OOM killer acts. See [module 25](25-memory-deep-dive.md).

**Overlayfs**
:   A filesystem that stacks read-only directories (image layers) under one writable directory and shows them as one tree. How containers get their root filesystem. See [module 18](18-containers.md).

## P

**Pacemaker**
:   The cluster resource manager used for high availability on Rocky. It moves services between nodes when one fails. Managed with `pcs`. See [module 28](28-high-availability.md).

**Page cache**
:   Memory the kernel uses to cache file contents. It makes reads fast and is given back when programs need memory, which is why `free` looks small on a healthy system. See [module 25](25-memory-deep-dive.md).

**Page fault**
:   The CPU trapping into the kernel because a process touched memory that isn't mapped yet. A **minor** fault is resolved from RAM; a **major** fault must wait for disk. See [module 25](25-memory-deep-dive.md).

**PAM (Pluggable Authentication Modules)**
:   The framework that handles authentication for logins, `sudo`, `sshd` and more, configured in `/etc/pam.d/`. See [module 03](03-users-groups-and-sudo.md).

**Panic (kernel panic)**
:   A fatal kernel error after which the kernel stops. With kdump armed, a panic boots the capture kernel to save a vmcore. See [module 24](24-debugging-crashes.md).

**Partition**
:   A slice of a disk with its own filesystem or purpose, recorded in a partition table (GPT on modern systems). See [module 09](09-disks-and-filesystems.md).

**PCR (Platform Configuration Register)**
:   A TPM register that accumulates hashes of what booted (firmware, Secure Boot state, boot loader). A secret sealed to PCR values is released only if the boot measured the same. PCR 7 (Secure Boot policy) is the common choice. See [module 30](30-network-bound-encryption.md).

**Peridot**
:   A cloud-native RPM build system written by the Rocky community, used to build Rocky Linux 9. See [module 21](21-inside-rocky-linux.md).

**Permissive mode**
:   An SELinux mode where denials are logged but not enforced. Useful for brief testing, never as a fix. See [module 16](16-selinux.md).

**PHC (PTP Hardware Clock)**
:   A clock inside a network card that timestamps packets in hardware for PTP. `phc2sys` copies its time to the system clock. See [module 36](36-time-synchronization.md).

**PID (Process ID)**
:   The number that identifies a process. PID 1 is systemd, the ancestor of all other processes. See [module 06](06-processes-and-signals.md).

**Pipe**
:   A connection that feeds one command's output into another's input, written `|`. See [module 02](02-shell-and-filesystem.md).

**Playbook**
:   An Ansible YAML file of plays, each mapping a group of hosts to an ordered list of tasks. Run with `ansible-playbook`. See [module 32](32-ansible-and-system-roles.md).

**Pod**
:   A group of containers that share a network namespace and reach each other on `localhost`, as in Kubernetes. See [module 18](18-containers.md).

**Podman**
:   Rocky's daemonless container engine. Runs OCI containers, supports rootless use, and integrates with systemd through Quadlet. See [module 18](18-containers.md).

**PREEMPT_RT**
:   The kernel configuration that makes almost all kernel code preemptible (interrupt handlers become threads, spinlocks become sleeping locks), giving bounded worst-case latency. Built into `kernel-rt`. See [module 37](37-real-time-and-low-latency.md).

**Principal (Kerberos)**
:   A name in a Kerberos realm: a user (`alice@LAB.TEST`) or a service (`host/client1.lab.test@LAB.TEST`). See [module 26](26-centralized-identity.md).

**Process**
:   A running program: code plus its memory, open files, user identity and other state, with a PID. See [module 06](06-processes-and-signals.md).

**procfs (/proc)**
:   A virtual filesystem where the kernel exposes information about processes and itself as files, such as `/proc/meminfo` and `/proc/PID/status`. See [module 01](01-how-linux-works.md).

**PSI (Pressure Stall Information)**
:   Kernel statistics in `/proc/pressure/` showing what percentage of time tasks were stalled waiting for CPU, memory or I/O. See [module 19](19-performance-and-observability.md) and [module 25](25-memory-deep-dive.md).

**PSS (Proportional Set Size)**
:   A process's memory with shared pages divided among the processes sharing them, so PSS values add up correctly across processes, unlike RSS. See [module 25](25-memory-deep-dive.md).

**PTP (Precision Time Protocol)**
:   IEEE 1588 time synchronisation using hardware timestamps in NICs and switches, reaching sub-microsecond accuracy on a LAN. Provided by `linuxptp` (`ptp4l`, `phc2sys`). See [module 36](36-time-synchronization.md).

**PXE (Preboot Execution Environment)**
:   Network booting: firmware gets an address and a boot file name from DHCP, downloads the boot loader over TFTP, and starts the installer without any local media. UEFI HTTP boot is the modern variant. See [module 23](23-automated-installs.md).

## Q

**qcow2**
:   QEMU's copy-on-write disk image format, supporting thin provisioning, backing files and internal snapshots. See [module 27](27-virtualization-kvm.md).

**qdisc (queueing discipline)**
:   The algorithm that decides how packets queue and leave a network interface: `fq_codel` by default, or `tbf`, `htb`, `netem` and others set with `tc`. See [module 34](34-nftables-and-traffic-control.md).

**QEMU**
:   The user-space program that emulates a VM's devices and, with KVM, runs its CPUs at near-native speed. Each running VM is one `qemu-kvm` process. See [module 27](27-virtualization-kvm.md).

**Quadlet**
:   Podman's way to run containers as systemd services: a short `.container` file that a systemd generator turns into a full unit. See [module 18](18-containers.md).

**Quorum**
:   The rule that a cluster partition may run resources only if it holds a majority of votes, which stops two halves from both acting. Two-node clusters need special handling or a quorum device. See [module 28](28-high-availability.md).

## R

**RAID**
:   Combining several disks for redundancy, speed or both. On Rocky, done with `mdadm` or LVM RAID. See [module 10](10-lvm-raid-and-encryption.md).

**rd.break**
:   A kernel argument that stops boot inside the initramfs with a shell, used to reset a lost root password. See [module 20](20-troubleshooting-playbook.md).

**Realm (Kerberos)**
:   A Kerberos administrative domain, written in capitals (`LAB.TEST`), usually matching the DNS domain. See [module 26](26-centralized-identity.md).

**ReaR (Relax-and-Recover)**
:   A bare-metal disaster recovery tool that builds a bootable rescue image of a system, recreates its disk layout on new hardware, and restores the backup. See [module 31](31-disaster-recovery-and-migration.md).

**Repository (repo)**
:   A server directory of RPM packages plus metadata that DNF downloads from. Configured in `/etc/yum.repos.d/`. See [module 05](05-software-rpm-and-dnf.md).

**Rescue mode**
:   A systemd target (`rescue.target`) with local filesystems mounted but no network services, for repairs as root. See [module 14](14-the-boot-process.md).

**Resource (Pacemaker)**
:   Anything a cluster starts, stops and monitors: an IP address, a filesystem, a service. Each is driven by a resource agent (OCF script or systemd unit). See [module 28](28-high-availability.md).

**Rocky Linux**
:   A free, community enterprise Linux distribution, compatible with Red Hat Enterprise Linux, governed by the Rocky Enterprise Software Foundation. See [module 21](21-inside-rocky-linux.md).

**Role (Ansible)**
:   A reusable bundle of tasks, handlers, templates and default variables with a standard directory layout. See [module 32](32-ansible-and-system-roles.md).

**Rootless container**
:   A container run by an ordinary user, with no root privileges anywhere. Root inside maps to the user's own UID on the host through a user namespace. See [module 18](18-containers.md).

**RPM**
:   Both the package file format (`.rpm`) and the low-level tool that installs, queries and verifies packages. DNF uses it underneath. See [module 05](05-software-rpm-and-dnf.md).

**RPO (Recovery Point Objective)**
:   How much data you can afford to lose, measured in time. Nightly backups mean an RPO of up to 24 hours. See [module 31](31-disaster-recovery-and-migration.md).

**RSS (Resident Set Size)**
:   The physical RAM a process is using right now, not counting memory swapped out or never touched. See [module 25](25-memory-deep-dive.md).

**RTO (Recovery Time Objective)**
:   How long a service can be down before recovery must be complete. See [module 31](31-disaster-recovery-and-migration.md).

**Run queue**
:   The list of tasks ready to run and waiting for a CPU. A long run queue means CPU saturation. See [module 19](19-performance-and-observability.md).

## S

**Samba**
:   The software that lets Linux share files and printers with Windows using the SMB protocol, and join Active Directory. See [module 13](13-nfs-and-samba.md).

**SAN (Storage Area Network)**
:   A network dedicated to block storage, over which servers use remote disks (iSCSI, Fibre Channel, NVMe-oF) as if they were local. See [module 35](35-enterprise-storage.md).

**sar**
:   The sysstat tool that reports current and historical system activity from data in `/var/log/sa/`. See [module 19](19-performance-and-observability.md).

**SBAT (Secure Boot Advanced Targeting)**
:   Version metadata embedded in shim and GRUB that lets whole generations of vulnerable boot components be revoked by number instead of by hash, so the firmware's `dbx` doesn't overflow. See [module 29](29-secure-boot-and-drivers.md).

**SCHED_FIFO**
:   A real-time scheduling policy: the highest-priority runnable task runs until it blocks or yields, ahead of every normal task. Set with `chrt -f`. See [module 37](37-real-time-and-low-latency.md).

**Scope (systemd)**
:   A unit that groups processes systemd did not start itself, such as a login session or a container, so they get their own cgroup. See [module 18](18-containers.md).

**Scriptlet**
:   A small shell script inside an RPM that runs on the target machine at install, upgrade or removal (`%pre`, `%post`, `%preun`, `%postun`). See [module 22](22-building-rpms.md).

**seccomp**
:   A kernel filter that limits which system calls a process may make. Containers use a default seccomp profile to block dangerous calls. See [module 18](18-containers.md).

**Secure Boot**
:   A UEFI feature where firmware runs only boot code signed by a trusted key, and each stage verifies the next: firmware, shim, GRUB, kernel, modules. See [module 29](29-secure-boot-and-drivers.md).

**SELinux**
:   Security-Enhanced Linux: mandatory access control that labels every process and file and allows only what the policy permits, even for root. See [module 16](16-selinux.md).

**Service unit**
:   A systemd unit (`.service`) describing how to start, stop and supervise a program. See [module 07](07-systemd-and-services.md).

**Shamir's Secret Sharing (sss)**
:   A way of splitting a secret into shares so that any *t* of them can rebuild it. Clevis's `sss` pin uses it to require, for example, Tang *and* the TPM. See [module 30](30-network-bound-encryption.md).

**Shell**
:   The program that reads your commands and runs them. Rocky's default is bash. See [module 02](02-shell-and-filesystem.md).

**shim**
:   A small first-stage boot loader signed by Microsoft's UEFI CA and carrying Rocky's certificate, so standard Secure Boot firmware can start Rocky's GRUB and kernel. It also manages MOKs. See [module 29](29-secure-boot-and-drivers.md).

**SIG (Special Interest Group)**
:   A Rocky community team that maintains extra packages or builds beyond the core distribution, such as SIG/Cloud, SIG/Kernel and SIG/AltArch. See [module 21](21-inside-rocky-linux.md).

**Signal**
:   A short message the kernel delivers to a process, such as `SIGTERM` (please exit), `SIGKILL` (die now) or `SIGHUP` (reload). See [module 06](06-processes-and-signals.md).

**Slew and step**
:   The two ways to correct a clock: **slewing** runs it slightly fast or slow until the error is gone (time never jumps), **stepping** jumps it at once. chrony slews by default and steps only when told or at startup. See [module 36](36-time-synchronization.md).

**Slice (systemd)**
:   A branch of the cgroup tree used to group and share resources between units: `system.slice`, `user.slice`, `machine.slice`. See [module 18](18-containers.md).

**SMB**
:   Server Message Block, the Windows file sharing protocol, provided on Linux by Samba. See [module 13](13-nfs-and-samba.md).

**SMI (System Management Interrupt)**
:   A firmware interrupt that freezes every CPU, invisibly to the OS, to run vendor housekeeping code. A source of unexplained latency spikes, found with `hwlatdetect`. See [module 37](37-real-time-and-low-latency.md).

**Snapshot (LVM)**
:   A point-in-time copy of a logical volume that stores only changed blocks, useful before risky changes. See [module 10](10-lvm-raid-and-encryption.md).

**SNI (Server Name Indication)**
:   The hostname a TLS client sends in its first message, so one IP address can serve many sites with different certificates. See [module 33](33-tls-and-crypto-policies.md).

**Spec file**
:   The recipe for an RPM: where the source comes from, how to build and install it, which files belong to the package, its dependencies and scriptlets. Built with `rpmbuild`. See [module 22](22-building-rpms.md).

**Split brain**
:   When cluster nodes lose contact and more than one believes it should run the same resource, risking data corruption. Quorum and fencing prevent it. See [module 28](28-high-availability.md).

**SRPM (source RPM)**
:   A `.src.rpm` package holding a spec file plus the source tarballs and patches, from which binary RPMs are built. See [module 22](22-building-rpms.md).

**SSH**
:   Secure Shell: an encrypted protocol for logging in and running commands on remote machines. The server is `sshd`. See [module 17](17-security-hardening.md).

**SSSD**
:   The System Security Services Daemon, which connects Rocky to central identity services like FreeIPA and Active Directory and caches logins. See [module 26](26-centralized-identity.md).

**Sticky bit**
:   A directory permission (`t`) that lets only a file's owner delete it, even if others can write to the directory. Set on `/tmp`. See [module 04](04-permissions-and-acls.md).

**STONITH ("Shoot The Other Node In The Head")**
:   Pacemaker's fencing: forcibly powering off or isolating a node that stopped responding, before its resources are started elsewhere, so it can't corrupt shared data. Required for a supported cluster. See [module 28](28-high-availability.md).

**Stratum**
:   A time source's distance from a reference clock: a GPS-fed server is stratum 1, its clients stratum 2, and so on. Lower isn't automatically better; measured accuracy matters more. See [module 36](36-time-synchronization.md).

**Subject Alternative Name (SAN)**
:   The certificate extension listing the DNS names and IP addresses it is valid for. Clients check only this, not the Common Name. See [module 33](33-tls-and-crypto-policies.md).

**subuid / subgid**
:   Ranges of extra user and group IDs, assigned in `/etc/subuid` and `/etc/subgid`, that rootless containers map into their user namespace. See [module 18](18-containers.md).

**sudo**
:   A tool that lets permitted users run commands as root (or another user), with each use logged. Membership in `wheel` grants it on Rocky. See [module 03](03-users-groups-and-sudo.md).

**sVirt**
:   libvirt's use of SELinux to give each VM process and its disk images a unique MCS category, so a compromised VM can't touch another VM's files. See [module 27](27-virtualization-kvm.md).

**Swap**
:   Disk space used as overflow for memory pages that have not been used recently. See [module 09](09-disks-and-filesystems.md).

**Symbolic link (symlink)**
:   A small file that points to another path by name. If the target is removed, the link breaks. See [module 02](02-shell-and-filesystem.md).

**sysctl**
:   A kernel tunable under `/proc/sys`, read and set with the `sysctl` command and made permanent in `/etc/sysctl.d/`. See [module 15](15-the-kernel.md).

**sysfs (/sys)**
:   A virtual filesystem where the kernel exposes devices, drivers and settings, including the cgroup tree at `/sys/fs/cgroup`. See [module 15](15-the-kernel.md).

**System call**
:   A request from a program to the kernel, such as `openat`, `read` or `execve`. The only way user programs get the kernel to act. See [module 01](01-how-linux-works.md).

**System Roles**
:   Ansible roles maintained by Red Hat and the linux-system-roles project (package `rhel-system-roles`) that configure common subsystems such as networking, time, SELinux and storage through one stable interface. See [module 32](32-ansible-and-system-roles.md).

**systemd**
:   PID 1 on Rocky: the init system and service manager that boots the system, starts and supervises services, and manages logs, timers and cgroups. See [module 07](07-systemd-and-services.md).

## T

**Taint (kernel)**
:   Flags the kernel sets when something happened that may make bug reports unreliable, such as loading a proprietary or unsigned module or a previous oops. Read from `/proc/sys/kernel/tainted`; 0 means clean. See [module 24](24-debugging-crashes.md).

**Tang**
:   A tiny, stateless HTTP server that helps Clevis clients recover their disk keys without ever learning them. If a disk leaves the network, Tang is unreachable and the disk stays locked. See [module 30](30-network-bound-encryption.md).

**Target (storage)**
:   The server side of a SAN protocol, which receives commands and serves disks (LUNs or namespaces). On Rocky, LIO provides iSCSI targets and `nvmet` NVMe targets. See [module 35](35-enterprise-storage.md).

**Target (systemd)**
:   A unit that groups others into a system state, such as `multi-user.target` or `graphical.target`. Replaces old runlevels. See [module 07](07-systemd-and-services.md).

**tc (traffic control)**
:   The command that configures qdiscs, classes and filters on network interfaces, for shaping, policing, prioritising and emulating networks. See [module 34](34-nftables-and-traffic-control.md).

**TGT (Ticket-Granting Ticket)**
:   The Kerberos ticket you get from the KDC when you log in (`kinit`). It proves who you are when you ask for service tickets, so you don't type your password again. See [module 26](26-centralized-identity.md).

**THP (Transparent Huge Pages)**
:   The kernel automatically backing large memory regions with 2 MiB pages. Usually a win, but some databases recommend `madvise` or `never` because of latency from compaction. Mode in `/sys/kernel/mm/transparent_hugepage/enabled`. See [module 25](25-memory-deep-dive.md).

**Timer (systemd)**
:   A `.timer` unit that starts a service on a schedule or after a delay, replacing many cron jobs. See [module 07](07-systemd-and-services.md).

**TLS (Transport Layer Security)**
:   The protocol that encrypts and authenticates network connections (HTTPS, SMTPS, LDAPS). Rocky's TLS libraries follow the system crypto policy. See [module 33](33-tls-and-crypto-policies.md).

**TPM (Trusted Platform Module)**
:   A security chip (or firmware equivalent) that stores keys and records boot measurements in PCRs, and can seal secrets so they are released only to an unmodified boot. See [module 30](30-network-bound-encryption.md).

**Trust store**
:   The set of CA certificates the system trusts, managed by `ca-certificates` and `update-ca-trust`; add private CAs in `/etc/pki/ca-trust/source/anchors/`. See [module 33](33-tls-and-crypto-policies.md).

**tuned**
:   A service that applies a profile of performance settings for a workload type, managed with `tuned-adm`. See [module 19](19-performance-and-observability.md).

**Type enforcement**
:   The core SELinux rule style: a process of one type (domain) may access objects of certain types in certain ways. Everything else is denied. See [module 16](16-selinux.md).

## U

**UID (User ID)**
:   The number that identifies a user. UID 0 is root. Files store UIDs, not names. See [module 03](03-users-groups-and-sudo.md).

**umask**
:   A per-process mask that removes permission bits from newly created files, typically `0022`. See [module 04](04-permissions-and-acls.md).

**Unit**
:   Anything systemd manages, described by a unit file: services, sockets, timers, mounts, targets, slices, scopes. See [module 07](07-systemd-and-services.md).

**USE method**
:   A performance method: for every resource, check Utilization, Saturation and Errors. See [module 19](19-performance-and-observability.md).

**User namespace**
:   A namespace that maps user IDs inside to different IDs outside, so a process can be root inside while unprivileged on the host. See [module 18](18-containers.md).

**User space**
:   Everything that runs outside the kernel: shells, services and applications. User programs must ask the kernel to touch hardware. See [module 01](01-how-linux-works.md).

**UUID**
:   A unique identifier for a filesystem or partition, used in `/etc/fstab` so mounts survive device name changes. See [module 09](09-disks-and-filesystems.md).

## V

**Vault (Rocky)**
:   The archive of older Rocky minor releases and their packages, kept at `dl.rockylinux.org/vault` after mirrors move on to the latest release. See [module 21](21-inside-rocky-linux.md).

**vDSO**
:   A tiny library the kernel maps into every process so that time calls like `clock_gettime()` run in user space without a real system call. See [module 01](01-how-linux-works.md).

**virtio**
:   Paravirtualized device drivers (disk, network, balloon, RNG) designed for VMs, much faster than emulating real hardware. Disks appear as `/dev/vda`. See [module 27](27-virtualization-kvm.md).

**vmcore**
:   The memory dump of a crashed kernel saved by kdump under `/var/crash/`, analysed with the `crash` tool. See [module 24](24-debugging-crashes.md).

**Volume group (VG)**
:   An LVM pool made from one or more physical volumes, from which logical volumes are allocated. See [module 10](10-lvm-raid-and-encryption.md).

## W

**wheel**
:   The administrative group on Rocky. Members may use `sudo`. See [module 03](03-users-groups-and-sudo.md).

**WWN / WWID**
:   A worldwide unique identifier for a storage device. Multipath uses it to recognise that several paths lead to the same disk; stable names appear in `/dev/disk/by-id/`. See [module 35](35-enterprise-storage.md).

## X

**X.509 certificate**
:   The standard certificate format: a public key plus subject, issuer, validity dates and extensions, signed by a CA. Inspected with `openssl x509`. See [module 33](33-tls-and-crypto-policies.md).

**x86-64-v3**
:   A level of the x86-64 instruction set that includes AVX2, BMI2 and FMA. Rocky 10 on x86 is built for it, so older CPUs (and VMs with a generic CPU model) can't run it. See [module 00](00-start-here.md).

**XFS**
:   Rocky's default filesystem: fast and scalable. It can grow but cannot shrink. See [module 09](09-disks-and-filesystems.md).

## Z

**Zombie process**
:   A process that has exited but whose parent has not yet collected its exit status. Shown as `Z` in `ps`; it uses no resources except a process table slot. See [module 06](06-processes-and-signals.md).

**Zone (firewalld)**
:   A named trust level (`public`, `internal`, `trusted`...) with its own rules, applied to interfaces or source networks. See [module 12](12-firewalld.md).

**zram**
:   A compressed block device in RAM, used as fast swap. See [module 25](25-memory-deep-dive.md).
