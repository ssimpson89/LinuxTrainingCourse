#!/bin/bash
# Step 2: how does a system or a tree replace rocky-release with myorg-release?
# Every experiment uses a throwaway --installroot; the host is never modified.
# Run with: sudo -E bash 04-conflict-experiments.sh   (needs root for installroot)
set -u; . "$(dirname "$0")/env.sh"
bash $(dirname "$0")/lab-repos.sh 99 99
DNF="dnf -y --setopt=reposdir=$M/repos.d --releasever=10 --setopt=install_weak_deps=False"
X=/var/tmp/m2-exp
hdr(){ echo; echo "################ $*"; }
newroot(){ rm -rf $X/$1; mkdir -p $X/$1; }

hdr "A. Rocky tree first, then plain 'install myorg-release' (expect file conflicts)"
newroot A; $DNF --installroot=$X/A install bash rocky-release 2>&1 | tail -3
rpm --root $X/A -qa | grep -E 'rocky|myorg'
$DNF --installroot=$X/A install myorg-release 2>&1 | grep -v -E '^(Last metadata|Dependencies resolved)' | tail -25

hdr "B. same tree: dnf swap rocky-release myorg-release"
$DNF --installroot=$X/A swap rocky-release myorg-release 2>&1 | grep -v -E '^(Last metadata)' | tail -25

hdr "C. same tree: swap with --allowerasing"
$DNF --installroot=$X/A --allowerasing swap rocky-release myorg-release 2>&1 | grep -v -E '^(Last metadata)' | tail -30
rpm --root $X/A -qa | grep -E 'rocky|myorg'; cat $X/A/etc/os-release | head -4

hdr "D. fresh tree, nothing named: who provides system-release when both repos offer a provider (equal priority)?"
newroot D; $DNF --installroot=$X/D install bash setup 2>&1 | grep -E 'Installing|rocky|myorg|Error|Problem' | head -20
rpm --root $X/D -q --whatprovides system-release; head -2 $X/D/etc/os-release

hdr "E. fresh tree, equal priority, install myorg-release AND ask for setup: any ambiguity?"
newroot E; $DNF --installroot=$X/E install bash setup myorg-release 2>&1 | grep -E 'rocky|myorg|Error|Problem' | head
rpm --root $X/E -qa | grep -E 'rocky|myorg'

hdr "F. fresh tree with --exclude='rocky-*' (the recommended way)"
newroot F; $DNF --installroot=$X/F --exclude='rocky-*' install bash coreutils setup myorg-release 2>&1 | grep -E 'rocky|myorg|Error|Problem|Complete' | head
rpm --root $X/F -qa | grep -E 'rocky|myorg'; rpm --root $X/F -q --whatprovides system-release

hdr "G. what 'rocky-*' would exclude from the seed (names only)"
dnf -q --setopt=reposdir=$M/repos.d --releasever=10 --enablerepo=seed-crb repoquery --available 'rocky-*' --qf '%{name}' 2>/dev/null | sort -u

hdr "H. what in the seed BaseOS/AppStream requires system-release / redhat-release / rocky-release by name (the real dependency surface)"
for p in system-release redhat-release rocky-release 'system-release(releasever)' system-logos system-repos; do echo "-- whatrequires $p"; dnf -q --setopt=reposdir=$M/repos.d --releasever=10 repoquery --whatrequires "$p" --qf '%{name}' 2>/dev/null | sort -u | head -8; done
