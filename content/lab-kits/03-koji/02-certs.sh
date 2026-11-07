#!/bin/bash
# Run as root. Local CA + certs for hub, web, kojira, builder, admin.
# CN of hub/web cert = FQDN clients use; CN of every client cert = the Koji username.
set -euxo pipefail
FQDN=${FQDN:-koji.lab.example}
PKI=/etc/pki/koji
mkdir -p $PKI && cd $PKI
rm -rf $PKI/* ; mkdir -p $PKI/{certs,private,newcerts}
touch index.txt; echo 01 > serial
echo 'unique_subject = no' > index.txt.attr   # hub+web+builder may share a CN

cat > ssl.cnf <<CNF
HOME = $PKI
RANDFILE = $PKI/.rand
[ca]
default_ca = ca_default
[ca_default]
dir = $PKI
certs = \$dir/certs
crl_dir = \$dir/crl
database = \$dir/index.txt
new_certs_dir = \$dir/newcerts
certificate = \$dir/koji_ca_cert.crt
private_key = \$dir/private/koji_ca_cert.key
serial = \$dir/serial
default_days = 3650
default_md = sha256
policy = policy_match
copy_extensions = copy
[policy_match]
countryName = optional
stateOrProvinceName = optional
localityName = optional
organizationName = optional
organizationalUnitName = optional
commonName = supplied
[req]
default_bits = 2048
default_md = sha256
distinguished_name = req_distinguished_name
prompt = no
[req_distinguished_name]
C = US
ST = Oregon
L = Portland
O = KojiLab
CN = placeholder
[v3_ca]
basicConstraints = CA:true
keyUsage = keyCertSign, cRLSign
subjectKeyIdentifier = hash
CNF
mkdir -p newcerts

# --- CA
openssl genrsa -out private/koji_ca_cert.key 2048
openssl req -config ssl.cnf -new -x509 -subj "/C=US/ST=Oregon/L=Portland/O=KojiLab/CN=$FQDN-CA" \
  -days 3650 -key private/koji_ca_cert.key -out koji_ca_cert.crt -extensions v3_ca

# --- server certs need a SAN (modern TLS clients ignore CN alone)
mkcert_server() {  # name cn [ou]
  local name=$1 cn=$2 ou=${3:+/OU=$3}
  openssl genrsa -out private/$name.key 2048
  openssl req -config ssl.cnf -new -nodes -subj "/C=US/ST=Oregon/L=Portland/O=KojiLab$ou/CN=$cn" \
    -key private/$name.key -out certs/$name.csr -addext "subjectAltName=DNS:$cn,DNS:koji"
  openssl ca -config ssl.cnf -batch -in certs/$name.csr -out certs/$name.crt -notext
}
mkcert_client() {  # name (= CN = koji username)
  local name=$1
  openssl genrsa -out private/$name.key 2048
  openssl req -config ssl.cnf -new -nodes -subj "/C=US/ST=Oregon/L=Portland/O=KojiLab/CN=$name" \
    -key private/$name.key -out certs/$name.csr
  openssl ca -config ssl.cnf -batch -in certs/$name.csr -out certs/$name.crt -notext
  cat certs/$name.crt private/$name.key > $name.pem      # PEM = cert + key, this is what koji clients use
}
mkcert_server kojihub $FQDN
mkcert_server kojiweb $FQDN kojiweb   # distinct DN (OU=kojiweb): this exact DN goes in hub.conf ProxyDNs
mkcert_client kojiadmin
mkcert_client kojira
mkcert_client $FQDN      # builder: CN = builder hostname = koji host name
chmod 600 private/*.key *.pem
chmod 644 koji_ca_cert.crt
chown -R root:root $PKI

# install builder / kojira / kojiadmin copies
install -m 600 -o root -g root $PKI/$FQDN.pem /etc/kojid/kojid.pem
cp $PKI/koji_ca_cert.crt /etc/kojid/koji_ca_cert.crt
install -m 600 $PKI/kojira.pem /etc/kojira/kojira.pem
cp $PKI/koji_ca_cert.crt /etc/kojira/koji_ca_cert.crt
openssl x509 -in certs/kojiweb.crt -noout -subject -nameopt RFC2253
