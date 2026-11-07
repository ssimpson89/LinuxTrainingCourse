#!/bin/bash
# Lab 05C: boot the installed qcow2 to a login prompt (UEFI, serial console, no ISO).
W=${W:-$HOME/lab/05}; cd $W
date +%s > boot.start
exec nice -n 10 /usr/libexec/qemu-kvm \
  -accel tcg,thread=multi -machine q35 -cpu max -smp 4 -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=$W/OVMF_VARS.fd \
  -drive file=$W/disk.qcow2,if=virtio,format=qcow2 \
  -nic user,model=virtio-net-pci \
  -display none -serial stdio -monitor none
