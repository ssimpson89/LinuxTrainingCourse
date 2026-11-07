#!/bin/bash
# M0 + M3: show the seed config, then rebuild which, and a library+consumer pair,
# with the .myorg dist tag. Two ways of getting the tag are compared on `which`.
set -eu; . "$(dirname "$0")/env.sh"
CFG=$M/mock/myorg-10-x86_64.cfg
cd $M; mkdir -p result
echo "### M0: buildroot of the MyOrg config (mock --shell). seed repos + our repo, identity from myorg-release"
t mock -r $CFG --init 2>&1 | tail -1
mock -r $CFG --shell 'cat /etc/os-release | head -4; echo; rpm -qa | grep -E "myorg|rocky" | sort; echo; rpm -E "dist=%{dist} rhel=%{rhel} myorg=%{?myorg} el10=%{?el10}"; rpm -q --whatprovides system-release' 2>&1 | grep -v -E "^(Start|Finish|<mock)" 
echo
echo "### Option A for the dist tag: seed's stock buildroot + --define 'dist .myorg' (identity of buildroot stays Rocky)"
rm -rf result/which-defineA
t mock -r rocky-10-x86_64 --define 'dist .myorg' --rebuild srpms/which-2.21-44.el10_0.src.rpm --resultdir=result/which-defineA 2>&1 | grep -E "\[time\]|ERROR"
ls result/which-defineA/*.rpm | sed 's|.*/||'
echo
echo "### Option B for the dist tag: MyOrg buildroot, macros.dist from myorg-release, no --define"
rm -rf result/which
t mock -r $CFG --rebuild srpms/which-2.21-44.el10_0.src.rpm --resultdir=result/which 2>&1 | grep -E "\[time\]|ERROR"
ls result/which/*.rpm | sed 's|.*/||'
echo "--- A and B compared (same payload digest means the two ways of setting the tag build the same bytes):"
for d in which-defineA which; do rpm -qp --qf "$d: %{NVRA} payload=%{PAYLOADDIGEST}\n" result/$d/which-2.21-44.myorg.x86_64.rpm; done
echo
echo "### pair: library + consumer, SRPMs built with the same dist tag, chained"
rm -rf rpmbuild-pair; mkdir -p rpmbuild-pair/{SOURCES,SRPMS}; \cp src/pair/*.tar.gz rpmbuild-pair/SOURCES/
for p in libgreet greeter; do rpmbuild -bs --define "_topdir $M/rpmbuild-pair" --define 'dist .myorg' src/pair/myorg-$p.spec 2>&1 | grep Wrote | sed 's|.*/||'; done
echo "--- greeter alone fails (its BuildRequires is in the library, which is not in any repo yet):"
mock -r $CFG --rebuild rpmbuild-pair/SRPMS/myorg-greeter-1.0-1.myorg.src.rpm --resultdir=result/greeter-fail 2>&1 | grep -E "No matching|Not all dep|ERROR" | head -3 || true
rm -rf result/pair repo-local
t mock -r $CFG --chain --localrepo=$M/repo-local rpmbuild-pair/SRPMS/myorg-libgreet-1.0-1.myorg.src.rpm rpmbuild-pair/SRPMS/myorg-greeter-1.0-1.myorg.src.rpm 2>&1 | grep -E "\[time\]|Success building|Packages built|ERROR|failed"
find repo-local -name '*.rpm' | sort | sed 's|.*/||'
