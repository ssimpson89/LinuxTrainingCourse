---
title: Lab kits
description: Downloadable scripts, spec files and configs for the labs in the How Rocky Gets Built series, with the honest test status of each kit.
---

# Lab kits

Most labs in the [How Rocky Gets Built](series-how-rocky-gets-built.md) series show every command on the page. A few are too long to retype: a single-host Koji is a set of numbered scripts, and the capstone is a set of spec files, sources and a checker. Those files live here, one folder per kit, so you can run what was tested instead of what you typed from memory.

Every kit is plain text (plus two tiny source tarballs). Read a script before you run it. Several change the machine they run on, and each kit's `README.txt` says how to undo that.

<!-- ev: labs/final SUMMARY | observed | Rocky 10.2 x86_64 VM, 2026-11-06 -->
!!! freshness "As of 2026-11-06 on Rocky 10.2"
    The kits were run on Rocky 10.2 on x86_64. They pull packages from the live Rocky repositories, so a later minor release, a newer `mock` or a new Koji can change an outcome. Package versions and timings in the READMEs are from the test run. This changes at each minor release.

    **Re-check:** run the kit and compare its output with the module. Where the two differ, trust the output you got and treat the page as dated.

## How to get the files

Each file below is a link. Use your browser's "save link as" on every file and keep the folder layout, or copy the `lab-kits` folder from the course repository if you cloned it. The scripts expect their companions in the same directory, so do not flatten the folders.

Each kit has a `README.txt`: prerequisites, how to run it, what to expect and how to clean up. Nothing here is signed. Check a download against the repository copy if it matters to you.

## What was tested, and what was not

| Kit | Module | Status | Test platform |
|-----|--------|--------|---------------|
| 01 Exact `which` | 45, 49 | Tested | Rocky 10.2 x86_64 VM, 2026-11-06. One package, one architecture. |
| 02 Packages | 49 | Tested | Rocky 10.2 x86_64 VM, 2026-11-06. Served with `python3 -m http.server`; httpd, SELinux and firewalld serving not tested. |
| 03 Koji | 50 | Tested | Rocky 10.2 x86_64 VM, 593 seconds for steps 01 to 08. Browser login to kojiweb not exercised. |
| 04 Media | 51, 43 | Tested | Rocky 10.2 x86_64 VM. KIWI builds and `livemedia-creator` were never run on x86_64 and are not in the kit. |
| 05 Boot | 51, 43 | Tested | Rocky 10.2 x86_64 VM without KVM. Stock ISO, not a branded one. No login typed. |
| 06 Capstone | 52 | Tested for M0 to M6 | Rocky 10.2 x86_64 VM, 2026-11-07. 28 of 28 checks. Install media and boot of a MyOrg image (M7, M8) are not tested and not in the kit. |

Two edits were made after the tested runs, both to replace an `xorriso -cat` line that printed nothing with `-extract` (the form module 43 shows): `b-inspect-iso.sh` in kit 04 and `a-make-iso.sh` in kit 05. Both edited steps were run on the x86_64 lab VM on 2026-11-07 UTC and printed the expected `grub.cfg` entries.

The two kickstart files carry a throwaway root password for a disposable VM. Change it, and never reuse it.

## Kit 01: exact reproduction of `which`

Used by [45 · Rocky's pipeline I](45-pipeline-source-to-build.md) (Lab 3) and [49 · Build your own packages and repository](49-build-your-own-packages-and-repo.md) (Lab 4). It rebuilds Rocky's `which` against today's repositories and against a buildroot pinned to the Rocky 10.0 vault, and compares both with the shipped package. Only the pinned build with `--define 'dist .el10_0'` matches.

**Status:** Tested, x86_64, one package. aarch64 with the pinned buildroot was not verified.

- [README.txt](lab-kits/01-exact-which/README.txt)
- [rocky-10.0-vault-x86_64.cfg](lab-kits/01-exact-which/rocky-10.0-vault-x86_64.cfg), the pinned mock config
- [run.sh](lab-kits/01-exact-which/run.sh), downloads the package and runs both builds
- [compare.sh](lab-kits/01-exact-which/compare.sh), the three-way comparison

## Kit 02: packages, signing, a repository and a consumer

Used by [49 · Build your own packages and repository](49-build-your-own-packages-and-repo.md). Two tiny C packages, a chain build with `mock`, your own signing key, a repository from `createrepo_c`, and a container that refuses the repository until it has your key. The installroot script builds a minimal OS tree and imports it into `podman`.

**Status:** Tested, x86_64.

- [README.txt](lab-kits/02-packages/README.txt)
- [b-chain-sign-serve.sh](lab-kits/02-packages/b-chain-sign-serve.sh)
- [c-serve-and-consume.sh](lab-kits/02-packages/c-serve-and-consume.sh)
- [d-installroot.sh](lab-kits/02-packages/d-installroot.sh)
- Sources: [myorg-libgreet.spec](lab-kits/02-packages/src/myorg-libgreet.spec), [myorg-greeter.spec](lab-kits/02-packages/src/myorg-greeter.spec), [libgreet-1.0.tar.gz](lab-kits/02-packages/src/libgreet-1.0.tar.gz), [greeter-1.0.tar.gz](lab-kits/02-packages/src/greeter-1.0.tar.gz). The unpacked source files sit beside them in `src/libgreet-1.0/` and `src/greeter-1.0/` (each holds a `Makefile` and one or two C files).

## Kit 03: a single-host Koji

Used by [50 · Build your own build system](50-build-your-own-koji.md). Nine step scripts, a runner, an observation script and the config files the scripts write. It changes the hostname, edits `/etc/hosts`, starts services and trusts a private CA, so use a disposable VM.

**Status:** Tested, x86_64. Browser login to kojiweb with a certificate was not exercised.

- [README.txt](lab-kits/03-koji/README.txt)
- [run-all.sh](lab-kits/03-koji/run-all.sh)
- Steps: [01-base.sh](lab-kits/03-koji/01-base.sh), [02-certs.sh](lab-kits/03-koji/02-certs.sh), [03-db-hub.sh](lab-kits/03-koji/03-db-hub.sh), [04-client.sh](lab-kits/03-koji/04-client.sh), [05-builder-kojira-web.sh](lab-kits/03-koji/05-builder-kojira-web.sh), [06-tags.sh](lab-kits/03-koji/06-tags.sh), [07-hello-srpm.sh](lab-kits/03-koji/07-hello-srpm.sh), [08-build.sh](lab-kits/03-koji/08-build.sh), [09-hello-build.sh](lab-kits/03-koji/09-hello-build.sh), [10-observe.sh](lab-kits/03-koji/10-observe.sh)
- Reference configs, for reading: [hub.conf](lab-kits/03-koji/reference-configs/etc/koji-hub/hub.conf), [kojid.conf](lab-kits/03-koji/reference-configs/etc/kojid/kojid.conf), [kojira.conf](lab-kits/03-koji/reference-configs/etc/kojira/kojira.conf), [web.conf](lab-kits/03-koji/reference-configs/etc/kojiweb/web.conf), [zz-koji-mpm.conf](lab-kits/03-koji/reference-configs/etc/httpd/conf.d/zz-koji-mpm.conf)

## Kit 04: install media

Used by [51 · Build your own install media](51-build-your-own-install-media.md) and, for the kickstart, [43 · Installer and install media](43-installer-and-install-media.md). A small unattended kickstart, a script that builds a boot ISO with `lorax` and wraps it with `mkksiso`, and a read-only ISO inspection script that works on any ISO. The kickstart wipes every disk it sees, so use it in a VM only.

**Status:** Tested, x86_64. KIWI image builds and `livemedia-creator` are not in the kit because they were never run on x86_64.

- [README.txt](lab-kits/04-media/README.txt)
- [lab-minimal.ks](lab-kits/04-media/lab-minimal.ks)
- [a-lorax.sh](lab-kits/04-media/a-lorax.sh)
- [b-inspect-iso.sh](lab-kits/04-media/b-inspect-iso.sh)

## Kit 05: boot test without KVM

Used by [51 · Build your own install media](51-build-your-own-install-media.md) as the source of its read-along boot test. Installs the kit 04 ISO unattended into a `qcow2` under QEMU software emulation, then boots the result. The install took about 51 minutes and the disk booted to a login prompt in about 2 minutes.

**Status:** Tested, x86_64, no KVM. The ISO was built from the stock repositories, not a branded one. A login was never typed, and BIOS boot and Secure Boot were not exercised.

- [README.txt](lab-kits/05-boot/README.txt)
- [lab-tcg.ks](lab-kits/05-boot/lab-tcg.ks)
- [a-make-iso.sh](lab-kits/05-boot/a-make-iso.sh)
- [b-install.sh](lab-kits/05-boot/b-install.sh)
- [c-boot-disk.sh](lab-kits/05-boot/c-boot-disk.sh)

## Kit 06: the capstone

Used by [52 · Capstone: MyOrg Lab](52-capstone-myorg-lab.md). This is the whole kit the capstone labs run from. Copy it into one directory (the module uses `~/m2`) so that `specs/`, `src/`, `scripts/`, `mock/` and `capstone-check.sh` sit together.

**Status:** Tested for milestones M0 to M6 on an x86_64 VM, 28 of 28 checks in a clean run. Install media built from the MyOrg repository (M7) and install and boot of a MyOrg image (M8) are design only and have no files here.

- [README.txt](lab-kits/06-capstone-m2/README.txt)
- [capstone-check.sh](lab-kits/06-capstone-m2/capstone-check.sh), the 28 checks and the dossier diff
- [specs/myorg-release.spec](lab-kits/06-capstone-m2/specs/myorg-release.spec), one source package that builds three
- [mock/myorg-10-x86_64.cfg.in](lab-kits/06-capstone-m2/mock/myorg-10-x86_64.cfg.in), the mock config template
- Scripts: [env.sh](lab-kits/06-capstone-m2/scripts/env.sh), [01-fetch-and-keys.sh](lab-kits/06-capstone-m2/scripts/01-fetch-and-keys.sh), [02-build-release.sh](lab-kits/06-capstone-m2/scripts/02-build-release.sh), [03-sign-publish.sh](lab-kits/06-capstone-m2/scripts/03-sign-publish.sh), [04-conflict-experiments.sh](lab-kits/06-capstone-m2/scripts/04-conflict-experiments.sh), [05-more-experiments.sh](lab-kits/06-capstone-m2/scripts/05-more-experiments.sh), [06-host-dryrun.sh](lab-kits/06-capstone-m2/scripts/06-host-dryrun.sh), [07-rebuild.sh](lab-kits/06-capstone-m2/scripts/07-rebuild.sh), [08-publish-and-image.sh](lab-kits/06-capstone-m2/scripts/08-publish-and-image.sh), [09-failure-demos.sh](lab-kits/06-capstone-m2/scripts/09-failure-demos.sh), [lab-repos.sh](lab-kits/06-capstone-m2/scripts/lab-repos.sh), [run-all.sh](lab-kits/06-capstone-m2/scripts/run-all.sh)
- Sources: [LICENSE](lab-kits/06-capstone-m2/src/myorg-release/LICENSE), [myorg.repo](lab-kits/06-capstone-m2/src/myorg-release/myorg.repo), [myorg-seed.repo](lab-kits/06-capstone-m2/src/myorg-release/myorg-seed.repo), and the library and consumer pair in `src/pair/` ([myorg-libgreet.spec](lab-kits/06-capstone-m2/src/pair/myorg-libgreet.spec), [myorg-greeter.spec](lab-kits/06-capstone-m2/src/pair/myorg-greeter.spec), [libgreet-1.0.tar.gz](lab-kits/06-capstone-m2/src/pair/libgreet-1.0.tar.gz), [greeter-1.0.tar.gz](lab-kits/06-capstone-m2/src/pair/greeter-1.0.tar.gz), plus the unpacked source directories)

## What is not here

The saved logs and transcripts from the test runs are not part of the kits. Neither are the author's own helper scripts for reaching the test machine. The module pages quote the output that matters, with its date.
