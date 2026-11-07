# lab-tcg.ks - smallest practical unattended Rocky 10 x86_64 install, for slow (TCG) emulation.
# Serial console only, powers off when done. WARNING: wipes every disk it sees. Use in a VM only.
text
poweroff
lang en_US.UTF-8
keyboard us
timezone UTC --utc
# Throwaway lab-only root password for a disposable VM. Change it, and never reuse it.
rootpw --plaintext labpass
network --bootproto=dhcp --device=link --activate --hostname=lab-tcg
selinux --enforcing
firewall --disabled
services --disabled=firewalld
zerombr
clearpart --all --initlabel
autopart --type=plain --nohome
bootloader --timeout=1 --append="console=ttyS0,115200n8"
url --url=https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/
repo --name=AppStream --baseurl=https://dl.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/

%packages --nocore --inst-langs=en --exclude-weakdeps
bash
coreutils
rocky-release
systemd
kernel
dnf
passwd
openssh-server
-iwl*-firmware
%end

%post --log=/root/ks-post.log
echo "installed by lab-tcg.ks on $(date -u)" > /etc/motd
%end
