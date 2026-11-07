#!/bin/bash
# Run as normal user: build the hello-world SRPM (made by 07) through Koji.
set -euxo pipefail
T=$(koji build mylab ~/rpmbuild/SRPMS/hello-1.0-1.el10.src.rpm --nowait | awk '/Created task/{print $3}')
koji watch-task $T
koji list-builds --package=hello
