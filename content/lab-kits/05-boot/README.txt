Lab kit 05: boot test without KVM (QEMU TCG, x86_64)
Used by: module 51 (Lab 4, a read-along of this run), module 43 (Lab 4, read-along)
Status: TESTED on Rocky 10.2 x86_64 (a VM with no /dev/kvm; qemu-kvm 10.1.0, edk2-ovmf 20251114), 2026-11-06.
        The ISO was the stock-repository lorax ISO from kit 04, NOT a branded one. It installed 249
        packages unattended over serial in about 51 minutes, and the disk booted to a login prompt in
        about 2 minutes. A login was never typed. BIOS boot and Secure Boot were not exercised.
        Edited after the tested run: the last line of a-make-iso.sh now copies grub.cfg out with
        xorriso -extract (the earlier form printed nothing). The extract command was run on the x86_64 lab VM
        on 2026-11-07 UTC against the lab-tcg ISO: it returned rc 0 and a 1,960-byte grub.cfg with the
        inst.ks and serial console arguments. The rest of the script is as tested.

Files
  lab-tcg.ks       smallest practical unattended install, serial console, powers off when done.
                   It WIPES the target disk (a qcow2 here) and contains a throwaway root password.
  a-make-iso.sh    wraps /var/tmp/lab04/lab-boot.iso (from kit 04) with lab-tcg.ks, serial console,
                   no media check, short GRUB timeout. Run as root.
  b-install.sh     unattended install into an 8 GiB qcow2 under TCG, UEFI, serial console
  c-boot-disk.sh   boot the installed qcow2 to a login prompt

Prerequisites
  Kit 04 done (/var/tmp/lab04/lab-boot.iso exists)
  sudo dnf -y install qemu-kvm qemu-img edk2-ovmf   (the binary is /usr/libexec/qemu-kvm, not on PATH)
  4 vCPU, 4 GiB for the guest installer, 8 GiB of disk for the qcow2, and patience
  Rocky 10 needs an x86-64-v3 CPU: under TCG the scripts use -cpu max

Run it
  sudo bash a-make-iso.sh
  bash b-install.sh        # about 50 minutes; the slow parts are kernel-core posttrans and initramfs generation
  bash c-boot-disk.sh      # about 2 minutes to the login prompt; stop QEMU from another terminal with pkill -f qemu-kvm

Clean up
  rm -rf ~/lab/05
  sudo rm -rf /var/tmp/lab04
