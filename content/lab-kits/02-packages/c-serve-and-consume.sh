#!/bin/bash
# Lab 02C: serve the repo over HTTP and consume it from a second environment (rootful podman container).
# Run after b-chain-sign-serve.sh. Needs sudo for podman (rootful bridge network); host is 10.88.0.1 from the container.
L=${L:-$HOME/lab/02}
cd $L/web && (python3 -m http.server 8080 --bind 0.0.0.0 > $L/http.log 2>&1 & echo $! > $L/http.pid)
sleep 1; curl -sI http://127.0.0.1:8080/myorg/10/x86_64/repodata/repomd.xml | head -1
HOST=10.88.0.1
sudo podman rm -f consumer >/dev/null 2>&1
sudo podman run -d --name consumer quay.io/rockylinux/rockylinux:10 sleep 3600 >/dev/null
echo "### A. repo WITHOUT gpgkey= (gpgcheck=1): expect NOKEY failure"
sudo podman exec consumer bash -c "cat > /etc/yum.repos.d/myorg-lab.repo <<R
[myorg-lab]
name=MyOrg lab
baseurl=http://$HOST:8080/myorg/10/\\\$basearch/
enabled=1
gpgcheck=1
R
dnf -y install myorg-greeter 2>&1 | tail -12
"
echo "### A2. rpm -K from outside the repo (download only)"
sudo podman exec consumer bash -c "dnf -y -q install dnf-plugins-core; dnf -y download myorg-greeter --destdir=/tmp/dl --nogpgcheck 2>&1 | tail -2; rpm -K /tmp/dl/myorg-greeter*.rpm; rpm -Kv /tmp/dl/myorg-greeter*.rpm | head -3; rpm -q gpg-pubkey"
echo "### B. repo WITH gpgkey=, no tty, no -y: dnf stops at the confirmation prompt (key not imported yet)"
sudo podman exec consumer bash -c "echo 'gpgkey=http://$HOST:8080/myorg/RPM-GPG-KEY-myorg-lab' >> /etc/yum.repos.d/myorg-lab.repo; dnf install myorg-greeter </dev/null 2>&1 | tail -8"
echo "### C. with -y (imports key and installs)"
sudo podman exec consumer bash -c "dnf -y install myorg-greeter 2>&1 | tail -25; greeter; rpm -q --qf '%{NAME} %{RSAHEADER:pgpsig}\n' myorg-greeter myorg-libgreet; rpm -qa gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n'"
