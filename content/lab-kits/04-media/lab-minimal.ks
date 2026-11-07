# lab-minimal.ks - tiny unattended Rocky 10 install (x86_64 lab, UEFI or BIOS)
# WARNING: wipes every disk it can see. Use in a VM only.
text
reboot --eject
lang en_US.UTF-8
keyboard us
timezone UTC --utc
# Throwaway lab-only root password for a disposable VM. Change it, and never reuse it.
rootpw --plaintext labpass
network --bootproto=dhcp --device=link --activate --hostname=lab-ks
selinux --enforcing
firewall --enabled --ssh
zerombr
clearpart --all --initlabel
autopart --type=plain --nohome
bootloader --timeout=1
url --url=https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/
repo --name=AppStream --baseurl=https://dl.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/

%packages --inst-langs=en
@^minimal-environment
-iwl*-firmware
%end

%post --log=/root/ks-post.log
echo "installed by lab-minimal.ks on $(date -u)" > /etc/motd
%end
