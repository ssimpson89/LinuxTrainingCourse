#!/bin/bash
# Run as normal user: the observation commands the course shows (outputs saved by the caller).
set -x
koji list-builds --package=which
koji buildinfo which-2.21-44.el10
koji list-tagged mylab-dest
koji list-tasks --all --after=2000-01-01 2>/dev/null | head -20 || koji list-tasks
koji taskinfo -v $(koji list-tasks --all --after=2000-01-01 --quiet 2>/dev/null | awk '$0 ~ /build \(mylab/ {print $1}' | tail -1)
koji list-tag-inheritance mylab-build
koji list-targets
koji list-external-repos --tag mylab-build
koji list-hosts
koji taginfo mylab-build | head -30
koji call getRepo mylab-build
ls /mnt/koji/repos/mylab-build/
ls /mnt/koji/packages/which/2.21/44.el10/ /mnt/koji/packages/which/2.21/44.el10/x86_64 /mnt/koji/packages/which/2.21/44.el10/data/logs/x86_64
tail -5 /mnt/koji/packages/which/2.21/44.el10/data/logs/x86_64/build.log
grep -E "Transaction Summary|Install +[0-9]+ Packages" /mnt/koji/packages/which/2.21/44.el10/data/logs/x86_64/root.log | head
tail -8 /var/log/kojira.log
rpm -qp --qf 'NVR=%{NVRA} buildhost=%{BUILDHOST} vendor=%{VENDOR} packager=%{PACKAGER} sig=%{RSAHEADER:pgpsig}\n' /mnt/koji/packages/which/2.21/44.el10/x86_64/which-2.21-44.el10.x86_64.rpm
rpm -qp --qf 'PAYLOADDIGEST=%{PAYLOADDIGEST}\n' /mnt/koji/packages/which/2.21/44.el10/x86_64/which-2.21-44.el10.x86_64.rpm
sudo du -sh /mnt/koji /var/lib/mock /var/cache/mock /var/lib/pgsql 2>/dev/null
free -m | sed -n 2p; df -h / | tail -1
