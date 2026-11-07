#!/bin/bash
# 3-way comparison: shipped / rebuilt-pinned / rebuilt-current. Run in the lab dir.
cd ${W:-$HOME/lab/01}
S=which-2.21-44.el10_0.x86_64.rpm
P=results-pinned/which-2.21-44.el10_0.x86_64.rpm
C=results-current/which-2.21-44.el10.x86_64.rpm
rm -rf x; mkdir -p x/s x/p x/c
(cd x/s && rpm2cpio ../../$S | cpio -idm 2>/dev/null)
(cd x/p && rpm2cpio ../../$P | cpio -idm 2>/dev/null)
(cd x/c && rpm2cpio ../../$C | cpio -idm 2>/dev/null)
echo "--- RPM header facts"
for f in $S $P $C; do echo "$f"; rpm -qp --qf '  PAYLOADDIGEST=%{PAYLOADDIGEST}\n  BUILDHOST=%{BUILDHOST}\n  BUILDTIME=%{BUILDTIME:date}\n  SIZE=%{SIZE}\n  SHA256HEADER=%{SHA256HEADER}\n' $f; echo "  file-sha256: $(sha256sum $f | cut -c1-64)"; done
echo "--- /usr/bin/which sha256"
sha256sum x/s/usr/bin/which x/p/usr/bin/which x/c/usr/bin/which
ls -l x/s/usr/bin/which x/p/usr/bin/which x/c/usr/bin/which | awk '{print $5, $9}'
echo "--- build-id"
for d in s p c; do printf '%s ' $d; readelf -n x/$d/usr/bin/which | awk '/Build ID/{print $3}'; done
echo "--- per-file sha256 of payload (all files, then diff vs shipped)"
for d in s p c; do (cd x/$d && find . -type f -o -type l | sort | xargs sha256sum 2>/dev/null > ../$d.sums); done
echo "pinned  vs shipped: $(diff x/s.sums x/p.sums >/dev/null && echo ALL-FILES-IDENTICAL || echo DIFFERENT)"
echo "current vs shipped:"; diff x/s.sums x/c.sums | head
echo "--- rpm --dump comparison (names, sizes, mtimes, digests)"
diff <(rpm -qp --dump $S) <(rpm -qp --dump $P) >/dev/null && echo "pinned dump identical" || echo "pinned dump differs"
diff <(rpm -qp --dump $S) <(rpm -qp --dump $C) | head -6 | cut -c1-200
echo "--- compiler (.comment of debuginfo is not shipped; use the .gnu_debuglink and annobin) "
for d in s p c; do printf '%s ' $d; readelf -p .gnu_debuglink x/$d/usr/bin/which 2>/dev/null | grep -o 'which.*debug' ; done
echo "--- cmp"
cmp x/s/usr/bin/which x/p/usr/bin/which && echo "BINARY-IDENTICAL pinned"
cmp x/s/usr/bin/which x/c/usr/bin/which | head -1
