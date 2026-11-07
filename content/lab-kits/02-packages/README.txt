Lab kit 02: your own packages, signing, a repository and a consumer
Used by: module 49 (Labs 1 to 3), module 40 (installroot ideas), module 44 (podman import)
Status: TESTED on Rocky 10.2 x86_64 (mock 6.9, rpm 4.19.1.1, gnupg2 2.4.5, createrepo_c 1.1.2,
        podman 5.8.2), 2026-11-06. Serving the repo with httpd, SELinux and firewalld was not tested:
        the lab serves it with python3 -m http.server.

Files
  src/                            two tiny C packages: libgreet and greeter (specs, source
                                  directories, tarballs)
  b-chain-sign-serve.sh           build both SRPMs, show the failure of building greeter alone,
                                  chain build with a local repo, make a signing key, sign,
                                  createrepo_c
  c-serve-and-consume.sh          serve the repo over HTTP and install from a rootful podman
                                  container: first without the key (refuses), then with it
  d-installroot.sh                build a minimal OS tree with dnf --installroot, inspect it with
                                  rpm --root and chroot, add kernel-core, import it into podman
                                  (run as root; it writes under /var/tmp)

Prerequisites
  Rocky 10.2 x86_64, a user in group mock with sudo, EPEL enabled (mock comes from EPEL)
  sudo dnf install -y mock rpmdevtools rpm-build rpm-sign createrepo_c gnupg2 podman python3

Run it (the scripts expect the sources in ~/lab/02/src)
  mkdir -p ~/lab/02 && cp -r src ~/lab/02/
  bash b-chain-sign-serve.sh
  bash c-serve-and-consume.sh
  sudo bash d-installroot.sh      # optional, about 40 seconds plus the kernel step

Expect
  chain build about 30 seconds. rpm -Kv shows four digest lines and no signature before
  rpmsign, and a NOKEY signature line after (the key is not in your rpm database).
  The consumer without a gpgkey= line refuses. With a gpgkey= line and -y it imports the key.
  Note: b-chain-sign-serve.sh writes %_gpg_name into ~/.rpmmacros with ">" (it replaces the file).
  Back up ~/.rpmmacros first if you have one.

Clean up
  sudo podman rm -f consumer
  kill $(cat ~/lab/02/http.pid)
  rm -rf ~/lab/02 ~/rpmbuild/SRPMS/myorg-* ~/.rpmmacros
  sudo rm -rf /var/tmp/lab-root /var/tmp/lab-root.tar /var/tmp/lab-root.tar.gz
  podman rmi localhost/rocky-lab-base:10
