#!/bin/bash
# Pitfall demos for M4/M5: what the consumer says when trust is missing or broken.
set -u; . "$(dirname "$0")/env.sh"
X=/var/tmp/m2-fail; sudo rm -rf $X; mkdir -p $X/repos $X/work
GPK=$(ls $REPO/myorg-gpg-keys-*.rpm | head -1)
echo "### 1. rpm -Kv with a keyring that lacks the key: NOKEY (digests fine, signature unverifiable)"
rpm --dbpath $X/emptydb -Kv $GPK 2>&1 | sed 's/^/   /'
echo "### 2. dnf, gpgcheck=1, key NOT given (no gpgkey= line), -y: does it import anything?"
cat > $X/repos/nokey.repo <<EOT
[nokey]
name=nokey
baseurl=http://localhost:$PORT/myorg/10/x86_64/
gpgcheck=1
EOT
sudo rm -rf $X/r1; sudo dnf -y --setopt=reposdir=$X/repos --installroot=$X/r1 --releasever=10 --setopt=cachedir=$X/c1 install myorg-gpg-keys 2>&1 | grep -i -E 'error|you have enabled|rpm --import|No GPG|not signed' | head -4 | sed 's/^/   /'
echo "### 3. gpgkey= given but no -y and no terminal (cron, CI): dnf refuses to import the key unattended"
cat > $X/repos/key.repo <<EOT
[withkey]
name=withkey
baseurl=http://localhost:$PORT/myorg/10/x86_64/
gpgcheck=1
gpgkey=file://$KEYFILE
EOT
sudo rm -rf $X/r2; printf 'y\n' | sudo dnf --setopt=reposdir=$X/repos --disablerepo=nokey --installroot=$X/r2 --releasever=10 --setopt=cachedir=$X/c2 install myorg-gpg-keys 2>&1 | grep -E 'Importing|Is this ok|Refusing|Error' | sed 's/^/   /'
echo "   (the -y runs in the main lab print 'Importing GPG key ... Key imported successfully' instead; that is the unattended opt-in)"
echo "### 4. tampered package: flip one payload byte, keep the signature"
cp $GPK $X/work/t.rpm; python3 - <<PY
p="$X/work/t.rpm"; b=bytearray(open(p,"rb").read()); b[-200]^=0xff; open(p,"wb").write(b)
PY
rpm --dbpath $X/keydb --import $KEYFILE; rpm --dbpath $X/keydb -Kv $X/work/t.rpm 2>&1 | sed 's/^/   /'
echo "### 5. version comparison luck: why a rebuild named .myorg 'wins' over .el10_0 without priority"
rpm --eval '%{lua:print("rpm.vercmp(2.21-44.myorg, 2.21-44.el10_0) = " .. rpm.vercmp("2.21-44.myorg","2.21-44.el10_0") .. "   (1 means the first is newer)\n"); print("rpm.vercmp(2.21-44.aaa, 2.21-44.el10_0) = " .. rpm.vercmp("2.21-44.aaa","2.21-44.el10_0") .. "   (a dist tag that sorts lower loses to the seed copy)\n")}' | sed 's/^/   /'
sudo rm -rf $X/r1 $X/r2
