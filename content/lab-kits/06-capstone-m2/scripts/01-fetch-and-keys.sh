#!/bin/bash
# M0/M1 and the key material M2 needs.
set -eu; . "$(dirname "$0")/env.sh"
mkdir -p $M/srpms $M/keys $GNUPGHOME; chmod 700 $GNUPGHOME
cd $M/srpms
# Source repos ship disabled in the stock repo files; enable per command.
t dnf -q download --source --enablerepo=baseos-source --enablerepo=appstream-source rocky-release which 2>&1 | grep -v '^enabling' || true
sha256sum *.src.rpm | tee $M/srpms/SHA256SUMS
# MyOrg signing key: RSA-4096, no passphrase (LAB ONLY: a real key lives on an HSM or an offline host)
if ! gpg --list-keys "$KEYNAME" >/dev/null 2>&1; then
  t gpg --batch --pinentry-mode loopback --passphrase "" --quick-generate-key "$KEYNAME" rsa4096 sign never 2>&1 | tail -1
fi
gpg --armor --export "$KEYNAME" > $KEYFILE
gpg --show-keys --with-fingerprint $KEYFILE
# The seed key, taken from the installed (already trusted) key package. Only the
# first PGP block: gpg 2.4 chokes on the v6 post-quantum block in the newer file.
sed -n '1,/END PGP PUBLIC KEY BLOCK/p' /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10 > $SEEDKEY
gpg --show-keys --with-fingerprint $SEEDKEY
# Render the mock config for THIS work dir and port (the template has @M@ and @PORT@).
sed "s#@M@#$M#g; s#@PORT@#$PORT#g" $M/mock/myorg-10-x86_64.cfg.in > $M/mock/myorg-10-x86_64.cfg
echo "rendered $M/mock/myorg-10-x86_64.cfg"
