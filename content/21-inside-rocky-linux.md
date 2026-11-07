---
title: Inside Rocky Linux
description: How Rocky Linux is actually made and delivered, from source code and debranding through the build system, signing, repositories, mirrors, errata, Secure Boot and SIGs, and how to verify every step yourself.
---

# 21 · Inside Rocky Linux: How It's Built and Delivered

<ul class="module-meta">
  <li>⏱ ~3 hours</li>
  <li>4 labs</li>
  <li>Builds on: 05 · Software: RPM and DNF, 14 · The Boot Process, 17 · Security Hardening</li>
</ul>

A security bulletin lands on Tuesday. Your manager asks three questions: "Are we patched? Where did that patch come from? How do we know nobody tampered with it?" Most admins can answer the first one. This module lets you answer all three with evidence, because you will know how Rocky Linux is built, signed, published and delivered, and which command proves each step.

!!! abstract "What you'll learn"
    - Where Rocky Linux's source code comes from, and how that changed in 2023
    - What "debranding" changes, and how to spot Rocky's fingerprints on a package
    - How the build system (Koji, Peridot, mock) turns sources into signed RPMs
    - The repository layout (BaseOS, AppStream, CRB, extras, add-ons), mirrors, the vault, debug and source repos
    - How to trace any installed package back to its repo, build and security advisory (RLSA)
    - How to verify signatures yourself, from `rpm -K` to the Secure Boot chain
    - What the Special Interest Groups (SIGs) ship, and how Rocky differs from AlmaLinux, Oracle Linux and CentOS Stream

## The big picture

### Rocky Linux in one sentence

Here is the whole idea:

> **Rocky takes RHEL's source code, swaps the labels, builds it in a clean room, seals every package with its own key, and ships it through mirrors. Every one of those steps leaves a fingerprint on your server that you can check.**

The rest of this module walks along that pipeline, one step at a time, and
shows you the fingerprint each step leaves.

**Rocky Linux** is a **rebuild**: a distribution compiled from the same source code as Red Hat Enterprise Linux (RHEL), with Red Hat's trademarks removed, so that software certified for RHEL runs on it unchanged. Rocky does not write most of the code. Its job is a pipeline: get the sources, remove the branding, build them reproducibly, sign them, and deliver them to millions of machines.

```mermaid
flowchart TB
    A["Upstream sources<br/>(CentOS Stream, RHEL SRPMs)"] --> B["Import into<br/>Rocky Git"]
    B --> C["Debrand<br/>(patch repos)"]
    C --> D["Build system<br/>(Koji + mock)"]
    D --> E["Sign RPMs<br/>(Rocky GPG key)"]
    E --> F["Compose (Pungi), staging sync<br/>+ errata metadata"]
    F --> G["dl.rockylinux.org<br/>+ mirrors"]
    G --> H["dnf on<br/>your server"]
```

### The good news: a few commands read every fingerprint

Every arrow in that picture leaves evidence you can inspect on your own server.
Four commands (`rpm -qi`, `rpm -K`, `dnf info --installed`, `dnf updateinfo`)
answer most "where did this come from, and can I trust it?" questions:

| Pipeline stage | Evidence on your machine |
|---|---|
| Sources and debranding | `rpm -qi` shows `Vendor`, URLs, changelog entries mentioning Rocky |
| Build | `rpm -qi` shows `Build Host` and `Build Date`; the release tag ends in `.el10` or `.el10_N` |
| Signing | `rpm -K`, and the `Signature` value in `rpm -qi` (or `rpm -q --qf '%{RSAHEADER:pgpsig}\n'` for one clean line) |
| Repos and errata | `dnf info --installed` shows `From repo`; `dnf updateinfo` maps fixes to advisories |
| Delivery | `/etc/yum.repos.d/*.repo`, the mirror you were sent to in `dnf -v` output |
| Boot | `mokutil --sb-state`, the kernel's loaded X.509 certificates |

!!! analogy "Think of it like a bottling plant"
    Red Hat brews the recipe. Rocky runs an independent bottling plant: it receives the recipe, swaps the labels, bottles it in a clean room, seals every bottle with a tamper-evident cap (the GPG signature), and ships it through a network of distributors (mirrors). You, the customer, can check the seal on every bottle. Where the analogy breaks: Rocky can also add its own bottles (extras, SIGs) and cannot always get the recipe on the same day Red Hat uses it.

### Words you'll see

| Word | Plain meaning |
|---|---|
| **upstream** / **downstream** | Where code comes from / who rebuilds it. RHEL is upstream of Rocky |
| **rebuild** | A distribution compiled from another's source, like Rocky from RHEL |
| **SRPM** | Source RPM: the original source plus the spec file that says how to build it |
| **debranding** | Replacing Red Hat trademarks while changing nothing functional |
| **build system** | The service that turns sources into RPMs reproducibly (Koji, Peridot) |
| **mock** | The tool that builds one package in a fresh, minimal chroot |
| **dist tag** | The end of the `Release` field, like `.el10_2`, saying which release it was built for |
| **GPG signature** | The tamper-evident seal on each RPM, made with Rocky's private key |
| **fingerprint** | The long ID of a key, checked out of band to prove the key is genuine |
| **repository** | A directory of RPMs plus metadata that DNF reads |
| **mirror** | A server that copies Rocky's repos; it cannot forge signatures |
| **vault** | Frozen trees of old minor releases, kept but not updated |
| **erratum** / **RLSA** | A published update with a description; RLSA is a security one |
| **SIG** | Special Interest Group: a community team shipping extra content |

### The core skill: read a package's fingerprints

The skill this module builds is tracing any package back through the pipeline.
Put what you find into one sentence:

> **"`<package>` was built by `<vendor>` for `<release>`, signed with key `<id>`, and came from repo `<repo>`."**

If any part of that sentence surprises you (a vendor you don't know, a missing
key, a repo you never enabled), you've found something worth a closer look.

Try these three. Each uses output you'll meet again later in the module.

**Output A** (from `rpm -qi`; on Rocky 10 the signature value sits on the line after its label):

```text
Signature   :
              RSA/SHA256, Fri 14 Aug 2026 10:23:09 AM UTC, Key ID 5b106c736fedfc85
Source RPM  : rocky-release-10.2-1.2.el10.src.rpm
Vendor      : Rocky Enterprise Software Foundation
```

??? success "Answer A"
    "`rocky-release` was built by the RESF for Rocky 10 (`.el10`), signed
    with key `6fedfc85`." That short ID is the end of the Rocky Linux 10
    release key. Nothing surprising: this is an official Rocky package.

**Output B** (from `rpm -qa --qf '%{VENDOR}\t%{NAME}\n'`):

```text
Fedora Project	htop
```

??? success "Answer B"
    "`htop` was built by the Fedora Project." That means EPEL, not Rocky. Not
    wrong in itself, but it is outside the RHEL-compatible promise, and it
    trusts a second key (EPEL's). `dnf info --installed htop` will show the
    repo it came from.

**Output C** (from `rpm -q kernel bash`):

```text
kernel-6.12.0-211.74.1.el10_2.x86_64
bash-5.2.26-6.el10.x86_64
```

??? success "Answer C"
    Read the dist tags. `bash` ends in `.el10`: built for Rocky 10 and
    unchanged since. The kernel ends in `.el10_2`: updated during the 10.2
    lifecycle. Neither tells you the repo or signature; for those, add
    `rpm -qi` and `dnf info --installed`.

Notice the pattern. **Vendor** says who built it, **dist tag** says for which
release, **Key ID** says who sealed it, **From repo** says where you got it.
Four fields, four questions.

## Where the source comes from

!!! tip "Go deeper in the series"
    [Module 45](45-pipeline-source-to-build.md) follows one package from Red Hat's source to a Koji build, one public command at a time.

### A short history

Rocky exists because of a change of plan. In December 2020, Red Hat announced that CentOS Linux, the free RHEL rebuild many people relied on, would end and be replaced by **CentOS Stream**, a rolling preview of the *next* RHEL minor release. Gregory Kurtzer, a co-founder of the original CentOS project, started Rocky Linux the same week. Rocky 8.4 was the first general release in June 2021.

??? question "For the curious: how Rocky got its source, year by year"
    ```mermaid
    flowchart TB
        T0["<b>2020</b><br/>CentOS Linux 8 end announced<br/>Rocky Linux project starts"]
        T1["<b>2021</b><br/>Rocky 8.4 GA, built with Koji<br/>Sources imported from git.centos.org"]
        T2["<b>2022</b><br/>Rocky 9.0 GA, built with Peridot<br/>RESF charter adopted"]
        T3["<b>2023</b><br/>Red Hat stops publishing RHEL sources to git.centos.org<br/>Rocky switches to multiple source routes"]
        T4["<b>2025</b><br/>Rocky 10.0 GA<br/>Early Rocky 10 content built in Peridot, Koji from 2025-05-16"]
        T4b["<b>Nov 2025</b><br/>Rocky 9.7: Rocky 9 builds move to Koji"]
        T5["<b>2026</b><br/>Rocky 10.2 GA (May)"]
        T0 --> T1 --> T2 --> T3 --> T4 --> T4b --> T5
    ```

### The 2023 change and Rocky's response

Until mid-2023, Red Hat published the exact source of every RHEL package to **git.centos.org**, and every rebuilder imported from there. In June 2023 Red Hat stopped doing that. The public source of truth became **CentOS Stream**, and the exact RHEL sources were made available only to Red Hat customers, under terms that discourage redistribution.

Rocky's published response ("Keeping Open Source Open", 2023) named several legal routes it could use. The post says these approaches are subject to change, and Rocky has not published which route supplies which package today:

- **CentOS Stream** git repositories, which hold most of the same changes, often before RHEL ships them.
- **RHEL source RPMs** obtained through the **Universal Base Image (UBI)** container images, which are freely redistributable and come with sources.
- **Pay-per-use public cloud RHEL instances**: Rocky's position is that the GPL gives a paying customer the right to the source.
- **Pristine upstream** project tarballs where needed.

!!! note "Why this matters to you"
    The sourcing route affects *timing*, not what lands on your disk. Rocky's stated target is to publish an update within 24 to 48 hours after Red Hat's release, as a best effort, not a guarantee. In practice the delay you see comes from import, build, compose and staging work (and, in 2026, the separate Secure Boot build environment), not from obtaining the source. That is the main reason to watch errata (covered below) rather than assume "same day as Red Hat".

### The ecosystem: who builds what from where

Four distributions share the Enterprise Linux family tree. They differ mainly in where they get source and what compatibility they promise.

| Distribution | Relationship to RHEL | Source | Compatibility goal |
|---|---|---|---|
| **CentOS Stream** | Upstream of RHEL: the next minor release, in development | Red Hat's own development | Preview of what RHEL will become |
| **RHEL** | The product | Red Hat | Reference |
| **Rocky Linux** | Downstream rebuild | CentOS Stream + RHEL SRPMs (UBI, cloud) + upstream | Match RHEL closely: Rocky's stated goal is bug-for-bug compatibility, with a few named exceptions |
| **AlmaLinux** | Downstream rebuild | Mainly CentOS Stream since 2023 | Application binary (ABI) compatible; may ship fixes earlier or differ in small ways |
| **Oracle Linux** | Downstream rebuild | Oracle's own sourcing | RHEL-compatible kernel plus its own UEK kernel option |

In August 2023, CIQ, Oracle and SUSE also formed **OpenELA** (the Open Enterprise Linux Association) to publish Enterprise Linux sources openly. Rocky's August 2023 statement says that multiple Rocky Linux and RESF members joined OpenELA, but OpenELA itself lists only CIQ, Oracle and SUSE as founders, and public sources do not show whether the RESF as an organisation is a member. Treat OpenELA as a sibling effort that happens to share a sponsor (CIQ), not as "Rocky's source".

!!! version "Hardware baseline on 10"
    RHEL 10, and therefore Rocky 10, requires the **x86-64-v3** microarchitecture level on Intel/AMD (roughly Haswell-era CPUs and later). AlmaLinux publishes an extra x86-64-v2 build of version 10. Rocky 10 also adds **riscv64** as an architecture. If an old server will not boot Rocky 10, check its CPU level before anything else.

### Who runs Rocky: the RESF

The **Rocky Enterprise Software Foundation (RESF)** is the organisation that owns the Rocky Linux project and its infrastructure. It is a Delaware public benefit corporation with a published charter (adopted November 2022) that limits how much any single company can control the project. Companies such as CIQ sponsor the work and sell support, but the distribution itself is the RESF's. You will see "RESF" in the `VENDOR_NAME` field of `/etc/os-release` and in package `Vendor` fields.

<div class="quiz" data-answer="3" markdown>

After June 2023, which statement about Rocky's sources is accurate?

- Rocky now builds exclusively from CentOS Stream
- Rocky stopped publishing source code
- Rocky collects RHEL sources through several routes (CentOS Stream, UBI images, cloud RHEL instances, upstream)
- Rocky receives sources directly from Red Hat under a partnership

Right. git.centos.org no longer carries every RHEL version, so Rocky's 2023 statement names several legal routes for assembling the matching sources. It still publishes all of its own sources.

</div>

## Importing and debranding

!!! tip "Go deeper in the series"
    [Module 45](45-pipeline-source-to-build.md) reads a real debranding patch and the landing-zone repository it starts from.

### What debranding means

RHEL's sources contain Red Hat trademarks: logos, the name "Red Hat Enterprise Linux" in installer screens, release files, URLs pointing to Red Hat's bug tracker and support portal. Redistributing those would violate the trademarks. **Debranding** is the process of replacing them while changing nothing functional.

Most packages need no change at all. A small list (a few dozen) needs patches. Typical changes:

| What | Example |
|---|---|
| Release identity | `redhat-release` is replaced by `rocky-release` (provides `/etc/os-release`, `/etc/rocky-release`) |
| Artwork | `redhat-logos` replaced by `rocky-logos` (boot splash, installer, desktop) |
| Installer branding | Anaconda product name, help links, the installer's product config |
| URLs | Bug report and documentation links pointing at `bugs.rockylinux.org`, `docs.rockylinux.org` |
| Secure Boot | `shim` and the kernel/GRUB signing keys are Rocky's own, not Red Hat's |
| Repository config | `.repo` files pointing at Rocky mirrors, with Rocky's GPG keys |

### How the import works

Rocky's import tool is **pv2** (written in Python). Red Hat's source first lands, unmodified, in a public "landing zone" repository on Rocky's Git server (`staging/src-rhel/rpms/PACKAGE`). pv2 then checks whether a matching **patch repository** exists. A patch repo holds small YAML config files that list actions (for example `replace_file`, `add_file`, `delete_file`, `apply_patch`, `search_and_replace`, `append_release`) plus any replacement files. pv2 applies them and commits the result to Rocky's own Git (`staging/rpms/PACKAGE`, branch `r10`), which is the input to the build system. Large source tarballs are kept in a separate **lookaside** store keyed by checksum, so Git itself stays small.

Before pv2, Rocky used **srpmproc**, an earlier tool written in Go. Its repository was archived in June 2025, and commits made by pv2 on Rocky 10 branches in 2026 say `(pv2) (patched by pv2)` in their subject line.

```mermaid
flowchart TB
    U["Upstream package source<br/>(landing-zone repo)"] --> S["pv2 import"]
    P["patch repo for PACKAGE<br/>(YAML: replace / add / delete / patch)"] -.->|"only if it exists"| S
    S --> R["Rocky Git: rpms/PACKAGE<br/>(branch r10)"]
    R --> B["Build system"]
```

The good news: you can see the outcome on any installed package.

```console
$ rpm -qi rocky-release
Name        : rocky-release
Version     : 10.2
Release     : 1.2.el10
Architecture: noarch
Install Date: Mon 17 Aug 2026 10:41:17 AM UTC
Group       : System Environment/Base
Size        : 30471
License     : BSD-3-Clause
Signature   :
              RSA/SHA256, Fri 14 Aug 2026 10:23:09 AM UTC, Key ID 5b106c736fedfc85
Source RPM  : rocky-release-10.2-1.2.el10.src.rpm
Build Date  : Fri 14 Aug 2026 10:01:15 AM UTC
Build Host  : …
Packager    : Rocky Linux Build System <releng@rockylinux.org>
Vendor      : Rocky Enterprise Software Foundation
URL         : https://rockylinux.org
Bug URL     : https://bugs.rockylinux.org
Summary     : Rocky Linux release files
…
```

The `Key ID` ends in `6fedfc85`, the short ID of the Rocky Linux 10 release key. You will verify that key properly later in this module.

Notice that the signature value is on its own line, after the `Signature   :` label. That means `rpm -qi PKG | grep Signature` prints only the label. For one clean line, ask rpm directly: `rpm -q --qf '%{RSAHEADER:pgpsig}\n' PKG`. The `Packager` line is another fingerprint: it names the build system (see the next section).

!!! tip "Find every non-Rocky package on a system"
    The `Vendor` tag is a quick audit. Anything not from the RESF came from a third party (EPEL, a vendor repo, a hand-built RPM):

    ```console
    $ rpm -qa --qf '%{VENDOR}\t%{NAME}\n' | grep -v '^Rocky Enterprise' | sort | head
    (none)	gpg-pubkey
    Fedora Project	epel-release
    Fedora Project	htop
    ```

    `gpg-pubkey` entries are imported keys, not software, so `(none)` is expected there.

## The build system

!!! tip "Go deeper in the series"
    [Module 45](45-pipeline-source-to-build.md) reads Koji's data model and the three kinds of build host, and [module 50](50-build-your-own-koji.md) builds a small Koji of your own.

### Koji, Peridot and mock

A **build system** takes a source package and produces binary RPMs in a clean, recorded, repeatable way. It keeps track of which exact versions of compilers and libraries were used (the **buildroot**), runs builds in parallel across architectures, and stores the results.

| Rocky version | Build system |
|---|---|
| Rocky 8 | **Koji**, the build system Fedora and CentOS use |
| Rocky 9 | **Peridot**, a cloud-native build system written in Go by the Rocky community, for 9.0 to 9.6. **Koji** from 9.7 (November 2025) |
| Rocky 10 | Started in **Peridot**; builds moved to **Koji** on 2025-05-16 |

Rocky's 10.0 announcement describes Rocky 10 as a Koji build: the next generation of Peridot ("Peridot Two") was not ready, and Rocky wanted to support **IMA** (the kernel's Integrity Measurement Architecture, which can check per-file signatures at runtime), which Koji's signing integration made practical. The packages themselves add a detail: the Rocky 10.0 release set was built on Peridot build hosts (names like `pb-<uuid>-b-x86-64`), and Koji-built packages start on 2025-05-16. Peridot Two is planned as a reimplementation of Koji's XML-RPC API, so Koji clients and builds can move across later.

Peridot is now legacy for the main distribution: Rocky 9.7 and 9.8 are built in Koji too. Rocky has not said whether any SIG still builds in Peridot.

Peridot's fingerprints are still on installed packages. As of 2026-11-06 (x86_64 repos, counting old retained versions), 8.6% of the RPM files in Rocky 10 BaseOS (276 of 3,194) and 35.7% of those in AppStream (2,741 of 7,672) carry a Peridot build host; for Rocky 9 BaseOS it is 13.3% (492 of 3,689). The share falls as packages are rebuilt. Re-check on your own machine: `rpm -qa --qf '%{PACKAGER}\n' | sort | uniq -c`. `Rocky Linux Build System (Peridot)` is a Peridot build, plain `Rocky Linux Build System` is Koji, and `Release Engineering` is the kernel and Secure Boot set described below.

??? question "Under the hood: does my Rocky 10 package carry IMA file signatures?"
    It depends on when the package was signed, so ask rpm rather than assume. IMA signatures live in the package header, one per file, in the `FILESIGNATURES` tag:

    ```console
    $ rpm -q --qf '[%{FILESIGNATURES}\n]' bash | grep -c .
    124
    $ rpm -q --qf '[%{FILESIGNATURES}\n]' kernel-core-6.12.0-211.74.1.el10_2 | grep -c .
    0
    $ rpm -q --qf '[%{FILENAMES} %{FILESIGNATURES}\n]' bash | head -3
    ```

    Packages Rocky signed up to early 2026-03-17 (UTC) carry per-file signatures, as `bash` does. Packages signed from 2026-03-25 carry none, as the current kernel and `dnf` show. I found no Rocky announcement explaining the change, so treat IMA signing as something Rocky did and then stopped, not as a current feature. (A few packages that contain only directories, such as `efi-filesystem`, have the tag but an empty value for every entry.)

    If the second column of the last command is empty, the package has no IMA signatures and an IMA appraisal policy would reject its files. If it holds long hex strings, they are there, and `rpm-plugin-ima` writes them into each file's `security.ima` extended attribute at install time (check with `getfattr -m security.ima -d /usr/bin/bash`). Nothing enforces them unless you load an IMA appraisal policy: signing and enforcement are separate decisions.

Underneath both sits **mock**, a tool that creates a fresh minimal chroot, installs only the declared build dependencies, and runs `rpmbuild` inside it. A Koji or Peridot "build" is essentially an orchestrated mock run with careful bookkeeping. You will use mock yourself in [module 22](22-building-rpms.md).

```mermaid
flowchart TB
    G["Rocky Git<br/>rpms/openssl @ el10"] --> K["Koji hub<br/>(schedules build)"]
    K --> B1["Builder x86_64<br/>mock chroot"]
    K --> B2["Builder aarch64<br/>mock chroot"]
    K --> B3["Builders ppc64le, s390x, riscv64"]
    B1 & B2 & B3 --> O["Unsigned RPMs + logs"]
    O --> SG["Signing service<br/>(RSA key; IMA until 2026-03)"]
    SG --> C["Compose into repos"]
```

!!! note "Why builds must be clean"
    If a package were built on a developer's laptop, it might accidentally link against some library that happened to be installed there. A clean mock buildroot means the RPM depends only on what its spec file declares. That is what makes a rebuild trustworthy, and what makes close compatibility with RHEL possible at all.

!!! note "Secure Boot packages are built apart"
    The kernel, `grub2`, `shim` and `fwupd` are not built on the normal Koji builders. Rocky builds them in a separate, isolated Secure Boot environment (a Koji channel restricted by permission), so the signing keys stay contained, and people import the results. Their `Packager` is `Release Engineering`, and they are signed with the RPM key hours after the build.

### Release tags tell you the minor release

The `Release` field of almost every package ends in a **dist tag** set by the build system's `%{dist}` macro. On Rocky 10 you see three forms:

| Dist tag | Meaning |
|---|---|
| `.el10` | Built for the 10 major release, unchanged since it was introduced |
| `.el10_1`, `.el10_2` | Rebuilt or updated during that minor release's lifecycle |
| `.rocky.0.N` (for example `.el10_2.rocky.0.1`) | Rocky itself changed this package (a debranding patch or a local change). `dnf-4.20.0-22.el10_2.rocky.0.1` is one. No suffix means a straight rebuild |

```console
$ rpm -q kernel libxml2 bash
kernel-6.12.0-211.74.1.el10_2.x86_64
libxml2-2.12.5-9.el10_0.x86_64
bash-5.2.26-6.el10.x86_64
```

<div class="quiz" data-answer="2" markdown>

An installed Rocky 10.2 package shows `Build Host: pb-0d1a2830-…-b-x86-64` and `Packager: Rocky Linux Build System (Peridot)`. What does that tell you?

- It was built recently on a Koji builder
- It was built in Peridot, on or before 2025-05-16, and has not been rebuilt since
- It was built by a third party outside Rocky
- It is one of the kernel or Secure Boot packages

Correct. The `pb-` build host and the `(Peridot)` packager are Peridot's fingerprints. Koji-built packages start on 2025-05-16, and recent Koji builds carry a different packager string. The kernel and Secure Boot packages use `Release Engineering`.

</div>

## Release packages and identity files

Three small packages define "this machine is Rocky Linux":

| Package | What it installs |
|---|---|
| `rocky-release` | `/etc/os-release`, `/etc/rocky-release`, the `/etc/redhat-release` and `/etc/system-release` symlinks, presets and macros |
| `rocky-repos` | The `.repo` files in `/etc/yum.repos.d/` and DNF variables in `/etc/dnf/vars/` |
| `rocky-gpg-keys` | Public signing keys in `/etc/pki/rpm-gpg/` |

```console
$ rpm -qf /etc/os-release /etc/yum.repos.d/rocky.repo /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
rocky-release-10.2-1.2.el10.noarch
rocky-repos-10.2-1.2.el10.noarch
rocky-gpg-keys-10.2-1.2.el10.noarch
$ ls -l /etc/redhat-release /etc/system-release
lrwxrwxrwx. 1 root root 13 Aug 10 00:00 /etc/redhat-release -> rocky-release
lrwxrwxrwx. 1 root root 13 Aug 10 00:00 /etc/system-release -> rocky-release
$ cat /etc/rocky-release
Rocky Linux release 10.2 (Red Quartz)
```

`/etc/os-release` is the machine-readable identity, defined by systemd's [[man:os-release(5)]]. Scripts should read it rather than parse `/etc/redhat-release`:

```console
$ cat /etc/os-release
NAME="Rocky Linux"
VERSION="10.2 (Red Quartz)"
ID="rocky"
ID_LIKE="rhel centos fedora"
VERSION_ID="10.2"
PLATFORM_ID="platform:el10"
PRETTY_NAME="Rocky Linux 10.2 (Red Quartz)"
…
HOME_URL="https://rockylinux.org/"
VENDOR_NAME="RESF"
BUG_REPORT_URL="https://bugs.rockylinux.org/"
SUPPORT_END="2035-05-31"
ROCKY_SUPPORT_PRODUCT="Rocky-Linux-10"
…
$ . /etc/os-release; echo "$ID $VERSION_ID (like: $ID_LIKE)"
rocky 10.2 (like: rhel centos fedora)
```

`ID_LIKE` is what lets installers for "RHEL-like" systems recognise Rocky. `PLATFORM_ID` is what DNF uses to match the platform. `SUPPORT_END` reflects Rocky 10's lifecycle: general support until May 2030 and security fixes until 31 May 2035.

## Repositories, mirrors and the vault

!!! tip "Go deeper in the series"
    [Module 46](46-pipeline-compose-to-your-server.md) follows a signed build through the compose, staging, production and the mirrors.

### The repository map

A **repository** is a directory of RPMs plus metadata (`repodata/`) that DNF downloads to know what is available. Rocky splits its content into several, each with a purpose:

<div class="layers" data-open="0" data-hint="Click a repository to see what lives there and when you'd enable it." markdown>

<div class="layer" data-label="BaseOS" data-tag="enabled" markdown>

**Repo ID:** `baseos`. The core operating system: kernel, systemd, glibc, bash, coreutils, openssh, dnf, NetworkManager. Packages here follow the full RHEL lifecycle and are what a minimal install is made of.

</div>

<div class="layer" data-label="AppStream" data-tag="enabled" markdown>

**Repo ID:** `appstream`. Applications, languages, databases and tools: httpd, nginx, postgresql, python3 extras, podman, gcc. On Rocky 10 there are no DNF **modules** in the default content; alternative versions ship as separately named packages.

</div>

<div class="layer" data-label="CRB" data-tag="disabled" markdown>

**Repo ID:** `crb` (CodeReady Linux Builder; called PowerTools on Rocky 8). Development headers and build-time libraries that RHEL ships but does not support for production use. Many EPEL packages require it. Enable with `sudo dnf config-manager --set-enabled crb` or `sudo crb enable` (from `epel-release`).

</div>

<div class="layer" data-label="extras" data-tag="enabled" markdown>

**Repo ID:** `extras`. Rocky-added packages that do not exist in RHEL but do not conflict with it: `epel-release`, SIG release packages (`rocky-release-*`), and similar helpers. Not tested by upstream.

</div>

<div class="layer" data-label="Add-ons" data-tag="disabled" markdown>

**HighAvailability** (Pacemaker, Corosync; see [module 28](28-high-availability.md)), **RT** (real-time kernel), **NFV** (network functions virtualization), **SAP** and **SAPHANA**. These mirror RHEL add-ons. ResilientStorage existed on 8 and 9 but is not part of Rocky 10.

</div>

<div class="layer" data-label="plus" data-tag="disabled" markdown>

**Repo ID:** `plus`. Rocky-built variants of upstream packages with extra features enabled (for example, options RHEL compiles out). Installing from here intentionally diverges from RHEL.

</div>

<div class="layer" data-label="devel" data-tag="disabled" markdown>

**Repo ID:** `devel`. Everything the build system had in its buildroots, including packages RHEL does not ship. Its own name in the repo file warns "FOR BUILDROOT ONLY DO NOT LEAVE ENABLED". Use it with `--enablerepo=devel` for a single build, never permanently.

</div>

<div class="layer" data-label="debuginfo and source" data-tag="disabled" markdown>

Every repo has a debug twin (`baseos-debuginfo`, …) holding the symbols you need for crash analysis ([module 24](24-debugging-crashes.md)), and a source twin (`baseos-source`, …) holding SRPMs. `dnf debuginfo-install` and `dnf download --source` enable these on demand, because they look for repos whose IDs end in `-debuginfo` and `-source`.

</div>

</div>

Check what your system knows about:

```console
$ dnf repolist --all
repo id                    repo name                                       status
appstream                  Rocky Linux 10 - AppStream                      enabled
appstream-debuginfo        Rocky Linux 10 - AppStream - Debug              disabled
appstream-source           Rocky Linux 10 - AppStream - Source             disabled
baseos                     Rocky Linux 10 - BaseOS                         enabled
baseos-debuginfo           Rocky Linux 10 - BaseOS - Debug                 disabled
baseos-source              Rocky Linux 10 - BaseOS - Source                disabled
crb                        Rocky Linux 10 - CRB                            disabled
…
extras                     Rocky Linux 10 - Extras                         enabled
highavailability           Rocky Linux 10 - High Availability              disabled
…
```

!!! tip "Trust the repo IDs on your machine"
    Repo IDs have changed between releases (for example `ha` on Rocky 8), and other tools use their own names: mock's Rocky configs call the debug repo `baseos-debug`. Always copy the ID from `dnf repolist --all` on the system in front of you before scripting `--enablerepo`.

`rocky-repos` splits these across five files: `rocky.repo` (BaseOS, AppStream, CRB and their twins), `rocky-addons.repo` (HighAvailability, RT, NFV, SAP, SAPHANA), `rocky-extras.repo` (extras and plus), `rocky-devel.repo` (devel) and `rocky-security.repo` (`security`, disabled by default). `ls /etc/yum.repos.d/` shows them.

The `security` repo is easy to misread. Rocky describes it as an opt-in, temporary **hotfix** repo for the narrow case of a critical vulnerability that is being actively exploited, with public proof-of-concept code and no upstream fix yet. Rocky says it is not a general-purpose fast-track channel, its packages carry no errata records, and they are superseded by the next upstream release. It exists for Rocky 8, 9 and 10, and you turn it on deliberately, for example with `sudo dnf --enablerepo=security update`.

### Anatomy of a repo file

```ini title="/etc/yum.repos.d/rocky.repo (excerpt)"
[baseos]
name=Rocky Linux $releasever - BaseOS
mirrorlist=https://mirrors.rockylinux.org/mirrorlist?arch=$basearch&repo=BaseOS-$releasever$rltype
#baseurl=http://dl.rockylinux.org/$contentdir/$releasever/BaseOS/$basearch/os/
gpgcheck=1
enabled=1
countme=1
metadata_expire=6h
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
```

1. `mirrorlist=…`: DNF asks the **mirrorlist** service for a list of mirrors near you. `$releasever` is `10` (the major version), so you always get the latest minor release. `$rltype` is a DNF variable from `/etc/dnf/vars/` that lets a variant (for example a cloud image) ask for a different repo flavour; on a normal install it is empty. The debug and source twins use the same URL with `-debug` or `-source` appended to the repo name (and `arch=source` for sources).
2. `#baseurl=…`: The commented-out direct URL. Uncomment it (and comment out `mirrorlist`) to pin a single server, for example an internal mirror.
3. `gpgcheck=1`: Refuse to install any package whose GPG signature does not verify.
4. `countme=1`: Once a week DNF adds an anonymous counter to one request, which is how the project estimates its user count.
5. `gpgkey=…`: The public key used to check signatures, installed by `rocky-gpg-keys`.

DNF variables like `$contentdir` and `$rltype` come from small files:

```console
$ grep -H . /etc/dnf/vars/*
/etc/dnf/vars/contentdir:pub/rocky
…
```

### How mirrors work

Rocky serves content from **dl.rockylinux.org** and from volunteer mirrors worldwide (about 150 active public mirrors; 152 on 2026-11-06 and 153 on 2026-11-07; re-check with `curl -s https://mirrors.rockylinux.org/mirrormanager/mirrors | grep -o 'We have currently [0-9]* active'`). Mirrors register with **MirrorManager** (the same software Fedora uses), which keeps the mirror list and hands DNF a list of mirror URLs for your location.

```mermaid
sequenceDiagram
    participant D as dnf (your server)
    participant M as mirrors.rockylinux.org
    participant X as Nearby mirror
    D->>M: GET /mirrorlist?arch=x86_64&repo=BaseOS-10
    M-->>D: list of up-to-date mirror URLs (by location)
    D->>X: GET repodata/repomd.xml
    X-->>D: repomd.xml (checksums of all metadata)
    D->>X: GET primary, filelists, updateinfo …
    D->>X: GET Packages/l/libxml2-….rpm
    Note over D: verify checksum against metadata,<br/>then GPG signature against Rocky key
```

Because every package is GPG-signed, a malicious or broken mirror cannot slip you a modified package: the signature check fails. The worst a bad mirror can do is serve stale content or nothing at all.

You can see which mirrors DNF is using, how fresh the metadata is, and which file defines the repo:

```console
$ dnf repoinfo baseos
Last metadata expiration check: 0:56:05 ago on Fri 06 Nov 2026 11:05:58 PM UTC.
Repo-id            : baseos
Repo-name          : Rocky Linux 10 - BaseOS
Repo-status        : enabled
Repo-revision      : 10.2
…
Repo-updated       : Fri 06 Nov 2026 08:03:08 AM UTC
Repo-pkgs          : 3,194
Repo-available-pkgs: 3,194
Repo-size          : 22 G
Repo-mirrors       : https://mirrors.rockylinux.org/mirrorlist?arch=x86_64&repo=BaseOS-10
Repo-baseurl       : https://<mirror-host>/pub/rocky//10.2/BaseOS/x86_64/os/ (37 more)
Repo-expire        : 21,600 second(s) (last: Fri 06 Nov 2026 10:53:46 PM UTC)
Repo-filename      : /etc/yum.repos.d/rocky.repo
```

These numbers are from an x86_64 machine on 2026-11-06 and will differ on yours: the package count includes old retained versions and grows over time, and aarch64 shows a different count. The mirror host differs per request. `Repo-revision` is Rocky's release label (`10.2`), not a timestamp.

### The tree on the server

```text
dl.rockylinux.org/pub/rocky/
└── 10/                       ← symlink to the current minor, e.g. 10.2
    ├── BaseOS/
    │   ├── x86_64/
    │   │   ├── os/           ← the repo DNF uses (Packages/, repodata/)
    │   │   ├── kickstart/    ← frozen GA tree, used by installers
    │   │   └── debug/tree/   ← debuginfo packages
    │   └── source/tree/      ← SRPMs
    ├── AppStream/  CRB/  extras/  plus/  security/  HighAvailability/  RT/  NFV/  SAP/  SAPHANA/  devel/
    └── isos/  images/        ← install ISOs, cloud and container images
dl.rockylinux.org/vault/rocky/
└── 10.0/  10.1/  9.x/ …      ← old minor releases, frozen
dl.rockylinux.org/pub/sig/    ← Special Interest Group repos
```

### The vault

Rocky supports only the **latest minor release** of each major version. When 10.2 ships, 10.1 stops receiving updates and, shortly afterwards, its tree moves to the **vault** at `dl.rockylinux.org/vault/rocky/`. Nothing is deleted: you can still fetch every package ever published, which is invaluable for reproducing an old bug or rolling back. But vault content gets no fixes, so it is for investigation, not for running production.

!!! warning "Pinning a minor release is not a supported way to run Rocky"
    Setting `releasever=10.1` and pointing at the vault keeps you on 10.1 forever, *without* security fixes. If you need longer-lived minor releases, that is a commercial offering (for example, CIQ's LTS products), not something the community repos provide.

<div class="quiz" data-answer="4" markdown>

A teammate wants the exact `openssl` package that shipped with Rocky 10.0, which is no longer current. Where should they look?

- The `devel` repo
- `appstream-source`
- Nowhere; superseded packages are deleted
- `dl.rockylinux.org/vault/rocky/10.0/`

Yes. Superseded minor releases move to the vault, unchanged and still signed.

</div>

## Errata and security advisories

!!! tip "Go deeper in the series"
    [Module 46](46-pipeline-compose-to-your-server.md) queries Apollo and shows a kernel advisory that arrived after its package.

### RLSA, RLBA, RLEA

An **erratum** (plural **errata**) is a published update with a description: what it fixes, which CVEs, which packages. Rocky's errata mirror Red Hat's, with the same numbers:

| Prefix | Type | Red Hat equivalent |
|---|---|---|
| **RLSA** | Security advisory | RHSA |
| **RLBA** | Bug fix advisory | RHBA |
| **RLEA** | Enhancement advisory | RHEA |

So `RLSA-2026:1234` fixes the same problem as `RHSA-2026:1234`. Rocky's errata service (named **Apollo**) clones Red Hat's advisory data, matches it to the packages Rocky actually built, and writes it into each repo's `updateinfo` metadata. You can browse the same data on the web at **errata.rockylinux.org**.

### Querying errata with dnf

```console
$ dnf updateinfo summary
Updates Information Summary: available
    3 Security notice(s)
        1 Important Security notice(s)
        2 Moderate Security notice(s)
    2 Bugfix notice(s)
$ dnf updateinfo list --security
RLSA-2026:4511 Important/Sec. libxml2-2.12.5-10.el10_2.4.x86_64
RLSA-2026:4530 Moderate/Sec.  sudo-1.9.17-10.p2.el10_2.7.x86_64
…
$ dnf updateinfo info RLSA-2026:4511
===============================================================================
  Important: libxml2 security update
===============================================================================
  Update ID: RLSA-2026:4511
       Type: security
    Updated: 2026-10-08 19:22:41
       CVEs: CVE-2026-…
Description: The libxml2 library is a development toolbox providing the
           : implementation of various XML standards.
           : …
   Severity: Important
```

Useful variations:

```console
$ dnf updateinfo list --cve CVE-2026-XXXXX     # which advisory fixes this CVE?
$ sudo dnf upgrade --security                  # install only security updates
$ sudo dnf upgrade --advisory RLSA-2026:4511   # install exactly one advisory
$ dnf updateinfo list --installed --security   # advisories already applied
```

!!! pitfall "\"dnf upgrade --security\" says nothing to do, but plain upgrade finds updates"
    Errata metadata can lag behind the packages themselves, especially just after a minor release. A package may be in the repo before its advisory is attached. If compliance depends on it, run a full `dnf upgrade` on a schedule rather than only `--security`, and cross-check critical CVEs on errata.rockylinux.org.

## Signatures: trusting what you install

!!! tip "Go deeper in the series"
    [Module 47](47-trust-signatures-and-keys.md) shows what each `rpm -Kv` line protects and how Rocky's two key files differ.

### The chain of trust

Every Rocky RPM carries a **GPG signature**: a cryptographic seal made with Rocky's private key, which never leaves the signing service. Your system holds the matching **public key**. If even one byte of the package changes, the signature no longer matches.

```mermaid
flowchart TB
    PK["Rocky private key<br/>(signing service only)"] -->|signs| RPM["libxml2-….rpm<br/>signed header + payload<br/>(digest recorded in the header)"]
    KF["RPM-GPG-KEY-Rocky-10<br/>(rocky-gpg-keys)"] -->|imported into| DB["rpm database<br/>gpg-pubkey-6fedfc85"]
    RPM --> V{"rpm / dnf<br/>verify"}
    DB --> V
    V -->|match| OK["install"]
    V -->|mismatch or unknown key| NO["refuse"]
```

The question that matters: how do you know `RPM-GPG-KEY-Rocky-10` itself is genuine? You compare its **fingerprint** with the one Rocky publishes on its website (the "GPG Key Info" page) and in its release announcements, through a channel other than the mirror. The Rocky 10 key fingerprint is:

```text
FC22 6859 C086 0BF0 DDB9  5B08 5B10 6C73 6FED FC85
```

```console
$ sed -n '1,/END PGP/p' /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10 | gpg --show-keys
pub   rsa4096 2025-05-19 [SCE]
      FC226859C0860BF0DDB95B085B106C736FEDFC85
uid                      Release Engineering (Rocky Linux 10) <releng@rockylinux.org>
```

`gpg --show-keys` reads a key without importing it anywhere, so it is safe to run on any key you are evaluating. The `sed` part prints the file only up to the first `END PGP` line, so gpg sees just the first certificate. You need that on a fully updated system, because the key file can hold two certificates (next note).

!!! note "Which key file is which"
    The same file name exists in more than one version. `rocky-gpg-keys-10.2-1.1`, the version in the Rocky 10 cloud and container images, installs a 1,688-byte `/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10` with one RSA certificate, and plain `gpg --show-keys FILE` works on it. The August 2026 update `rocky-gpg-keys-10.2-1.2` installs an 18,586-byte file with **two** certificates: the same RSA key first, then a post-quantum key (ML-DSA-87 plus Ed448, an OpenPGP "v6" key). `https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-10` is the old one-certificate file, while the copy inside each repo tree (for example under `10/BaseOS/x86_64/os/`) is the two-certificate file.

    GnuPG 2.4, the version in Rocky 10, cannot read v6 keys and rejects the whole two-certificate file with `gpg: packet(6) with unknown version 6` and `Invalid keyring`. A newer GnuPG (2.5.24 was tested) does not abort, but it does not know the post-quantum algorithm, so it lists only the RSA key. The `sed` form above works with every version and is the fingerprint you compare with Rocky's website.

### Checking packages by hand

```console
$ dnf download libxml2
$ rpm -K libxml2-2.12.5-9.el10_0.x86_64.rpm
libxml2-2.12.5-9.el10_0.x86_64.rpm: digests signatures OK
$ rpm -Kv libxml2-2.12.5-9.el10_0.x86_64.rpm
libxml2-2.12.5-9.el10_0.x86_64.rpm:
    Header V4 RSA/SHA256 Signature, key ID 6fedfc85: OK
    Header SHA256 digest: OK
    Header SHA1 digest: OK
    Payload SHA256 digest: OK
    MD5 digest: OK
```

**Digests** prove the file is intact. **Signatures** prove who made it. If the key is not imported, you see `NOKEY`; if the file was modified, you see `BAD` or `NOT OK`.

??? question "Under the hood: why there is one signature and four digests"
    An RPM file is four parts in a row: a lead (legacy), a **signature header**, the **main header** (name, dependencies, file list, per-file digests) and the compressed **payload** (the files).

    - `Header V4 RSA/SHA256 Signature` covers only the main header. Because the main header stores the payload's SHA256 digest and every file's digest, a good header signature plus a good `Payload SHA256 digest` vouches for every byte. This is why `dnf` can verify a package before decompressing it.
    - The `Header SHA1` and `MD5` lines are legacy digests, kept so older rpm versions can still check the file. Older packages could also carry a second, legacy signature over header plus payload; Rocky 10 packages carry only the header signature. A good Rocky 10 package prints exactly the five lines above. A `Payload SHA256 ALT digest` line did not appear on good packages in our tests, only on a package whose payload had been tampered with.
    - After install, the per-file digests are what `rpm -V PKG` compares against your disk. That is how you detect a binary changed after installation, long after the package signature was checked.

    Since the August 2026 `rocky-gpg-keys-10.2-1.2` update, `RPM-GPG-KEY-Rocky-10` also holds a second, post-quantum (PQC) OpenPGP v6 key with the same user ID, appended after the RSA key in the same file. Packages are still signed with the RSA key (on 2026-11-06, every Rocky-signed package checked had only the RSA signature). The PQC certificate is self-certified, and Rocky's public key page lists only the RSA key. `grep -c BEGIN /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10` shows how many keys your copy holds.

Which keys does RPM trust right now?

```console
$ rpm -q gpg-pubkey --qf '%{VERSION}\t%{SUMMARY}\n'
6fedfc85	Release Engineering (Rocky Linux 10) …
e37ed158	Fedora (epel10) <epel@fedoraproject.org>
```

The `VERSION` of a `gpg-pubkey` pseudo-package is the short key ID. On a system with the two-certificate key file, `rpm -q gpg-pubkey` also lists a second line with `VERSION` `2ebba43f`, the post-quantum key. In our tests in November 2026 (DNF 4.20.0, x86_64 and aarch64) DNF's first-use import and `sudo rpmkeys --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10` both imported both certificates, although one earlier test saw only the first one, so check on your own build. To trust a new key (for example, your own repo's, from [module 22](22-building-rpms.md)):

```console
$ sudo rpm --import /path/to/RPM-GPG-KEY-mycorp
$ sudo rpm -e gpg-pubkey-<keyid>      # remove trust again
```

### gpgcheck, localpkg_gpgcheck, repo_gpgcheck

| Option | Where | What it checks |
|---|---|---|
| `gpgcheck=1` | each repo | Every package's signature before install (Rocky default) |
| `localpkg_gpgcheck` | `/etc/dnf/dnf.conf` | Signatures of local files given to `dnf install ./foo.rpm` (off by default) |
| `repo_gpgcheck=1` | each repo | A detached signature on the repo metadata (`repomd.xml.asc`), if the repo publishes one. Rocky publishes the `.asc` file, but its stock repo files do not set this option, so DNF does not check it unless you or a hardening tool turns it on |

!!! danger "Never fix NOKEY with --nogpgcheck"
    `dnf install --nogpgcheck` turns a security control into a formality. If a key is missing, find out why: is the package from a repo you did not intend to trust? Import the vendor's key only after checking its fingerprint out of band.

<div class="quiz" data-answer="1" markdown>

`rpm -Kv` on a downloaded package shows every digest line `OK`, but the signature lines end in `NOKEY`. What does that tell you?

- The file is intact, but its signing key is not in your RPM database, so you cannot yet tell who signed it
- The package has been tampered with
- The package is unsigned
- The mirror is out of date

Right. The digests match, so the file was not damaged. NOKEY means "signed, but by a key I don't trust yet". Find and verify that key before importing it.

</div>

## Secure Boot: the chain before the OS

!!! tip "Go deeper in the series"
    [Module 48](48-trust-secure-boot-and-reproducibility.md) reads the chain from firmware to a loaded kernel module with real signers and SBAT rows.

Signatures protect packages on disk. **Secure Boot** protects the boot path: the firmware runs only code signed by a key it trusts. PC firmware ships trusting Microsoft's keys, and Microsoft will not sign GRUB or Linux kernels directly. The solution is **shim**, a tiny first-stage boot loader.

```mermaid
flowchart LR
    FW["UEFI firmware<br/>trusts Microsoft UEFI CA"] -->|"verifies MS signature"| SH["shimx64.efi<br/>(Rocky build, signed by Microsoft)"]
    SH -->|"verifies with embedded Rocky CA<br/>(+ MOK list)"| GR["grubx64.efi<br/>(signed by Rocky)"]
    GR -->|"verifies via shim"| K["vmlinuz<br/>(signed by Rocky)"]
    K -->|"checks module signatures"| M["kernel modules<br/>(signed at build time)"]
```

1. Rocky builds shim with **Rocky's CA certificate embedded**, and Microsoft signs that shim binary after review, again for each new shim release.
2. The firmware trusts Microsoft, so it runs shim.
3. Shim trusts Rocky's CA, plus any keys you enrolled yourself in the **MOK** (Machine Owner Key) list, so it runs Rocky's GRUB and kernel.
4. The kernel checks signatures on modules it loads. Out-of-tree modules (NVIDIA, ELRepo, your own) need a key you enrolled with `mokutil --import`.

Rocky's own certificates have two lifetimes. The root CA embedded in shim is valid from 2021-06-20 to 2031-06-18. The leaf certificates under it, which sign GRUB, the kernel and other pieces, last one year and are renewed each spring by rebuilding those packages (the current set runs 2026-03-31 to 2027-03-31). Firmware does not check these dates, so expiry does not stop a machine booting. [Module 29](29-secure-boot-and-drivers.md#the-2011-to-2023-microsoft-certificate-transition) has the details.

See the boot flow in context in [module 14](14-the-boot-process.md).

```console
$ mokutil --sb-state
SecureBoot enabled
$ mokutil --list-enrolled | grep -E 'Subject:'
        Subject: …O=Rocky Enterprise Software Foundation, CN=Rocky Linux Secure Boot Root CA…
$ sudo keyctl list %:.platform
…: ---lswrv     0     0 asymmetric: Rocky Enterprise Software Foundation: Rocky Linux Secure Boot Root CA: …
…: ---lswrv     0     0 asymmetric: Microsoft Corporation: Microsoft Corporation UEFI CA 2011: …
$ sudo journalctl -k -b | grep -i 'Loaded X.509'
kernel: Loaded X.509 cert 'Rocky … kernel signing key: …'
kernel: integrity: Loaded X.509 cert 'Microsoft Corporation UEFI CA 2011: …'
…
```

`mokutil --db` and `mokutil --kek` show what the firmware itself trusts. The kernel copies the firmware `db` and the MOK list into its **platform keyring** at boot, which `keyctl` shows (from the `keyutils` package); exact certificate names vary between releases, so read them on your own machine.

??? question "Under the hood: why --list-enrolled shows a Rocky CA you never enrolled"
    Shim exports its built-in vendor certificate (Rocky's Secure Boot root CA) into the `MokListRT` UEFI variable alongside anything you enrolled, so the OS can see the whole set shim trusts. That is why `mokutil --list-enrolled` lists Rocky's CA on a fresh install, and also why it can come back **empty** on old shims or some hypervisors: the variable was not exported, but shim still trusts the CA internally. The keys you add with `mokutil --import` only take effect after the next reboot, when the blue **MokManager** screen asks for the one-time password you set. Nobody at the console means the key is never enrolled.

!!! warning "The Microsoft CA transition (2026)"
    Microsoft's original third-party UEFI CA (*Microsoft Corporation UEFI CA 2011*) is being replaced by 2023 CAs, and the 2011 certificates reached their scheduled expiry in 2026. In its June 2026 Secure Boot post, Rocky said it ships **dual-signed** shims, signed under both the 2011 and the 2023 CA. Expiry alone does not stop a signed shim from booting: Rocky's 2024 Secure Boot post explains that firmware has no reliable clock at that point, so it does not check certificate dates. The risks Rocky's 2026 post names are different. Whether a dual-signed shim boots depends on the firmware reading two signatures on one file, a shim signed only by the old CA fails on firmware where the old CA was removed, and new hardware ships with only the 2023 CAs. Rocky also warns against enrolling Microsoft's new keys by hand because it can brick a system. Keep `shim-x64` updated, check `mokutil --db` for the 2023 CA, and apply firmware updates from your hardware vendor. Module 29 covers this in depth.

!!! example "Try it"
    On a VM with UEFI and Secure Boot enabled, run `mokutil --sb-state` and `sudo dmesg | grep -i secure`. On a BIOS VM, `mokutil` reports that EFI variables are not supported: a quick way to tell how a machine booted.

## Special Interest Groups (SIGs)

Not everything belongs in a RHEL-compatible core. **Special Interest Groups** are community teams that build and maintain extra content on Rocky's infrastructure, published under `dl.rockylinux.org/pub/sig/` and installed via release packages from the `extras` repo.

| SIG | Focus |
|---|---|
| **SIG/AltArch** | Alternative architectures and devices not directly supported, such as Raspberry Pi images |
| **SIG/Cloud** | Running Rocky in and as public/private cloud images |
| **SIG/Kernel** | Alternative kernels (for example mainline or other long-term branches) and drivers |
| **SIG/Security** | Extra security features and hardened override packages |
| Others | Desktop and Gaming, FastTrack, HPC and AI, and more at various stages (the wiki lists which are active) |

```console
$ dnf search rocky-release
…
rocky-release-…  : … SIG repository configuration
…
```

Installing a SIG release package adds a `.repo` file and the SIG's GPG key. Treat SIG content like any third-party repo: it is Rocky infrastructure, but it is not part of the RHEL-compatible promise, and some SIG packages deliberately replace core ones.

!!! tip "Is a package from a SIG?"
    `dnf info --installed PACKAGE` shows `From repo`. A repo ID that is not `baseos`, `appstream`, `crb` or another core repo is your signal that you have left the core distribution.

## Verifying and rebuilding a package yourself

!!! tip "Go deeper in the series"
    [Module 45](45-pipeline-source-to-build.md) explains why a rebuild differs from the shipped package, and [module 49](49-build-your-own-packages-and-repo.md) rebuilds `which` exactly.

"Trust, but verify" applies to your OS. Because every Rocky source is published, you can inspect and rebuild any package.

```console
$ dnf download --source libxml2       # auto-enables the *-source repos
$ rpm -qpl libxml2-2.12.5-9.el10_0.src.rpm
libxml2-2.12.5.tar.xz
libxml2-2.12.5-CVE-….patch
…
libxml2.spec
$ rpm -qp --changelog libxml2-2.12.5-9.el10_0.src.rpm | head -4
* … - 2.12.5-9
- Fix CVE-…
```

The changelog tells you which CVE patch was added in which release. Rebuilding it in mock ([module 22](22-building-rpms.md)) and comparing the result with the binary from the mirror is how you prove the binary matches its source. Tools like `rpmdiff` (shipped with rpmlint, from EPEL) compare two RPMs file by file and flag differences in content, permissions or dependencies. Expect build timestamps and some embedded paths to differ; functional files should match.

### The journey of a security fix

Put it all together. Step through what happens between a vulnerability being found and the fix running on your server:

<div class="stepper" markdown>

<div class="step" data-title="Disclosure" markdown>

A researcher reports a flaw in, say, libxml2. It gets a **CVE** ID. The upstream project and Red Hat's security team coordinate a fix, often under embargo until a disclosure date.

</div>

<div class="step" data-title="Fix lands upstream" markdown>

Red Hat ships the fix in RHEL as an **RHSA** advisory with a new release number such as `2.12.5-10.el10_2.4`. For embargoed security fixes, third-party reports say the fix usually reaches RHEL before it appears in the public CentOS Stream repositories, so do not assume Stream shows it first. Rocky's own imports follow Red Hat's public releases. In one 2026 kernel case, Red Hat's advisory was issued on 9 July and the matching Rocky 10 advisory carries an issue time of 11 July. The public record shows the build and signing times in the package header, but not where the rest of the time went.

</div>

<div class="step" data-title="Rocky imports the source" markdown>

Rocky's tooling picks up the new source, writes it unmodified into the public landing-zone repo, runs pv2 to apply any debranding patches, and commits to Rocky Git.

```mermaid
flowchart LR
    A[RHEL / Stream source] --> B[landing-zone repo] --> C[pv2] --> D["Rocky Git (r10 branch)"]
```

</div>

<div class="step" data-title="Build" markdown>

Koji schedules builds for every architecture. Each builder runs mock with a clean buildroot. Logs and results are stored with the build. Kernel, shim, GRUB and fwupd builds happen separately in the isolated Secure Boot environment and are imported afterwards.

</div>

<div class="step" data-title="Sign" markdown>

The signing service signs each RPM with the Rocky 10 RSA key. Unsigned output never goes to the public repos. (Until 2026-03-17, packages also carried per-file IMA signatures.)

</div>

<div class="step" data-title="Publish and errata" markdown>

Signed builds are tagged into a compose tag, and **Pungi** (the compose tool Rocky uses as of 2026-11) turns that tag into a compose in about an hour. The compose holds only the newest packages. A separate staging sync (`syncv2`) merges it with the older packages already in the staging tree, adds errata from Apollo as **RLSA-2026:NNNN** in the updateinfo metadata (mirroring the RHSA number), signs `repomd.xml`, and swaps the tree in. After testing, the staging tree is promoted to production on dl.rockylinux.org. The errata record can arrive hours after the RPM does.

</div>

<div class="step" data-title="Mirrors" markdown>

Mirrors sync on their own schedules, so a client may reach a mirror that is still behind. Package signatures still protect it, and the update appears as each mirror catches up.

</div>

<div class="step" data-title="Your server" markdown>

`dnf upgrade --security` (or `dnf-automatic`) downloads the package, checks the checksum against metadata, verifies the GPG signature against `RPM-GPG-KEY-Rocky-10`, installs it, and records the transaction in `dnf history`.

```console
$ sudo dnf needs-restarting -r
```

Finally, restart the affected services (or reboot for kernel and glibc fixes). Until then, the old code is still running in memory.

</div>

</div>

<div class="quiz" data-answer="3" markdown>

You ran `dnf upgrade` for an OpenSSL advisory an hour ago. A scanner still reports the vulnerable library loaded in `nginx`. Most likely reason?

- The mirror served an old package
- The RLSA number doesn't match the RHSA
- nginx is still running with the old library mapped in memory; it needs a restart
- GPG verification silently failed

Exactly. Updating files on disk doesn't change running processes. `dnf needs-restarting` lists processes still using replaced files.

</div>

## Practice

<div class="terminal-sim" data-title="Interrogate a package" data-prompt="[alex@rocky-lab ~]$ " markdown>

<div class="task" data-expect="cat /etc/os-release" data-hint="The machine-readable OS identity lives in /etc/os-release." markdown>

**Step 1.** Print the machine-readable OS identity file.

```text
NAME="Rocky Linux"
VERSION="10.2 (Red Quartz)"
ID="rocky"
ID_LIKE="rhel centos fedora"
VERSION_ID="10.2"
PLATFORM_ID="platform:el10"
…
```

</div>

<div class="task" data-expect="rpm -qf /etc/os-release" data-hint="rpm -qf asks which package owns a file." markdown>

**Step 2.** Which package owns `/etc/os-release`?

```text
rocky-release-10.2-1.2.el10.noarch
```

</div>

<div class="task" data-expect="dnf info --installed libxml2||dnf info installed libxml2" data-match="^dnf info (--installed|installed) libxml2$" data-hint="dnf info with --installed shows the From repo field." markdown>

**Step 3.** Show details of the installed `libxml2`, including which repo it came from.

```text
Installed Packages
Name         : libxml2
Version      : 2.12.5
Release      : 9.el10_0
Architecture : x86_64
From repo    : baseos
…
```

</div>

<div class="task" data-expect="dnf updateinfo list --security" data-match="^dnf updateinfo list (--security|--sec-severity.*)$" data-hint="dnf updateinfo list, filtered with --security." markdown>

**Step 4.** List the available security advisories.

```text
RLSA-2026:4511 Important/Sec. libxml2-2.12.5-10.el10_2.4.x86_64
RLSA-2026:4530 Moderate/Sec.  sudo-1.9.17-10.p2.el10_2.7.x86_64
```

</div>

<div class="task" data-expect="mokutil --sb-state" data-hint="mokutil has an option that reports the Secure Boot state." markdown>

**Step 5.** Is Secure Boot on?

```text
SecureBoot enabled
```

</div>

</div>

## Labs

!!! lab "Lab 1: Verify the chain from fingerprint to package"

    **Goal:** Prove, with your own commands, that a package came from Rocky and was not modified.

    **You'll need:** a Rocky 10 VM with network access.

    1. Check the fingerprint of the key file shipped on your system and compare it with the fingerprint on Rocky's GPG Key Info page (open it in a browser on another machine):

        ```bash
        sed -n '1,/END PGP/p' /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10 | gpg --show-keys
        ```

        (The `sed` keeps only the first certificate, which is the RSA key packages are signed with. See "Which key file is which" above.)

    2. Confirm RPM trusts that key:

        ```bash
        rpm -q gpg-pubkey --qf '%{VERSION}\t%{SUMMARY}\n'
        ```

    3. Download a package without installing it and verify it:

        ```bash
        mkdir -p ~/lab21 && cd ~/lab21
        dnf download bash
        rpm -Kv bash-*.rpm
        ```

    4. Now break it on purpose. Copy the file and flip some bytes near the end, then verify again:

        ```bash
        cp bash-*.rpm broken.rpm
        printf 'XXXX' | dd of=broken.rpm bs=1 seek=$(( $(stat -c %s broken.rpm) - 100 )) conv=notrunc
        rpm -K broken.rpm
        ```

    5. Check what DNF would do with each repo: list the `gpgcheck` setting of every enabled repo:

        ```bash
        dnf repoinfo --enabled | grep -E '^Repo-id|^Repo-name'
        grep -H '^gpgcheck' /etc/yum.repos.d/*.repo
        ```

    **Check your work:** the original package shows `digests signatures OK`; `broken.rpm` shows a failed digest (`NOT OK`), and every enabled repo has `gpgcheck=1`.

    ??? success "What just happened?"
        The fingerprint check anchors your trust outside the mirror network. RPM then uses that key to check each package. Corrupting a few bytes of payload breaks the payload digest, which is covered by the signature, so the package would be refused by DNF.

    **Clean up:** `rm -rf ~/lab21`

!!! lab "Lab 2: Trace a package to its repo, transaction and advisory"

    **Goal:** Answer "where did this come from, when, and why?" for an installed package.

    **You'll need:** a Rocky 10 VM that has had at least one `dnf upgrade`.

    1. Pick a package that was updated (for example the kernel or any library) and see where it came from:

        ```bash
        dnf info --installed kernel-core | grep -E 'Version|Release|From repo'
        rpm -q --qf 'Signed: %{RSAHEADER:pgpsig}\nBuilt:  %{BUILDTIME:date}\nVendor: %{VENDOR}\n' kernel-core
        ```

    2. Find the transaction that installed it:

        ```bash
        dnf history list kernel-core
        sudo dnf history info <ID from the previous output>
        ```

    3. Find the advisory (if any) that delivered it:

        ```bash
        dnf updateinfo list --installed | grep kernel
        dnf updateinfo info <RLSA or RLBA ID>
        ```

    4. Compare with what the repo offers right now:

        ```bash
        dnf repoquery --show-duplicates kernel-core | tail -5
        ```

    **Check your work:** you can state the repo (`From repo`), the transaction ID and command line from `dnf history info`, and the advisory ID and severity.

    ??? tip "Hint"
        If `updateinfo list --installed` shows nothing for that package, the build may have shipped without an advisory (common at minor release boundaries). The changelog (`rpm -q --changelog kernel-core | head`) is the fallback evidence.

    **Clean up:** nothing to clean up; these are read-only queries.

!!! lab "Lab 3: Inspect the Secure Boot chain"

    **Goal:** See every link of the boot trust chain on a real machine.

    **You'll need:** a Rocky 10 VM booted with UEFI and Secure Boot enabled (with libvirt: `virt-install --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes …`, or tick "Enable Secure Boot" in your hypervisor).

    1. Check the state and the boot loader packages:

        ```bash
        mokutil --sb-state
        rpm -q shim-x64 grub2-efi-x64 kernel-core
        ls /boot/efi/EFI/rocky/
        ```

    2. See which keys shim and the firmware trust:

        ```bash
        mokutil --list-enrolled | grep -E 'Subject:|Not After'
        mokutil --db | grep -E 'Subject:' | head
        ```

    3. See which certificates the kernel loaded, and confirm that modules are signed:

        ```bash
        sudo journalctl -k -b | grep -i 'x.509'
        modinfo -F signer xfs
        cat /sys/kernel/security/lockdown
        ```

    **Check your work:** `SecureBoot enabled`; the kernel log shows Rocky's kernel signing key loaded; `modinfo` prints a Rocky signer; the lockdown file shows `[integrity]` selected (Secure Boot enables kernel lockdown).

    ??? success "What just happened?"
        You walked the chain from firmware trust (`--db`), through shim's embedded CA (`--list-enrolled`), to the kernel's keyring and module signatures. Kernel **lockdown** is the kernel's way of refusing actions (like loading unsigned modules) that would let root break the chain after boot.

    **Clean up:** nothing to clean up.

!!! lab "Lab 4: Browse the vault and compare minor releases"

    **Goal:** Query an older minor release's repo without changing your system's configuration.

    **You'll need:** a Rocky 10 VM with internet access.

    1. Look at the current `bash` in BaseOS:

        ```bash
        dnf repoquery --repo=baseos bash
        ```

    2. Query the 10.0 BaseOS repo from the vault, using a temporary repo defined on the command line:

        ```bash
        dnf --repofrompath=vault100,https://dl.rockylinux.org/vault/rocky/10.0/BaseOS/x86_64/os/ \
            --repo=vault100 repoquery bash kernel-core
        ```

    3. Download a package from the vault and verify it is signed by the same key:

        ```bash
        mkdir -p ~/lab21v && cd ~/lab21v
        dnf --repofrompath=vault100,https://dl.rockylinux.org/vault/rocky/10.0/BaseOS/x86_64/os/ \
            --repo=vault100 download bash
        rpm -Kv bash-*.rpm
        ```

    4. Notice what `--releasever` does: it only substitutes `$releasever` in the repo URLs. Compare:

        ```bash
        dnf --releasever=10 repoinfo baseos | grep -iE 'mirrors|baseurl'
        ```

    **Check your work:** the vault returns older versions (with `.el10` or `.el10_0` tags) than the current repo, and the vault package verifies with key ID `6fedfc85`.

    ??? question "Why not just use --releasever=10.0?"
        `--releasever=10.0` would ask the mirrorlist for `BaseOS-10.0`, but mirrors only carry the current minor release. Old minors live only in the vault, so you point a temporary repo at the vault URL instead. Nothing is written to `/etc/yum.repos.d/`.

    **Clean up:** `rm -rf ~/lab21v; sudo dnf clean all`

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `GPG check FAILED` / `NOKEY` on a third-party package | Vendor key not imported, or package from an unintended repo | Find the repo (`dnf info`), verify the vendor's key fingerprint out of band, `rpm --import` it |
| `dnf upgrade --security` finds nothing right after a release | Errata metadata lags the packages | Run a full `dnf upgrade`; check errata.rockylinux.org |
| Can't install a `-devel` package that "should exist" | It lives in CRB, which is disabled | `sudo dnf config-manager --set-enabled crb` |
| System stuck on an old minor release | `releasever` pinned in `/etc/dnf/vars/releasever` or a vault baseurl left in a repo file | Remove the pin; restore `rocky.repo` with `sudo dnf reinstall rocky-repos` |
| Everything is broken after enabling `devel` | `devel` contains buildroot-only packages that replace core ones | Disable it; `dnf history undo` the transaction |
| Third-party kernel module fails to load with Secure Boot | Module signed with a key shim does not trust | Enroll the vendor key with `mokutil --import`, confirm at the next boot's MOK manager |
| Old server won't boot Rocky 10 | CPU below x86-64-v3 | Run `/lib64/ld-linux-x86-64.so.2 --help` and look for `x86-64-v3 (supported, searched)`; stay on Rocky 9 or replace hardware |

!!! pitfall "Editing rocky.repo by hand"
    `rocky.repo` belongs to `rocky-repos`. Your edits survive upgrades (RPM saves new versions as `.rpmnew`), but you then silently miss repo changes Rocky ships. For an internal mirror, prefer a separate `.repo` file and `enabled=0` on the originals, or use `dnf config-manager --setopt`.

## Cheat sheet

| Command | What it does |
|---|---|
| `cat /etc/os-release` | Machine-readable OS identity (ID, VERSION_ID, SUPPORT_END) |
| `rpm -qf FILE` | Which package owns a file |
| `rpm -qi PKG` | Package details: Vendor, Signature (value on the next line), Build Date, Source RPM |
| `rpm -q --qf '%{RSAHEADER:pgpsig}\n' PKG` | The package signature on one clean line |
| `rpm -Kv FILE.rpm` | Verify digests and signature of a package file |
| `rpm -q gpg-pubkey --qf '%{VERSION} %{SUMMARY}\n'` | Keys RPM trusts |
| `sed -n '1,/END PGP/p' KEYFILE \| gpg --show-keys` | Show the first key's fingerprint without importing it (works even when the file holds a second, v6 key) |
| `dnf repolist --all` | Every configured repo and whether it's enabled |
| `dnf repoinfo REPO` | Repo details: mirrorlist, metadata age, size |
| `dnf info --installed PKG` | Shows `From repo` for an installed package |
| `dnf history info ID` | What a transaction changed, and the command used |
| `dnf updateinfo list --security` | Pending security advisories (RLSA) |
| `dnf updateinfo info RLSA-…` | Full advisory text and CVEs |
| `dnf upgrade --advisory ID` | Install only one advisory |
| `dnf download --source PKG` | Fetch the SRPM (enables source repos) |
| `dnf --repofrompath=ID,URL --repo=ID …` | Query a one-off repo, e.g. the vault |
| `mokutil --sb-state` | Is Secure Boot enabled? |
| `mokutil --list-enrolled` | Keys in the MOK list |
| `dnf needs-restarting -r` | Does the system need a reboot after updates? |

## Flashcards

<div class="flashcards" markdown>

<div class="card" markdown>

Explain how Rocky Linux is made in one sentence.

Rocky takes RHEL's source, swaps the labels, builds it in a clean room, seals every package with its own key, and ships it through mirrors. Each step leaves a fingerprint you can check.

</div>

<div class="card" markdown>

Which four fields trace a package back through the pipeline?

`Vendor` (who built it), the dist tag in `Release` (for which release), the signature `Key ID` (who sealed it), and `From repo` (where you got it).

</div>

<div class="card" markdown>

What does RLSA-2026:1234 correspond to?

The Red Hat advisory RHSA-2026:1234. RLSA = security, RLBA = bug fix, RLEA = enhancement.

</div>

<div class="card" markdown>

Which three packages define a Rocky system's identity, repos and keys?

`rocky-release` (os-release), `rocky-repos` (`/etc/yum.repos.d`), `rocky-gpg-keys` (`/etc/pki/rpm-gpg`).

</div>

<div class="card" markdown>

Which build systems has Rocky used?

Koji for Rocky 8. Peridot for Rocky 9.0 to 9.6 and for the early Rocky 10 content (until 2025-05-16). Koji for later Rocky 10 builds and for Rocky 9.7 onward. All of them use mock for the actual clean builds.

</div>

<div class="card" markdown>

What is the vault?

`dl.rockylinux.org/vault/rocky/`: frozen trees of superseded minor releases. Signed and complete, but no longer updated.

</div>

<div class="card" markdown>

Why can't a malicious mirror give you a modified package?

Every package is GPG-signed by Rocky, and `gpgcheck=1` makes DNF refuse anything whose signature doesn't verify against the trusted key.

</div>

<div class="card" markdown>

What is shim and why does it exist?

A small first-stage UEFI boot loader signed by Microsoft (after review, per shim release; Rocky's is dual-signed) that carries Rocky's CA, so firmware that trusts only Microsoft can boot Rocky's GRUB and kernel.

</div>

<div class="card" markdown>

What does CRB contain and is it enabled by default?

Build-time libraries and `-devel` packages (CodeReady Linux Builder). Disabled by default; many EPEL packages need it.

</div>

<div class="card" markdown>

Where did Rocky get its sources before and after June 2023?

Before: git.centos.org. After: several routes named in Rocky's 2023 post (CentOS Stream, RHEL SRPMs via UBI images and cloud instances, upstream). Rocky has not published the current mix.

</div>

</div>

## Recap

!!! recap "Key takeaways"
    - The mental model: source in, labels swapped, clean build, sealed with
      Rocky's key, shipped via mirrors. Read the fingerprints with `rpm -qi`,
      `rpm -K`, `dnf info --installed` and `dnf updateinfo`.
    - Rocky is a rebuild: same sources as RHEL, debranded, rebuilt cleanly, and signed by the RESF.
    - Since 2023 Rocky gathers sources through several routes (its post names CentOS Stream, UBI images, cloud RHEL instances and upstream). This affects timing, not content.
    - Debranding touches a small set of packages: release files, logos, installer branding, URLs, repo files and Secure Boot keys.
    - Rocky is built with Koji today (Rocky 9.7 and 10 builds since 2025-05-16). Peridot built Rocky 9.0 to 9.6 and the early Rocky 10 content, and its fingerprints are still on many packages. Every build runs in a clean mock buildroot.
    - BaseOS and AppStream are the core; CRB, add-ons, extras, plus, devel, debuginfo and source repos each have a purpose. Old minors move to the vault.
    - Every package is signed with the Rocky 10 key (`6fedfc85`); verify the key's fingerprint once, then let `gpgcheck=1` do the rest.
    - `dnf info --installed`, `dnf history info` and `dnf updateinfo` together answer "where did this package come from and why?"
    - Secure Boot runs firmware → Microsoft-signed shim → Rocky-signed GRUB and kernel → signed modules.

## Go deeper

- [[man:rpm(8)]] [[man:rpmkeys(8)]] [[man:dnf(8)]] [[man:dnf.conf(5)]] [[man:os-release(5)]] [[man:mokutil(1)]] [[man:yum-config-manager(1)]]
- [Rocky Linux documentation: repositories, release engineering and guides](https://docs.rockylinux.org/)
- [Rocky Linux GPG key information (official fingerprints)](https://rockylinux.org/keys/)
- [Rocky Linux and the changing Secure Boot landscape (June 2026)](https://rockylinux.org/news/2026-06-02-secure-boot-ca-kek-transition)
- [Keeping Open Source Open: Rocky's 2023 sourcing statement](https://rockylinux.org/news/keeping-open-source-open/)
- [Rocky Linux 10.0 release announcement (build system, IMA)](https://rockylinux.org/news/rocky-linux-10-0-ga-release)
- [Rocky Linux SIG/Core wiki (release engineering)](https://sig-core.rocky.page/)

**Next:** [22 · Building RPM Packages](22-building-rpms.md)
