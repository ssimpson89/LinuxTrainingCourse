Lab kit 06: capstone, MyOrg Lab (milestones M0 to M6)
Used by: module 52 (all labs). Copy the files into one directory, normally ~/m2.
Status: TESTED on Rocky 10.2 x86_64 (mock 6.9, dnf 4.20.0, rpm 4.19.1.1, podman, SELinux enforcing),
        2026-11-07 UTC: clean run, 28 of 28 checks pass, 387 seconds including the optional experiments.
        NOT tested: install media with the MyOrg repository (M7) and install and boot of a MyOrg
        image (M8). Those are design in module 52, not part of this kit.

Files
  specs/myorg-release.spec      one source package that builds three: myorg-release, myorg-repos,
                                myorg-gpg-keys
  src/myorg-release/            LICENSE, myorg.repo, myorg-seed.repo (sources for that spec)
  src/pair/                     library and consumer packages used for the chain build (M3)
  mock/myorg-10-x86_64.cfg.in   mock config template, rendered by step 01 with your work directory and port
  scripts/env.sh                paths, key name, port, tree and image names, a timing helper
  scripts/01 ... 09, run-all.sh one script per step, and the runner
  scripts/lab-repos.sh          writes the bootstrap repo file the host dnf needs before myorg-repos exists
  capstone-check.sh             28 PASS/FAIL checks for M0 to M6, then the dossier diff

Prerequisites
  Rocky 10.2 x86_64, 4 vCPU, 8 GiB RAM or more, 10 GB free in /var/tmp and /var/lib/mock
  A user in group mock with passwordless sudo
  mock rpm-build rpm-sign createrepo_c podman gnupg2 python3 (mock comes from EPEL)
  Internet access to dl.rockylinux.org

Run it
  mkdir ~/m2 && cp -r specs src scripts mock capstone-check.sh ~/m2/ && cd ~/m2
  M=$HOME/m2 bash scripts/run-all.sh               # about 6 minutes
  M=$HOME/m2 bash scripts/run-all.sh --experiments # adds the conflict experiments, about 2.5 minutes more
  M=$HOME/m2 bash capstone-check.sh

Notes
  The MyOrg signing key is RSA-4096 with no passphrase. That is for this lab only. A real key
  belongs on an HSM or an offline host.
  Step 04 and 05 create throwaway installroots under your work directory.

Clean up
  rm -rf ~/m2 ; sudo rm -rf /var/tmp/m2-root
  podman rmi localhost/myorg-base:10
  mock caches can be removed with mock --scrub=all, run for each config you used
