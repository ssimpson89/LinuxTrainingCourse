#!/bin/bash
# Lab 05A: wrap the lorax boot ISO (from lab 04) with lab-tcg.ks, serial console, no media check, short grub timeout.
# Run as root: sudo bash a-make-iso.sh
set -eu
HERE="$(dirname "$(readlink -f "$0")")"
cd /var/tmp/lab04
rm -f lab-tcg.iso
mkksiso --ks "$HERE/lab-tcg.ks" \
  -c "console=ttyS0,115200n8 inst.text" \
  -r "rd.live.check quiet" \
  -R 'set timeout=60' 'set timeout=3' \
  -R 'set default="1"' 'set default="0"' \
  lab-boot.iso lab-tcg.iso
chmod 644 lab-tcg.iso
T=$(mktemp -d); xorriso -osirrox on -indev lab-tcg.iso -extract /EFI/BOOT/grub.cfg "$T/grub.cfg" >/dev/null 2>&1
grep -E "set default|set timeout|linuxefi" "$T/grub.cfg" | head -4; rm -rf "$T"
