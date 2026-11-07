#!/bin/bash
# Lab 01: exact reproduction of Rocky's `which` build. Run as a user in group mock.
# Prereqs: Rocky 10.2 x86_64 VM, EPEL enabled, mock rpmdevtools dnf-plugins-core installed,
#          ~/mockcfg/rocky-10.0-vault-x86_64.cfg present (see this directory).
set -eu
W=${W:-$HOME/lab/01}; CFG=${CFG:-$HOME/mockcfg/rocky-10.0-vault-x86_64.cfg}
mkdir -p $W && cd $W
echo "== fetch shipped binary RPM and SRPM"
dnf download --source which --enablerepo=baseos-source --enablerepo=appstream-source
dnf download which --arch x86_64
rpm -K which-2.21-44.el10_0.src.rpm
echo "== Run A: current buildroot (stock config)"
time mock -r rocky-10-x86_64 --rebuild which-2.21-44.el10_0.src.rpm --resultdir=$W/results-current
echo "== Run B: pinned 10.0 vault buildroot + point-release dist tag"
time mock -r $CFG --define 'dist .el10_0' --rebuild which-2.21-44.el10_0.src.rpm --resultdir=$W/results-pinned
