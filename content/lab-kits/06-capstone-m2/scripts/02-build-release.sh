#!/bin/bash
# M2: build myorg-release (three binary packages) in a STOCK seed buildroot.
# The seed buildroot carries the seed's macros.dist; the spec's own %define dist wins.
set -eu; . "$(dirname "$0")/env.sh"
cd $M
rm -rf rpmbuild result/release; mkdir -p rpmbuild/{SOURCES,SRPMS}
\cp src/myorg-release/* $KEYFILE $SEEDKEY rpmbuild/SOURCES/
t rpmbuild -bs --define "_topdir $M/rpmbuild" specs/myorg-release.spec | tail -1
SRPM=$(ls rpmbuild/SRPMS/myorg-release-*.src.rpm)
rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' $SRPM
t mock -r rocky-10-x86_64 --rebuild $SRPM --resultdir=$M/result/release 2>&1 | grep -E "Wrote:|Finish|ERROR|rror:" | head -20
ls -l $M/result/release/*.rpm
