#!/bin/bash
# M4/M5: copy RPMs into the repo dir, sign unsigned ones with rpmsign, createrepo_c, serve with python.
# Usage: 03-sign-publish.sh <rpm files...>
set -eu; . "$(dirname "$0")/env.sh"
SRCDIR=$WEB/myorg/10/source
mkdir -p $REPO $SRCDIR
for f in "$@"; do case $f in *.src.rpm) \cp $f $SRCDIR/;; *) \cp $f $REPO/;; esac; done
\cp $KEYFILE $WEB/myorg/
cd $SRCDIR; for f in *.src.rpm; do
  if [ "$(rpm -q --qf '%{RSAHEADER:pgpsig}' -p $f)" = "(none)" ]; then echo "sign $f"; t rpmsign --define "_gpg_name $KEYNAME" --addsign $f 2>&1 | tail -1; fi
done
cd $REPO
for f in *.rpm; do
  # idempotent: sign only files whose header has no signature yet
  if [ "$(rpm -q --qf '%{RSAHEADER:pgpsig}' -p $f)" = "(none)" ]; then echo "sign $f"; t rpmsign --define "_gpg_name $KEYNAME" --addsign $f 2>&1 | tail -1; fi
done
t createrepo_c --quiet .
gpg --batch --yes --armor --detach-sign -u "$KEYNAME" repodata/repomd.xml   # makes repo_gpgcheck=1 possible too
ls
if ! curl -fsS -o /dev/null http://localhost:$PORT/myorg/RPM-GPG-KEY-myorg; then
  cd $WEB && setsid -f python3 -m http.server $PORT --bind 127.0.0.1 >$M/http.log 2>&1 </dev/null; sleep 1
fi
curl -fsS -o /dev/null -w "http %{http_code}\n" http://localhost:$PORT/myorg/10/x86_64/repodata/repomd.xml
