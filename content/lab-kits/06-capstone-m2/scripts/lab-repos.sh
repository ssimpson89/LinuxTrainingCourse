#!/bin/bash
# Writes $M/repos.d/lab.repo: the BOOTSTRAP repo definitions used by the host's dnf
# before myorg-repos exists inside the tree (chicken and egg: the tree gets its own
# repo files FROM myorg-repos, but dnf needs some repo to fetch myorg-repos from).
# Usage: lab-repos.sh [local-priority] [seed-priority]
set -eu; . "$(dirname "$0")/env.sh"
LP=${1:-99}; SP=${2:-99}
mkdir -p $M/repos.d
cat > $M/repos.d/lab.repo <<EOT
[seed-baseos]
name=seed BaseOS
baseurl=https://dl.rockylinux.org/pub/rocky/\$releasever/BaseOS/\$basearch/os/
gpgcheck=1
gpgkey=file://$SEEDKEY
priority=$SP
[seed-appstream]
name=seed AppStream
baseurl=https://dl.rockylinux.org/pub/rocky/\$releasever/AppStream/\$basearch/os/
gpgcheck=1
gpgkey=file://$SEEDKEY
priority=$SP
[seed-crb]
name=seed CRB
baseurl=https://dl.rockylinux.org/pub/rocky/\$releasever/CRB/\$basearch/os/
enabled=0
gpgcheck=1
gpgkey=file://$SEEDKEY
priority=$SP
[myorg-local]
name=myorg local
baseurl=http://localhost:$PORT/myorg/\$releasever/\$basearch/
gpgcheck=1
gpgkey=file://$KEYFILE
metadata_expire=1m
priority=$LP
EOT
chown -R --reference=$M $M/repos.d 2>/dev/null || true   # experiments run under sudo; hand the file back to the lab user
