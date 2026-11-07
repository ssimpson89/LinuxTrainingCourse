#!/bin/bash
# Run as root in the VM. Prep: hostname + /etc/hosts
set -euxo pipefail
KOJI_FQDN=koji.lab.example
hostnamectl set-hostname $KOJI_FQDN
grep -q "$KOJI_FQDN" /etc/hosts || echo "127.0.0.1 $KOJI_FQDN koji" >> /etc/hosts
dnf install -y epel-release
dnf install -y httpd mod_ssl postgresql-server python3-mod_wsgi \
  koji koji-hub koji-web koji-builder koji-utils mock createrepo_c rpm-build \
  policycoreutils-python-utils
