#!/bin/bash
# Run as the normal user (sudo available). Registers builder + kojira, configures and starts kojid, kojira, kojiweb.
set -euxo pipefail
FQDN=koji.lab.example
PKI=/etc/pki/koji
# --- hub-side registration (as kojiadmin)
koji add-user kojira || true
koji grant-permission repo kojira || true
koji add-host $FQDN x86_64 || true
koji add-host-to-channel $FQDN createrepo || true
koji edit-host --capacity=4 $FQDN

# --- trust the lab CA system-wide: mock/dnf fetch the build repo from https://$FQDN/kojifiles
# and use the host trust store (mock copies the host CA bundle into the chroot)
sudo cp $PKI/koji_ca_cert.crt /etc/pki/ca-trust/source/anchors/koji-lab-ca.crt
sudo update-ca-trust

# --- kojid
sudo tee /etc/kojid/kojid.conf >/dev/null <<CONF
[kojid]
sleeptime=15
maxjobs=3
minspace=4096
topdir=/mnt/koji
workdir=/tmp/koji
mockdir=/var/lib/mock
mockuser=kojibuilder
server=https://$FQDN/kojihub
topurl=https://$FQDN/kojifiles
use_createrepo_c=True
cert=/etc/kojid/kojid.pem
serverca=/etc/kojid/koji_ca_cert.crt
CONF

# --- kojira
sudo tee /etc/kojira/kojira.conf >/dev/null <<CONF
[kojira]
server=https://$FQDN/kojihub
topdir=/mnt/koji
logfile=/var/log/kojira.log
cert=/etc/kojira/kojira.pem
serverca=/etc/kojira/koji_ca_cert.crt
CONF

# --- kojiweb
sudo bash -c "cat $PKI/certs/kojiweb.crt $PKI/private/kojiweb.key > $PKI/kojiweb.pem; chown root:apache $PKI/kojiweb.pem; chmod 640 $PKI/kojiweb.pem"
sudo tee /etc/kojiweb/web.conf >/dev/null <<CONF
[web]
SiteName = koji
KojiHubURL = https://$FQDN/kojihub
KojiFilesURL = https://$FQDN/kojifiles
WebCert = $PKI/kojiweb.pem
ClientCA = $PKI/koji_ca_cert.crt
KojiHubCA = $PKI/koji_ca_cert.crt
LoginTimeout = 72
LibPath = /usr/share/koji-web/lib
LiteralFooter = True
CONF
sudo setsebool -P httpd_can_network_connect=1   # kojiweb (inside httpd) must connect to the hub over TCP, even on localhost
sudo systemctl restart httpd
sudo systemctl enable --now kojid kojira
sleep 20
systemctl --no-pager status kojid kojira | grep -E "Active|●"
koji list-hosts
