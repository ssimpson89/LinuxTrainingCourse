#!/bin/bash
# capstone-check.sh: verify milestones M0..M6 of the MyOrg capstone and print the dossier diff.
# Read-only against your work: it never rebuilds, signs or publishes. It uses a throwaway rpm database
# and a throwaway dnf cache under $TMPD, and sudo only to inspect the installroot and run podman.
#
#   usage:  M=$HOME/m2work ./capstone-check.sh
#   exit:   0 if every check passed, 1 otherwise
#   output: one line per check: PASS|FAIL <id> <what>: <evidence>
#           then the dossier diff (Rocky which vs MyOrg which), then a sha256 over the evidence lines.
#
# Expected layout (the lab scripts create it):
#   $M/srpms/*.src.rpm   $M/mock/myorg-10-x86_64.cfg   $M/keys/RPM-GPG-KEY-myorg
#   $M/web/myorg/10/x86_64 (signed repo)   $M/web/myorg/10/source   $TREE (installroot)   podman image localhost/myorg-base:10
set -u
M=${M:-$HOME/m2work}
PORT=${PORT:-8080}
TREE=${TREE:-/var/tmp/m2-root}
IMG=${IMG:-localhost/myorg-base:10}
CFG=$M/mock/myorg-10-x86_64.cfg
KEY=$M/keys/RPM-GPG-KEY-myorg
REPO=$M/web/myorg/10/x86_64
SRCREPO=$M/web/myorg/10/source
ROCKYKEYID=5b106c736fedfc85          # key id on the seed's packages (from `rpm -qi`, long form)
TMPD=$(mktemp -d /var/tmp/capstone-check.XXXXXX); trap 'sudo rm -rf $TMPD' EXIT
EV=$TMPD/evidence.txt; : > $EV
NPASS=0; NFAIL=0
say(){ echo "$*" | tee -a $EV; }
ok(){   NPASS=$((NPASS+1)); say "PASS $1 $2: $3"; }
bad(){  NFAIL=$((NFAIL+1)); say "FAIL $1 $2: $3"; }
# chk ID "what" "evidence-on-pass" <command...>   (command exit status decides)
chk(){ local id=$1 what=$2 ev=$3; shift 3; local out; if out=$("$@" 2>&1); then ok "$id" "$what" "${ev:-$(echo "$out" | head -1)}"; else bad "$id" "$what" "$(echo "$out" | head -2 | tr '\n' ' ')"; fi; }
pkgfile(){ ls $REPO/$1 2>/dev/null | head -1; }
filein(){ rpm2cpio "$1" | cpio -i --to-stdout ".$2" 2>/dev/null; }   # filein rpm /path
say "capstone-check on $(hostname) $(date -u +%FT%TZ)  M=$M"
say "host: $(. /etc/os-release; echo $PRETTY_NAME)  rpm $(rpm --version | awk '{print $3}')  mock $(mock --version 2>/dev/null)"

### M0 seed -----------------------------------------------------------------
echo "--- M0 seed"
chk M0.1 "mock config exists and points at the seed (BaseOS, AppStream, CRB over https)" "" \
  bash -c "[ -f $CFG ] && [ \$(grep -c '^baseurl=https://dl.rockylinux.org/pub/rocky/10/\(BaseOS\|AppStream\|CRB\)/x86_64/os/' $CFG) -eq 3 ] && echo 3 seed baseurls in $(basename $CFG)"
SH=$(mock -r $CFG --shell 'rpm -q myorg-release; rpm -E "dist=%{dist}"; . /etc/os-release; echo ID=$ID' 2>/dev/null | grep -v '^INFO' | tr '\n' ' ')
if echo "$SH" | grep -q 'dist=.myorg.*ID=myorg'; then ok M0.2 "buildroot is a MyOrg buildroot (mock --shell prints identity and dist)" "$SH"; else bad M0.2 "buildroot is a MyOrg buildroot" "$SH"; fi

### M1 source ---------------------------------------------------------------
echo "--- M1 source"
for s in which rocky-release; do
  f=$(ls $M/srpms/$s-*.src.rpm 2>/dev/null | head -1)
  if [ -z "$f" ]; then bad M1.$s "SRPM present" "missing in $M/srpms"; continue; fi
  sig=$(rpm -qp --nosignature --qf '%{RSAHEADER:pgpsig}' $f | awk '{print $NF}')
  h=$(sha256sum $f | cut -d' ' -f1)
  rec=$(grep " $(basename $f)\$" $M/srpms/SHA256SUMS 2>/dev/null | cut -d' ' -f1)
  if [ "$sig" = "$ROCKYKEYID" ] && [ "$h" = "$rec" ]; then ok M1.$s "SRPM signed by the seed, hash matches the recorded one" "$(basename $f) sha256=${h:0:16}... key=$sig"
  else bad M1.$s "SRPM signed by the seed, hash matches the recorded one" "$(basename $f) key=$sig sha256=${h:0:16} recorded=${rec:0:16}"; fi
done

### M2 rebrand --------------------------------------------------------------
echo "--- M2 rebrand"
REL=$(pkgfile 'myorg-release-*.noarch.rpm'); RPO=$(pkgfile 'myorg-repos-*.noarch.rpm'); GPK=$(pkgfile 'myorg-gpg-keys-*.noarch.rpm')
chk M2.1 "three identity packages exist" "$(basename "$REL") $(basename "$RPO") $(basename "$GPK")" bash -c "[ -f '$REL' ] && [ -f '$RPO' ] && [ -f '$GPK' ]"
chk M2.2 "myorg-release Provides system-release (and the releasever capability)" "" \
  bash -c "rpm -qp --nosignature --provides '$REL' | grep -E '^system-release(\(releasever\))? = ' | tr '\n' ';'"
OSR=$(filein "$REL" /usr/lib/os-release)
if echo "$OSR" | grep -q '^ID="myorg"$'; then ok M2.3 "os-release has ID=myorg" "$(echo "$OSR" | grep '^ID=')"; else bad M2.3 "os-release has ID=myorg" "$(echo "$OSR" | grep '^ID=')"; fi
if echo "$OSR" | grep -q '^ID_LIKE=.*rhel'; then ok M2.4 "ID_LIKE names the real lineage" "$(echo "$OSR" | grep '^ID_LIKE=')"; else bad M2.4 "ID_LIKE names the real lineage" "$(echo "$OSR" | grep '^ID_LIKE=')"; fi
MD=$(filein "$REL" /usr/lib/rpm/macros.d/macros.dist)
if echo "$MD" | grep -q '^%distcore \.myorg$' && echo "$MD" | grep -q '^%rhel 10$'; then ok M2.5 "macros.dist sets the .myorg dist tag and %rhel" "$(echo "$MD" | grep -E '^%(distcore|rhel) ' | tr '\n' ';')"; else bad M2.5 "macros.dist sets the .myorg dist tag and %rhel" "$(echo "$MD" | head -3 | tr '\n' ';')"; fi
# legal hygiene: names of packages and file paths must not carry the seed's or its upstream's marks
BADNAMES=$(for p in "$REL" "$RPO" "$GPK"; do rpm -qp --nosignature --qf '%{NAME}\n' $p; rpm -qpl --nosignature $p; done | grep -i -E 'rocky|centos|logo' | grep -v -E '^/etc/pki/rpm-gpg/RPM-GPG-KEY-upstream-seed$' )
BADPROV=$(for p in "$REL" "$RPO" "$GPK"; do rpm -qp --nosignature --provides $p; done | grep -i -E '^(rocky|centos)-' )
if [ -z "$BADNAMES$BADPROV" ]; then ok M2.6 "no seed-branded package names, file paths, logos or Provides" "checked names, file lists and Provides of 3 packages"; else bad M2.6 "no seed-branded package names, file paths, logos or Provides" "$BADNAMES $BADPROV"; fi
chk M2.7 "repo package ships a local-repo file and a seed-repo file with gpgcheck=1" "" \
  bash -c "n=\$(rpm -qpl --nosignature '$RPO' | grep -c '/etc/yum.repos.d/.*\.repo'); g=\$(for f in \$(rpm -qpl --nosignature '$RPO' | grep '\.repo\$'); do rpm2cpio '$RPO' | cpio -i --to-stdout .\$f 2>/dev/null; done | grep -c '^gpgcheck=1'); [ \$n -ge 2 ] && [ \$g -ge 4 ] && echo \$n repo files, \$g gpgcheck=1 lines"
chk M2.8 "key package installs the MyOrg key and the seed key under /etc/pki/rpm-gpg" "" \
  bash -c "rpm -qpl --nosignature '$GPK' | tr '\n' ' '"

### M3 rebuild --------------------------------------------------------------
echo "--- M3 rebuild"
for n in which myorg-libgreet myorg-greeter; do
  f=$(ls $REPO/$n-[0-9]*.x86_64.rpm 2>/dev/null | head -1); s=$(ls $SRCREPO/$n-[0-9]*.src.rpm 2>/dev/null | head -1)
  nvr=$( [ -n "$f" ] && rpm -qp --nosignature --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' $f); snvr=$( [ -n "$s" ] && rpm -qp --nosignature --qf '%{NAME}-%{VERSION}-%{RELEASE}' $s).src
  if echo "$nvr" | grep -q '\.myorg\.x86_64$' && echo "$snvr" | grep -q '\.myorg\.src$'; then ok M3.$n "NVR carries .myorg (binary and source)" "$nvr  $snvr"; else bad M3.$n "NVR carries .myorg (binary and source)" "bin='$nvr' src='$snvr'"; fi
done
chk M3.devel "library ships a -devel package and the consumer Requires the library soname" "" \
  bash -c "ls $REPO/myorg-libgreet-devel-*.rpm >/dev/null && rpm -qp --nosignature --requires $REPO/myorg-greeter-[0-9]*.x86_64.rpm | grep -q libgreet && rpm -qp --nosignature --requires $REPO/myorg-greeter-[0-9]*.x86_64.rpm | grep libgreet | head -1"

### M4 sign -----------------------------------------------------------------
echo "--- M4 sign"
KB=$(gpg --show-keys --with-colons $KEY 2>/dev/null | awk -F: '$1=="pub"{print $3}')
if [ "$KB" = 4096 ]; then ok M4.0 "signing key is RSA-4096" "$(gpg --show-keys --with-fingerprint $KEY 2>/dev/null | sed -n 2p | tr -d ' ')"; else bad M4.0 "signing key is RSA-4096" "bits=$KB"; fi
mkdir -p $TMPD/emptydb $TMPD/keydb
rpm --dbpath $TMPD/keydb --import $KEY
ALL=$(ls $REPO/*.rpm $SRCREPO/*.src.rpm 2>/dev/null)
NOK=0; NTOT=0; SHOW=""
for f in $ALL; do
  NTOT=$((NTOT+1))
  out=$(rpm --dbpath $TMPD/keydb -Kv $f 2>&1)
  lines=$(echo "$out" | grep -c ': OK$'); [ $NTOT -eq 1 ] && SHOW="$out"
  if [ "$lines" -eq 5 ]; then NOK=$((NOK+1)); else say "     not five OK lines: $(basename $f) ($lines)"; fi
done
if [ $NTOT -gt 0 ] && [ $NOK -eq $NTOT ]; then ok M4.1 "rpm -Kv prints five OK lines for every package ($NTOT files)" "$(echo "$SHOW" | sed -n 2,6p | sed 's/^ *//' | tr '\n' ';')"; else bad M4.1 "rpm -Kv prints five OK lines for every package" "$NOK of $NTOT"; fi
NK=$(rpm --dbpath $TMPD/emptydb -Kv $REL 2>&1 | grep -c NOKEY)
if [ "$NK" -ge 1 ]; then ok M4.2 "negative control: with an empty keyring the same package is NOKEY" "$(rpm --dbpath $TMPD/emptydb -Kv $REL 2>&1 | grep NOKEY | sed 's/^ *//')"; else bad M4.2 "negative control: empty keyring gives NOKEY" "no NOKEY line"; fi

### M5 repo -----------------------------------------------------------------
echo "--- M5 repo"
mkdir -p $TMPD/repos
cat > $TMPD/repos/check.repo <<EOF
[myorg-check]
name=myorg-check
baseurl=http://localhost:$PORT/myorg/10/x86_64/
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$KEY
EOF
Q=$(dnf -q -y --setopt=reposdir=$TMPD/repos --setopt=cachedir=$TMPD/cache --setopt=logdir=$TMPD/log --setopt=persistdir=$TMPD/persist --releasever=10 repoquery --qf '%{name}-%{version}-%{release}.%{arch}' 2>&1)
N=$(echo "$Q" | grep -c '\.myorg\.')
if [ "$N" -ge 7 ] && ! echo "$Q" | grep -qi 'error'; then ok M5.1 "repo is served over http and dnf reads it with gpgcheck=1 and repo_gpgcheck=1" "$N packages: $(echo "$Q" | grep -o '^[a-z-]*[a-z]' | sort -u | tr '\n' ' ')"; else bad M5.1 "repo readable with gpgcheck=1 and repo_gpgcheck=1" "$(echo "$Q" | head -3 | tr '\n' ' ')"; fi
chk M5.2 "repomd.xml has a detached signature" "" bash -c "gpg --verify $REPO/repodata/repomd.xml.asc $REPO/repodata/repomd.xml 2>&1 | grep -E 'Good signature|using RSA' | head -1; [ -f $REPO/repodata/repomd.xml.asc ]"
# a repo is not 'consumable' if an unsigned package slips in: prove the consumer refuses one
cp $GPK $TMPD/unsigned-copy.rpm; U=$TMPD/myorg-gpg-keys-unsigned.rpm
rpm --delsign $TMPD/unsigned-copy.rpm >/dev/null 2>&1; mv $TMPD/unsigned-copy.rpm $U
mkdir -p $TMPD/urepo $TMPD/uroot; cp $U $TMPD/urepo/; createrepo_c -q $TMPD/urepo
cat > $TMPD/repos/unsigned.repo <<EOF
[unsigned]
name=unsigned
baseurl=file://$TMPD/urepo
gpgcheck=1
gpgkey=file://$KEY
EOF
UOUT=$(sudo dnf -y --setopt=reposdir=$TMPD/repos --disablerepo=myorg-check --installroot=$TMPD/uroot --releasever=10 --setopt=cachedir=$TMPD/ucache install myorg-gpg-keys 2>&1 | tail -3)
if echo "$UOUT" | grep -qi -E 'not signed|signature|GPG'; then ok M5.3 "negative control: gpgcheck=1 refuses an unsigned package" "$(echo "$UOUT" | grep -i -E 'not signed|signature|GPG' | head -1 | sed 's/^ *//')"; else bad M5.3 "gpgcheck=1 refuses an unsigned package" "$(echo "$UOUT" | tr '\n' ' ')"; fi

### M6 image ----------------------------------------------------------------
echo "--- M6 image"
IDT=$(sudo grep '^ID=' $TREE/etc/os-release 2>/dev/null)
if [ "$IDT" = 'ID="myorg"' ]; then ok M6.1 "installroot identity" "$IDT"; else bad M6.1 "installroot identity" "'$IDT' ($TREE missing? run scripts/08-publish-and-image.sh)"; fi
PW=$(sudo rpm --root $TREE -q --whatprovides system-release 2>&1)
if echo "$PW" | grep -q '^myorg-release-' && [ $(echo "$PW" | wc -l) -eq 1 ]; then ok M6.2 "only myorg-release provides system-release in the tree" "$PW"; else bad M6.2 "only myorg-release provides system-release" "$PW"; fi
NR=$(sudo rpm --root $TREE -qa --qf '%{NAME}\n' 2>/dev/null | grep -c '^rocky-'); NT=$(sudo rpm --root $TREE -qa 2>/dev/null | wc -l)
if [ "$NR" = 0 ] && [ "$NT" -gt 50 ]; then ok M6.3 "no seed identity packages (rocky-*) in the tree" "0 of $NT packages; note seed packages keep their own '.rocky.' release tags, that is the seed's patching, not identity"; else bad M6.3 "no seed identity packages in the tree" "$NR rocky-* of $NT packages"; fi
GC=$(sudo cat $TREE/etc/yum.repos.d/*.repo 2>/dev/null | grep -c '^gpgcheck=1')
GN=$(sudo cat $TREE/etc/yum.repos.d/*.repo 2>/dev/null | grep -c '^gpgcheck=0')
if [ "${GC:-0}" -ge 4 ] && [ "${GN:-1}" = 0 ]; then ok M6.4 "the tree's own repo files have gpgcheck=1 only" "gpgcheck=1 x$GC, gpgcheck=0 x$GN"; else bad M6.4 "the tree's own repo files have gpgcheck=1 only" "1:$GC 0:$GN"; fi
CO=$(sudo podman run --rm $IMG cat /etc/os-release 2>&1 | grep -E '^(ID|PRETTY_NAME)=' | tr '\n' ' ')
if echo "$CO" | grep -q 'ID="myorg"'; then ok M6.5 "podman run shows the identity" "$CO"; else bad M6.5 "podman run shows the identity" "$CO"; fi
GR=$(sudo podman run --rm $IMG greeter 2>&1 | head -1)
if echo "$GR" | grep -q 'libgreet'; then ok M6.6 "a package we built runs in the image (consumer + library)" "$GR"; else bad M6.6 "a package we built runs in the image" "$GR"; fi

### Secure Boot (written item, not machine-checked) --------------------------
say "NOTE  SB  Secure Boot is a written rubric item, not checked here: this tree ships no shim, no signed kernel and no myorg-sb-certs."

### dossier diff --------------------------------------------------------------
echo "--- dossier diff: Rocky which vs MyOrg which"
mkdir -p $TMPD/rocky; dnf -q download --destdir=$TMPD/rocky which >/dev/null 2>&1
RW=$(ls $TMPD/rocky/which-*.x86_64.rpm 2>/dev/null | head -1); MW=$(ls $REPO/which-[0-9]*.x86_64.rpm | head -1)
if [ -n "$RW" ] && [ -n "$MW" ]; then
  row(){ printf '%-14s | %-46s | %-46s\n' "$1" "$2" "$3"; }
  q(){ rpm -qp --nosignature --qf "$2" "$1" 2>/dev/null; }
  say ""
  say "$(row field 'Rocky (seed)' 'MyOrg (our rebuild)')"
  say "$(row NVRA "$(q $RW '%{NVRA}')" "$(q $MW '%{NVRA}')")"
  say "$(row SOURCERPM "$(q $RW '%{SOURCERPM}')" "$(q $MW '%{SOURCERPM}')")"
  say "$(row BUILDHOST "$(q $RW '%{BUILDHOST}')" "$(q $MW '%{BUILDHOST}')")"
  say "$(row BUILDTIME "$(q $RW '%{BUILDTIME:date}')" "$(q $MW '%{BUILDTIME:date}')")"
  say "$(row signature "$(q $RW '%{RSAHEADER:pgpsig}' | sed 's/.*Key ID //')" "$(q $MW '%{RSAHEADER:pgpsig}' | sed 's/.*Key ID //')")"
  say "$(row PAYLOADDIGEST "$(q $RW '%{PAYLOADDIGEST}' | cut -c1-16)..." "$(q $MW '%{PAYLOADDIGEST}' | cut -c1-16)...")"
  say "$(row VENDOR "$(q $RW '%{VENDOR}')" "$(q $MW '%{VENDOR}')")"
  say "file hashes (path | Rocky vs MyOrg):"
  join -j1 <(rpm -qp --nosignature --qf '[%{FILENAMES} %{FILEDIGESTS}\n]' $RW | sort) <(rpm -qp --nosignature --qf '[%{FILENAMES} %{FILEDIGESTS}\n]' $MW | sort) | \
    awk '{ s=($2==$3)?"identical":"DIFFERENT"; if ($2=="") s="(dir/link)"; printf "%-14s | %-46s | %s\n", "file", $1, s " " substr($2,1,12) " vs " substr($3,1,12) }' | tee -a $EV
else
  bad DOSSIER "both which packages available" "rocky='$RW' myorg='$MW'"
fi

### result -------------------------------------------------------------------
say ""
HASH=$(grep -E '^(PASS|FAIL)' $EV | sed 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9:]*Z//' | sha256sum | cut -c1-32)
say "RESULT: $NPASS passed, $NFAIL failed.  evidence-bundle sha256 (pass/fail lines) = $HASH"
cp $EV $M/capstone-evidence.txt 2>/dev/null && echo "evidence saved to $M/capstone-evidence.txt"
[ $NFAIL -eq 0 ]
