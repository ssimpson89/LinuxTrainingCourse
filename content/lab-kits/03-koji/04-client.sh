#!/bin/bash
# Run as the normal (non-root) user in the VM: user client config for kojiadmin
set -euxo pipefail
mkdir -p ~/.koji/config.d
sudo install -m 600 -o $USER -g $(id -gn) /etc/pki/koji/kojiadmin.pem ~/.koji/kojiadmin.pem
sudo install -m 644 -o $USER -g $(id -gn) /etc/pki/koji/koji_ca_cert.crt ~/.koji/serverca.crt
# NOTE: /etc/koji.conf ships authtype=kerberos; the authtype=ssl line below is required. No inline comments in koji ini files.
cat > ~/.koji/config.d/lab.conf <<CONF
[koji]
server = https://koji.lab.example/kojihub
weburl = https://koji.lab.example/koji
topurl = https://koji.lab.example/kojifiles
topdir = /mnt/koji
cert = $HOME/.koji/kojiadmin.pem
serverca = $HOME/.koji/serverca.crt
authtype = ssl
CONF
koji moshimoshi
koji call getLoggedInUser
koji hello
