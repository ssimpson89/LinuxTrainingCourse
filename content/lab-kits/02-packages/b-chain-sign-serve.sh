#!/bin/bash
# Lab 02B: two-package chain build, signing, createrepo_c, HTTP serve, consume from a container.
# Run as a user in group mock (not root) on Rocky 10.2 x86_64. Sources in ./src.
set -u
L=${L:-$HOME/lab/02}; cd $L
echo "### 1. build SRPMs"
for p in libgreet greeter; do
  rpmbuild -bs --define "_sourcedir $L/src" $L/src/myorg-$p.spec 2>&1 | tail -1
done
echo "### 2. failure demo: greeter alone"
time mock -r rocky-10-x86_64 --rebuild ~/rpmbuild/SRPMS/myorg-greeter-1.0-1.el10.src.rpm --resultdir=$L/fail 2>&1 | grep -E "No matching|Not all dep|ERROR|Error" | head -5
echo "### 3. chain build"
time mock -r rocky-10-x86_64 --chain --localrepo=$L/repo \
  ~/rpmbuild/SRPMS/myorg-libgreet-1.0-1.el10.src.rpm ~/rpmbuild/SRPMS/myorg-greeter-1.0-1.el10.src.rpm 2>&1 | grep -E "Success building|Packages built|Results"
find $L/repo -name '*.rpm' | sort
echo "### 4. generate key, sign"
export GNUPGHOME=$L/gnupg; mkdir -p -m 700 $GNUPGHOME
time gpg --batch --pinentry-mode loopback --passphrase "" --quick-generate-key "MyOrg Lab Signing <signing@lab.example>" rsa4096 sign never 2>&1 | tail -2
gpg --armor --export "MyOrg Lab Signing" > $L/RPM-GPG-KEY-myorg-lab
gpg --show-keys --with-fingerprint $L/RPM-GPG-KEY-myorg-lab
echo '%_gpg_name MyOrg Lab Signing <signing@lab.example>' > ~/.rpmmacros
mkdir -p $L/web/myorg/10/x86_64
cp $(find $L/repo -name '*.rpm') $L/web/myorg/10/x86_64/; cp $L/RPM-GPG-KEY-myorg-lab $L/web/myorg/
cd $L/web/myorg/10/x86_64
rpm -Kv myorg-greeter-1.0-1.el10.x86_64.rpm | head -8
time rpmsign --addsign *.rpm 2>&1 | tail -3
rpm -Kv myorg-greeter-1.0-1.el10.x86_64.rpm | head -8
time createrepo_c . 2>&1 | tail -3
ls
