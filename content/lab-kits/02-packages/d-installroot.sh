#!/bin/bash
# Lab 02D: minimal OS tree with --installroot, inspect with rpm --root and chroot, kernel/initramfs, podman import round trip.
# Run as root (sudo bash d-installroot.sh) on Rocky 10.2 x86_64. Needs podman.
set -u
R=/var/tmp/lab-root; rm -rf $R; mkdir -p $R
echo "### 1. minimal tree"
time dnf -y --installroot=$R --releasever=10 --setopt=install_weak_deps=False install bash coreutils rpm dnf rootfiles rocky-release 2>&1 | tail -4
dnf --installroot=$R clean all >/dev/null 2>&1
du -sh $R; rpm --root $R -qa | wc -l
echo "### 2. rpm --root"
rpm --root $R -qa | sort | head -3
rpm --root $R -qf /bin/bash
rpm --root $R -V bash && echo VERIFY-OK
echo "### 3. chroot"
chroot $R /bin/bash -c 'head -3 /etc/os-release; rpm -qa | wc -l; uname -m; dnf --version | head -1; ls /dev | wc -l; ls /boot | wc -l'
echo "### 4. kernel + initramfs in the tree"
time dnf -y --installroot=$R --releasever=10 --setopt=install_weak_deps=False install kernel-core dracut 2>&1 | tail -3
ls -l $R/boot
KV=$(ls $R/lib/modules | head -1); echo KV=$KV
ls -lh $R/boot/initramfs-$KV.img 2>&1
chroot $R lsinitrd /boot/initramfs-$KV.img 2>&1 | head -12
du -sh $R
echo "### 5. podman import round trip (the tree now includes kernel-core, so the image is larger than the official ones)"
tar --numeric-owner --xattrs -C $R -cf /var/tmp/lab-root.tar .
ls -lh /var/tmp/lab-root.tar; gzip -k -1 -f /var/tmp/lab-root.tar; ls -lh /var/tmp/lab-root.tar.gz
podman import --change 'CMD ["/bin/bash"]' --message "installroot lab" /var/tmp/lab-root.tar.gz localhost/rocky-lab-base:10
podman images localhost/rocky-lab-base
podman run --rm localhost/rocky-lab-base:10 bash -c 'head -2 /etc/os-release; rpm -qa | wc -l; dnf -q install -y which; which which'
echo "### 6. compare official images"
podman pull -q quay.io/rockylinux/rockylinux:10 >/dev/null; podman pull -q quay.io/rockylinux/rockylinux:10-minimal >/dev/null
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}'
