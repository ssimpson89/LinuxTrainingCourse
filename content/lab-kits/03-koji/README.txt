Lab kit 03: a single-host Koji (hub, PostgreSQL, builder, kojira, kojiweb)
Used by: module 50 (Labs 1 to 4)
Status: TESTED on Rocky 10.2 x86_64 (Koji 1.35.3 from EPEL, PostgreSQL 16, httpd 2.4, mock 6.9,
        SELinux enforcing), 593 seconds for steps 01 to 08, 2026-11-06. It also ran on aarch64 (about 37 minutes).
        The browser login to kojiweb with a certificate was not exercised.

WARNING: this kit changes the machine. It sets the hostname to koji.lab.example, edits /etc/hosts,
installs and starts services, and adds a private CA to the system trust store. Use a disposable VM.

Files
  01-base.sh ... 08-build.sh      one step each: packages and hostname, private CA and certificates,
                                  database and hub, client config, builder + kojira + kojiweb, tags and
                                  external Rocky repos, a hello-world SRPM, the build of which
  09-hello-build.sh               builds the hello SRPM through Koji
  10-observe.sh                   the read-only observation commands that module 50 uses
  run-all.sh                      runs steps 01 to 08 in order
  reference-configs/              the config files the scripts write (hub, kojid, kojira, kojiweb,
                                  httpd MPM cap), for reading. No keys or passwords in them.

Prerequisites
  Rocky 10.2 x86_64 VM, a user with sudo, network to dl.rockylinux.org and EPEL
  4 vCPU, 8 GiB RAM recommended (tested with 15 GiB), 20 GB free disk
  Do not run the builder and a QEMU boot test (kit 05) at the same time on 4 vCPU.

Run it (as the normal user, from this directory)
  bash run-all.sh 2>&1 | tee run-all.log
  bash 09-hello-build.sh
  bash 10-observe.sh

Notes
  koji build returns immediately without a terminal: always use --nowait, then koji watch-task.
  koji list-tasks --all needs --after=2000-01-01.
  The Koji-built which is named which-2.21-44.el10 and has no signature (Koji does not sign).

Clean up
  sudo systemctl disable --now kojid kojira httpd postgresql
  sudo hostnamectl set-hostname YOUR_OLD_HOSTNAME
  sudo sed -i '/koji.lab.example/d' /etc/hosts
  sudo rm /etc/pki/ca-trust/source/anchors/koji-lab-ca.crt && sudo update-ca-trust
  Full removal: sudo dnf remove 'koji*' postgresql-server; sudo rm -rf /mnt/koji /var/lib/pgsql /etc/pki/koji
