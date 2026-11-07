# sourced by every script. Everything lives under $M; nothing outside it is touched
# except mock's own caches (/var/lib/mock, /var/cache/mock) and the installroot $TREE.
export M=${M:-$HOME/m2work}
export GNUPGHOME=$M/gnupg
export WEB=$M/web                      # what python http.server serves
export REPO=$WEB/myorg/10/x86_64       # baseurl = $myorg_baseurl/myorg/$releasever/$basearch/
export PORT=${PORT:-8080}
export KEYNAME="MyOrg Lab Signing <signing@myorg.example>"
export KEYFILE=$M/keys/RPM-GPG-KEY-myorg
export SEEDKEY=$M/keys/RPM-GPG-KEY-upstream-seed
export TREE=${TREE:-/var/tmp/m2-root}  # the installroot (root-owned; /var/tmp, not tmpfs /tmp)
export IMG=${IMG:-localhost/myorg-base:10}
t() { local s=$(date +%s); "$@"; local rc=$?; echo "[time] $1 ${2:-} : $(( $(date +%s)-s ))s rc=$rc" >&2; return $rc; }
