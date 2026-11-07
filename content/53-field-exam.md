---
title: Field exam
description: A one-hour retrieval exam over modules 40 to 52 with thirty items, four field scenarios and a calibration round that grades whether you can say what the evidence does not show.
---

# 53 · Field exam

<ul class="module-meta">
  <li>⏱ ~1 hour for the exam, plus review time</li>
  <li>No labs, one exam</li>
  <li>Builds on: modules 40 to 52 of this series</li>
  <li>Environment: Tier A (no VM needed)</li>
  <li>Verified: Rocky 10.2, 2026-11-07</li>
</ul>

A customer writes that two servers both say Rocky Linux 10.2, one of them failed a check, and they want to know what that proves. Nothing in this module is new. It asks you to retrieve what modules 40 to 52 taught, read real output from those modules, and, above all, say what the output does not show. In the field, an honest "that is not public" is worth more than a confident guess.

<div class="pipeline-strip" data-here="none" role="group" aria-label="Rocky build pipeline, six stages" markdown>

1. Source
2. Build
3. Sign
4. Compose
5. Publish
6. Install

</div>

*You are here: the whole pipeline, no single stage lit. Before: 52 · Capstone, the MyOrg lab. After: the series landing page.*

!!! abstract "What you'll learn"
    - Recall the facts from modules 40 to 52 that decide everyday support and release questions, without opening the pages.
    - Read a command output and say, in one sentence each, what it proves and what it does not.
    - Mark a claim as Proven, Plausible or Not public, using the unknown boxes of the series as the answer key.
    - Handle four realistic situations with evidence, a stated limit and a safe next step.
    - Find your weak modules from your score and go back to the exact section that teaches them.

## How the exam works

The exam has four parts and takes about an hour. Work through it once without opening the module pages. Use a notebook for the answers you want to defend.

| Part | What it is | Time | Points |
|------|-----------|------|--------|
| A | 30 retrieval items, tagged by module and lap | about 25 minutes | 30 |
| B | Calibration round: 5 claims, mark each Proven, Plausible or Not public | about 5 minutes | 5 |
| C | 4 field scenarios, written answers, self-graded with a rubric | about 28 minutes | 32 |
| D | Scoring and the review map | about 5 minutes | none |

Each item in Part A carries a tag such as `Item 7 · Module 42 · Lap 2 · Calibration`. The module number tells you where the answer lives. The lap is the series lap (1 the map, 2 the parts, 3 Rocky today, 4 do it yourself). The last word is the item type:

- **Recall** asks for a fact or a rule you should know.
- **Output** shows real output from a module and asks what it means.
- **Predict** asks what a command will print before you see it.
- **Calibration** shows real output and asks what it proves and what it does not. At least eight items are this type, because this is the skill the series is built around.

Click an answer. A wrong click is greyed out and you can try again, but only your first click on each item counts for your score. The explanation appears when you get it right and names the module and the section to re-read.

!!! tip "The calibration formula"
    For every output, say three things: what it proves, what it does not prove, and who could tell you the rest. "Not public" means the project has not published it. "Not tested" means nobody ran it, and the course says so. Never swap the two, and never fill a gap with a guess.

### Keep a confidence log

Calibration is a skill you can measure. Before you click an answer in Part A or Part B, write down one letter: **S** for sure, **L** for leaning, **G** for guessing. After the item, note whether you were right. Part D turns the log into a calibration score.

| Your letter | If you were right | If you were wrong |
|-------------|-------------------|-------------------|
| S | what you expect | a gap you did not know you had |
| L | fine | normal |
| G | luck, so the topic is not learned yet | honest, and the cheapest kind of miss |

A sure-and-wrong item is the most useful result in the exam, because it marks a belief that would have reached a customer. Review those first.

<!-- ev: modules 40 to 52 as finished | observed | course pages read in full, 2026-11-07 -->
!!! freshness "As of 2026-11-07 on Rocky 10.2"
    Every fact in this exam comes from a finished module page, and the page carries the evidence. A few answers rest on values that drift (a compose id, an advisory scan, a key file size). Each such item says on which day the value was seen, and the table in "Facts and freshness" gives the command to ask again. If a value has moved since, the relationship in the answer still holds. This changes whenever a module is edited or Rocky 10.3 ships.

    **Re-check:** `curl -s https://dl.rockylinux.org/pub/rocky/10/metadata/composeinfo.json | jq -c '.payload.compose'`

## Part A: thirty retrieval items

### Items 1 to 12: laps 1 and 2 (modules 40 to 44)

<div class="quiz" data-answer="2" data-title="Item 1 · Module 40 · Lap 1 · Predict" markdown>

Predict the last line. A release that carries a bootstrap marker is compared with the real release of the same package.

```console
$ rpm --define 'with_bootstrap 1' -E '%{dist}'
.el10~bootstrap
$ python3 -c "import rpm; print(rpm.labelCompare(('0','44','el10~bootstrap'), ('0','44','el10')))"
?
```

- `1`, the bootstrap build is newer
- `-1`, the bootstrap build is older, so the real rebuild replaces it
- `0`, the tilde is ignored

Right: `-1` means the first version is older, so a `~bootstrap` package never blocks the real rebuild. Review: [module 40](40-how-an-os-gets-built.md), section "The bootstrap loop".

</div>

<div class="quiz" data-answer="1" data-title="Item 2 · Module 40 · Lap 1 · Calibration" markdown>

Two hosts both print this line for `rpm -q bash`.

```console
bash-5.2.26-6.el10.x86_64
```

What does that prove, and what does it not?

- It proves both were built from the same source version. It does not prove the files, the builder or the build date match, because only digests show that
- It proves the two `/usr/bin/bash` files are identical. It does not prove who built them
- It proves the same builder produced both. It does not prove the signing key is the same

Right: the version string is a promise about the source, not about the bits. Comparing digests is the next step. Review: [module 40](40-how-an-os-gets-built.md), section "The core skill: ask what a version string promises".

</div>

<div class="quiz" data-answer="3" data-title="Item 3 · Module 41 · Lap 2 · Recall" markdown>

Which part of an RPM file holds the digest of the payload, and which part does the signature cover?

- The lead holds the digest, and the signature covers the whole file
- The signature header holds the digest, and the signature covers the payload
- The main header holds the digest, and the signature covers the main header

Right: `PAYLOADDIGEST` is a tag in the main header, and the signature covers that header. The payload is protected through the digest, not signed directly. Review: [module 41](41-anatomy-of-a-package.md), section "The four parts of an RPM file".

</div>

<div class="quiz" data-answer="2" data-title="Item 4 · Module 41 · Lap 2 · Output" markdown>

On Rocky 10, `rpm -qi bash | grep Signature` prints only this.

```console
Signature   :
```

What is the right reading?

- The package is unsigned
- The value sits on the next indented line, so `grep` did not print it. `rpm -q --qf '%{RSAHEADER:pgpsig}\n' bash` prints it on one line
- The signing key is not imported

Right: `rpm -qi` prints the label and puts the value on the next line. The package is signed. Review: [module 41](41-anatomy-of-a-package.md), section "The core skill: ask the package, not the file name".

</div>

<div class="quiz" data-answer="4" data-title="Item 5 · Module 41 · Lap 2 · Calibration" markdown>

You run this on a Rocky 10.2 machine on 2026-11-07.

```console
$ rpm -q --qf 'built  %{BUILDTIME:date}\nsigned %{RSAHEADER:pgpsig}\n' bash
built  Thu 31 Oct 2024 05:16:11 AM UTC
signed RSA/SHA256, Wed 21 May 2025 01:19:52 PM UTC, Key ID 5b106c736fedfc85
```

What does it prove, and what does it not?

- It proves the package was rebuilt in May 2025. It does not prove which key signed it
- It proves the signature is forged. It does not prove the key
- It proves nothing, because the two times are always equal
- It proves signing is a separate step that here came months after the build. It does not show how the signature was added or why it came later

Right: the two events are recorded separately in the header. The mechanism that signs is not public. Review: [module 41](41-anatomy-of-a-package.md), section "Rocky's fingerprints in the name and header", and [module 47](47-trust-signatures-and-keys.md), section "Signing is a separate event, hours after the build".

</div>

<div class="quiz" data-answer="3" data-title="Item 6 · Module 42 · Lap 2 · Predict" markdown>

Predict the owner. You run `rpm -qf /etc/os-release` on a Rocky 10.2 machine. Which package do you expect?

- `systemd`, because it reads the file
- `rocky-repos`, because it supplies the repository files
- `rocky-release`, because that package supplies the identity files

Right: `rocky-release` owns `/usr/lib/os-release` and the `/etc/os-release` link. `rocky-repos` owns the `.repo` files and `rocky-gpg-keys` owns the key files. Review: [module 42](42-what-is-inside-an-os.md), section "The core skill: ask rpm whose file this is".

</div>

<div class="quiz" data-answer="2" data-title="Item 7 · Module 42 · Lap 2 · Calibration" markdown>

On a Rocky 10.2 machine the installed kernel release ends in `.el10_2` and has no `.rocky` part. A colleague says: "So Rocky changed nothing, it is identical to Red Hat's kernel, bit for bit." What does the evidence show?

- It supports the claim, because Rocky adds `.rocky` to everything it touches
- It does not support the claim. The kernel source package carries a Rocky debranding patch while its release has no marker, and an identical version string can still hide different bits
- It refutes the claim, because every Rocky kernel is rebuilt with different options

Right: the `.rocky.0.N` marker records edits Rocky chose to mark, and no suffix is only a hint. We did not diff the kernel binaries against Red Hat's. Review: [module 42](42-what-is-inside-an-os.md), section "What Rocky changed, and how to see it".

</div>

<div class="quiz" data-answer="1" data-title="Item 8 · Module 43 · Lap 2 · Predict" markdown>

Predict both counts. You search `Rocky-10.2-x86_64-boot.iso` with `xorriso`, and you read `.treeinfo` from the public tree.

```console
$ xorriso -indev Rocky-10.2-x86_64-boot.iso -find / -name '*treeinfo*' 2>/dev/null | grep -c "^'"
?
$ xorriso -indev Rocky-10.2-x86_64-boot.iso -find / -name '.discinfo' 2>/dev/null | grep -c "^'"
?
```

- `0` and `1`: the ISO has a `.discinfo` and no `.treeinfo`, and the tree's `.treeinfo` lists the ISO
- `1` and `1`: both files are inside the ISO
- `0` and `0`: neither file is inside the ISO
- `1` and `0`: the ISO has a `.treeinfo` and no `.discinfo`

Right: the tree answers with a table of contents that even lists `images/boot.iso`. The ISO does not carry it. Review: [module 43](43-installer-and-install-media.md), section "Two objects: the ISO and the tree".

</div>

<div class="quiz" data-answer="3" data-title="Item 9 · Module 43 · Lap 2 · Calibration" markdown>

You download an ISO. `sha256sum -c` prints `OK`, and `gpg --verify` on the checksum file prints `Good signature ... [unknown]`. What does that prove, and what does it not?

- It proves the key belongs to Rocky's release engineering. It does not prove the download is intact
- It proves the ISO is the one in the compose. It does not prove the checksum file is signed
- It proves your copy matches a checksum that the imported key signed. It does not prove the key is Rocky's, which you decide by comparing its fingerprint with an independent source

Right: the hash covers the file and the signature covers the checksum. Whose key it is stays your decision. Review: [module 43](43-installer-and-install-media.md), section "The checksum chain".

</div>

<div class="quiz" data-answer="2" data-title="Item 10 · Module 44 · Lap 2 · Recall" markdown>

You add `kernel-core` to a container image and rebuild it. What do you have now?

- A container that boots its own kernel
- A bigger image that still uses the host's kernel when it runs as a container
- A virtual machine

Right: a container runtime starts a process on the host's kernel. The extra files add size only. To boot a kernel from an image you need image mode (bootc) or a disk image. Review: [module 44](44-images-cloud-container-bootc.md), section "Container images: names, tags and trust".

</div>

<div class="quiz" data-answer="3" data-title="Item 11 · Module 44 · Lap 2 · Calibration" markdown>

An auditor asks whether your cloud VM boots with Secure Boot enforced. On a Rocky 10.2 x86_64 cloud VM on 2026-11-06 you saw this.

```console
$ mokutil --sb-state
SecureBoot disabled
Platform is in Setup Mode
```

What does it prove, and what does it not?

- It proves the cloud image carries no signed boot files. It does not show anything about the host
- It proves Secure Boot is enforced, because the line `Setup Mode` is cosmetic
- It proves Secure Boot is not enforced on this VM, because no platform key is enrolled. It does not show the image lacks signed files, and it was seen on this VM and the earlier test hosts, not on every environment

Right: signed binaries are one half and enforcement is the other. The firmware decides. Review: [module 44](44-images-cloud-container-bootc.md), section "Cloud image layout".

</div>

<div class="quiz" data-answer="1" data-title="Item 12 · Module 44 · Lap 2 · Calibration" markdown>

On 2026-11-06 you ran this against the Rocky container image on Quay.

```console
$ skopeo list-tags docker://quay.io/rockylinux/rockylinux | grep -c 'sha256-'
0
```

What does it prove, and what does it not?

- It shows no cosign-style signature or attestation tags in that tag list on that day. It does not show the image is bad, and it says nothing about whether signing is planned
- It shows the image is unsigned and therefore unsafe to run
- It shows signing is planned for the next release

Right: it shows the absence of something you could verify with, not a defect. Whether the project will sign images is not public. Review: [module 44](44-images-cloud-container-bootc.md), section "Container images: names, tags and trust".

</div>

### Items 13 to 23: lap 3 (modules 45 to 48)

<div class="quiz" data-answer="2" data-title="Item 13 · Module 45 · Lap 3 · Output" markdown>

An installed package has release `3.el10_2.rocky.0.1` and packager `Rocky Linux Build System`. What do the two fields tell you?

- Rocky changed the source, and it was built on a Peridot pod
- Rocky changed the source, and it was built on a Koji builder
- Rocky did not change the source, and it was built on a Koji builder
- The kernel team built it in the Secure Boot environment

Right: `.rocky.0.N` is the mark of a Rocky change, and the plain packager, without `(Peridot)` or `Release Engineering`, is the Koji population. Review: [module 45](45-pipeline-source-to-build.md), section "The core skill: trace a package backwards".

</div>

<div class="quiz" data-answer="4" data-title="Item 14 · Module 45 · Lap 3 · Calibration" markdown>

You query Rocky's public Koji hub anonymously on 2026-11-06 and read build id, task id, start time and completion time.

```console
openssl-3.5.8-2.el10_2   125917  801106  2026-10-07 23:19:03  2026-10-08 00:26:14
kernel-6.12.0-211.74.1.el10_2  127819  None  2026-11-05 18:27:33  2026-11-05 18:27:33
```

What can you defensibly say about the kernel row?

- The kernel build failed
- The kernel build was signed by hand, which is why it has no task
- The kernel was compiled in Peridot, so Koji has no task
- It has no task and equal start and completion times, which is what an import looks like. It shows this hub did not compile it, and it does not show why it was imported or by whom

Right: no task means no compile on this hub. The reason comes from other evidence, not from the empty field. Review: [module 45](45-pipeline-source-to-build.md), section "Koji: the build system as a database".

</div>

<div class="quiz" data-answer="1" data-title="Item 15 · Module 45 · Lap 3 · Calibration" markdown>

On 2026-11-06 two commands print the same hash. The first reads the `.which.checksum` file in Rocky's `staging/rpms` repository, and the second hashes the `which-2.21-44.el10_0.src.rpm` that Red Hat publishes in its Universal Base Image.

```console
ff3ee430391dd8cf0ba07d3f2d734a971028be5441d02fefd506bfb21746912b
ff3ee430391dd8cf0ba07d3f2d734a971028be5441d02fefd506bfb21746912b  -
```

What does it prove, and what does it not?

- It proves the source package Rocky imported has the same bytes as one Red Hat publishes in the UBI. It does not prove which route Rocky used to get it
- It proves Rocky downloads its sources from the UBI. It does not prove the file is intact
- It proves the source RPM from `dnf download --source which` on Rocky equals Red Hat's. It does not prove the checksum file is public

Right: the same file can reach you by more than one route. The `dnf download --source` copy differs, because Koji builds Rocky's source package again from Git. Review: [module 45](45-pipeline-source-to-build.md), section "The front door: where a package enters Rocky".

</div>

<div class="quiz" data-answer="3" data-title="Item 16 · Module 46 · Lap 3 · Predict" markdown>

Predict the result. You want the full package list of Rocky 10.2 and you fetch `pub/rocky/10/metadata/rpms.json` on 2026-11-06. Why is it not the full list?

- Rocky 10 does not publish inventories
- It lists only source packages
- The shared `metadata/` directory is overwritten by whichever compose wrote last, and that was a security compose, so the file lists only its packages

Right: `composeinfo.json` named a security compose while `images.json` still named the May compose. To list a whole tree, read the repository metadata (`primary`). Review: [module 46](46-pipeline-compose-to-your-server.md), section "A compose is a dated shelf of builds".

</div>

<div class="quiz" data-answer="2" data-title="Item 17 · Module 46 · Lap 3 · Calibration" markdown>

A package file's `Last-Modified` header reads 21:56 GMT on 5 November, and the `repomd.xml` that lists the repository reads 08:03 GMT on 6 November. What does that prove, and what does it not?

- It proves the mirror is stale. It does not prove the file is signed
- It shows the order of two events: the file landed before the metadata that could list it. It does not show a cause, and by itself it does not show the new metadata lists the file
- It proves the package was rebuilt on 6 November

Right: times show order, never cause. To be sure, look inside `primary`. Review: [module 46](46-pipeline-compose-to-your-server.md), section "The core skill: find the station an update is waiting at".

</div>

<div class="quiz" data-answer="1" data-title="Item 18 · Module 46 · Lap 3 · Calibration" markdown>

You page through Apollo, Rocky's public errata service, for the Rocky Linux 10 product on 2026-11-06 and compare each advisory's year and number with its Red Hat source.

```json
{ "total": 894, "same_tail": 894 }
```

What does it prove, and what does it not?

- In this scan every Rocky advisory number matched its Red Hat number. It does not show the service guarantees that, because its documentation does not promise it
- It proves Rocky copies Red Hat's advisory text word for word
- It proves Rocky never issues an advisory of its own

Right: "always observed" is not "guaranteed". Treat the mapping as strong evidence and keep the `source.name` field as the authority. Review: [module 46](46-pipeline-compose-to-your-server.md), section "Errata: Apollo says why the shelf changed".

</div>

<div class="quiz" data-answer="3" data-title="Item 19 · Module 47 · Lap 3 · Predict" markdown>

Predict the verdict. You flip every bit of one byte inside the payload of a copy of `bash-5.2.26-6.el10` and run `rpm -Kv`. Which line goes BAD?

- `Header V4 RSA/SHA256 Signature`
- `Header SHA256 digest`
- `Payload SHA256 digest`

Right: the payload is protected by a digest stored in the signed header. The signature line stays OK because the header did not change. Review: [module 47](47-trust-signatures-and-keys.md), section "What one signature covers: header, payload and files".

</div>

<div class="quiz" data-answer="1" data-title="Item 20 · Module 47 · Lap 3 · Output" markdown>

On a fully updated Rocky 10 machine, `gpg --show-keys /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10` fails.

```console
gpg: packet(6) with unknown version 6
gpg: read_block: read error: Invalid packet
gpg: import from 'key-tree.asc' failed: Invalid keyring
```

What is the right reading?

- GnuPG 2.4 cannot read the second, v6 certificate in the file. The file is fine, `rpm` reads both certificates, and `sed -n '1,/END PGP/p'` isolates the first
- The file is corrupted, so reinstall `rocky-gpg-keys`
- The key was revoked

Right: the failure is GnuPG 2.4 meeting a v6 key, not a bad file. Review: [module 47](47-trust-signatures-and-keys.md), section "Two key files with one name, and a certificate GnuPG cannot read".

</div>

<div class="quiz" data-answer="2" data-title="Item 21 · Module 47 · Lap 3 · Calibration" markdown>

On 2026-11-06 a current `kernel-core` build shows no IMA file signatures, and `bash` shows 124. What does that prove, and what does it not?

- It proves the kernel package is unsigned
- It shows the two packages were signed on different sides of a change in what Rocky puts in packages (the build-time boundary is early on 2026-03-17 UTC). It does not say why the change happened or whether it will reverse
- It proves the kernel package was altered after signing

Right: the kernel verifies with `rpm -Kv` like any other Rocky package. The count is a property of when it was signed, and the cause is not public. Review: [module 47](47-trust-signatures-and-keys.md), section "IMA file signatures: present, then absent".

</div>

<div class="quiz" data-answer="3" data-title="Item 22 · Module 48 · Lap 3 · Recall" markdown>

In the SBAT row `kernel.rocky,1,RESF,kernel-core,…`, what does the `1` mean?

- The number of signatures on the file
- The release number of the package
- The component generation, which shim compares against its stored minimum for `kernel.rocky`

Right: if the stored minimum rises above 1, kernels at generation 1 are refused. Review: [module 48](48-trust-secure-boot-and-reproducibility.md), section "SBAT: how to read a generation line".

</div>

<div class="quiz" data-answer="2" data-title="Item 23 · Module 48 · Lap 3 · Predict" markdown>

Predict the outcome. You pin the build root to the Rocky 10.0 vault to rebuild `which-2.21-44.el10_0` on x86_64, but you forget `--define 'dist .el10_0'`. What do you get?

- The shipped payload, byte for byte
- A different NVR (`el10`) and a different payload digest, so not the shipped package
- The same payload with a different RPM signature

Right: both inputs matter. The dist define changes the NVR, the debug link name and so the build-id. Review: [module 48](48-trust-secure-boot-and-reproducibility.md), section "Reproducibility as a spectrum", and [module 49](49-build-your-own-packages-and-repo.md), section "Proving the loop works: an exact rebuild of `which`".

</div>

### Items 24 to 30: lap 4 (modules 49 to 52)

<div class="quiz" data-answer="1" data-title="Item 24 · Module 49 · Lap 4 · Calibration" markdown>

`rpm -Kv` on a package from a repository you built prints this.

```console
    Header V4 RSA/SHA256 Signature, key ID 80045a5b: NOKEY
    Header SHA256 digest: OK
    Payload SHA256 digest: OK
```

What does it prove, and what does it not?

- The package is signed and intact (the digests match), and this machine has no key to check the signature. It does not say who signed it or whether the signer is who you think
- The package was tampered with
- The package is unsigned

Right: NOKEY means a signature is present and unchecked. Tampering would show BAD. Review: [module 49](49-build-your-own-packages-and-repo.md), section "The core skill: reading a package's verdict".

</div>

<div class="quiz" data-answer="3" data-title="Item 25 · Module 49 · Lap 4 · Predict" markdown>

Predict the value. You rebuild a Rocky package in mock. What does `rpm -q --qf '%{RSAHEADER:pgpsig}\n'` print for your result?

- The same Rocky key ID, because the source is identical
- Your hostname, because you built it
- `(none)`, because mock does not sign

Right: on the test machine the pinned rebuild of `which` printed `(none)`, while the shipped package printed Rocky's signature line. Review: [module 49](49-build-your-own-packages-and-repo.md), section "Signing your packages".

</div>

<div class="quiz" data-answer="2" data-title="Item 26 · Module 50 · Lap 4 · Predict" markdown>

A `koji build` finished and `koji list-tagged mylab-dest` shows nothing new. The task tree has `rebuildSRPM` and `buildArch` but no `tagBuild`. What happened?

- The builder could not reach the hub
- It was a scratch build: the whole build ran and the result was thrown away, so nothing was filed in the destination tag
- The destination tag is full

Right: no `tagBuild` task means no build was tagged. Review: [module 50](50-build-your-own-koji.md), section "The core skill: read a task tree".

</div>

<div class="quiz" data-answer="1" data-title="Item 27 · Module 50 · Lap 4 · Calibration" markdown>

In the single-host lab on 2026-11-06 you read the header of the RPM that your own Koji built.

```console
NVR=which-2.21-44.el10.x86_64 buildhost=localhost.localdomain vendor=Koji packager=Koji sig=(none)
```

What does it prove, and what does it not?

- It proves this lab's Koji build is unsigned, so signing is a separate step the lab did not do. It does not show how Rocky signs its packages, which is not public
- It proves Koji cannot sign packages
- It proves Rocky's packages are unsigned

Right: the output describes one lab build only. Review: [module 50](50-build-your-own-koji.md), section "Koji does not sign".

</div>

<div class="quiz" data-answer="2" data-title="Item 28 · Module 51 · Lap 4 · Calibration" markdown>

A colleague says: "We proved a custom Rocky-based ISO installs and boots." The course ran a boot test in QEMU without KVM. What does the evidence prove, and what does it not?

- It proves a MyOrg-branded ISO boots. It does not show anything about Rocky's official ISO
- An ISO built by lorax from stock Rocky repositories installed 249 packages unattended on 2026-11-06 and its disk reached a login prompt. It does not show a MyOrg ISO was built or booted, that `livemedia-creator` works on x86_64, or that the official ISO was installed
- It proves `livemedia-creator` builds bootable disks on x86_64

Right: the nearest evidence is the stock-repository ISO. Anything else is not tested. Review: [module 51](51-build-your-own-install-media.md), section "Boot it without KVM", and [module 52](52-capstone-myorg-lab.md), section "Scoring: the rubric".

</div>

<div class="quiz" data-answer="3" data-title="Item 29 · Module 52 · Lap 4 · Predict" markdown>

You run a plain `dnf install myorg-release` on a Rocky tree and get six file conflicts with `rocky-release`. What is the cleanest fix for an existing tree?

- Add `--nogpgcheck` to the install
- Delete `/etc/os-release` by hand and try again
- `dnf swap rocky-release myorg-release`, which erases the old owner in the same transaction

Right: rpm allows overlapping files when the old owner goes in the same transaction. The conflict has nothing to do with signatures. Review: [module 52](52-capstone-myorg-lab.md), section "Worked story: replacing rocky-release".

</div>

<div class="quiz" data-answer="1" data-title="Item 30 · Module 52 · Lap 4 · Output" markdown>

A tree built with two equal-priority repositories shows `rocky-release` as the only provider.

```console
$ sudo rpm --root $X/D -q --whatprovides system-release
rocky-release-10.2-1.2.el10.noarch
```

Which statement explains it?

- dnf had two valid providers, and with equal priority it picked the seed's without a warning
- `myorg-release` was missing its `Provides: system-release` line
- dnf prefers the package with the older version

Right: both release packages provide `system-release`, and nothing broke the tie. Setting the MyOrg repository to a better priority flips the answer. Review: [module 52](52-capstone-myorg-lab.md), section "Worked story: the tree that said Rocky".

</div>

## Part B: calibration round

Part A tested single outputs. Part B tests the habit. Five claims follow. For each, choose the label the public evidence supports.

- **Proven:** a module shows evidence for it. State the limits of the evidence.
- **Plausible:** a reasonable reading that nobody states and nobody proved. The module says "Our reading".
- **Not public:** the project has not published it, and no output of ours can answer it.

<div class="quiz" data-answer="3" data-title="Claim 1 · Modules 47 and 48 · Lap 3" markdown>

"Rocky stopped signing packages with IMA file signatures on purpose."

- Proven
- Plausible
- Not public

Right: the build-time boundary (early on 2026-03-17 UTC) is observed, and we found no announcement. Why signing stopped, whether it was intended and whether it returns is not public. Review: [module 47](47-trust-signatures-and-keys.md), section "IMA file signatures: present, then absent" and its unknown box.

</div>

<div class="quiz" data-answer="1" data-title="Claim 2 · Module 41 · Lap 2" markdown>

"Rocky's shipped `bash` was signed months after it was built."

- Proven
- Plausible
- Not public

Right: the header carries both times (built 31 Oct 2024, signed 21 May 2025). The evidence is on your own machine. What it does not show is how or why. Review: [module 41](41-anatomy-of-a-package.md), section "Rocky's fingerprints in the name and header".

</div>

<div class="quiz" data-answer="2" data-title="Claim 3 · Module 48 · Lap 3" markdown>

"A release engineer imports the kernel and shim builds by hand, from a build environment separate from the normal builders."

- Proven
- Plausible
- Not public

Right: the data shows no task, equal start and completion times, a different build host family, the packager `Release Engineering` and an individual owner account. The inference is ours, and the project has not described the environment. Review: [module 48](48-trust-secure-boot-and-reproducibility.md), section "Where the signed boot files come from".

</div>

<div class="quiz" data-answer="3" data-title="Claim 4 · Modules 40 and 45 · Lap 1 and 3" markdown>

"The first x86_64 and aarch64 Rocky 10 buildroot got its compiler the same way the riscv64 stack did."

- Proven
- Plausible
- Not public

Right: the project documents a bootstrap for riscv64 only (see the riscv64 row of the table in module 40). For x86_64 and aarch64, I found no public description. Do not carry the riscv64 story over to the other architectures. Review: [module 40](40-how-an-os-gets-built.md), section "The bootstrap loop" and its unknown box.

</div>

<div class="quiz" data-answer="1" data-title="Claim 5 · Modules 48 and 49 · Lap 3 and 4" markdown>

"A rebuild of Rocky's `which-2.21-44.el10_0` in a pinned 10.0 vault buildroot, with `--define 'dist .el10_0'`, gives the shipped payload."

- Proven
- Plausible
- Not public

Right: observed for this one package on x86_64 with both inputs pinned. It does not say how Rocky assembled its own buildroot (not public), and it was not tested on aarch64 or for other packages. Review: [module 49](49-build-your-own-packages-and-repo.md), section "Proving the loop works: an exact rebuild of `which`".

</div>

## Part C: four field scenarios

Each scenario is a situation you could meet on a support queue or a release-engineering call. Write your answer first, in a notebook, in four parts: the evidence you would collect, what it would prove, what you would say you do not know, and the next step. Then open the model answer and score yourself.

### How to score a scenario

Give yourself 0, 1 or 2 on each of four criteria, for 8 points per scenario.

| Criterion | 2 points | 1 point | 0 points |
|-----------|----------|---------|----------|
| Evidence | Names the command or public source and what it shows | Names a source but not what it shows | No evidence, only opinion |
| Matching | Says what the evidence proves, and only that | Mixes proof with inference | Claims more than the output shows |
| Calibration | Names what is unknown, "not public" for the project's choices and "not tested" for what nobody ran, with no guess filled in | States a limit vaguely | Fills a gap with a guess or a confident cause |
| Next step and safety | A concrete step the customer can take, with no unsafe shortcut | A step with a gap | No step, or a shortcut such as `--nogpgcheck` |

An overclaim in the calibration row caps that scenario at 4 points, however good the rest is.

### Scenario 1: the scanner still says vulnerable after the update

A customer ran `dnf update` on a Rocky 10.2 server a day ago. Their vulnerability scanner still flags a package for a CVE. The ticket reads: "Rocky says it is patched, the advisory page says so, why does the scan still fail?" They paste the scanner's finding (a package name, a version and a CVE id) and nothing else.

Do not answer yet. Decide what you would look at first, and what you could honestly say after looking.

??? success "Model answer and checklist"
    **Evidence to collect.** Three things, all public or on the customer's machine.

    1. The installed package: `rpm -q PKG` prints name, version and release. This is what the machine has, whatever the scanner believes.
    2. Rocky's advisory for the CVE. Apollo answers anonymously: `curl -s 'https://apollo.build.resf.org/v2/advisories?filters.keyword=CVE-ID' | jq -r '.advisories[]|[.name,.synopsis,.publishedAt,(.affectedProducts|join(",")),.source.name]|@tsv'`. The `source.name` column gives the Red Hat advisory the Rocky one came from. `dnf updateinfo list --all` shows what the customer's own repositories carry.
    3. What the customer's repositories can see. A package file can sit on the origin for hours before the metadata that lists it, and a mirror can be half-synced. Compare `curl -sI $B/repodata/repomd.xml | grep -i last-modified` with the RPM's own `Last-Modified`.

    **What this proves.** The installed release, the existence of an advisory with a Red Hat number, and the order of two timestamps. If the installed release is the build the advisory names, the package on the machine is the fixed build as far as Rocky's records go.

    **What it does not prove.** It does not show the scanner is right or wrong, because you cannot see its matching logic from the finding. The release string is only a hint about edits: the changelog is the packager's note and the `.rocky` marker is not a complete list, so do not read an unfamiliar release as "unpatched". Times show order, not cause.

    **What you say you do not know.** Whether Rocky received the fix early or under an embargo is not public. Where a delay arose, if there was one, is not public: compose hosts and schedule are not published. The project's own page calls 24 to 48 hours a target for ordinary updates, and a staff reply says it cannot be assumed to be the rule.

    **Next step.** Ask for the scanner's data source and the exact version it matched, and ask the customer to send the `rpm -q` line and the repository id. Do not tell them "Rocky is patched" until the NVR comparison is done.

    **Checklist for full marks:** names `rpm -q` and Apollo (evidence); separates installed state from scanner belief (matching); says embargo and delay causes are not public and the scanner logic is not visible (calibration); asks for the scanner's matched version before concluding (next step).

??? failure "What a weak answer looks like (scenario 1)"
    "Rocky patched it, so the scanner is wrong. Ask them to rescan." This states a cause with no evidence and skips `rpm -q`. Another weak answer names a fixed release without checking which build the advisory names. A third waits for the next compose without showing that anything is missing. Each one replaces evidence with confidence.

### Scenario 2: "is my rebuild the same as Rocky's?"

A customer rebuilt a Rocky source package named `pkg-1.0-1.el10_0` in mock with the stock `rocky-10-x86_64` configuration. Their result is named `pkg-1.0-1.el10`, and its checksum differs from the shipped file. On the call, a colleague says: "Rocky is bit-for-bit identical to RHEL, so their rebuild should be bit-for-bit identical to Rocky's." The customer asks whether they did something wrong.

??? success "Model answer and checklist"
    **Evidence to collect.** The two names, then digests that mean something. `rpm -q --qf '%{PAYLOADDIGEST}\n' PKG` on the shipped package and on the rebuild, and `rpm -q PKG --qf '[%{FILEDIGESTS} %{FILENAMES}\n]' | sort` on each, then `diff`. The whole-file checksum is the wrong test, because build time, host and signature differ even for a rebuild that reproduces the payload.

    **What this proves.** The release changed from `el10_0` to `el10` because the dist tag is recomputed in the buildroot, and rpm sorts `el10` below `el10_0`. A rebuild in mock is not signed, so its signature header reads `(none)` where the shipped one shows Rocky's line. The customer did nothing wrong. In our one reproduction, `which-2.21-44.el10_0` on x86_64 gave the shipped payload digest only with both a pinned 10.0 vault buildroot and `--define 'dist .el10_0'`. Pinned alone did not reproduce it.

    **The colleague's claim.** The evidence does not support "bit-for-bit identical". For `bash-5.2.26-6.el10`, 123 of 124 file digests matched Red Hat's and the main binary differed, with a different payload digest. For `glibc-2.39-145.el10_2` all 36 file digests matched and the payload digest still differed, with the cause not isolated. The RHEL side of these comparisons is a captured result from a paid cloud image. The same version string is a promise about the source, not about the bits.

    **What you say you do not know.** Why a payload digest differs where the file digests match is not isolated. How Rocky assembled its own buildroot for `which` is not public. Whether the pinned reproduction works on aarch64 or for the customer's package is not tested.

    **Next step.** Ask for the package name and architecture. Have them compare payload digests and file digest lists. If they need an exact match, they can try the pinned buildroot plus the dist define, with the warning that it worked for one package.

    **Checklist for full marks:** payload digest and file digests instead of the whole-file hash (evidence); dist recomputation and `(none)` explained (matching); the one-package limit and the unproven RHEL claim (calibration); a comparison the customer can run (next step).

??? failure "What a weak answer looks like (scenario 2)"
    "Your rebuild is different because you built it wrong." The customer did nothing wrong, and the answer never explains why the name changed. Another weak answer promises that pinning the buildroot gives an identical package for any source package, when the course tested one package on one architecture. A third repeats "bit-for-bit identical" because the version strings match.

### Scenario 3: NOKEY after adding a third-party repository

A customer added a vendor's repository file with `gpgcheck=1` and no `gpgkey=` line. `dnf install` stops with `Public key for ... is not installed` and `Error: GPG check FAILED`. Their manager asks whether the package was tampered with. The customer asks if they can use `--nogpgcheck` to get on with it.

??? success "Model answer and checklist"
    **Evidence to collect.** Download the package without installing it and run `rpm -Kv` on it. A NOKEY signature line with the digest lines reading OK means the package is signed and intact and this machine has no key for it. Tampering would show BAD on a digest or on the signature.

    **What this proves.** A signature is present and the bytes match the digests in the header. The fault is on the consumer side: the repository file has `gpgcheck=1` and nothing says where the key is. It proves nothing about who signed the package.

    **The fix.** Get the vendor's public key from a place independent of the repository host. Print its fingerprint without importing it: `gpg --show-keys --with-fingerprint KEYFILE`. Compare all forty hex digits with a source you did not get from the same place. Then add `gpgkey=` to the repository file, or run `sudo rpmkeys --import KEYFILE`, and run `rpm -Kv` again. Expect OK.

    **What it does not prove.** An OK line means a key in your database verified the signature. It says nothing about whether you were right to import that key, or whether the vendor's software is safe. Rocky cannot vouch for a third-party key. Whether the vendor signs the repository metadata is a separate question (`repo_gpgcheck`, which the stock Rocky repository files do not set).

    **Why not `--nogpgcheck`.** It switches off the package check for the whole transaction. The check that failed was working, and the customer would install unverified bytes from an unverified key.

    **What you say you do not know.** Whether the key really belongs to the vendor, until the customer compares the fingerprint with an independent source.

    **Checklist for full marks:** `rpm -Kv` and the NOKEY versus BAD distinction (evidence); signed, intact, key missing (matching); the key's owner unverified until compared (calibration); fingerprint check then import, and a refusal of `--nogpgcheck` (next step).

??? failure "What a weak answer looks like (scenario 3)"
    "Use `--nogpgcheck`, the package is fine." Nothing in a NOKEY line says the package is fine, only that no key was available. Another weak answer says the package was tampered with, which NOKEY with four OK digests does not show. A third tells the customer to import the key from the host that serves the repository, which proves nothing about who owns the key.

### Scenario 4: Secure Boot refuses a custom kernel module

A customer on a physical Rocky 10.2 server with Secure Boot on built a kernel module for a hardware card. `modprobe` prints `Key was rejected by service`. They ask Rocky to send a signed build of the module, or to tell them how to turn the check off.

??? success "Model answer and checklist"
    **Evidence to collect.** Two commands, run right after the failure: `mokutil --sb-state` and `sudo dmesg | tail -1`. The `modprobe` message is the same for both kinds of rejection, so it tells you little. The `dmesg` line decides: `Loading of unsigned module is rejected` means nobody signed it, and `Loading of module with unavailable key is rejected` means it is signed by a key the kernel does not trust.

    **What this proves.** Which of the two cases you are in, and whether Secure Boot is enforcing at all. If the state is `SecureBoot disabled`, the module would load and taint the kernel instead of being refused.

    **The fix.** Unsigned: sign the module with the customer's own key, then enroll that key. Unavailable key: enroll the key with `mokutil --import`, reboot and confirm at the console in MokManager. If the module came from a vendor package, a `weak-updates` link only solves compatibility with a new kernel. It adds no trust, so the key still has to be enrolled.

    **Why Rocky cannot send a signed module.** The project states in its shim-review submission that the kernel module signing keys are ephemeral per kernel build, and you can see the effect: `modinfo -k KERNEL xfs | grep -E '^(signer|sig_key)'` shows the same signer name and a different `sig_key` fingerprint for each installed kernel. There is no standing Rocky key for a customer's module.

    **What you say you do not know.** Whether the private module-signing key is destroyed after each build is not public, and neither is how the Secure Boot build environment is designed. Whether the customer's card driver is compatible with the next kernel is a vendor matter, not something the output answers.

    **Turning the check off.** Say that this is the customer's security decision, and that the kernel then loads unsigned code and nothing protects it from more. Do not offer it as the fix.

    **Checklist for full marks:** `mokutil --sb-state` and the `dmesg` line (evidence); unsigned versus unavailable key (matching); the ephemeral-key statement as the project's statement, plus the two not-public items (calibration); own key plus MOK enrollment, and no casual advice to disable the check (next step).

??? failure "What a weak answer looks like (scenario 4)"
    "Disable Secure Boot in the firmware and it will load." This trades the customer's boot trust for a loaded module and never asks which rejection it was. Another weak answer promises a signed module from Rocky, which the per-build ephemeral key rules out. A third blames a broken kABI promise, which the `dmesg` line does not support.

## Part D: scoring and the review map

### Score sheet

Count only first-click correct answers in Part A and Part B.

| Part | Items | Points available | Your score |
|------|-------|------------------|-----------|
| A, lap 1 and 2 | 1 to 12 | 12 | |
| A, lap 3 | 13 to 23 | 11 | |
| A, lap 4 | 24 to 30 | 7 | |
| B, calibration round | claims 1 to 5 | 5 | |
| C, scenarios | 4 scenarios, 8 points each | 32 | |

### Pass criteria

You pass the field exam when both of these hold:

- You score at least 24 of 30 (80%) in Part A.
- You mark both Not public claims correctly in Part B (claims 1 and 4). Wrong confidence on an unknown is the error this exam exists to catch.

Part C does not change the pass mark, because it is self-graded. If you pass Part A but score less than 6 of 8 on three of the four scenarios, the number overstates what you can do in the field. Redo those scenarios after reviewing.

The three recognitions in the series plan need no server. **Pipeline Reader** is modules 40 to 48 plus this exam. **Chain Verifier** is the labs of modules 47 and 48 plus a perfect trust strand in this exam (items 19 to 23). **Distro Builder** is the capstone gate of module 52.

### If you did not pass

A first attempt below 24 is normal for an exam that asks what outputs do not prove. Do this before you retake it.

1. Use the review map below to rank modules by missed items, most misses first.
2. For each of the top three modules, re-read the sections the explanations named, and run the "Check it yourself" line of one evidence box in each. Seeing the output on your own machine fixes more than re-reading.
3. Wait a day. A retake the same afternoon measures short-term memory, not retrieval.
4. Retake Part A and Part B only. Rewrite one scenario answer from scratch and compare it with the model answer.

The widget lets you click again after a wrong answer, so the first click is the honest one. If you cannot resist peeking, use the confidence log: a guess marked G is a fair record of where you stood.

### Calibration score

Use your confidence log. Count the items you marked S and got wrong. This is your overconfidence count.

| Sure-and-wrong items | What it means |
|----------------------|---------------|
| 0 | Your confidence matched your knowledge. Keep it |
| 1 to 2 | Each is a belief to fix. Read the module section the explanation names |
| 3 or more | Slow down on outputs. Say what an output does not prove before you answer |

A high score with three or more sure-and-wrong items is a weaker result than a slightly lower score with none, because the first learner will say wrong things in the field and the second will say "I do not know yet".

### What to review

Find the items you missed, then re-read the section named in the explanation. This map lists them by module.

| Module | Items | If you missed these, start here |
|--------|-------|---------------------------------|
| [40 · How an OS gets built](40-how-an-os-gets-built.md) | 1, 2, claim 4 | The version string promise and the bootstrap loop |
| [41 · Anatomy of a package](41-anatomy-of-a-package.md) | 3, 4, 5, claim 2 | The four parts of an RPM file and `RSAHEADER` |
| [42 · What is inside an OS](42-what-is-inside-an-os.md) | 6, 7 | `rpm -qf` and the `.rocky` marker as a hint |
| [43 · Installer and install media](43-installer-and-install-media.md) | 8, 9 | ISO versus tree, and the checksum chain |
| [44 · Images: cloud, container, bootc](44-images-cloud-container-bootc.md) | 10, 11, 12 | Container versus kernel, Secure Boot state |
| [45 · Pipeline: source to build](45-pipeline-source-to-build.md) | 13, 14, 15 | Packager strings, empty task ids, the landing zone |
| [46 · Pipeline: compose to your server](46-pipeline-compose-to-your-server.md) | 16, 17, 18 | The shared `metadata/` directory, timestamps, Apollo |
| [47 · Trust I: signatures and keys](47-trust-signatures-and-keys.md) | 19, 20, 21, claim 1 | `rpm -Kv`, the two key files, the IMA boundary |
| [48 · Trust II: Secure Boot and reproducibility](48-trust-secure-boot-and-reproducibility.md) | 22, 23, claims 3 and 5 | SBAT, pinned rebuilds, boot-path imports |
| [49 · Build your own packages and repo](49-build-your-own-packages-and-repo.md) | 24, 25, claim 5 | NOKEY, unsigned mock output |
| [50 · Build your own Koji](50-build-your-own-koji.md) | 26, 27 | Task trees and the fact that Koji does not sign |
| [51 · Build your own install media](51-build-your-own-install-media.md) | 28 | What the boot test did and did not show |
| [52 · Capstone: MyOrg lab](52-capstone-myorg-lab.md) | 29, 30 | Replacing `rocky-release`, equal repository priority |

## Facts and freshness

Every dated value behind an answer, in one place. If a value has moved, the relationship in the explanation still holds.

| Fact | Value (dated) | Re-check | Stale when |
|------|---------------|----------|------------|
| Cloud VM Secure Boot state (item 11) | `SecureBoot disabled`, Setup Mode, 2026-11-06 | `mokutil --sb-state` | the image or the cloud firmware changes |
| No cosign-style tags on the registry (item 12) | 0 tags starting `sha256-`, 2026-11-06 | `skopeo list-tags docker://quay.io/rockylinux/rockylinux \| grep -c 'sha256-'` | the project signs images |
| Kernel build has no Koji task (item 14) | task id `None`, 2026-11-06 | the `getBuild` loop in the Koji section of module 45 | the build is replaced by a newer one |
| Source hash equals UBI source package (item 15) | same value, 2026-11-06 and 2026-11-07 | the two commands in the front-door section of module 45 | Rocky changes its sourcing route |
| Shared metadata directory (item 16) | `composeinfo.json` names a security compose, 2026-11-06 | `curl -s https://dl.rockylinux.org/pub/rocky/10/metadata/composeinfo.json \| jq -c '.payload.compose'` | the next compose writes there |
| Apollo number match (item 18) | all advisories in the scan matched, 2026-11-06 | the paging loop in module 46 | any advisory breaks the pattern, and daily as advisories arrive |
| IMA boundary (item 21, claim 1) | early on 2026-03-17 UTC, 2026-11-06 | `rpm -qp --qf '[%{FILESIGNATURES}\n]' PACKAGE.rpm \| grep -c .` | signing resumes |
| Boot test (item 28) | 249 packages installed, disk reached login, 2026-11-06 | read lab 4 of module 51 | a MyOrg ISO is built and booted |

## Flashcards

<div class="flashcards" markdown>

<div class="card" markdown>

Two hosts print the same `rpm -q bash` string. What is promised?

The same source version, not the same bits. Compare digests to know more. (Module 40)

</div>

<div class="card" markdown>

NOKEY or BAD: which means "signed, intact, no key here"?

NOKEY. BAD means a key was found and the check failed. (Modules 47 and 49)

</div>

<div class="card" markdown>

What does an RPM signature cover?

The main header. The payload is protected through a digest stored in that header. (Module 41)

</div>

<div class="card" markdown>

A Koji build has task id `None` and equal start and completion times. What is it?

An import: this hub did not compile it. Why it was imported needs other evidence. (Module 45)

</div>

<div class="card" markdown>

A weak-updates link or a MOK: which adds compatibility, which adds trust?

The link adds compatibility. Enrolling the key adds trust. They are separate checks. (Modules 29 and 48)

</div>

<div class="card" markdown>

What does an exact rebuild of `which` need?

A pinned 10.0 vault buildroot and `--define 'dist .el10_0'`. One package, x86_64 only. (Modules 48 and 49)

</div>

<div class="card" markdown>

The ISO or the tree: which has `.treeinfo`?

The tree. The boot ISO has `.discinfo` and no `.treeinfo`. (Module 43)

</div>

<div class="card" markdown>

Does Koji sign packages?

No. A Koji-built RPM shows `sig=(none)`. Signing is a separate step. (Module 50)

</div>

<div class="card" markdown>

The calibration formula in three parts?

What it proves, what it does not prove, who could tell you the rest. (This module)

</div>

<div class="card" markdown>

"Not public" or "not tested": what is the difference?

Not public: the project has not published it. Not tested: nobody ran it, and we say so. (This module)

</div>

</div>

## Recap

!!! recap "Key takeaways"
    - A version string promises a source version. Digests, headers and signatures tell you about the bits.
    - Read every output for what it proves and for what it does not prove. The second half is the harder skill.
    - NOKEY is a missing key, BAD is a failed check, and OK is only as good as the key you chose to import.
    - Empty task ids, equal timestamps and absent tags are evidence of an import or an absence. They are not evidence of a cause.
    - Say "not public" for what the project has not published and "not tested" for what nobody ran. Never fill either gap with a guess.
    - Reproduction needs controlled inputs. One package on one architecture is a result, not a rule.

## Go deeper

- [Start here: how Rocky gets built](series-how-rocky-gets-built.md), the series landing page with the four laps and the dossier.
- [21 · Inside Rocky Linux](21-inside-rocky-linux.md), the field guide to reading the fingerprints a Rocky package carries.
- [29 · Secure Boot and drivers](29-secure-boot-and-drivers.md), the module behind scenario 4 and the MOK flashcard.

**Next:** [Back to the series landing page](series-how-rocky-gets-built.md)
