Lab kit 04: install media (kickstart check, lorax boot ISO, mkksiso, ISO inspection)
Used by: module 51 (Labs 1 to 3), module 43 (Lab 3 uses the kickstart)
Status: TESTED on Rocky 10.2 x86_64 (lorax 40.5.15, pykickstart 3.52.12, anaconda 40.22.3.46), 2026-11-06.
        NOT in this kit because they were never run on x86_64: the KIWI container and disk
        builds, and livemedia-creator --make-disk.
        Edited after the tested run: the grub.cfg step of b-inspect-iso.sh now copies the file out
        with xorriso -extract (the earlier form printed nothing). The edited script was run as shipped on the
        x86_64 lab VM on 2026-11-07 UTC against the lorax ISO and printed the real grub.cfg entries.

Files
  lab-minimal.ks     a tiny unattended Rocky 10 kickstart for x86_64 (UEFI or BIOS). It WIPES every
                     disk it can see: use it in a VM only. It contains a throwaway root password.
  a-lorax.sh         lorax builds a boot ISO from the public Rocky 10 trees, then mkksiso wraps it
                     with the kickstart. Run as root. Writes under /var/tmp/lab04.
  b-inspect-iso.sh   read-only report on any ISO: volume ID, El Torito entries, partition layout,
                     treeinfo and isolinux search, media check, grub.cfg entries, node count.

Prerequisites
  sudo dnf -y install xorriso squashfs-tools isomd5sum lorax lorax-templates-rocky pykickstart
  4 vCPU and 8 GiB RAM minimum. About 4.2 GB for the lorax output, work directory and two ISOs.
  For the comparison, the official Rocky-10.2-x86_64-boot.iso from
  https://dl.rockylinux.org/pub/rocky/10/isos/x86_64/ (1,049,538,560 bytes)

Run it
  ksvalidator lab-minimal.ks
  sudo bash a-lorax.sh                    # lorax took 16 minutes on 4 vCPU, mkksiso about 20 seconds
  bash b-inspect-iso.sh /var/tmp/lab04/lab-boot.iso /var/tmp/lab04/lab-boot-ks.iso ~/iso/Rocky-10.2-x86_64-boot.iso

Expect
  The lorax ISO matches the official one in structure (BIOS El Torito, appended EFI partition, no isolinux,
  no .treeinfo inside the ISO), with one difference: lorax leaves a visible images/efiboot.img.

Clean up
  sudo rm -rf /var/tmp/lab04
