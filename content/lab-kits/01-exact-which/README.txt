Lab kit 01: exact reproduction of Rocky's `which` (x86_64)
Used by: module 45 (Lab 3), module 49 (Lab 4), module 48 (refers to the config)
Status: TESTED on Rocky 10.2 x86_64 (a VM with systemd, SELinux enforcing, mock 6.9, rpm 4.19.1.1), 2026-11-06.
        One package, one architecture. aarch64 with the pinned buildroot was not verified.

What it does
  Rebuilds which-2.21-44.el10_0.src.rpm twice with mock and compares both results with the
  RPM Rocky ships. Run A uses today's repositories. Run B uses a buildroot pinned to the
  Rocky 10.0 vault AND --define 'dist .el10_0'. Only Run B matches (same PAYLOADDIGEST,
  same per-file digests, same build ID). The pinned buildroot alone does not.

Files
  rocky-10.0-vault-x86_64.cfg   mock config. Copy to ~/mockcfg/. It includes the stock
                                rocky-10-x86_64.cfg and points BaseOS, AppStream and CRB
                                at https://dl.rockylinux.org/vault/rocky/10.0/. gpgcheck stays on.
  run.sh                        downloads the shipped RPM and SRPM, then runs Run A and Run B
  compare.sh                    prints the three-way comparison

Prerequisites
  Rocky 10.2 x86_64 VM (a container makes mock fall back to chroot), epel-release enabled,
  packages: mock rpmdevtools rpm-build dnf-plugins-core
  Your user in group mock (sudo usermod -aG mock $USER, then log in again)
  Network access to dl.rockylinux.org
  About 2 vCPU, 4 GiB RAM. Disk after both builds: about 0.5 GB in /var/lib/mock and 0.7 GB in /var/cache/mock

Run it
  mkdir -p ~/mockcfg && cp rocky-10.0-vault-x86_64.cfg ~/mockcfg/
  bash run.sh        # about 2 minutes cold
  bash compare.sh

Expected
  Run A about 1 minute, Run B about 50 seconds (cold). compare.sh ends with
  "pinned vs shipped: ALL-FILES-IDENTICAL" and "BINARY-IDENTICAL pinned".
  The current-repos rebuild is named which-2.21-44.el10 (not el10_0) and differs.

Clean up
  rm -rf ~/lab/01 ~/mockcfg
  mock -r rocky-10-x86_64 --scrub=all; mock -r ~/mockcfg/rocky-10.0-vault-x86_64.cfg --scrub=all
  (run the two scrubs before removing ~/mockcfg)
