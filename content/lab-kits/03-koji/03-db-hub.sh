#!/bin/bash
# Run as root. PostgreSQL + koji schema + hub + httpd.
set -euxo pipefail
FQDN=koji.lab.example
PKI=/etc/pki/koji

# ---- PostgreSQL
[ -f /var/lib/pgsql/data/PG_VERSION ] || postgresql-setup --initdb
PGDATA=/var/lib/pgsql/data
sed -i "s/^#\?listen_addresses.*/listen_addresses = ''/" $PGDATA/postgresql.conf
cat > $PGDATA/pg_hba.conf <<HBA
local   koji      koji                       trust
local   all       postgres                   peer
HBA
systemctl enable --now postgresql
id koji &>/dev/null || useradd -r -m -d /home/koji koji   # (-r makes a system account; a plain useradd also works)
su - postgres -c "createuser --no-superuser --no-createrole --no-createdb koji"
su - postgres -c "createdb -O koji koji"
su - koji -c "psql koji koji < /usr/share/koji/schema.sql" > /tmp/schema-load.log 2>&1
tail -3 /tmp/schema-load.log
# bootstrap admin (SSL auth): perm_id 1 = admin
su - koji -c "psql -c \"insert into users (name, status, usertype) values ('kojiadmin', 0, 0);\""
su - koji -c "psql -c \"insert into user_perms (user_id, perm_id, creator_id) select u.id, 1, u.id from users u where u.name='kojiadmin';\""
su - koji -c "psql -c 'select * from users; select * from user_perms; select id,name from permissions;'"

# ---- hub config
cat > /etc/koji-hub/hub.conf <<HUB
[hub]
DBName = koji
DBUser = koji
KojiDir = /mnt/koji
DNUsernameComponent = CN
ProxyDNs = CN=$FQDN,OU=kojiweb,O=KojiLab,L=Portland,ST=Oregon,C=US
LoginCreatesUser = On
KojiWebURL = https://$FQDN/koji
NotifyOnSuccess = False
HUB
# enable the ssllogin block in kojihub.conf
python3 - <<'PY'
import re
p='/etc/httpd/conf.d/kojihub.conf'; s=open(p).read()
blk="""# <Location /kojihub/ssllogin>
#         SSLVerifyClient require
#         SSLVerifyDepth  10
#         SSLOptions +StdEnvVars
# </Location>"""
assert blk in s
s=s.replace(blk, "\n".join(l[2:] for l in blk.splitlines()))
open(p,'w').write(s)
PY
# ssl.conf
sed -i "s|^SSLCertificateFile .*|SSLCertificateFile $PKI/certs/kojihub.crt|; s|^SSLCertificateKeyFile .*|SSLCertificateKeyFile $PKI/private/kojihub.key|" /etc/httpd/conf.d/ssl.conf
grep -q '^SSLCACertificateFile' /etc/httpd/conf.d/ssl.conf || \
  sed -i "/^SSLCertificateKeyFile/a SSLCACertificateFile $PKI/koji_ca_cert.crt" /etc/httpd/conf.d/ssl.conf
grep -n "^SSLCert\|^SSLCA\|^SSLCertificateKey" /etc/httpd/conf.d/ssl.conf
# MaxConnectionsPerChild
# Each hub thread keeps its own PostgreSQL connection. Stock mpm_event (3 children x 25 threads, up to 400 workers)
# exhausts PostgreSQL's default max_connections=100 ('remaining connection slots are reserved ...'), hub then
# answers 'ServerOffline: database outage'. Cap httpd so workers < max_connections.
cat > /etc/httpd/conf.d/zz-koji-mpm.conf <<MPM
MaxConnectionsPerChild 100
<IfModule mpm_event_module>
    StartServers 1
    ServerLimit 4
    ThreadsPerChild 10
    MaxRequestWorkers 40
</IfModule>
MPM

# ---- /mnt/koji + SELinux
mkdir -p /mnt/koji/{packages,repos,work,scratch,repos-dist}
chown -R apache:apache /mnt/koji
setsebool -P allow_httpd_anon_write=1
semanage fcontext -a -t public_content_rw_t "/mnt/koji(/.*)?"
restorecon -r /mnt/koji
systemctl enable --now httpd
systemctl --no-pager status httpd | head -5
