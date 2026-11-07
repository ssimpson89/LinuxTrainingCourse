#!/bin/bash
# Lab 04B: inspect the lorax ISO, the mkksiso ISO and (for comparison) the official boot.iso. Read-only; no root needed except mount (not used).
# Usage: bash b-inspect-iso.sh /var/tmp/lab04/lab-boot.iso /var/tmp/lab04/lab-boot-ks.iso ~/iso/Rocky-10.2-x86_64-boot.iso
for iso in "$@"; do
  echo "=================== $iso ($(stat -c %s "$iso") bytes)"
  echo "--- volume id / preparer"
  xorriso -indev "$iso" -pvd_info 2>&1 | grep -E 'Volume Id|Preparer|Creation Time'
  echo "--- El Torito (plain)"
  xorriso -indev "$iso" -report_el_torito plain 2>&1 | grep -E '^(Boot record|El Torito)'
  echo "--- El Torito (as_mkisofs)"
  xorriso -indev "$iso" -report_el_torito as_mkisofs 2>&1 | grep -v '^xorriso\|^$' | head -20
  echo "--- root listing"
  xorriso -indev "$iso" -ls 2>&1 | grep -v '^xorriso\|^$' | tr '\n' ' '; echo
  echo "--- treeinfo anywhere?"
  xorriso -indev "$iso" -find / -name '*treeinfo*' 2>&1 | grep -v '^xorriso' ; echo "(end of find)"
  echo "--- isolinux anywhere?"
  xorriso -indev "$iso" -find / -name 'isolinux*' 2>&1 | grep -v '^xorriso'; echo "(end of find)"
  echo "--- GPT/MBR partition layout"
  xorriso -indev "$iso" -report_system_area plain 2>&1 | grep -E 'GPT|MBR|partition' | head -12
  echo "--- isomd5"
  checkisomd5 "$iso"; echo "checkisomd5 rc=$?"
  echo "--- grub.cfg (first entries)"
  T=$(mktemp -d); xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT/grub.cfg "$T/grub.cfg" >/dev/null 2>&1
  grep -E "search|set default|set timeout|menuentry|linux|inst\." "$T/grub.cfg" | head -12; rm -rf "$T"
  echo "--- node count"
  xorriso -indev "$iso" -find / 2>/dev/null | wc -l
done
