#!/bin/bash
# M4/M5/M6: publish everything into the signed repo, build an installroot whose
# identity is MyOrg, import it as an image, run it. Run as the lab user (uses sudo).
set -eu; . "$(dirname "$0")/env.sh"
cd $M
echo "### publish: sign + createrepo_c + serve (binaries and SRPMs, no debuginfo)"
FILES="result/release/*.rpm result/which/*.rpm $(find repo-local -name '*.rpm')"
LIST=$(ls $FILES | grep -v -E 'debuginfo|debugsource' | sort -u)
bash scripts/03-sign-publish.sh $LIST
echo
echo "### lab repo definitions for the HOST dnf (bootstrap only; the tree gets its own from myorg-repos)"
bash scripts/lab-repos.sh 10 99
cat $M/repos.d/lab.repo | grep -E '^\[|priority|baseurl'
echo
echo "### build the tree: seed repos + signed MyOrg repo, gpgcheck=1, rocky-* excluded"
sudo rm -rf $TREE; sudo mkdir -p $TREE
t sudo dnf -y --installroot=$TREE --releasever=10 --setopt=reposdir=$M/repos.d --exclude='rocky-*' \
  --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
  install bash coreutils dnf rpm rootfiles which myorg-release myorg-repos myorg-gpg-keys myorg-greeter 2>&1 \
  | grep -E 'Install|Importing|Fingerprint|Userid|Key imported|Complete|Error|Problem|Total download' | head -30
sudo dnf --installroot=$TREE clean all >/dev/null 2>&1 || true
sudo rm -rf $TREE/var/cache/dnf
echo; echo "### the identity of the tree"
echo '$ cat /etc/os-release'; cat $TREE/etc/os-release
echo '$ rpm -q --whatprovides system-release'; sudo rpm --root $TREE -q --whatprovides system-release
echo '$ rpm -qa | grep -E "myorg|rocky"'; sudo rpm --root $TREE -qa | grep -E 'myorg|rocky' | sort
echo '$ rpm -qa | grep -c rocky   (the seed identity packages must be absent)'; sudo rpm --root $TREE -qa | grep -c rocky || true
echo '$ ls -l /etc/*release /etc/os-release'; ls -l $TREE/etc/*release $TREE/etc/os-release | awk '{print $1,$9,$10,$11}'
echo '$ dnf --installroot repolist  (reads the TREE'"'"'s own /etc/yum.repos.d)'; sudo dnf -q --installroot=$TREE repolist 2>&1
echo '$ rpm -Kv on the MyOrg packages, against the keyring INSIDE the tree'
sudo rpm --root $TREE -qa 'gpg-pubkey*' --qf '%{NAME}-%{VERSION} %{SUMMARY}\n'
for p in $REPO/myorg-release-*.rpm $REPO/which-*.rpm; do sudo rpm --root $TREE -Kv $p; done
echo
echo "### image: tar, podman import, run"
t sudo tar --numeric-owner --xattrs -C $TREE -cf $M/myorg-root.tar .
ls -lh $M/myorg-root.tar | awk '{print $5, $9}'
sudo podman rmi -f $IMG >/dev/null 2>&1 || true
t sudo podman import --change 'CMD ["/bin/bash"]' --message "myorg lab tree" $M/myorg-root.tar $IMG 2>&1 | tail -1
sudo podman images localhost/myorg-base --format '{{.Repository}}:{{.Tag}} {{.Size}}'
echo '$ podman run --rm $IMG cat /etc/os-release'
sudo podman run --rm $IMG cat /etc/os-release
echo '$ podman run ... rpm -q myorg-release which myorg-greeter; which which; greeter'
sudo podman run --rm $IMG bash -c 'rpm -q myorg-release which myorg-greeter; which which; greeter'
echo '$ podman run --network=host ... dnf repolist  (container reaches the host repo through the tree'"'"'s own repo file)'
sudo podman run --rm --network=host $IMG dnf -q repolist
sudo podman run --rm --network=host $IMG dnf -q repoquery --repo=myorg 'myorg-*' 2>&1 | head -8
