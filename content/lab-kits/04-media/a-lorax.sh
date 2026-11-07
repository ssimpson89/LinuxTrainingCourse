#!/bin/bash
# Lab 04A: build a Rocky 10.2 x86_64 boot ISO with lorax, then wrap it with mkksiso. Run as root from a scratch dir.
# Usage: sudo bash a-lorax.sh   (expects lab-minimal.ks next to it)
set -eu
HERE="$(dirname "$(readlink -f "$0")")"
W=/var/tmp/lab04; rm -rf $W; mkdir -p $W/scratch; cd $W/scratch      # lorax drops logs into the cwd
R=https://dl.rockylinux.org/pub/rocky/10
time lorax --product "Rocky Linux" --version 10.2 --release 10.2 --variant BaseOS \
  --volid Lab-Rocky-10-2-x86_64 --isfinal \
  --source $R/BaseOS/x86_64/os/ --source $R/AppStream/x86_64/os/ \
  --bugurl https://example.invalid/lab --nomacboot \
  --logfile $W/lorax.log --workdir $W/lorax-work --cachedir $W/lorax-cache $W/lorax-out
ls -la $W/lorax-out $W/lorax-out/images
cp $W/lorax-out/images/boot.iso $W/lab-boot.iso
cd $W
time mkksiso --ks "$HERE/lab-minimal.ks" lab-boot.iso lab-boot-ks.iso
ls -l lab-boot.iso lab-boot-ks.iso
