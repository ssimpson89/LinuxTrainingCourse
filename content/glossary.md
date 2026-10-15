---
title: Glossary
description: Plain-English definitions of the Linux and Rocky Linux terms used in this course, each linked to the module that covers it.
---

# Glossary

Plain-English definitions of the terms used across the course, in alphabetical order. Each entry links to the module that explains it in depth. Use your browser's find (++ctrl+f++) or the site search to jump to a term.

This glossary has 118 terms.

## A

**ACL (Access Control List)**
:   Extra permission entries on a file that grant or deny access to specific users or groups beyond the owner/group/other bits. Managed with `getfacl` and `setfacl`. See [module 04](04-permissions-and-acls.md).

**AppStream**
:   The Rocky Linux repository holding applications, languages and tools, alongside BaseOS. It is updated alongside BaseOS with every minor release. See [module 05](05-software-rpm-and-dnf.md).

**Audit log**
:   The kernel audit system's record of security events, including SELinux denials, logins and `sudo` use, in `/var/log/audit/audit.log`. Searched with `ausearch`. See [module 16](16-selinux.md).

**AVC denial**
:   An SELinux "access vector cache" message saying the policy blocked an action. Each one names the process (source context), the object (target context) and the permission. See [module 16](16-selinux.md).

## B

**BaseOS**
:   The core Rocky Linux repository: the kernel, systemd, core libraries and tools that every system needs. See [module 05](05-software-rpm-and-dnf.md).

**Bind mount**
:   Mounting an existing directory at a second location so the same files appear in both places. Containers use bind mounts for volumes. See [module 18](18-containers.md).

**Boot Loader Specification (BLS)**
:   A standard where each boot menu entry is a small file in `/boot/loader/entries/`. Rocky's GRUB reads these, and `grubby` edits them. See [module 14](14-the-boot-process.md).

**bpftrace**
:   A small scripting language for writing eBPF tracing one-liners, such as counting system calls per process. See [module 19](19-performance-and-observability.md).

## C

**Capability**
:   One slice of root's power, such as `CAP_NET_BIND_SERVICE` (bind low ports) or `CAP_SYS_ADMIN`. Lets a process have some root powers without all of them. See [module 17](17-security-hardening.md).

**cgroup (control group)**
:   A kernel feature that groups processes so their CPU, memory, I/O and process count can be measured and limited together. Rocky 10 uses only cgroup v2, a single tree under `/sys/fs/cgroup`. See [module 18](18-containers.md).

**chroot**
:   Changing a process's idea of the root directory `/`. Used in recovery (`chroot /sysroot`) and as one of the ideas behind containers. See [module 20](20-troubleshooting-playbook.md).

**Cockpit**
:   A web-based admin console for Rocky (port 9090) showing metrics, services, logs, storage and more. See [module 19](19-performance-and-observability.md).

**Container**
:   A normal process isolated with namespaces, limited with cgroups, given its own filesystem image and restricted by SELinux, seccomp and capabilities. It shares the host's kernel. See [module 18](18-containers.md).

**Context (SELinux)**
:   The label on every process and file, written `user:role:type:level`, e.g. `system_u:object_r:httpd_sys_content_t:s0`. The type part drives most decisions. See [module 16](16-selinux.md).

**Core dump**
:   A file containing a crashed program's memory at the moment it died, used to debug the crash. On Rocky, `systemd-coredump` stores them and `coredumpctl` lists them. See [module 24](24-debugging-crashes.md).

**CRB (CodeReady Builder)**
:   A Rocky repository of extra development packages, disabled by default, that many EPEL packages depend on. See [module 05](05-software-rpm-and-dnf.md).

**crun**
:   The low-level OCI container runtime Podman uses on Rocky. It creates the namespaces and cgroups and starts the container's first process. See [module 18](18-containers.md).

**Crypto policy**
:   A system-wide setting (`DEFAULT`, `FUTURE`, `LEGACY`, `FIPS`) that controls which ciphers and protocols every library allows. Set with `update-crypto-policies`. See [module 17](17-security-hardening.md).

## D

**D state (uninterruptible sleep)**
:   A process waiting inside the kernel, usually for disk or NFS I/O, that ignores signals, even `kill -9`, until the I/O completes (NFS waits use a "killable" variant that `SIGKILL` can end). Counts toward load average. See [module 06](06-processes-and-signals.md).

**Daemon**
:   A background program with no terminal, usually started by systemd, such as `sshd` or `chronyd`. See [module 07](07-systemd-and-services.md).

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

**Exit code**
:   The number a program returns when it ends: 0 for success, anything else for failure. systemd also reports its own codes such as `203/EXEC`. See [module 07](07-systemd-and-services.md).

## F

**FHS (Filesystem Hierarchy Standard)**
:   The convention for where things live: `/etc` for config, `/var` for changing data, `/usr` for programs, and so on. See [module 02](02-shell-and-filesystem.md).

**File descriptor**
:   A small number a process uses to refer to an open file, socket or pipe. 0, 1 and 2 are standard input, output and error. See [module 01](01-how-linux-works.md).

**firewalld**
:   Rocky's firewall service. It organises rules into zones and services and programs the kernel's nftables underneath. See [module 12](12-firewalld.md).

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

## I

**Initramfs**
:   A compressed temporary root filesystem loaded with the kernel. It contains just enough tools and drivers to find, unlock and mount the real root. See [module 14](14-the-boot-process.md).

**Inode**
:   The filesystem record that holds a file's metadata (owner, mode, size, block locations) but not its name. A filesystem can run out of inodes before it runs out of space. See [module 09](09-disks-and-filesystems.md).

## J

**Journal**
:   systemd's structured, indexed log store, read with `journalctl`. Persistent under `/var/log/journal/`. See [module 08](08-logging-and-the-journal.md).

## K

**kdump**
:   A mechanism that boots a second, small kernel when the main kernel crashes, to save a memory dump (vmcore) for analysis. See [module 24](24-debugging-crashes.md).

**Kerberos**
:   A network authentication protocol based on tickets, used by FreeIPA and Active Directory so users log in once and are trusted across services. See [module 26](26-centralized-identity.md).

**Kernel**
:   The core of the operating system. It manages hardware, memory, processes, filesystems and networking, and everything else asks it for services through system calls. See [module 01](01-how-linux-works.md).

**Kernel module**
:   A piece of kernel code, usually a driver, that can be loaded and unloaded while the system runs (`modprobe`, `lsmod`). See [module 15](15-the-kernel.md).

**Kickstart**
:   A text file that answers every installer question, so Rocky can be installed automatically and identically on many machines. See [module 23](23-automated-installs.md).

**KVM**
:   The Linux kernel's built-in hypervisor, which turns Rocky into a host for virtual machines, managed with libvirt and `virsh`. See [module 27](27-virtualization-kvm.md).

## L

**Load average**
:   The average number of tasks running, waiting for a CPU, or in uninterruptible sleep over about 1, 5 and 15 minutes. Compare it with the number of CPUs. See [module 19](19-performance-and-observability.md).

**Logical volume (LV)**
:   A flexible virtual partition carved from an LVM volume group. It can be resized, snapshotted and moved between disks. See [module 10](10-lvm-raid-and-encryption.md).

**LUKS**
:   Linux Unified Key Setup, the standard for full-disk encryption on Linux, managed with `cryptsetup`. See [module 10](10-lvm-raid-and-encryption.md).

**LVM**
:   Logical Volume Manager: a layer that pools disks into volume groups and carves flexible logical volumes from them. See [module 10](10-lvm-raid-and-encryption.md).

## M

**MCS (Multi-Category Security)**
:   The category part of an SELinux label (`s0:c214,c739`). Podman gives each container different categories so containers cannot read each other's files. See [module 18](18-containers.md).

**Mount**
:   Attaching a filesystem to a directory (the mount point) so its files appear there. See [module 09](09-disks-and-filesystems.md).

## N

**Namespace**
:   A kernel feature that gives a process a private view of one global resource, such as process IDs, network interfaces, hostname or mounts. The basis of containers. See [module 18](18-containers.md).

**NetworkManager**
:   The service that manages all network configuration on Rocky. Configure it with `nmcli`, `nmtui` or keyfiles in `/etc/NetworkManager/system-connections/`. See [module 11](11-networking.md).

**NFS**
:   Network File System, the standard Unix way to share directories over the network. See [module 13](13-nfs-and-samba.md).

**nftables**
:   The kernel's packet filtering framework, which replaced iptables. firewalld generates nftables rules for you. See [module 12](12-firewalld.md).

**NSS (Name Service Switch)**
:   The system configured in `/etc/nsswitch.conf` that decides where lookups for users, groups and hosts go: local files, DNS, SSSD and so on. See [module 03](03-users-groups-and-sudo.md).

## O

**OOM killer**
:   The kernel mechanism that kills a process when memory runs out completely, leaving an `Out of memory: Killed process` message in the kernel log. See [module 25](25-memory-deep-dive.md).

**Overlayfs**
:   A filesystem that stacks read-only directories (image layers) under one writable directory and shows them as one tree. How containers get their root filesystem. See [module 18](18-containers.md).

## P

**Pacemaker**
:   The cluster resource manager used for high availability on Rocky. It moves services between nodes when one fails. Managed with `pcs`. See [module 28](28-high-availability.md).

**Page cache**
:   Memory the kernel uses to cache file contents. It makes reads fast and is given back when programs need memory, which is why `free` looks small on a healthy system. See [module 25](25-memory-deep-dive.md).

**PAM (Pluggable Authentication Modules)**
:   The framework that handles authentication for logins, `sudo`, `sshd` and more, configured in `/etc/pam.d/`. See [module 03](03-users-groups-and-sudo.md).

**Partition**
:   A slice of a disk with its own filesystem or purpose, recorded in a partition table (GPT on modern systems). See [module 09](09-disks-and-filesystems.md).

**Permissive mode**
:   An SELinux mode where denials are logged but not enforced. Useful for brief testing, never as a fix. See [module 16](16-selinux.md).

**PID (Process ID)**
:   The number that identifies a process. PID 1 is systemd, the ancestor of all other processes. See [module 06](06-processes-and-signals.md).

**Pipe**
:   A connection that feeds one command's output into another's input, written `|`. See [module 02](02-shell-and-filesystem.md).

**Pod**
:   A group of containers that share a network namespace and reach each other on `localhost`, as in Kubernetes. See [module 18](18-containers.md).

**Podman**
:   Rocky's daemonless container engine. Runs OCI containers, supports rootless use, and integrates with systemd through Quadlet. See [module 18](18-containers.md).

**Process**
:   A running program: code plus its memory, open files, user identity and other state, with a PID. See [module 06](06-processes-and-signals.md).

**procfs (/proc)**
:   A virtual filesystem where the kernel exposes information about processes and itself as files, such as `/proc/meminfo` and `/proc/PID/status`. See [module 01](01-how-linux-works.md).

**PSI (Pressure Stall Information)**
:   Kernel statistics in `/proc/pressure/` showing what percentage of time tasks were stalled waiting for CPU, memory or I/O. See [module 19](19-performance-and-observability.md).

## Q

**Quadlet**
:   Podman's way to run containers as systemd services: a short `.container` file that a systemd generator turns into a full unit. See [module 18](18-containers.md).

## R

**RAID**
:   Combining several disks for redundancy, speed or both. On Rocky, done with `mdadm` or LVM RAID. See [module 10](10-lvm-raid-and-encryption.md).

**rd.break**
:   A kernel argument that stops boot inside the initramfs with a shell, used to reset a lost root password. See [module 20](20-troubleshooting-playbook.md).

**Repository (repo)**
:   A server directory of RPM packages plus metadata that DNF downloads from. Configured in `/etc/yum.repos.d/`. See [module 05](05-software-rpm-and-dnf.md).

**Rescue mode**
:   A systemd target (`rescue.target`) with local filesystems mounted but no network services, for repairs as root. See [module 14](14-the-boot-process.md).

**Rocky Linux**
:   A free, community enterprise Linux distribution, compatible with Red Hat Enterprise Linux, governed by the Rocky Enterprise Software Foundation. See [module 21](21-inside-rocky-linux.md).

**Rootless container**
:   A container run by an ordinary user, with no root privileges anywhere. Root inside maps to the user's own UID on the host through a user namespace. See [module 18](18-containers.md).

**RPM**
:   Both the package file format (`.rpm`) and the low-level tool that installs, queries and verifies packages. DNF uses it underneath. See [module 05](05-software-rpm-and-dnf.md).

**RSS (Resident Set Size)**
:   The physical RAM a process is using right now, not counting memory swapped out or never touched. See [module 25](25-memory-deep-dive.md).

**Run queue**
:   The list of tasks ready to run and waiting for a CPU. A long run queue means CPU saturation. See [module 19](19-performance-and-observability.md).

## S

**Samba**
:   The software that lets Linux share files and printers with Windows using the SMB protocol, and join Active Directory. See [module 13](13-nfs-and-samba.md).

**sar**
:   The sysstat tool that reports current and historical system activity from data in `/var/log/sa/`. See [module 19](19-performance-and-observability.md).

**Scope (systemd)**
:   A unit that groups processes systemd did not start itself, such as a login session or a container, so they get their own cgroup. See [module 18](18-containers.md).

**seccomp**
:   A kernel filter that limits which system calls a process may make. Containers use a default seccomp profile to block dangerous calls. See [module 18](18-containers.md).

**SELinux**
:   Security-Enhanced Linux: mandatory access control that labels every process and file and allows only what the policy permits, even for root. See [module 16](16-selinux.md).

**Service unit**
:   A systemd unit (`.service`) describing how to start, stop and supervise a program. See [module 07](07-systemd-and-services.md).

**Shell**
:   The program that reads your commands and runs them. Rocky's default is bash. See [module 02](02-shell-and-filesystem.md).

**Signal**
:   A short message the kernel delivers to a process, such as `SIGTERM` (please exit), `SIGKILL` (die now) or `SIGHUP` (reload). See [module 06](06-processes-and-signals.md).

**Slice (systemd)**
:   A branch of the cgroup tree used to group and share resources between units: `system.slice`, `user.slice`, `machine.slice`. See [module 18](18-containers.md).

**SMB**
:   Server Message Block, the Windows file sharing protocol, provided on Linux by Samba. See [module 13](13-nfs-and-samba.md).

**Snapshot (LVM)**
:   A point-in-time copy of a logical volume that stores only changed blocks, useful before risky changes. See [module 10](10-lvm-raid-and-encryption.md).

**SSH**
:   Secure Shell: an encrypted protocol for logging in and running commands on remote machines. The server is `sshd`. See [module 17](17-security-hardening.md).

**SSSD**
:   The System Security Services Daemon, which connects Rocky to central identity services like FreeIPA and Active Directory and caches logins. See [module 26](26-centralized-identity.md).

**Sticky bit**
:   A directory permission (`t`) that lets only a file's owner delete it, even if others can write to the directory. Set on `/tmp`. See [module 04](04-permissions-and-acls.md).

**subuid / subgid**
:   Ranges of extra user and group IDs, assigned in `/etc/subuid` and `/etc/subgid`, that rootless containers map into their user namespace. See [module 18](18-containers.md).

**sudo**
:   A tool that lets permitted users run commands as root (or another user), with each use logged. Membership in `wheel` grants it on Rocky. See [module 03](03-users-groups-and-sudo.md).

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

**systemd**
:   PID 1 on Rocky: the init system and service manager that boots the system, starts and supervises services, and manages logs, timers and cgroups. See [module 07](07-systemd-and-services.md).

## T

**Target (systemd)**
:   A unit that groups others into a system state, such as `multi-user.target` or `graphical.target`. Replaces old runlevels. See [module 07](07-systemd-and-services.md).

**Timer (systemd)**
:   A `.timer` unit that starts a service on a schedule or after a delay, replacing many cron jobs. See [module 07](07-systemd-and-services.md).

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

**Volume group (VG)**
:   An LVM pool made from one or more physical volumes, from which logical volumes are allocated. See [module 10](10-lvm-raid-and-encryption.md).

## W

**wheel**
:   The administrative group on Rocky. Members may use `sudo`. See [module 03](03-users-groups-and-sudo.md).

## X

**XFS**
:   Rocky's default filesystem: fast and scalable. It can grow but cannot shrink. See [module 09](09-disks-and-filesystems.md).

## Z

**Zombie process**
:   A process that has exited but whose parent has not yet collected its exit status. Shown as `Z` in `ps`; it uses no resources except a process table slot. See [module 06](06-processes-and-signals.md).

**Zone (firewalld)**
:   A named trust level (`public`, `internal`, `trusted`...) with its own rules, applied to interfaces or source networks. See [module 12](12-firewalld.md).
