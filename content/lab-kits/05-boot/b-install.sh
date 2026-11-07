#!/bin/bash
# Lab 05B: unattended install from the ISO into a qcow2 under QEMU TCG (no KVM), UEFI, serial console.
# Usage: bash b-install.sh   (run as a normal user; leaves install.log and disk.qcow2 in $W)
W=${W:-$HOME/lab/05}; mkdir -p $W; cd $W
ISO=${ISO:-/var/tmp/lab04/lab-tcg.iso}
rm -f disk.qcow2; qemu-img create -f qcow2 disk.qcow2 8G
cp /usr/share/edk2/ovmf/OVMF_VARS.fd ./OVMF_VARS.fd
date +%s > install.start
exec nice -n 10 /usr/libexec/qemu-kvm \
  -accel tcg,thread=multi -machine q35 -cpu max -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=$W/OVMF_VARS.fd \
  -drive file=$W/disk.qcow2,if=virtio,format=qcow2 \
  -drive file=$ISO,media=cdrom,readonly=on \
  -nic user,model=virtio-net-pci \
  -display none -serial stdio -monitor none
