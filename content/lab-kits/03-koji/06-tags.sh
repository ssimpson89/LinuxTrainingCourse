#!/bin/bash
# Run as the normal user. Tags, target, external repos, groups, package ownership.
set -euxo pipefail
koji add-tag mylab-dest
koji add-tag --parent mylab-dest --arches x86_64 mylab-build
koji add-target mylab mylab-build mylab-dest
koji add-external-repo -t mylab-build -p 10 rocky10-baseos   'https://dl.rockylinux.org/pub/rocky/10/BaseOS/$arch/os/'
koji add-external-repo -t mylab-build -p 20 rocky10-appstream 'https://dl.rockylinux.org/pub/rocky/10/AppStream/$arch/os/'
koji add-external-repo -t mylab-build -p 30 rocky10-crb       'https://dl.rockylinux.org/pub/rocky/10/CRB/$arch/os/'
koji add-group mylab-build build
koji add-group mylab-build srpm-build
koji add-group-pkg mylab-build build bash bzip2 coreutils cpio diffutils findutils gawk glibc-minimal-langpack grep gzip info patch redhat-rpm-config rocky-release rpm-build sed tar unzip util-linux which xz
koji add-group-pkg mylab-build srpm-build bash gnupg2 rpm-build redhat-rpm-config shadow-utils
koji add-pkg --owner kojiadmin mylab-dest which hello
koji list-tag-inheritance mylab-build
koji list-targets
koji list-external-repos --tag mylab-build
koji taginfo mylab-build
# Optional: skip mock's bootstrap chroot (mock 6.x enables it by default). Tag config is frozen at repo creation, so regen after.
koji edit-tag -x mock.use_bootstrap=False mylab-build
koji regen-repo mylab-build --wait || true
