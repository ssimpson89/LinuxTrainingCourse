#!/bin/bash
# Step 2 part 3: what would a swap do to a REAL (booted) Rocky host? Dry run only (--assumeno).
# And: where does $releasever come from inside an installroot that has no release package yet?
set -u; . "$(dirname "$0")/env.sh"
echo "## protected packages on this host (dnf refuses to remove these)"
cat /etc/dnf/protected.d/*.conf | sort -u | tr '\n' ' '; echo
echo; echo "## dry run on the HOST: dnf swap rocky-release myorg-release  (nothing is changed: --assumeno)"
sudo dnf --assumeno --setopt=reposdir=$M/repos.d --releasever=10 swap rocky-release myorg-release 2>&1 | grep -v -E 'Last metadata|^$' | head -40
echo; echo "## releasever inside an empty installroot (no release package inside): host value used?"
sudo rm -rf /var/tmp/m2-exp/empty; sudo mkdir -p /var/tmp/m2-exp/empty
sudo dnf --installroot=/var/tmp/m2-exp/empty --setopt=reposdir=$M/repos.d repolist -v 2>&1 | grep -E 'Repo-baseurl|releasever|Error' | head -4
