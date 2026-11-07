#!/bin/bash
# Run as normal user: fetch `which` SRPM from Rocky 10, scratch build then real build; show results.
set -euxo pipefail
mkdir -p ~/srpms && cd ~/srpms
curl -sO https://dl.rockylinux.org/pub/rocky/10/BaseOS/source/tree/Packages/w/which-2.21-44.el10_0.src.rpm
# NOTE: `koji build` returns immediately when stdin is not a tty (as in scripts); follow with watch-task.
T=$(koji build --scratch mylab ~/srpms/which-2.21-44.el10_0.src.rpm --nowait | awk '/Created task/{print $3}')
koji watch-task $T
T=$(koji build mylab ~/srpms/which-2.21-44.el10_0.src.rpm --nowait | awk '/Created task/{print $3}')
koji watch-task $T
koji list-builds --package=which
koji buildinfo which-2.21-44.el10
koji list-tagged mylab-dest
