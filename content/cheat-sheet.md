---
title: Command Cheat Sheet
description: The most useful Rocky Linux commands from every module, grouped by task, with a link to the module that explains each one.
---

# Command Cheat Sheet

Every command worth remembering from the course, grouped by job. Each row links
to the module that explains it properly. Commands that need root are shown with
`sudo`. Replace words in CAPITALS with your own values.

!!! tip "Finding more"
    Use the search box (press ++s++ or ++slash++) to jump to a command. On a
    real system, `man -k KEYWORD` searches man page summaries and
    `COMMAND --help` prints a short usage summary. Man pages are also on
    [rockyman.org](https://rockyman.org/).

## Files and text

| Command | What it does | Module |
|---------|--------------|--------|
| `pwd`, `cd DIR`, `cd -` | Show / change / go back to the previous directory | [02](02-shell-and-filesystem.md) |
| `ls -lah` | Long listing including hidden files, human sizes | [02](02-shell-and-filesystem.md) |
| `ls -lZ` | Show SELinux labels too | [16](16-selinux.md) |
| `cp -a SRC DST` | Copy, preserving owner, mode, times and links | [02](02-shell-and-filesystem.md) |
| `mv SRC DST`, `rm FILE`, `rm -r DIR` | Move or rename; delete files; delete a tree | [02](02-shell-and-filesystem.md) |
| `mkdir -p a/b/c` | Create a directory and any missing parents | [02](02-shell-and-filesystem.md) |
| `ln -s TARGET LINK` | Create a symbolic link | [02](02-shell-and-filesystem.md) |
| `cat`, `less`, `head -n 20`, `tail -f` | Print, page through, show start, follow end | [02](02-shell-and-filesystem.md) |
| `grep -rin PATTERN DIR` | Search recursively, case-insensitive, with line numbers | [02](02-shell-and-filesystem.md) |
| `find / -xdev -name '*.conf' -mtime -1` | Find files by name and age on one filesystem | [02](02-shell-and-filesystem.md) |
| `find DIR -size +100M` | Find big files | [09](09-disks-and-filesystems.md) |
| `sort`, `uniq -c`, `wc -l`, `cut -d: -f1` | Sort, count duplicates, count lines, pick fields | [02](02-shell-and-filesystem.md) |
| `sed -i 's/old/new/g' FILE` | Replace text in a file in place | [02](02-shell-and-filesystem.md) |
| `awk -F: '{print $1}' /etc/passwd` | Print a field from each line | [02](02-shell-and-filesystem.md) |
| `diff -u OLD NEW` | Show differences between files | [02](02-shell-and-filesystem.md) |
| `tar -czf out.tar.gz DIR`, `tar -xf FILE` | Create / extract an archive | [02](02-shell-and-filesystem.md) |
| `file FILE`, `stat FILE` | What kind of file; full metadata | [02](02-shell-and-filesystem.md) |
| `which CMD`, `type CMD` | Where a command comes from | [02](02-shell-and-filesystem.md) |
| `history`, ++ctrl+r++ | Previous commands; search them | [02](02-shell-and-filesystem.md) |

To chain commands, pipe the output of one into the next:

```console
$ ps aux --sort=-%mem | head -5
$ sudo grep -c Failed /var/log/secure
$ journalctl -u sshd | grep -i 'invalid user' | wc -l
```

## Users, groups and permissions

| Command | What it does | Module |
|---------|--------------|--------|
| `id`, `id USER` | Show UID, GID and groups | [03](03-users-groups-and-sudo.md) |
| `sudo useradd -m USER` | Create a user with a home directory | [03](03-users-groups-and-sudo.md) |
| `sudo passwd USER` | Set a password | [03](03-users-groups-and-sudo.md) |
| `sudo usermod -aG wheel USER` | Add to a group (wheel grants sudo) | [03](03-users-groups-and-sudo.md) |
| `sudo userdel -r USER` | Delete a user and their home | [03](03-users-groups-and-sudo.md) |
| `sudo groupadd GROUP` | Create a group | [03](03-users-groups-and-sudo.md) |
| `sudo chage -l USER` | Password age and expiry details | [03](03-users-groups-and-sudo.md) |
| `getent passwd USER` | Look up a user from any source (files, LDAP, SSSD) | [03](03-users-groups-and-sudo.md) |
| `sudo -l` | What may I run with sudo? | [03](03-users-groups-and-sudo.md) |
| `sudo visudo` | Safely edit sudoers | [03](03-users-groups-and-sudo.md) |
| `su - USER` | Switch to another user with a login shell | [03](03-users-groups-and-sudo.md) |
| `chmod 640 FILE`, `chmod u+x FILE` | Change mode, octal or symbolic | [04](04-permissions-and-acls.md) |
| `chown USER:GROUP FILE` | Change owner and group | [04](04-permissions-and-acls.md) |
| `chmod g+s DIR` | New files inherit the directory's group | [04](04-permissions-and-acls.md) |
| `chmod +t DIR` | Sticky bit: only owners can delete their files | [04](04-permissions-and-acls.md) |
| `umask` | Default permission mask for new files | [04](04-permissions-and-acls.md) |
| `getfacl FILE`, `setfacl -m u:USER:rw FILE` | Read / set ACL entries | [04](04-permissions-and-acls.md) |
| `namei -l PATH` | Permissions of every directory on a path | [04](04-permissions-and-acls.md) |

## Packages: RPM and DNF

| Command | What it does | Module |
|---------|--------------|--------|
| `sudo dnf install PKG` / `remove PKG` | Install / remove a package and dependencies | [05](05-software-rpm-and-dnf.md) |
| `sudo dnf update` | Update everything | [05](05-software-rpm-and-dnf.md) |
| `dnf search WORD`, `dnf info PKG` | Find packages; show details | [05](05-software-rpm-and-dnf.md) |
| `dnf provides /path/or/cmd` | Which package provides a file | [05](05-software-rpm-and-dnf.md) |
| `dnf repolist -v` | Enabled repositories and their URLs | [05](05-software-rpm-and-dnf.md) |
| `sudo dnf config-manager --set-enabled crb` | Enable a repository | [05](05-software-rpm-and-dnf.md) |
| `sudo dnf install epel-release` | Add the EPEL repository | [05](05-software-rpm-and-dnf.md) |
| `dnf history`, `sudo dnf history undo N` | List / undo transactions | [05](05-software-rpm-and-dnf.md) |
| `sudo dnf clean all` | Clear cached metadata and packages | [05](05-software-rpm-and-dnf.md) |
| `rpm -qa`, `rpm -qi PKG` | List installed packages; package info | [05](05-software-rpm-and-dnf.md) |
| `rpm -ql PKG`, `rpm -qf FILE` | Files in a package; package owning a file | [05](05-software-rpm-and-dnf.md) |
| `rpm -V PKG`, `rpm -Va` | Verify files against the package database | [05](05-software-rpm-and-dnf.md) |
| `sudo rpm --import KEYFILE` | Trust a repository's GPG key | [05](05-software-rpm-and-dnf.md) |
| `rpmbuild -ba SPECFILE` | Build an RPM from a spec file | [22](22-building-rpms.md) |

## Processes and signals

| Command | What it does | Module |
|---------|--------------|--------|
| `ps -ef`, `ps aux` | All processes | [06](06-processes-and-signals.md) |
| `ps -eo pid,ppid,stat,cmd --forest` | Custom columns as a tree | [06](06-processes-and-signals.md) |
| `pgrep -a NAME` | Find PIDs by name | [06](06-processes-and-signals.md) |
| `top`, `htop` (EPEL) | Live process view | [06](06-processes-and-signals.md) |
| `kill PID`, `kill -9 PID` | Send SIGTERM / SIGKILL | [06](06-processes-and-signals.md) |
| `pkill -HUP NAME` | Signal processes by name | [06](06-processes-and-signals.md) |
| `nice -n 10 CMD`, `renice 10 -p PID` | Start / change at lower priority | [06](06-processes-and-signals.md) |
| `jobs`, `bg`, `fg`, ++ctrl+z++ | Shell job control | [06](06-processes-and-signals.md) |
| `nohup CMD &` | Keep running after logout | [06](06-processes-and-signals.md) |
| `ls -l /proc/PID/fd` | A process's open files | [06](06-processes-and-signals.md) |
| `lsof -p PID`, `lsof +L1` | Open files; deleted-but-open files | [20](20-troubleshooting-playbook.md) |
| `strace -f -p PID` | Trace system calls (test systems only) | [06](06-processes-and-signals.md) |

## systemd and services

| Command | What it does | Module |
|---------|--------------|--------|
| `systemctl status UNIT` | State, PID, recent log lines | [07](07-systemd-and-services.md) |
| `sudo systemctl start` / `stop` / `restart UNIT` | Control a service now | [07](07-systemd-and-services.md) |
| `sudo systemctl enable --now UNIT` | Start now and at every boot | [07](07-systemd-and-services.md) |
| `sudo systemctl disable --now UNIT` | Stop and do not start at boot | [07](07-systemd-and-services.md) |
| `sudo systemctl mask UNIT` | Make a unit impossible to start | [07](07-systemd-and-services.md) |
| `systemctl --failed` | List failed units | [07](07-systemd-and-services.md) |
| `systemctl list-units --type=service` | Loaded services | [07](07-systemd-and-services.md) |
| `systemctl cat UNIT` | Show the unit file and drop-ins | [07](07-systemd-and-services.md) |
| `sudo systemctl edit UNIT` | Create a drop-in override | [07](07-systemd-and-services.md) |
| `sudo systemctl daemon-reload` | Reload unit files after editing | [07](07-systemd-and-services.md) |
| `systemctl list-timers` | Scheduled timers and next run | [07](07-systemd-and-services.md) |
| `systemctl get-default`, `sudo systemctl set-default multi-user.target` | Boot target | [14](14-the-boot-process.md) |
| `systemd-analyze blame` | What slowed the boot | [14](14-the-boot-process.md) |
| `systemd-analyze verify FILE` | Check a unit file | [07](07-systemd-and-services.md) |
| `sudo systemd-run --unit=N -p MemoryMax=… CMD` | Run a command as a transient service | [18](18-containers.md) |
| `sudo systemctl set-property UNIT CPUQuota=50%` | Set a resource limit persistently | [18](18-containers.md) |

## Logs and the journal

| Command | What it does | Module |
|---------|--------------|--------|
| `journalctl -u UNIT` | Logs for one unit | [08](08-logging-and-the-journal.md) |
| `journalctl -xeu UNIT` | Jump to the end, with explanations | [08](08-logging-and-the-journal.md) |
| `journalctl -f` | Follow new messages | [08](08-logging-and-the-journal.md) |
| `journalctl -b`, `journalctl -b -1` | This boot; previous boot | [08](08-logging-and-the-journal.md) |
| `journalctl -p err -b` | Errors and worse since boot | [08](08-logging-and-the-journal.md) |
| `journalctl --since "1 hour ago"` | Time window | [08](08-logging-and-the-journal.md) |
| `journalctl -k` | Kernel messages (like `dmesg`) | [08](08-logging-and-the-journal.md) |
| `journalctl --disk-usage`, `sudo journalctl --vacuum-size=500M` | Journal size; shrink it | [08](08-logging-and-the-journal.md) |
| `logger -t TAG "message"` | Write a message to the log | [08](08-logging-and-the-journal.md) |
| `sudo tail -f /var/log/secure` | Authentication log (rsyslog) | [08](08-logging-and-the-journal.md) |

## Disks and filesystems

| Command | What it does | Module |
|---------|--------------|--------|
| `lsblk -f` | Block devices, filesystems, UUIDs, mount points | [09](09-disks-and-filesystems.md) |
| `blkid` | UUIDs and filesystem types | [09](09-disks-and-filesystems.md) |
| `df -hT`, `df -i` | Space used per filesystem; inodes | [09](09-disks-and-filesystems.md) |
| `du -xh --max-depth=1 DIR` | What uses the space | [09](09-disks-and-filesystems.md) |
| `sudo parted /dev/vdb print` | Show / edit a partition table | [09](09-disks-and-filesystems.md) |
| `sudo mkfs.xfs /dev/vdb1` | Create an XFS filesystem | [09](09-disks-and-filesystems.md) |
| `sudo mount /dev/vdb1 /mnt`, `sudo umount /mnt` | Mount / unmount | [09](09-disks-and-filesystems.md) |
| `findmnt`, `sudo findmnt --verify` | Mount tree; check `/etc/fstab` | [09](09-disks-and-filesystems.md) |
| `sudo mount -a` | Mount everything in fstab (test edits) | [09](09-disks-and-filesystems.md) |
| `sudo xfs_growfs /mnt` | Grow a mounted XFS filesystem | [09](09-disks-and-filesystems.md) |
| `sudo xfs_repair /dev/vdb1` | Repair an unmounted XFS filesystem | [09](09-disks-and-filesystems.md) |
| `sudo mkswap /dev/vdb2`, `sudo swapon -a`, `swapon --show` | Create / enable / list swap | [09](09-disks-and-filesystems.md) |

## LVM, RAID and encryption

| Command | What it does | Module |
|---------|--------------|--------|
| `sudo pvs`, `vgs`, `lvs` | Summaries of physical volumes, volume groups, logical volumes | [10](10-lvm-raid-and-encryption.md) |
| `sudo pvcreate /dev/vdb` | Prepare a disk for LVM | [10](10-lvm-raid-and-encryption.md) |
| `sudo vgcreate data /dev/vdb` | Create a volume group | [10](10-lvm-raid-and-encryption.md) |
| `sudo vgextend data /dev/vdc` | Add a disk to a volume group | [10](10-lvm-raid-and-encryption.md) |
| `sudo lvcreate -n web -L 10G data` | Create a logical volume | [10](10-lvm-raid-and-encryption.md) |
| `sudo lvextend -r -L +5G data/web` | Grow an LV and its filesystem together | [10](10-lvm-raid-and-encryption.md) |
| `sudo lvcreate -s -n snap -L 2G data/web` | Snapshot a logical volume | [10](10-lvm-raid-and-encryption.md) |
| `sudo lvcreate --type raid1 -m1 -n r1 -L 5G data` | Mirrored LV with LVM RAID | [10](10-lvm-raid-and-encryption.md) |
| `cat /proc/mdstat`, `sudo mdadm --detail /dev/md0` | Software RAID status | [10](10-lvm-raid-and-encryption.md) |
| `sudo cryptsetup luksFormat /dev/vdb1` | Encrypt a partition with LUKS | [10](10-lvm-raid-and-encryption.md) |
| `sudo cryptsetup open /dev/vdb1 secret` | Unlock it as `/dev/mapper/secret` | [10](10-lvm-raid-and-encryption.md) |

## Networking

| Command | What it does | Module |
|---------|--------------|--------|
| `ip -br addr`, `ip -br link` | Addresses and links, brief | [11](11-networking.md) |
| `ip route`, `ip route get 1.1.1.1` | Routing table; route used for a destination | [11](11-networking.md) |
| `nmcli dev status`, `nmcli con show` | Devices and connection profiles | [11](11-networking.md) |
| `sudo nmcli con mod NAME ipv4.addresses 10.0.0.5/24 ipv4.method manual` | Set a static address | [11](11-networking.md) |
| `sudo nmcli con up NAME` | Apply / activate a profile | [11](11-networking.md) |
| `nmtui` | Text-menu network configuration | [11](11-networking.md) |
| `sudo hostnamectl set-hostname NAME` | Set the hostname | [11](11-networking.md) |
| `ss -tlnp`, `ss -tunap` | Listening sockets; all connections | [11](11-networking.md) |
| `ping`, `tracepath HOST` | Reachability; path and MTU | [11](11-networking.md) |
| `getent hosts NAME` | Resolve a name the way apps do | [11](11-networking.md) |
| `dig NAME`, `dig @SERVER NAME` | Query DNS directly (`bind-utils`) | [11](11-networking.md) |
| `curl -v URL` | Test an HTTP endpoint | [11](11-networking.md) |
| `sudo tcpdump -i eth0 port 53` | Capture packets | [11](11-networking.md) |
| `ip -s link show DEV` | Interface counters, errors, drops | [19](19-performance-and-observability.md) |

## Firewall

| Command | What it does | Module |
|---------|--------------|--------|
| `sudo firewall-cmd --state` | Is firewalld running? | [12](12-firewalld.md) |
| `sudo firewall-cmd --list-all` | Everything in the default zone | [12](12-firewalld.md) |
| `sudo firewall-cmd --get-active-zones` | Zones in use, with interfaces | [12](12-firewalld.md) |
| `sudo firewall-cmd --permanent --add-service=http` | Allow a service permanently | [12](12-firewalld.md) |
| `sudo firewall-cmd --permanent --add-port=8080/tcp` | Allow a port permanently | [12](12-firewalld.md) |
| `sudo firewall-cmd --reload` | Apply permanent changes | [12](12-firewalld.md) |
| `sudo firewall-cmd --runtime-to-permanent` | Save runtime changes | [12](12-firewalld.md) |
| `sudo firewall-cmd --permanent --zone=internal --add-source=10.0.0.0/24` | Bind a source network to a zone | [12](12-firewalld.md) |
| `sudo firewall-cmd --permanent --add-rich-rule='…'` | Fine-grained rule | [12](12-firewalld.md) |
| `sudo nft list ruleset` | The nftables rules firewalld generated | [12](12-firewalld.md) |

## File sharing

| Command | What it does | Module |
|---------|--------------|--------|
| `sudo exportfs -rav` | Re-export `/etc/exports` | [13](13-nfs-and-samba.md) |
| `showmount -e SERVER` | List a server's NFS exports (NFSv3) | [13](13-nfs-and-samba.md) |
| `sudo mount -t nfs SERVER:/export /mnt` | Mount an NFS share | [13](13-nfs-and-samba.md) |
| `testparm` | Check Samba configuration | [13](13-nfs-and-samba.md) |
| `sudo smbpasswd -a USER` | Add a Samba user | [13](13-nfs-and-samba.md) |
| `smbclient -L //SERVER -U USER` | List SMB shares | [13](13-nfs-and-samba.md) |

## SELinux

| Command | What it does | Module |
|---------|--------------|--------|
| `getenforce`, `sestatus` | Current mode and details | [16](16-selinux.md) |
| `sudo setenforce 0` / `1` | Permissive / enforcing until reboot (testing only) | [16](16-selinux.md) |
| `ls -Z`, `ps -eZ`, `id -Z` | Labels of files, processes, you | [16](16-selinux.md) |
| `sudo ausearch -m AVC -ts recent` | Recent denials | [16](16-selinux.md) |
| `sudo sealert -a /var/log/audit/audit.log` | Explain denials (`setroubleshoot-server`) | [16](16-selinux.md) |
| `sudo restorecon -Rv PATH` | Reset labels to policy defaults | [16](16-selinux.md) |
| `sudo semanage fcontext -a -t TYPE 'PATH(/.*)?'` | Add a labelling rule | [16](16-selinux.md) |
| `sudo semanage port -a -t TYPE -p tcp PORT` | Allow a service on a port | [16](16-selinux.md) |
| `getsebool -a`, `sudo setsebool -P BOOL on` | List / set booleans persistently | [16](16-selinux.md) |
| `sudo audit2allow -a -M mymod` | Build a local policy module (last resort) | [16](16-selinux.md) |

## Security hardening

| Command | What it does | Module |
|---------|--------------|--------|
| `sudo sshd -t` | Test sshd configuration | [17](17-security-hardening.md) |
| `update-crypto-policies --show` | Current system-wide crypto policy | [17](17-security-hardening.md) |
| `sudo dnf install openscap-scanner scap-security-guide` | Install compliance scanning tools | [17](17-security-hardening.md) |
| `sudo oscap xccdf eval --profile PROFILE …` | Scan against a security profile | [17](17-security-hardening.md) |
| `sudo ausearch -m USER_LOGIN -ts today` | Today's login audit records | [17](17-security-hardening.md) |
| `sudo dnf updateinfo list --security` | Pending security updates | [17](17-security-hardening.md) |

## Boot and kernel

| Command | What it does | Module |
|---------|--------------|--------|
| `uname -r` | Running kernel version | [15](15-the-kernel.md) |
| `sudo grubby --info=ALL` | Boot entries and their arguments | [14](14-the-boot-process.md) |
| `sudo grubby --update-kernel=ALL --args="ARG"` | Add a kernel argument | [14](14-the-boot-process.md) |
| `sudo grubby --set-default /boot/vmlinuz-VERSION` | Choose the default kernel | [14](14-the-boot-process.md) |
| `sudo dracut -f` | Rebuild the initramfs | [14](14-the-boot-process.md) |
| `cat /proc/cmdline` | Arguments the kernel booted with | [14](14-the-boot-process.md) |
| `rd.break`, `systemd.unit=rescue.target` | Kernel arguments for recovery | [20](20-troubleshooting-playbook.md) |
| `lsmod`, `modinfo MOD`, `sudo modprobe MOD` | List / describe / load kernel modules | [15](15-the-kernel.md) |
| `sysctl NAME`, `sudo sysctl -w NAME=VALUE` | Read / set a kernel parameter | [15](15-the-kernel.md) |
| `/etc/sysctl.d/*.conf` | Persistent kernel parameters | [15](15-the-kernel.md) |
| `dmesg -T` | Kernel ring buffer with readable times | [15](15-the-kernel.md) |
| `coredumpctl list`, `coredumpctl info PID` | Crashed programs and their core dumps | [24](24-debugging-crashes.md) |
| `kdumpctl status` | Is kernel crash dumping ready? | [24](24-debugging-crashes.md) |

## Performance and observability

| Command | What it does | Module |
|---------|--------------|--------|
| `uptime`, `nproc` | Load average and CPU count | [19](19-performance-and-observability.md) |
| `vmstat 1` | Run queue, blocked tasks, swap, CPU split | [19](19-performance-and-observability.md) |
| `mpstat -P ALL 1` | Per-CPU utilization (`sysstat`) | [19](19-performance-and-observability.md) |
| `pidstat 1`, `pidstat -d 1` | Per-process CPU; per-process disk I/O | [19](19-performance-and-observability.md) |
| `iostat -xz 1` | Per-disk utilization, queue and latency | [19](19-performance-and-observability.md) |
| `free -m` | Memory (read `available`) | [19](19-performance-and-observability.md) |
| `cat /proc/pressure/memory` | Pressure stall information | [19](19-performance-and-observability.md) |
| `sar -n DEV 1`, `sar -n TCP,ETCP 1` | Network throughput; TCP and retransmits | [19](19-performance-and-observability.md) |
| `sudo systemctl enable --now sysstat` | Start recording history for `sar` | [19](19-performance-and-observability.md) |
| `sar -q -f /var/log/sa/saDD` | Historical run queue and load | [19](19-performance-and-observability.md) |
| `tuned-adm active`, `sudo tuned-adm profile NAME` | Show / switch tuning profile | [19](19-performance-and-observability.md) |
| `sudo perf top`, `sudo perf record -g -p PID` | CPU profiling | [19](19-performance-and-observability.md) |
| `sudo /usr/share/bcc/tools/execsnoop` | Trace new processes (`bcc-tools`) | [19](19-performance-and-observability.md) |
| `sudo /usr/share/bcc/tools/biolatency` | Disk latency histogram | [19](19-performance-and-observability.md) |
| `sudo bpftrace -e '…'` | eBPF one-liners | [19](19-performance-and-observability.md) |
| `cat /proc/PID/smaps_rollup` | Detailed memory totals for one process | [25](25-memory-deep-dive.md) |

## Containers

| Command | What it does | Module |
|---------|--------------|--------|
| `podman run -d --name N -p 8080:80 IMAGE` | Start a container in the background | [18](18-containers.md) |
| `podman ps -a`, `podman images` | Containers; local images | [18](18-containers.md) |
| `podman logs -f N`, `podman exec -it N bash` | Follow logs; shell inside | [18](18-containers.md) |
| `podman inspect N` | All details as JSON | [18](18-containers.md) |
| `podman stop N`, `podman rm N`, `podman rmi IMAGE` | Stop / delete container / delete image | [18](18-containers.md) |
| `-v /host/dir:/ctr/dir:Z` | Bind mount with SELinux relabel | [18](18-containers.md) |
| `podman pod create --name P -p 8080:80` | Create a pod | [18](18-containers.md) |
| `podman build -t NAME .` | Build an image from a Containerfile | [18](18-containers.md) |
| `skopeo inspect docker://IMAGE` | Inspect a remote image without pulling | [18](18-containers.md) |
| `podman unshare cat /proc/self/uid_map` | Show rootless UID mapping | [18](18-containers.md) |
| `~/.config/containers/systemd/NAME.container` | Rootless Quadlet unit | [18](18-containers.md) |
| `/usr/libexec/podman/quadlet -dryrun` | Show units generated from Quadlet files | [18](18-containers.md) |
| `sudo unshare --pid --fork --mount-proc bash` | Shell in a new PID namespace | [18](18-containers.md) |
| `lsns`, `sudo nsenter -t PID -n CMD` | List namespaces; run a command inside one | [18](18-containers.md) |
| `systemd-cgls`, `systemd-cgtop` | cgroup tree; live usage per cgroup | [18](18-containers.md) |

## Deep cuts: Rocky itself and packaging

| Command | What it does | Module |
|---------|--------------|--------|
| `cat /etc/os-release`, `rpm -q rocky-release` | Which Rocky release you run (and its `SUPPORT_END`) | [21](21-inside-rocky-linux.md) |
| `rpm -qi PKG` | Vendor, signature, build date and source RPM of a package | [21](21-inside-rocky-linux.md) |
| `rpm -Kv FILE.rpm` | Verify a package file's digests and signature | [21](21-inside-rocky-linux.md) |
| `rpm -q gpg-pubkey --qf '%{VERSION} %{SUMMARY}\n'` | Keys RPM trusts | [21](21-inside-rocky-linux.md) |
| `dnf repoinfo REPO` | Repo details: mirrorlist, metadata age, size | [21](21-inside-rocky-linux.md) |
| `dnf updateinfo info RLSA-…`, `sudo dnf upgrade --advisory ID` | Read one advisory; install only that advisory | [21](21-inside-rocky-linux.md) |
| `dnf download --source PKG` | Fetch a package's source RPM | [21](21-inside-rocky-linux.md) |
| `dnf needs-restarting -r` | Does the system need a reboot after updates? | [21](21-inside-rocky-linux.md) |
| `rpmdev-setuptree`, `rpmdev-newspec NAME` | Create `~/rpmbuild`; start a spec file from a template | [22](22-building-rpms.md) |
| `rpm --eval '%{_libdir}'` | Expand an RPM macro | [22](22-building-rpms.md) |
| `sudo dnf builddep FILE.spec` | Install a spec's `BuildRequires` | [22](22-building-rpms.md) |
| `rpmbuild -ba FILE.spec`, `rpmbuild --rebuild X.src.rpm` | Build source and binary RPMs; rebuild from an SRPM | [22](22-building-rpms.md) |
| `mock -r rocky-10-x86_64 --rebuild X.src.rpm` | Build in a clean chroot (EPEL) | [22](22-building-rpms.md) |
| `rpmlint FILE.spec`, `rpm -qp --scripts FILE.rpm` | Lint packaging; show a package's scriptlets | [22](22-building-rpms.md) |
| `rpmsign --addsign FILE.rpm`, `createrepo_c --update DIR` | Sign a package; build or refresh repo metadata | [22](22-building-rpms.md) |
| `rpmdev-vercmp A B` | Compare two versions the way RPM does | [22](22-building-rpms.md) |

## Deep cuts: installs, crashes and memory

| Command | What it does | Module |
|---------|--------------|--------|
| `sudo cat /root/anaconda-ks.cfg` | The kickstart of the current install: a starting point | [23](23-automated-installs.md) |
| `ksvalidator -v RHEL10 FILE.ks` | Validate kickstart syntax (`pykickstart`) | [23](23-automated-installs.md) |
| `inst.ks=URL`, `inst.repo=URL` | Boot options: where the kickstart and install tree are | [23](23-automated-installs.md) |
| `sudo mkksiso --ks FILE.ks IN.iso OUT.iso` | Embed a kickstart into an ISO (`lorax`) | [23](23-automated-installs.md) |
| `composer-cli blueprints push FILE.toml`, `composer-cli compose start NAME qcow2` | Upload a blueprint; build an image with Image Builder | [23](23-automated-installs.md) |
| `cloud-init status --long`, `cloud-init analyze show` | Did cloud-init finish, and where did the time go? | [23](23-automated-installs.md) |
| `sudo cloud-init clean --logs --reboot` | Re-run cloud-init as if on first boot | [23](23-automated-installs.md) |
| `bootc status` | Image mode: which image this host runs | [23](23-automated-installs.md) |
| `sysctl kernel.core_pattern` | Where core dumps go | [24](24-debugging-crashes.md) |
| `coredumpctl list`, `coredumpctl debug PID` | List crashed programs; open one in gdb | [24](24-debugging-crashes.md) |
| `sudo dnf debuginfo-install --enablerepo='*debug*' PKG` | Install matching debug symbols | [24](24-debugging-crashes.md) |
| `gdb BINARY CORE`, then `bt full`, `thread apply all bt` | Backtraces from a core | [24](24-debugging-crashes.md) |
| `gcore -o PREFIX PID`, `gstack PID` | Core or stack trace of a live process | [24](24-debugging-crashes.md) |
| `cat /proc/sys/kernel/tainted` | Kernel taint flags (0 = clean) | [24](24-debugging-crashes.md) |
| `kdumpctl status`, `kdumpctl showmem` | Is kdump armed, and how much RAM is reserved? | [24](24-debugging-crashes.md) |
| `crash vmlinux vmcore` | Open a kernel dump (then `sys`, `bt`, `log`, `ps`) | [24](24-debugging-crashes.md) |
| `cat /proc/PID/smaps_rollup`, `pmap -x PID` | Per-process memory: RSS, PSS, swap; per-mapping detail | [25](25-memory-deep-dive.md) |
| `fincore FILE` | How much of a file is in the page cache | [25](25-memory-deep-dive.md) |
| `sysctl vm.swappiness vm.overcommit_memory` | Reclaim bias and overcommit mode | [25](25-memory-deep-dive.md) |
| `grep allocstall /proc/vmstat` | Direct reclaim stalls | [25](25-memory-deep-dive.md) |
| `journalctl -k -g 'Killed process'` | Find OOM kills | [25](25-memory-deep-dive.md) |
| `systemd-run --scope -p MemoryMax=256M CMD` | Run a command in a memory-limited cgroup | [25](25-memory-deep-dive.md) |
| `numactl --hardware`, `numastat -m` | NUMA layout and per-node memory | [25](25-memory-deep-dive.md) |
| `cat /sys/kernel/mm/transparent_hugepage/enabled` | Transparent Huge Pages mode | [25](25-memory-deep-dive.md) |

## Deep cuts: identity, virtualization and clusters

| Command | What it does | Module |
|---------|--------------|--------|
| `getent passwd USER`, `id USER` | Look a user up through NSS (files and SSSD) | [26](26-centralized-identity.md) |
| `authselect current` | Active NSS/PAM profile and features | [26](26-centralized-identity.md) |
| `sssctl domain-status DOMAIN` | Is SSSD online, and which server is active? | [26](26-centralized-identity.md) |
| `sssctl user-checks USER -s sshd` | Test lookup and access for a user and PAM service | [26](26-centralized-identity.md) |
| `sudo sss_cache -E` | Expire every SSSD cache entry | [26](26-centralized-identity.md) |
| `kinit USER`, `klist`, `kdestroy` | Get, list and destroy Kerberos tickets | [26](26-centralized-identity.md) |
| `sudo klist -k /etc/krb5.keytab` | Keys in the machine keytab | [26](26-centralized-identity.md) |
| `sudo ipa-client-install --mkhomedir` | Join a host to FreeIPA | [26](26-centralized-identity.md) |
| `ipa hbactest --user=U --host=H --service=sshd` | Simulate a host-based access rule | [26](26-centralized-identity.md) |
| `realm discover DOMAIN`, `sudo realm join DOMAIN` | Find and join an Active Directory domain | [26](26-centralized-identity.md) |
| `virt-host-validate qemu` | Is this host ready for KVM? | [27](27-virtualization-kvm.md) |
| `virsh list --all`, `virsh dominfo VM` | List VMs; summary of one | [27](27-virtualization-kvm.md) |
| `virsh start VM`, `virsh shutdown VM`, `virsh destroy VM` | Boot / clean shutdown / hard power off | [27](27-virtualization-kvm.md) |
| `virsh console VM` | Serial console (exit with ++ctrl+bracket-right++) | [27](27-virtualization-kvm.md) |
| `virsh edit VM`, `virsh dumpxml VM` | Edit / print the domain XML | [27](27-virtualization-kvm.md) |
| `virsh domifaddr VM`, `virsh net-dhcp-leases default` | A VM's IP addresses; DHCP leases | [27](27-virtualization-kvm.md) |
| `qemu-img create -f qcow2 -F qcow2 -b BASE NEW` | Create an overlay on a backing file | [27](27-virtualization-kvm.md) |
| `qemu-img info -U --backing-chain FILE` | Format, sizes and backing chain of an image | [27](27-virtualization-kvm.md) |
| `virsh snapshot-create-as VM NAME`, `virsh snapshot-revert VM NAME` | Take / roll back to a snapshot | [27](27-virtualization-kvm.md) |
| `virsh migrate --live VM qemu+ssh://HOST/system` | Live-migrate a VM | [27](27-virtualization-kvm.md) |
| `sudo pcs status`, `sudo crm_mon -1rf` | Cluster state | [28](28-high-availability.md) |
| `sudo corosync-quorumtool` | Votes and quorum | [28](28-high-availability.md) |
| `sudo pcs resource create NAME AGENT key=value` | Create a cluster resource | [28](28-high-availability.md) |
| `sudo pcs constraint colocation add A with B INFINITY` | Keep A on the same node as B | [28](28-high-availability.md) |
| `sudo pcs node standby NODE`, `sudo pcs node unstandby NODE` | Drain a node / return it to service | [28](28-high-availability.md) |
| `sudo pcs resource move R NODE`, `sudo pcs resource clear R` | Move a resource; remove leftover move constraints | [28](28-high-availability.md) |
| `sudo pcs resource cleanup R` | Reset a resource's failure history | [28](28-high-availability.md) |
| `sudo pcs stonith fence NODE` | Fence a node now (test fencing) | [28](28-high-availability.md) |
| `sudo crm_simulate -sL` | Show placement scores | [28](28-high-availability.md) |

## Deep cuts: boot trust, encryption and recovery

| Command | What it does | Module |
|---------|--------------|--------|
| `mokutil --sb-state` | Is Secure Boot on? | [29](29-secure-boot-and-drivers.md) |
| `mokutil --list-enrolled`, `mokutil --db` | Keys in the MOK list; firmware `db` | [29](29-secure-boot-and-drivers.md) |
| `sudo mokutil --import key.der` | Queue a key for enrollment at next boot | [29](29-secure-boot-and-drivers.md) |
| `cat /sys/kernel/security/lockdown` | Current kernel lockdown mode | [29](29-secure-boot-and-drivers.md) |
| `modinfo -F signer MODULE` | Who signed a kernel module | [29](29-secure-boot-and-drivers.md) |
| `dkms status`, `sudo dkms autoinstall -k KERNEL` | DKMS modules; build them for a kernel | [29](29-secure-boot-and-drivers.md) |
| `efibootmgr` | UEFI boot entries | [29](29-secure-boot-and-drivers.md) |
| `sudo systemctl enable --now tangd.socket` | Start a Tang server | [30](30-network-bound-encryption.md) |
| `tang-show-keys PORT` | Tang's signing key thumbprint | [30](30-network-bound-encryption.md) |
| `sudo clevis luks bind -d DEV tang '{"url":"…"}'` | Bind a LUKS device to Tang | [30](30-network-bound-encryption.md) |
| `sudo clevis luks bind -d DEV tpm2 '{"pcr_ids":"7"}'` | Bind a LUKS device to the TPM (PCR 7) | [30](30-network-bound-encryption.md) |
| `sudo clevis luks list -d DEV` | Show Clevis bindings | [30](30-network-bound-encryption.md) |
| `sudo clevis luks regen -d DEV -s SLOT` | Rebind after key rotation or a PCR change | [30](30-network-bound-encryption.md) |
| `sudo tpm2_pcrread sha256:0,7` | Show TPM PCR values | [30](30-network-bound-encryption.md) |
| `sudo cryptsetup luksDump DEV` | LUKS keyslots and tokens | [30](30-network-bound-encryption.md) |
| `sudo tar --xattrs --acls --selinux -czpf FILE -C / DIR` | Archive keeping SELinux labels, ACLs and xattrs | [31](31-disaster-recovery-and-migration.md) |
| `sudo semanage export -f FILE`, `sudo semanage import -f FILE` | Save / replay local SELinux customizations | [31](31-disaster-recovery-and-migration.md) |
| `sudo rsync -aAXH SRC DST` | Copy with ACLs, xattrs and hard links | [31](31-disaster-recovery-and-migration.md) |
| `sudo rear -v mkbackup`, `sudo rear -v mkrescue` | ReaR rescue image plus backup; rescue image only | [31](31-disaster-recovery-and-migration.md) |
| `sudo rear checklayout` | Has the disk layout changed since the rescue image? | [31](31-disaster-recovery-and-migration.md) |
| `rear recover` | Restore, from inside the ReaR rescue system | [31](31-disaster-recovery-and-migration.md) |
| `sudo rpm -Va` | Files that differ from their packages | [31](31-disaster-recovery-and-migration.md) |
| `dnf repoquery --userinstalled` | Packages installed on purpose | [31](31-disaster-recovery-and-migration.md) |
| `/lib64/ld-linux-x86-64.so.2 --help` | Which x86-64 levels this CPU supports | [31](31-disaster-recovery-and-migration.md) |

## Deep cuts: automation, TLS and networking

| Command | What it does | Module |
|---------|--------------|--------|
| `ansible-inventory --graph` | Draw inventory groups and hosts | [32](32-ansible-and-system-roles.md) |
| `ansible all -m ansible.builtin.ping` | Test SSH, Python and module execution | [32](32-ansible-and-system-roles.md) |
| `ansible-playbook site.yml` | Apply a playbook | [32](32-ansible-and-system-roles.md) |
| `ansible-playbook site.yml --check --diff` | Report drift without changing anything | [32](32-ansible-and-system-roles.md) |
| `ansible-playbook site.yml --limit HOST` | Run against a subset of hosts | [32](32-ansible-and-system-roles.md) |
| `ansible-doc MODULE` | Module documentation, offline | [32](32-ansible-and-system-roles.md) |
| `ansible-vault create FILE`, `ansible-vault edit FILE` | Manage encrypted variable files | [32](32-ansible-and-system-roles.md) |
| `sudo dnf install rhel-system-roles` | Install the System Roles collection | [32](32-ansible-and-system-roles.md) |
| `openssl x509 -in c.pem -noout -subject -issuer -dates` | Quick certificate identity and validity check | [33](33-tls-and-crypto-policies.md) |
| `openssl x509 -in c.pem -noout -ext subjectAltName` | Names the certificate is valid for | [33](33-tls-and-crypto-policies.md) |
| `openssl x509 -in c.pem -noout -checkend 2592000` | Exit 1 if it expires within 30 days | [33](33-tls-and-crypto-policies.md) |
| `openssl verify -CAfile ca.crt c.pem` | Verify a certificate against a CA | [33](33-tls-and-crypto-policies.md) |
| `openssl s_client -connect HOST:443 -servername HOST -showcerts` | Inspect a live TLS handshake and chain | [33](33-tls-and-crypto-policies.md) |
| `sudo cp ca.crt /etc/pki/ca-trust/source/anchors/`, `sudo update-ca-trust` | Trust a private CA system-wide | [33](33-tls-and-crypto-policies.md) |
| `trust list --filter=ca-anchors` | List trusted root CAs | [33](33-tls-and-crypto-policies.md) |
| `sudo update-crypto-policies --set DEFAULT:NO-PQ` | Set a crypto policy with a subpolicy (`NO-PQ` is 10.1+) | [33](33-tls-and-crypto-policies.md) |
| `sudo certbot renew --dry-run` | Test Let's Encrypt renewal | [33](33-tls-and-crypto-policies.md) |
| `sudo nft list ruleset` | Every nftables table, chain, rule and set | [34](34-nftables-and-traffic-control.md) |
| `sudo nft -a list chain inet T C` | A chain with rule handles | [34](34-nftables-and-traffic-control.md) |
| `sudo nft -c -f FILE`, `sudo nft -f FILE` | Check a ruleset file; apply it atomically | [34](34-nftables-and-traffic-control.md) |
| `sudo nft monitor trace` | Follow packets marked with `meta nftrace set 1` | [34](34-nftables-and-traffic-control.md) |
| `sudo conntrack -L`, `sudo conntrack -E` | List tracked flows; stream conntrack events | [34](34-nftables-and-traffic-control.md) |
| `sudo ip netns add N`, `sudo ip netns exec N CMD` | Create a network namespace; run a command in it | [34](34-nftables-and-traffic-control.md) |
| `tc -s qdisc show dev IF` | Queueing disciplines with statistics | [34](34-nftables-and-traffic-control.md) |
| `sudo tc qdisc add dev IF root netem delay 200ms loss 5%` | Inject latency and packet loss | [34](34-nftables-and-traffic-control.md) |
| `sudo tc qdisc add dev IF root tbf rate 5mbit burst 32kbit latency 400ms` | Simple rate limit | [34](34-nftables-and-traffic-control.md) |
| `sudo tc qdisc del dev IF root` | Remove your qdisc, restore the default | [34](34-nftables-and-traffic-control.md) |

## Deep cuts: storage, time and real-time

| Command | What it does | Module |
|---------|--------------|--------|
| `sudo targetcli ls`, `sudo targetcli saveconfig` | Show and save the LIO iSCSI target configuration | [35](35-enterprise-storage.md) |
| `sudo iscsiadm -m discovery -t sendtargets -p IP` | Discover iSCSI targets on a portal | [35](35-enterprise-storage.md) |
| `sudo iscsiadm -m node -T IQN -l` | Log in to a target (`-u` logs out) | [35](35-enterprise-storage.md) |
| `sudo iscsiadm -m session -P 3` | Session details, including attached disks | [35](35-enterprise-storage.md) |
| `sudo mpathconf --enable --with_multipathd y` | Create `multipath.conf` and start multipathd | [35](35-enterprise-storage.md) |
| `sudo multipath -ll` | Multipath devices, path groups and path states | [35](35-enterprise-storage.md) |
| `sudo nvme discover -t tcp -a IP -s 4420` | Query an NVMe-oF discovery controller | [35](35-enterprise-storage.md) |
| `sudo nvme connect -t tcp -a IP -s 4420 -n NQN` | Connect to an NVMe/TCP subsystem | [35](35-enterprise-storage.md) |
| `sudo nvme list-subsys` | NVMe subsystems and their paths | [35](35-enterprise-storage.md) |
| `ls -l /dev/disk/by-id/` | Stable device names (WWN, multipath) | [35](35-enterprise-storage.md) |
| `cat /sys/block/DEV/queue/scheduler` | Current I/O scheduler | [35](35-enterprise-storage.md) |
| `fio --direct=1 --iodepth=N --rw=randread …` | Benchmark the device, not the cache | [35](35-enterprise-storage.md) |
| `timedatectl` | Clock, time zone, RTC and sync status | [36](36-time-synchronization.md) |
| `chronyc tracking` | Clock offset, frequency error, stratum, leap status | [36](36-time-synchronization.md) |
| `chronyc sources -v` | Time sources and their state, with a legend | [36](36-time-synchronization.md) |
| `sudo chronyc makestep` | Step the clock now | [36](36-time-synchronization.md) |
| `chronyc waitsync 30 0.1` | Wait until synchronised (scripts, boot ordering) | [36](36-time-synchronization.md) |
| `sudo chronyc -N authdata` | NTS authentication status per source | [36](36-time-synchronization.md) |
| `ethtool -T IF` | Hardware timestamping and PTP clock support | [36](36-time-synchronization.md) |
| `sudo ptp4l -i IF -s -m`, `sudo phc2sys -s IF -c CLOCK_REALTIME -w` | PTP client; sync the system clock from the NIC | [36](36-time-synchronization.md) |
| `uname -v` | Shows `PREEMPT_DYNAMIC` (stock) or `PREEMPT_RT` (kernel-rt) | [37](37-real-time-and-low-latency.md) |
| `sudo dnf config-manager --set-enabled rt`, `sudo dnf install kernel-rt` | Install the real-time kernel | [37](37-real-time-and-low-latency.md) |
| `sudo tuned-adm profile cpu-partitioning`, `tuned-adm verify` | Isolate CPUs with tuned; check it applied | [37](37-real-time-and-low-latency.md) |
| `cat /sys/devices/system/cpu/isolated` | Which CPUs are isolated | [37](37-real-time-and-low-latency.md) |
| `cat /proc/interrupts` | Interrupt counts per CPU | [37](37-real-time-and-low-latency.md) |
| `taskset -c 3 CMD`, `chrt -f 80 CMD` | Pin to CPU 3; run as SCHED_FIFO priority 80 | [37](37-real-time-and-low-latency.md) |
| `ps -eLo pid,tid,class,rtprio,psr,comm` | Policy, priority and CPU of every thread | [37](37-real-time-and-low-latency.md) |
| `sudo cyclictest -m -S -p95 -i200 -D 60 -q` | Measure scheduling latency on every CPU | [37](37-real-time-and-low-latency.md) |
| `sudo hwlatdetect --duration=60 --threshold=10` | Detect firmware or hypervisor stalls | [37](37-real-time-and-low-latency.md) |

## Troubleshooting first five minutes

```console
$ systemctl --failed
$ journalctl -p err -b --no-pager | tail -20
$ df -h; df -i
$ free -m; uptime
$ sudo ausearch -m AVC -ts recent
$ sudo ss -tlnp
```

See [20 · Troubleshooting Playbook](20-troubleshooting-playbook.md) for what to
do with the results.
