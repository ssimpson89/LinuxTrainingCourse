---
title: Boot and Init
type: module
track: linux-internals
tags: [linux-internals, boot, uefi, secure-boot, grub2, initramfs, dracut, systemd, recovery]
requires: [Rocky 9.x UEFI VM with root, Secure Boot-capable OVMF firmware (Lab 4), SELinux enforcing (Lab 3), console access not SSH (Labs 2-3), kernel-devel headers (Lab 4)]
module_number: 8
status: reviewed
created: 2026-07-08
---

# 08 - Boot and Init

Backlink: [[00 - Track Overview]]

> The boot path is the one code path on the machine that runs with *no* running kernel to help you. Every abstraction you rely on the rest of the time (a scheduler, virtual memory that works, a filesystem you can `open()`, a logger) is being *bootstrapped* here, one layer at a time, each layer building just enough machine to load the next. Staff-level boot competence is the ability to name exactly which layer you are in when something breaks, know what state the machine is in at that instant, and know which break-glass hatch drops you into that layer with a shell. Everything below is organized around that skill.

The chain, end to end, with the "who is running" at each step:

```
power-on
  │
  ▼
[CPU reset vector] ── firmware in flash (SPI ROM)
  │   BIOS: real mode, 16-bit, jumps to MBR sector
  │   UEFI: protected/long mode, runs PE/COFF EFI apps from the ESP (a FAT partition)
  ▼
[UEFI Boot Manager] ── reads EFI vars (BootOrder, Boot####), loads an EFI app
  │   Secure Boot ON → firmware verifies the app's signature against db/dbx
  ▼
[shim.efi] ── signed by Microsoft 3rd-party CA; the distro's foot in the door
  │   verifies next stage against: db  OR  distro cert (baked in)  OR  MOK  OR  MOK hash
  ▼
[grubx64.efi (GRUB2)] ── the bootloader proper
  │   reads grub.cfg + BLS snippets, presents menu
  │   shim provides a verify protocol GRUB calls to check the kernel
  ▼
[vmlinuz + initramfs] ── GRUB loads both into RAM, sets up boot params, jumps to kernel entry
  │   kernel self-decompresses, brings up MMU/paging, mounts initramfs as rootfs (tmpfs)
  ▼
[/init in initramfs] ── on RHEL/Fedora this is systemd in the initrd
  │   dracut hooks assemble the REAL root: LVM/LUKS/RAID/multipath/iSCSI
  │   mounts real root at /sysroot
  ▼
[switch_root] ── wipe initramfs, chroot to /sysroot, exec the real /usr/lib/systemd/systemd
  │
  ▼
[systemd PID 1] ── sysinit.target → basic.target → multi-user.target → graphical.target
```

Modern twist (learn it, it is now default on RHEL/Fedora): the **Unified Kernel Image (UKI)** collapses stub+kernel+initramfs+cmdline into *one* signed PE binary, so the whole "GRUB loads two files" story can disappear. More below.

---

## Concept deep-dive

### 1. Firmware: BIOS vs UEFI, and why the difference is architectural, not cosmetic

**BIOS (legacy).** The CPU comes out of reset in 16-bit real mode at the reset vector (`0xFFFFFFF0`), executes firmware from flash, runs POST, then loads the first 512 bytes (the MBR) of the boot disk to physical `0x7C00` and jumps there. That 512 bytes contains 446 bytes of code + the 64-byte partition table + the `0x55AA` signature. 446 bytes is not enough to understand a filesystem, so GRUB's `boot.img` in the MBR does exactly one thing: load the first sector of `core.img` using a hardcoded LBA (block-list) patched at install time. This is the fragility of BIOS booting: the bootloader chases raw block addresses, so anything that moves those blocks (a `dd`, a partition resize, restoring an image) breaks boot in a way the OS can't warn you about.

**UEFI.** Firmware is a small OS in its own right. It understands GPT partition tables and FAT, runs the CPU in protected or long mode from the start, and loads **PE/COFF executables** (`.efi`, the same container format as Windows `.exe`) from the **EFI System Partition (ESP)** — a FAT32 partition, type GUID `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`, conventionally mounted at `/boot/efi`. There is no 512-byte straitjacket; a bootloader is just a file at `/boot/efi/EFI/<vendor>/`.

Boot targets live in **NVRAM** as EFI variables, exposed by the kernel through the **efivarfs** filesystem at `/sys/firmware/efi/efivars/`. The load order is `BootOrder` (a list of 16-bit IDs); each `Boot####` variable is an `EFI_LOAD_OPTION` holding a description, a device path, and optional data. `efibootmgr(8)` is the userspace tool that reads/writes these. The presence of `/sys/firmware/efi` is itself the definitive test of whether you booted UEFI or BIOS — if that directory is absent, you are on legacy BIOS, full stop.

```
/sys/firmware/efi/efivars/BootOrder-8be4df61-...   # ordered list of Boot#### IDs
/sys/firmware/efi/efivars/Boot0000-8be4df61-...    # one boot entry (device path + desc)
/sys/firmware/efi/efivars/SecureBoot-8be4df61-...  # 1 byte: is Secure Boot active?
```

> Failure mode at scale: efivarfs is backed by *actual firmware NVRAM*, which on some boards is a few dozen KB of flash with a finite write endurance. There is a real class of bricked machines (the infamous 2016 "rm -rf bricked my laptop" bug) caused by writing junk to efivars or filling NVRAM. Treat `/sys/firmware/efi/efivars` as precious hardware, not a scratch directory. The immutable flag (`chattr`) that the kernel sets on those files is a guardrail, not decoration.

### 2. Secure Boot, shim, and MOK — the chain of trust and where it actually breaks

Secure Boot is UEFI firmware refusing to hand control to a PE binary whose signature doesn't chain to a key in the platform's allow-list. The key hierarchy, from most to least privileged:

- **PK** (Platform Key): one key, the platform owner. Signs updates to KEK.
- **KEK** (Key Exchange Keys): sign updates to db/dbx. Microsoft's KEK is here on virtually all retail hardware.
- **db** (signature database): the allow-list. Contains Microsoft's "Windows Production" CA *and* the "UEFI CA 2011 / 2023" third-party CA.
- **dbx** (forbidden database): the deny-list of revoked hashes/certs. This is how vulnerable binaries (old GRUBs, old shims) get killed globally.

The distro problem: getting a key into `db` on every machine means getting Microsoft to sign it, per binary, forever. Distros solve this with **shim** — a tiny first-stage loader that Microsoft signs *once* (via the UEFI CA). Shim carries the distro's own CA baked into it. So the runtime chain is:

```
firmware --(verifies against db: MS UEFI CA)--> shim.efi
shim --(verifies against: its embedded distro cert  OR  db  OR  MOK db  OR  MOK hash list)--> grubx64.efi
shim installs the EFI_SHIM_LOCK / Shim verify protocol
grub  --(calls shim's verify protocol)--> vmlinuz
kernel --(with lockdown + module.sig_enforce)--> only loads signed modules
```

**MOK (Machine Owner Key)** is the escape hatch for *you*. It is a separate key database that shim consults, stored in a boot-services EFI variable and managed by **MokManager** (`mmx64.efi`, which shim launches when enrollment is pending) and the userspace tool **`mokutil`**. When you build an out-of-tree module (NVIDIA, DKMS, a custom kernel), you sign it with your own key and enroll that key's public half into MOK. Enrollment deliberately requires a *physical reboot and a firmware-time confirmation screen* — `mokutil --import key.der` only queues the request; MokManager prompts you to confirm on next boot with a password you set. This is intentional: it means a remote attacker who owns root still cannot silently enroll a signing key, because the confirmation happens before any OS is running, at the console.

```
sign a module:   /usr/src/kernels/$(uname -r)/scripts/sign-file sha256 MOK.priv MOK.der module.ko
queue the key:   mokutil --import MOK.der         # sets a password, queues for MokManager
reboot → MokManager blue screen → "Enroll MOK" → enter password → reboot
verify:          mokutil --list-enrolled | grep -A2 <your CN>
kernel view:     keyctl show %:.platform   (and the .machine keyring on newer kernels)
```

**SBAT (Secure Boot Advanced Targeting)** is the modern revocation mechanism you must know in 2026. The old way to revoke a broken GRUB was to add its *hash* to dbx — but every distro rebuild produces a new hash, so dbx would need thousands of entries and would eventually overflow the tiny NVRAM. SBAT instead embeds a `.sbat` CSV section in shim/GRUB listing component names and *generation numbers*. Firmware/shim stores a minimum-generation policy in the `SBAT` EFI variable; a binary whose generation is below the floor is refused. This is how the 2022–2024 "BootHole"-class and follow-on GRUB CVEs got revoked en masse. The failure mode that will land on your desk: a firmware or shim update bumps the SBAT floor, and machines that dual-boot an *old* Linux (or a rescue USB with an old shim) suddenly refuse to boot with `Verifying shim SBAT data failed: Security Policy Violation`. The fix is updating the old GRUB/shim, not disabling Secure Boot.

> The senior distinction: `setenforce`-style "just turn it off" for Secure Boot is `mokutil --disable-validation`. Knowing it exists is fine; reaching for it first is the junior move. The staff move is to read the *actual* failure string (SBAT vs signature vs missing db entry) and fix the specific link in the chain.

### 3. GRUB2: stages, images, and the config model

GRUB2 is not one binary; it is a tiny kernel + loadable modules (`.mod`). The pieces:

- **`boot.img`** (BIOS only): the 446-byte MBR stub. Loads sector 1 of `core.img`.
- **`core.img`**: GRUB's runtime core — device/filesystem framework, environment, and crucially the **rescue-mode command parser**. On BIOS it's embedded in the "BIOS boot" gap (the `bios_grub` GPT partition, ~1 MiB after the GPT). On UEFI, the equivalent is **`grubx64.efi`** on the ESP, built by `grub2-mkimage` with a baked-in `prefix` (where to find `/boot/grub2`) and a set of preload modules.
- **`normal.mod`**: the module that implements the *normal* mode — menus, `grub.cfg` parsing, the full command set. The single most important fact about GRUB failure modes: **if GRUB can't load `normal.mod`, you land at `grub rescue>`** (a minimal prompt with only `ls`, `set`, `insmod`, `linux`, `initrd`, `boot`). If it loads `normal` but the config is broken, you land at the fuller `grub>` prompt.

The `grub rescue>` recovery ritual (memorize this, it is a genuine break-glass skill):

```
grub rescue> ls                          # list devices: (hd0), (hd0,gpt1), ...
grub rescue> ls (hd0,gpt2)/              # find the one with /boot or a grub dir
grub rescue> set prefix=(hd0,gpt2)/boot/grub2
grub rescue> set root=(hd0,gpt2)
grub rescue> insmod normal
grub rescue> normal                      # promotes you to full grub> with the menu
```

**The config model is where RHEL 8/9 diverges from "edit grub.cfg".** The **Boot Loader Specification (BLS)** is now the default on RHEL 8+/Fedora. Instead of `grub2-mkconfig` regenerating one giant `grub.cfg` with a stanza per kernel, `grub.cfg` contains a `blscfg` command that reads drop-in snippet files at boot time:

```
/boot/loader/entries/<machine-id>-<kernelver>.conf
```

Each snippet is a few lines: `title`, `version`, `linux`, `initrd`, `options` (the kernel cmdline), `grub_users`, etc. This is the same drop-in-directory philosophy as systemd units, and it means kernel installs/removals just add/remove a file rather than rewriting a monolith. The correct tool to edit kernel cmdline args on RHEL 9 is **`grubby`** (or `grub2-editenv` for the default), *not* hand-editing `grub.cfg`:

```
grubby --info=ALL                                   # list all BLS entries
grubby --update-kernel=ALL --args="audit=0"         # add a cmdline arg to every entry
grubby --update-kernel=ALL --remove-args="quiet"    # remove one
grubby --default-kernel                             # which entry boots by default
```

`/etc/default/grub` still holds the *defaults* (`GRUB_CMDLINE_LINUX`, timeout, etc.) that feed newly-created entries; `grub2-mkconfig -o /boot/grub2/grub.cfg` regenerates the top-level config. The trap: on a BLS system, editing `GRUB_CMDLINE_LINUX` and running `grub2-mkconfig` does **not** retroactively change existing BLS entries — you have to use `grubby` for those. This bites people who "fixed" the cmdline and rebooted into the unchanged old args.

> UEFI vs BIOS config paths on RHEL: `/boot/grub2/grub.cfg` on BIOS; on UEFI the real file is `/boot/efi/EFI/redhat/grub.cfg` (older layout) or, on recent RHEL, a small stub `grub.cfg` on the ESP that chains to `/boot/grub2/grub.cfg`. Knowing which file is authoritative on the box in front of you is a five-minute time-saver you'll use constantly.

### 4. The kernel + initramfs handoff: on-disk format and decompression

GRUB's `linux` command loads `vmlinuz` and `initrd` loads the initramfs, both into RAM; `boot` sets up the boot protocol structure (the "zero page" on x86, carrying the cmdline pointer, memory map, framebuffer info) and jumps to the kernel's entry point.

`vmlinuz` is a **self-extracting image**: a small decompressor stub (`arch/x86/boot/compressed/`) plus the compressed real kernel (gzip/xz/zstd/lz4 depending on `CONFIG_KERNEL_*`). The stub sets up early paging, relocates itself (KASLR picks a random base here), decompresses the kernel to its run address, and jumps to `start_kernel()`.

**The initramfs is a cpio archive**, specifically the **newc** ("SVR4 no-CRC") format, usually compressed. The kernel unpacks it into a **tmpfs that becomes the initial rootfs** — this is the key difference from the old `initrd` (which was a block device / ramdisk you mounted). initramfs is *the* root; there is no mount, the files simply exist in a rootfs. The kernel then executes `/init`.

**The dual-cpio microcode trick** is a detail that trips people up when they manually unpack an initramfs. Modern initramfs on x86 is frequently *two concatenated cpio archives*:

```
[ uncompressed cpio ]  ── kernel/x86/microcode/{GenuineIntel,AuthenticAMD}.bin
[ compressed   cpio ]  ── the actual initramfs (busybox/systemd, modules, dracut scripts)
```

The kernel reads the leading *uncompressed* cpio very early (before most init) to apply CPU microcode updates ASAP, then treats the remainder as the real initramfs. Practical consequence: naive `zcat initramfs | cpio -idv` sees only garbage or stops early, because the first archive isn't compressed. Use `lsinitrd` / `lsinitramfs`, or the kernel's own `scripts/extract-vmlinux` and `unmkinitramfs`, which know about the concatenation. This is exactly the "cpio premature end of archive" error people hit.

```
lsinitrd /boot/initramfs-$(uname -r).img            # RHEL/Fedora: lists contents + args
lsinitrd /boot/initramfs-$(uname -r).img -f /path    # dump one file from inside it
# Manual, handling the early-cpio microcode segment:
/usr/lib/dracut/skipcpio /boot/initramfs-$(uname -r).img | zstd -d | cpio -idv
```

### 5. dracut and initramfs internals: why the initramfs exists and how it's assembled

The initramfs exists to solve a chicken-and-egg problem: the real root filesystem may live on **LVM, LUKS-encrypted, on software RAID, on multipath SAN, on iSCSI/NBD, on NFS**, or need a filesystem module (XFS, Btrfs) that isn't built into the kernel. The kernel can't mount `/` until those subsystems are assembled, but the tools to assemble them live on `/`. The initramfs breaks the cycle: it's a self-contained mini-userspace with `lvm`, `cryptsetup`, `mdadm`, `dmraid`, `multipath`, udev, and just enough kernel modules to bring the real root online, then get out of the way.

**dracut** builds it. Two design choices worth internalizing:

1. **Modular, not monolithic.** dracut modules live in `/usr/lib/dracut/modules.d/NNname/` (e.g. `90lvm`, `90crypt`, `95udev-rules`, `98dracut-systemd`). Each has a `module-setup.sh` with `check()` (should this module be included?), `depends()` (what else it needs), and `install()` (copy binaries/scripts/units in). dracut computes dependencies (via `ldd`, udev rules, kmod) and assembles the archive.

2. **Two build strategies.** `dracut --hostonly` (RHEL default) tailors the image to *this* machine's hardware and storage — smaller, faster, but will not boot on different hardware. `dracut --no-hostonly` builds a generic image with drivers for everything — this is what installers and rescue images use. **This is a top-tier gotcha:** clone a host-only-built VM to different virtual hardware, or move a disk to a new box, and it drops to the dracut emergency shell because the needed storage driver was never included. The fix is regenerating with `dracut -f --no-hostonly` from a rescue environment.

**The dracut boot flow and hook points** (on a systemd-in-initrd system, these map to systemd units in the initrd, but the hook concept is the mental model):

```
kernel execs /init  →  dracut/systemd initrd
  │
  ├─ cmdline hook   ── parse rd.* kernel args
  ├─ pre-udev       ── load essential modules
  ├─ udev starts    ── device discovery; devices appear in /dev
  ├─ pre-trigger / initqueue ── retry loop waiting for root device to appear
  ├─ pre-mount      ── LUKS unlock, LVM activate, mdadm assemble, multipath
  ├─ mount hook     ── mount real root at /sysroot (read-only first)
  ├─ pre-pivot / cleanup ── last chance before leaving initramfs
  └─ switch_root /sysroot /usr/lib/systemd/systemd
```

`switch_root` (the tool, or systemd's `initrd-switch-root.service`) does something subtle and irreversible: it **deletes the entire initramfs rootfs to free the RAM**, `chroot`s into `/sysroot`, and `exec`s the real init with PID 1 preserved. You cannot go "back" to the initramfs after this. The reason it deletes rather than unmounts: initramfs *is* the rootfs (mount point `/` with no underlying device), so you can't just `umount` it; `switch_root` recursively removes its files and uses `mount --move` semantics to swap the root.

The **kernel command line `rd.*` namespace** is the dracut control surface. The ones that matter:

```
rd.break                 # drop to emergency shell right before switch_root
rd.break=pre-mount       # drop BEFORE the real root is mounted (fs repair, etc.)
rd.break=mount           # after mount attempt
rd.shell rd.debug        # spawn a shell on failure + verbose set -x tracing to /run/initramfs/rdsosreport.txt
rd.driver.pre=xfs        # force-load a module early
root=UUID=... rootflags= # the real root and its mount options
rd.lvm.lv=vg/lv  rd.luks.uuid=  rd.md.uuid=  # tell dracut what to assemble
```

`rd.break` variants are the single most useful break-glass tool in this module. `rd.break` alone gives you a shell with the real root mounted read-only at `/sysroot` — that's your entry point for a forgotten root password reset (chroot, passwd, and on SELinux systems `touch /.autorelabel` so the changed `/etc/shadow` gets relabeled — forget that step and you'll be locked out again by an AVC denial).

### 6. systemd early boot: from PID 1 to a login prompt

After `switch_root`, the real `/usr/lib/systemd/systemd` runs as PID 1. systemd is a dependency-resolving, cgroup-tracking service manager; boot is just "reach the default target." The **`default.target`** (a symlink, usually to `multi-user.target` or `graphical.target`) is the goal; systemd works backwards through the dependency graph.

The canonical target ordering (`bootup(7)` is the authoritative diagram):

```
                     (initrd) initrd.target
                                │  switch_root
                                ▼
    local-fs-pre.target ─► local-fs.target ─┐
    swap.target ────────────────────────────┤
    cryptsetup.target ───────────────────────┤
                                              ▼
                                    sysinit.target      ← low-level init done
                                              │            (fsck, mounts, udev,
                                              ▼             tmpfiles, sysctl, LVM)
                       sockets.target  timers.target  paths.target
                                              │
                                              ▼
                                     basic.target        ← "system is usable"
                                              │
                                              ▼
                          (all the normal services: sshd, network, etc.)
                                              │
                                              ▼
                                  multi-user.target
                                              │
                                              ▼
                                  graphical.target = default.target
```

Two mechanisms that separate "I know the target names" from understanding:

- **`sysinit.target`** is the synchronization barrier for all the low-level, must-happen-first work: mounting `/proc`, `/sys`, API VFSes, applying sysctls, running `systemd-tmpfiles`, journald, udev settle. Nothing in `basic.target` or later can assume the system is sane until `sysinit.target` is reached.
- **Socket/bus activation** is *the* design insight that replaced sequential SysV init. systemd creates and holds all the listening sockets *first* (before the daemons that own them start). A client connecting to a not-yet-started service blocks on the socket buffer instead of failing, so services can start in **parallel** and in any order — the dependency ordering that SysV enforced serially mostly evaporates. This is why systemd boot is fast and why `After=`/`Before=` is about *ordering* while `Wants=`/`Requires=` is about *pulling units in*; the two are orthogonal and conflating them is a classic bug.

**`systemd-analyze`** is your boot-performance and boot-debug toolkit:

```
systemd-analyze                       # total firmware/loader/kernel/userspace time
systemd-analyze blame                 # slowest units, descending
systemd-analyze critical-chain        # the dependency chain on the critical path (the one that matters)
systemd-analyze plot > boot.svg       # timeline visualization
systemd-analyze dump                  # full internal state
```

`blame` is the beginner trap: the slowest unit is often *not* on the critical path (it started in parallel and nobody waited for it). `critical-chain` shows what actually gated boot. That distinction is a senior tell.

**Emergency and rescue targets** are the systemd-era break-glass:

- `emergency.target` (`systemd.unit=emergency.target` or `emergency` on cmdline): the most minimal — root shell, `/` mounted read-only, almost nothing else started. For "the root filesystem itself is broken."
- `rescue.target` (`systemd.unit=rescue.target` or the legacy `single` / `1`): single-user, local filesystems mounted, `sysinit` done, but no networking/multi-user services. For "the system boots but a service is wedging multi-user."

`systemctl default`, `systemctl isolate <target>`, and `systemctl rescue`/`emergency` switch between them at runtime.

### 7. Unified Kernel Images (UKI) and systemd-boot — where this is all heading

The traditional model (shim → GRUB → separate kernel + initramfs + external cmdline) has a soft spot: the **kernel command line and initramfs are not covered by the Secure Boot signature**. An attacker with brief physical/console access can append `init=/bin/bash` or swap the initramfs and defeat the whole chain. The **UKI** fixes this by packing, into a single signed PE/COFF binary via `systemd-stub`:

```
UKI .efi (one signed PE binary):
  .linux    → the kernel
  .initrd   → the initramfs
  .cmdline  → the fixed kernel command line
  .osrel    → os-release identification
  .uname    → kernel version
  (.sbat, .pcrsig, .pcrpkey for measured boot / TPM policy)
```

Now the signature covers kernel *and* initramfs *and* cmdline together — tamper with any of them and Secure Boot refuses to load it. UKIs are built with `ukify` or `dracut --uefi`, dropped in the ESP under `EFI/Linux/`, and booted directly by the firmware or by **`systemd-boot`** (`sd-boot`, a minimal EFI boot manager that reads simple `.conf` entries from the ESP and, unlike GRUB, has essentially no filesystem/scripting attack surface). This dovetails with **measured boot**: each stage extends **TPM PCRs** (PCR 4/7/8/9 etc.) with hashes of what it loaded, and you can seal a LUKS key so it only unseals if the PCRs match a known-good chain (`systemd-cryptenroll --tpm2-device=auto`). RHEL 9/10 and Fedora ship UKI support; know that BLS+GRUB is the present and UKI+sd-boot is the near future, so a symptom like "my cmdline edit via `grubby` did nothing" might mean the box boots a UKI where the cmdline is baked in and immutable.

### Cross-subsystem coupling (the staff lens)

Boot is where every other subsystem in this track shows up at once:

- **Storage** ([[05 - Storage and LVM]] / device-mapper): the initramfs *is* the LVM/LUKS/mdraid assembly layer. A snapshot-full origin, a degraded RAID with no `rd.md.uuid`, or a multipath map that didn't settle all manifest as "dropped to dracut shell."
- **Namespaces/mounts**: `switch_root` and `mount --move`, mount propagation, and the fact that initramfs is a rootfs with no backing device all live in the [[10 - Namespaces and cgroups v2]] mount-namespace mechanics.
- **systemd resource control** ([[07 - systemd]]): the same unit/target/cgroup model runs in the initrd and the real system.
- **Security** ([[12 - SELinux and Hardening]]): the missing-`.autorelabel` lockout, kernel `lockdown` mode under Secure Boot, and `module.sig_enforce`.

---

## Hands-on labs

> Use a **throwaway UEFI VM**. The clean way to get one is a cloud image booted locally. Below assumes a fresh VM you can snapshot and destroy. Where a step is destructive to the VM's bootability, that's the point — snapshot first. Distro-agnostic commands are given; RHEL/Fedora/Rocky specifics are called out because that's the CIQ-relevant target.
>
> Fastest disposable UEFI VM (any host with libvirt/QEMU):
> ```
> # Fedora/Rocky cloud image + UEFI firmware (OVMF)
> virt-install --name bootlab --memory 2048 --vcpus 2 \
>   --disk size=10 --os-variant rocky9 \
>   --boot uefi \
>   --cdrom /path/to/Rocky-9-latest-x86_64-boot.iso
> # snapshot the instant install finishes:
> virsh snapshot-create-as bootlab clean
> ```
> `virsh snapshot-revert bootlab clean` resets between labs.

### Lab 1 — Dissect a running boot: firmware mode, the chain, and the initramfs on-disk format

**Objective:** Prove to yourself which firmware/Secure-Boot state you're in, read the actual EFI boot variables, and crack open an initramfs including the early-cpio microcode segment.

**Setup:** Any booted Linux VM (UEFI preferred). Install `efibootmgr`, `mokutil`, `binutils`, `cpio`, `zstd`. On RHEL/Rocky: `dnf install -y efibootmgr mokutil binutils cpio zstd`.

**Steps:**

1. Determine firmware mode from first principles, not from a tool:
   ```
   [ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS"
   ls /sys/firmware/efi/efivars | head
   ```
2. Read the boot order and entries straight from firmware NVRAM:
   ```
   efibootmgr -v
   ```
   Note the `BootOrder`, and for each `Boot####` the device path (which disk/partition/file). Identify which entry is shim vs the fallback.
3. Check Secure Boot state and the key databases:
   ```
   mokutil --sb-state
   mokutil --list-enrolled | head -40      # MOK db
   # raw firmware view of the SecureBoot variable (last byte: 01 = on):
   od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
   ```
4. Find and inspect the initramfs the high-level way:
   ```
   lsinitrd /boot/initramfs-$(uname -r).img | head -40
   lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'dracut|lvm|crypt|xfs'
   ```
5. Now crack it open the *hard* way to see the two-cpio structure. First confirm the early cpio is uncompressed microcode:
   ```
   mkdir /tmp/initr && cd /tmp/initr
   cp /boot/initramfs-$(uname -r).img .
   # The leading archive is a plain cpio; skipcpio jumps past it:
   /usr/lib/dracut/skipcpio initramfs-*.img > main.cpio.compressed
   # Detect compression of the main part and decompress accordingly (zstd on modern RHEL):
   file main.cpio.compressed
   zstd -d < main.cpio.compressed | cpio -idmv 2>/dev/null | head
   ```
6. Extract *just* the microcode front archive to prove it's there and uncompressed:
   ```
   cpio -idmv < initramfs-*.img 2>/dev/null    # stops after the first (early) archive
   find kernel/x86/microcode -type f
   ```

**Prove it:**
```
# One command that verifies you correctly parsed the two-archive layout:
diff <(lsinitrd /boot/initramfs-$(uname -r).img | grep -c . ) \
     <(echo "just checking lsinitrd works") ; \
find /tmp/initr/kernel/x86/microcode -name '*.bin' -o -name 'GenuineIntel*' 2>/dev/null && \
echo "SUCCESS: early-cpio microcode segment found; main archive decompressed separately"
```
You understand the format when you can state *why* `zcat initramfs | cpio -id` fails on a modern image (the leading archive isn't compressed) and why `skipcpio` is needed.

**Teardown:** This lab is read-only against the system but leaves an extracted copy of the initramfs on disk. Remove it:
```
cd / && rm -rf /tmp/initr
```

### Lab 2 — Break GRUB, recover from `grub rescue>`, and drive BLS with grubby

**Objective:** Deliberately induce the two distinct GRUB failure prompts (`grub rescue>` vs `grub>`), recover by hand, and then manage kernel cmdline the *correct* BLS way.

**Setup:** UEFI RHEL/Rocky/Fedora VM with BLS (default). **Snapshot first** (`virsh snapshot-create-as bootlab prebreak`). You need console access (`virsh console` or the graphical console), not SSH — you're going to break boot.

**Steps:**

1. Map the current, correct config so you know what "fixed" looks like:
   ```
   grubby --default-kernel
   grubby --info=DEFAULT
   ls /boot/loader/entries/
   cat /boot/loader/entries/*.conf | sed -n '1,20p'
   ```
2. Induce a `grub rescue>` by breaking the prefix. On a BIOS box you'd corrupt `core.img`; on UEFI, temporarily move the grub dir so `normal.mod` can't be found:
   ```
   mv /boot/grub2 /boot/grub2.bak
   reboot        # you'll land at grub rescue>
   ```
3. At `grub rescue>`, recover by hand (this is the skill):
   ```
   grub rescue> ls
   grub rescue> ls (hd0,gpt2)/            # find the partition holding /boot
   grub rescue> set prefix=(hd0,gpt2)/boot/grub2.bak
   grub rescue> set root=(hd0,gpt2)
   grub rescue> insmod normal
   grub rescue> normal
   ```
   You should now get the menu; boot normally, then `mv /boot/grub2.bak /boot/grub2` to fully repair.
4. Induce the *other* prompt (`grub>`) by breaking the config content, not the prefix:
   ```
   cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.bak
   echo "this is not valid grub syntax {{{" >> /boot/grub2/grub.cfg
   # (or point a BLS entry's linux= at a nonexistent kernel)
   reboot
   ```
   At `grub>` you have the full command set; boot manually with `linux`/`initrd`/`boot`, then restore the config.
5. Now do it the right way: change a kernel cmdline arg across all entries using grubby, and prove BLS vs `/etc/default/grub` behavior:
   ```
   grubby --update-kernel=ALL --args="systemd.log_level=debug"
   grep options /boot/loader/entries/*.conf
   # Contrast: editing GRUB_CMDLINE_LINUX does NOT touch existing BLS entries
   grep GRUB_CMDLINE_LINUX /etc/default/grub
   ```

**Prove it:**
```
# After grubby edit + reboot, the running kernel must show the arg:
grep -o 'systemd.log_level=debug' /proc/cmdline && echo "SUCCESS: BLS cmdline edit took effect"
# And you can articulate the rule:
echo "grub rescue> = normal.mod not loaded (prefix/core broken); grub> = config broken"
```

**Teardown:** Undo the deliberate breakage and the persistent cmdline arg, and drop the config backups:
```
# If not already restored during the steps:
[ -d /boot/grub2.bak ] && mv /boot/grub2.bak /boot/grub2
[ -f /boot/grub2/grub.cfg.bak ] && mv -f /boot/grub2/grub.cfg.bak /boot/grub2/grub.cfg
# Remove the cmdline arg added to every BLS entry:
grubby --update-kernel=ALL --remove-args="systemd.log_level=debug"
grep options /boot/loader/entries/*.conf   # confirm it's gone
```
Cleanest reset if boot state is uncertain: `virsh snapshot-revert bootlab prebreak`.

### Lab 3 — `rd.break`: break-glass into the initramfs and reset a lost root password

**Objective:** Enter the dracut emergency shell at a chosen point, understand what's mounted where, and perform the canonical forgotten-root-password recovery *including the SELinux relabel step* that everyone forgets.

**Setup:** UEFI RHEL/Rocky/Fedora VM with SELinux in enforcing mode (default). Console access required. Snapshot first.

**Steps:**

1. Reboot, interrupt GRUB (hold Shift / press `e` on the entry), and append to the `linux` line:
   ```
   rd.break enforcing=0
   ```
   `Ctrl-x` to boot. You'll drop to `switch_root:/#` — this is the dracut/initramfs emergency shell, *before* switch_root.
2. Inspect where you are. The real root is mounted read-only at `/sysroot`; the initramfs is `/`:
   ```
   mount | grep sysroot
   ls /sysroot            # this is the real filesystem
   cat /proc/cmdline      # confirm rd.break is present
   ```
3. Remount the real root read-write and enter it:
   ```
   mount -o remount,rw /sysroot
   chroot /sysroot
   ```
4. Reset the password and stage the SELinux relabel (the critical step):
   ```
   passwd root
   touch /.autorelabel      # forces full relabel on next boot so /etc/shadow gets a correct context
   exit                     # leave chroot
   exit                     # leave initramfs shell → boot continues, relabels, reboots
   ```
5. Observe *why* `.autorelabel` matters: repeat the lab but skip the `touch /.autorelabel` and skip `enforcing=0`. With SELinux enforcing and a shadow file written with the wrong context, login fails with an AVC denial even though the password is correct. That's the trap this step avoids.

**Prove it:**
```
# After reboot, log in with the new root password, then confirm the relabel ran:
ls -Z /etc/shadow          # context should be system_u:object_r:shadow_t:s0
ausearch -m avc -ts recent 2>/dev/null | tail || echo "no AVC denials -> relabel succeeded"
echo "SUCCESS if you can log in AND shadow_t context is correct"
```

**Teardown:** This lab changes the root password and triggers a full filesystem relabel, both persistent. Set the password back to a known value if you're keeping the VM, and clear the relabel flag if it's still pending:
```
passwd root                 # reset to your known credential
[ -f /.autorelabel ] && rm -f /.autorelabel   # only if a relabel hasn't already consumed it
```
The clean reset for this disposable VM is to revert the snapshot: `virsh snapshot-revert bootlab clean`.

### Lab 4 — Own the Secure Boot chain: sign a kernel module and enroll a MOK

**Objective:** Understand the shim→MOK trust extension by generating your own signing key, signing an out-of-tree module, enrolling the key via MokManager, and proving the kernel loaded a module it would otherwise reject.

**Setup:** UEFI VM with **Secure Boot enabled** in firmware (in libvirt/OVMF, use the `*_VARS.secboot.fd` template and an enrolled MS keys firmware, e.g. `edk2-ovmf` secboot variant). Install kernel headers + `mokutil` + `openssl` + `keyutils`. On Rocky: `dnf install -y kernel-devel mokutil openssl keyutils`. Snapshot first.

**Steps:**

1. Confirm Secure Boot is actually on and lockdown is engaged:
   ```
   mokutil --sb-state
   cat /sys/kernel/security/lockdown       # expect [integrity] or [confidentiality]
   ```
2. Build a trivial out-of-tree module (a hello-world `.ko`) so you have something unsigned to load. Minimal module + `Makefile` using `/lib/modules/$(uname -r)/build`. Confirm it's rejected while Secure Boot enforces module signatures:
   ```
   insmod ./hello.ko        # EKEYREJECTED: "Key was rejected by service" / "Required key not available"
   dmesg | tail -3          # PKCS#7 signature not signed with a trusted key
   ```
3. Generate a MOK signing keypair:
   ```
   openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv -out MOK.der \
     -outform DER -days 3650 -nodes -subj "/CN=bootlab MOK/"
   ```
4. Sign the module with the kernel's `sign-file`:
   ```
   /usr/src/kernels/$(uname -r)/scripts/sign-file sha256 MOK.priv MOK.der ./hello.ko
   ```
5. Queue the public key for enrollment (sets a one-time password MokManager will ask for):
   ```
   mokutil --import MOK.der
   reboot
   ```
6. At reboot, shim launches **MokManager** (blue screen): choose *Enroll MOK* → *View key* → *Continue* → enter the password. It reboots.
7. Prove the key is now trusted and the previously-rejected module loads:
   ```
   mokutil --list-enrolled | grep -A2 "bootlab MOK"
   keyctl show %:.platform 2>/dev/null; cat /proc/keys | grep -i mok
   insmod ./hello.ko && echo "loaded"
   lsmod | grep hello
   ```

**Prove it:**
```
# Before enrollment insmod failed with EKEYREJECTED; after enrollment it succeeds.
# One-shot verification:
mokutil --list-enrolled | grep -q "bootlab MOK" && lsmod | grep -q hello \
  && echo "SUCCESS: MOK enrolled and self-signed module loaded under Secure Boot"
```
You understand the chain when you can explain *why* enrollment required a physical reboot confirmation (so a remote root can't silently enroll a key) and *why* the same module was rejected before but accepted after, in terms of shim's verify protocol and the kernel keyring.

**Teardown:** Unload the module, queue removal of the enrolled MOK (this too requires a MokManager confirmation at reboot), and delete the signing keypair:
```
rmmod hello 2>/dev/null
mokutil --delete MOK.der    # sets a one-time password; confirm "Delete MOK" in MokManager on reboot
reboot                      # complete the deletion, then verify:
# mokutil --list-enrolled | grep "bootlab MOK"   → should return nothing
rm -f MOK.priv MOK.der hello.ko hello.mod.c hello.o hello.mod.o hello.mod hello.ko.* modules.order Module.symvers
```
Since the MOK lives in firmware NVRAM, the fully clean reset is reverting the pre-lab snapshot: `virsh snapshot-revert bootlab clean`.

---

## Curated resources

**Primary specs and kernel/tool docs (the authoritative layer)**

- **bootup(7) — systemd boot process** — https://www.freedesktop.org/software/systemd/man/latest/bootup.html — The definitive diagram and prose for the entire target ordering from initrd through `sysinit.target`/`basic.target` to `graphical.target`, including the initrd→switch_root handoff and the `initrd-*.target` units. This is the map you should be able to redraw from memory.
- **dracut.cmdline(7)** — https://www.man7.org/linux/man-pages/man7/dracut.cmdline.7.html — Every `rd.*` kernel parameter dracut honors, including all the `rd.break` stages, `rd.lvm.lv`, `rd.luks.uuid`, `rd.md.uuid`, `rd.driver.pre`, and the debug/shell knobs. Your break-glass reference.
- **dracut.modules(7) + dracut(8)** — https://man7.org/linux/man-pages/man7/dracut.modules.7.html and https://www.man7.org/linux/man-pages/man8/dracut.8.html — The module system (`check`/`depends`/`install`, the hook directories) and the generator flags (`--hostonly` vs `--no-hostonly`, `-f`, `--uefi`). This is what turns the initramfs from a black box into something you can rebuild and reason about.
- **GNU GRUB Manual — "Images"** — https://www.gnu.org/software/grub/manual/grub/html_node/Images.html — Authoritative on `boot.img`/`core.img`/`normal.mod`, the prefix mechanism, and exactly why you land at `grub rescue>` vs `grub>`. Read the whole manual's boot and rescue sections.
- **Boot Loader Specification (freedesktop)** — https://uapi-group.org/specifications/specs/boot_loader_specification/ (originally https://www.freedesktop.org/wiki/Specifications/BootLoaderSpec/) — The spec behind `/boot/loader/entries/*.conf`. Explains the drop-in entry format that RHEL 8+/Fedora and systemd-boot both consume; the "why" behind grubby.
- **Documentation/x86/microcode & initrd handling (kernel.org)** — https://docs.kernel.org/arch/x86/microcode.html — The early-cpio microcode mechanism: why initramfs is often two concatenated archives and how the kernel consumes the uncompressed leading one. Pair with `lsinitrd`/`skipcpio`.

**Secure Boot / shim / MOK (the trust-chain layer)**

- **rodsbooks — "Dealing with Secure Boot" (Rod Smith)** — https://www.rodsbooks.com/efi-bootloaders/secureboot.html — The clearest end-to-end explanation of PK/KEK/db/dbx, shim, and MOK from someone who wrote EFI boot tooling (rEFInd). Best single orientation before the wikis.
- **ArchWiki — UEFI/Secure Boot** — https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot — The most complete practical reference on `mokutil`, `sbctl`, signing your own binaries, and custom key enrollment. Distro-agnostic and kept current.
- **rhboot/shim README + SBAT.md (GitHub)** — https://github.com/rhboot/shim/blob/main/SBAT.md — The primary source on SBAT: why hash-based dbx revocation didn't scale and how generation-number revocation works. This is the document behind the `Verifying shim SBAT data failed` errors you'll debug in 2026.
- **`sign-file` and Kernel Module Signing (kernel.org)** — https://docs.kernel.org/admin-guide/module-signing.html — The mechanism behind Lab 4: PKCS#7 signatures, the trusted keyrings (`.builtin_trusted_keys`, `.platform`, `.machine`), `module.sig_enforce`, and how lockdown ties in under Secure Boot.

**UKI / measured boot / the near future**

- **systemd-stub(7) and ukify(1)** — https://www.freedesktop.org/software/systemd/man/latest/systemd-stub.html — The Unified Kernel Image container format (`.linux`/`.initrd`/`.cmdline`/`.osrel` PE sections) and the tool that builds them. Read this to understand why a UKI's cmdline is immutable and Secure-Boot-covered.
- **systemd-boot(7)** — https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html — The minimal EFI boot manager replacing GRUB in the UKI world. Understand its near-zero attack surface vs GRUB's filesystem/scripting complexity.
- **Brauner/Poettering "Brave New Trusted Boot World" + Fedora UKI/BLS docs** — https://0pointer.net/blog/brave-new-trusted-boot-world.html — Poettering's own articulation of TPM-measured boot, PCR sealing, and where the ecosystem is heading. The strategic context for why UKI exists.

**Deep-debug and hands-on companions**

- **Fedora Magazine — "InitRAMFS, Dracut, and the Dracut Emergency Shell"** — https://fedoramagazine.org/initramfs-dracut-and-the-dracut-emergency-shell/ — The best practical walkthrough of `rd.break`, what's mounted at `/sysroot`, and navigating the emergency shell. Direct companion to Lab 3.
- **Fedora Project Wiki — "How to debug Dracut problems"** — https://fedoraproject.org/wiki/How_to_debug_Dracut_problems — `rd.debug`, `rd.shell`, `rdsosreport.txt`, and a systematic method for a machine stuck in the initramfs. The reference for "it drops to dracut and I don't know why."
- **0xAX — linux-insides, "Booting" chapters** — https://0xax.gitbooks.io/linux-insides/content/Booting/ — Source-level walk of real→protected→long mode, decompression, and early setup in `arch/x86/boot`. Read with the source tree open when you want to connect "the kernel boots" to specific functions.
- **Bootlin embedded-Linux slides (boot chain)** — https://bootlin.com/docs/ — Continuously updated, CC-licensed slide decks; the boot-chain material (bootloader → kernel → initramfs → init) is the best concise, *current* treatment against modern kernels, unlike the older books.
- **Red Hat — "Managing, monitoring and updating the kernel" (RHEL 9 docs)** — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/ — Authoritative on `grubby`, BLS entries, and the RHEL-specific `/boot` layout you'll actually touch on CIQ/Rocky systems.
- **rockyman.org** — https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here (`grubby`, `mokutil`, `dracut`, `efibootmgr`, `systemd-analyze`, `ausearch`, etc.) before trusting them in a recovery on a live box.

---

## Senior signal

- **Names the layer before touching anything.** Given "it won't boot," a staff engineer's first question is *which stage* — no POST (firmware/hardware), `grub rescue>` (core/prefix), `grub>` (config), dropped to dracut (`/sysroot` assembly), or hung after switch_root (systemd unit) — because each has a different break-glass hatch and a different state of the machine. Mid-level tries fixes; senior localizes first.
- **Distinguishes `grub rescue>` from `grub>` instantly and knows the one-liner recovery** (`set prefix`/`set root`/`insmod normal`/`normal`). This is the difference between a 3-minute console recovery and a reinstall.
- **Knows BLS changed the config model** and that on RHEL 8+/Fedora you edit cmdline with `grubby`, not by hand-editing `grub.cfg` or `GRUB_CMDLINE_LINUX` (which silently doesn't touch existing entries). Catches the "I fixed the cmdline and it did nothing" trap.
- **Reads the actual Secure Boot failure string and fixes the specific link** — SBAT floor bump vs missing db/MOK entry vs bad signature — instead of reflexively disabling Secure Boot. Understands shim exists so distros don't need per-binary Microsoft signatures, and that MOK enrollment requires a physical reboot confirmation *by design* (remote root can't enroll a key).
- **Understands the initramfs is a tmpfs rootfs, not a mounted ramdisk, and that `switch_root` deletes it irreversibly** to reclaim RAM. Explains the two-cpio microcode layout and why `zcat | cpio` fails on a modern image (`skipcpio`/`lsinitrd` needed).
- **Reaches for `rd.break` (and its stage variants) as a first-class tool**, and never forgets `touch /.autorelabel` after editing files on an SELinux-enforcing system in the initramfs shell — the single most common self-inflicted lockout in password recovery.
- **Knows `--hostonly` initramfs is the reason cloned/migrated VMs drop to the dracut shell**, and that `dracut -f --no-hostonly` from rescue is the fix. Reasons about the initramfs as the LVM/LUKS/RAID/multipath assembly layer, connecting a boot failure back to the storage stack.
- **Uses `systemd-analyze critical-chain`, not `blame`, to find what actually gated boot**, and can explain why socket activation lets services start in parallel (so the slowest unit is usually not on the critical path). Understands `sysinit.target` as the low-level barrier and the `emergency` vs `rescue` target distinction.
- **Sees where boot is going:** UKI + systemd-boot + TPM-measured boot collapse the GRUB/kernel/initramfs/cmdline story into one signed, immutable, attestable binary — and recognizes symptoms (an immutable cmdline, `EFI/Linux/*.efi`) that mean the box boots a UKI rather than BLS+GRUB.

## See also

- [[07 - systemd]] — the same unit/target/cgroup model that PID 1 drives to `default.target` also runs inside the initrd; this module picks up exactly where systemd early boot (`sysinit.target` → `basic.target`) leaves off.
- [[09 - The Kernel]] — the other side of the GRUB handoff: `vmlinuz` self-decompression, KASLR, `start_kernel()`, module signing/lockdown, and the kernel command line this module feeds in.
- [[02 - Warewulf Stateless Provisioning]] — Warewulf PXE/iPXE-boots diskless compute nodes: the firmware → bootloader → kernel + (network-delivered) initramfs → init chain here is exactly what Warewulf drives at cluster scale, minus a local disk.
- [[01 - HPC Cluster Architecture]] — provisioning and bringing up compute nodes is a fleet-scale application of this boot chain; the dracut `--no-hostonly` / hardware-mismatch gotcha is why golden images boot across heterogeneous nodes.
- [[05 - EC2 and Compute Internals]] — cloud instance boot (UEFI/OVMF, cloud images, NVMe root, cloud-init as the init hook) is the same chain; the efivars/UEFI and initramfs mechanics transfer directly.
