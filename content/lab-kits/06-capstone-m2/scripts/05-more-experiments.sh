#!/bin/bash
# Step 2 part 2: priorities, releasever detection, the tree's own repo files,
# and the Obsoletes / Conflicts spec variants. Run: sudo -E env M=$M HOME=$HOME bash 05-more-experiments.sh
set -u; . "$(dirname "$0")/env.sh"
DNF="dnf -y --setopt=reposdir=$M/repos.d --releasever=10 --setopt=install_weak_deps=False"
X=/var/tmp/m2-exp
hdr(){ echo; echo "################ $*"; }
newroot(){ rm -rf $X/$1; mkdir -p $X/$1; }

hdr "D2. fresh tree, nothing named, myorg-local priority=10 vs seed priority=99: who provides system-release?"
bash $(dirname "$0")/lab-repos.sh 10 99
newroot D2; $DNF --installroot=$X/D2 install bash setup 2>&1 | grep -E 'Installing.*(rocky|myorg)|Error|Problem' | head
rpm --root $X/D2 -q --whatprovides system-release; head -3 $X/D2/etc/os-release | head -1
echo "(so priority alone decides it; the clean answer is still --exclude plus naming myorg-release)"

hdr "H2. who really requires rocky-release BY NAME (not via a capability rocky-release also provides)"
for p in $(dnf -q --setopt=reposdir=$M/repos.d --releasever=10 repoquery --whatrequires rocky-release --qf '%{name}' 2>/dev/null | sort -u); do
  echo "-- $p: $(dnf -q --setopt=reposdir=$M/repos.d --releasever=10 repoquery --requires $p 2>/dev/null | grep -E 'rocky-release|system-release|redhat-release|/etc/issue.d|os-release' | sort -u | tr '\n' ' ')"; done

hdr "I. the tree from experiment F: does it carry its own repo files, and does dnf inside use them (no reposdir override, no releasever)?"
ls $X/F/etc/yum.repos.d $X/F/etc/dnf/vars
dnf -q --installroot=$X/F repolist 2>&1 | head
echo "-- same, but releasever not given: where does \$releasever come from?"
dnf --installroot=$X/F repoquery --installed myorg-release 2>&1 | tail -1
dnf -q --installroot=$X/F --setopt=cachedir=/var/tmp/m2-exp/F-cache repolist -v 2>&1 | grep -E 'Repo-id|Repo-baseurl|Repo-name' | head -12

hdr "J. spec variants: Obsoletes vs Conflicts (unsigned throwaway repos, gpgcheck=0 ONLY here)"
mkdir -p $M/variants && cd $M/variants && rm -rf obs conf && mkdir obs conf
for v in obs conf; do
  rel=2; [ $v = conf ] && rel=3
  sed -e "s/^Release:        1%{dist}/Release:        $rel%{dist}/" $M/specs/myorg-release.spec > $v/myorg-release.spec
  if [ $v = obs ]; then
    sed -i 's/^Requires:       myorg-repos(%{major})/Requires:       myorg-repos(%{major})\nObsoletes:      rocky-release\nObsoletes:      redhat-release/' $v/myorg-release.spec
    sed -i 's/^Requires:       myorg-gpg-keys = %{version}-%{release}/&\nObsoletes:      rocky-repos/' $v/myorg-release.spec
    sed -i 's/^Summary:        %{distro_name} RPM GPG keys/&\nObsoletes:      rocky-gpg-keys/' $v/myorg-release.spec
  else
    sed -i 's/^Requires:       myorg-repos(%{major})/Requires:       myorg-repos(%{major})\nConflicts:      rocky-release/' $v/myorg-release.spec
  fi
  mkdir -p $v/SOURCES $v/SRPMS; \cp $M/src/myorg-release/* $KEYFILE $SEEDKEY $v/SOURCES/
  rpmbuild -bs --define "_topdir $M/variants/$v" $v/myorg-release.spec >/dev/null 2>&1
  mock -r rocky-10-x86_64 --rebuild $v/SRPMS/*.src.rpm --resultdir=$M/variants/$v/out >/dev/null 2>&1
  mkdir -p $v/repo; \cp $v/out/*.noarch.rpm $v/repo/; createrepo_c -q $v/repo
  echo "variant $v built: $(ls $v/repo | grep release)"
  grep -E '^(Obsoletes|Conflicts)' $v/myorg-release.spec
done
for v in obs conf; do
  hdr "J-$v. Rocky tree + 'dnf install myorg-release' from the $v variant (no swap, no allowerasing)"
  newroot J$v; $DNF --disablerepo=myorg-local --installroot=$X/J$v install bash rocky-release 2>&1 | tail -1
  cat > $M/repos.d/variant.repo <<EOT
[variant]
name=variant
baseurl=file://$M/variants/$v/repo
gpgcheck=0
EOT
  $DNF --disablerepo=myorg-local --installroot=$X/J$v install myorg-release 2>&1 | grep -v -E 'Last metadata|^$' | tail -14
  rpm --root $X/J$v -qa | grep -E 'rocky|myorg' | sort
  echo "-- retry with --allowerasing"
  $DNF --disablerepo=myorg-local --installroot=$X/J$v --allowerasing install myorg-release 2>&1 | grep -E 'Erasing|Removed|rocky|Error|Problem|Complete' | head -8
  rpm --root $X/J$v -qa | grep -E 'rocky|myorg' | sort
  rm -f $M/repos.d/variant.repo
done
chown -R --reference=$M $M/variants $M/repos.d 2>/dev/null || true
