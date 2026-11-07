---
title: "Start here: how Rocky gets built"
description: A series that follows one package from Red Hat's source to your server, shows the evidence at every step you can check yourself, and ends with you building a small distro of your own.
---

# How Rocky gets built

When two machines both say they are Rocky Linux 10.2, what exactly is the same between them, and how would you prove it? That one question drives this series. You will answer it by following a single package through every step that turns source code into something your server installs, using only tools and public services anyone can reach.

The first 37 modules teach you to run and fix a Rocky system. This series is the second spine of the course: it teaches how that system gets made. Every topic is anchored in something you can observe on a real Rocky Linux 10 system or a public Rocky service. Other distributions appear only as short, collapsed **comparison lenses** that make a Rocky behaviour clearer. They are never the main line.

## Who this is for

You have finished the basics and you are curious, or your job needs answers. Support engineers need to say whether a package is really Rocky's, whether it was signed, and what a signature does and does not prove. Sysadmins need to mirror Rocky, vet third-party repositories and build their own media. Aspiring packagers want to understand a distribution build pipeline well enough to join a special interest group or run a downstream.

**Prerequisites.** Hard requirements are [00 · Start Here](00-start-here.md), [02 · The Shell and the Filesystem](02-shell-and-filesystem.md) and [05 · Software: RPM and DNF](05-software-rpm-and-dnf.md). Read at least the core skill and chain of trust sections of [21 · Inside Rocky Linux](21-inside-rocky-linux.md) first. [01 · How Linux Works](01-how-linux-works.md) helps. Each module's meta bar lists what it builds on.

!!! tip "Short on time? Take the quick tour first"
    [21 · Inside Rocky Linux](21-inside-rocky-linux.md) is the field guide: how to read the fingerprints a Rocky package carries. [22 · Building RPM Packages](22-building-rpms.md) is the module on writing a spec file. This series assumes you have at least skimmed both, and goes much deeper than either.

## The shape of the series: four journeys, four laps

The series covers four journeys. You walk them as four **laps** over the same pipeline, each at a higher resolution, rather than as four separate silos.

| Lap | Modules | Resolution | The question you carry |
|-----|---------|-----------|------------------------|
| 1. The map | 40 | The whole pipeline, one screen | What are the steps? |
| 2. The parts | 41 to 44 | Artifacts: package, OS layers, media, images | What is physically in the thing? |
| 3. Rocky today | 45 to 48 | The live pipeline and trust, public evidence only | How does Rocky actually do each step, and how do I check? |
| 4. Do it yourself | 49 to 52 | The same steps, run by you, small | Can I make one? |

The four journeys behind the laps are: how an operating system gets built in general (journey 1), what is inside an OS (journey 2), how Rocky does it today (journey 3), and building it yourself (journey 4). Module 53 is a field exam that covers all of them (it is still being written).

## The pipeline strip

Every module starts with the same six-stage strip, so you always know which part of the build you are in. The lit stage is where the module lives.

<div class="pipeline-strip" data-here="none" role="group" aria-label="Rocky build pipeline, six stages" markdown>

1. Source
2. Build
3. Sign
4. Compose
5. Publish
6. Install

</div>

*Legend: the stages run in order, Source, Build, Sign, Compose, Publish, Install. In a module, the lit stage is marked "here" and the sentence under the strip says it in words.*

| Stage | What happens there |
|-------|--------------------|
| Source | Where the source comes from and how it lands, including any rebranding |
| Build | Turning source packages into binary packages in a build system |
| Sign | Attaching a signature to what was built |
| Compose | Assembling the built and signed packages into a release tree and testing it |
| Publish | Staging, the public mirrors, and the advisories that describe changes |
| Install | Your `dnf`, the installer, and the images a user finally runs |

## The dossier: one package, followed all the way down

The through-line is a small package, `which`, with `bash` and `kernel-core` as foils. In module 40 you create a plain file, `~/dossier/which.md`. Every later module adds one section to it in a block titled "Dossier entry", always in the same format.

By module 52 your dossier holds your own evidence for each step: which package owns the file, what its header says, which build produced it, which key signed it, and whether you can rebuild it. In the capstone you compare Rocky's `which` with the one from your own distro. The dossier is your evidence, not the author's.

## Four ways to read it

You do not need all of it. The same pages serve four reading orders. Hours are rough.

| Track | Who | Read closely | Skim |
|-------|-----|--------------|------|
| S: support and operations (about 19 hours with the skims) | Support engineers, TAMs, on-call SREs | 40, 41, 45, 46, 47, 48 | 42, 43, 44 |
| O: operator and builder (about 24 hours with the skims) | Sysadmins and platform engineers | 40, 41, 43, 44, 47, 49, 51 | the rest as needed |
| R: release engineer (about 43 hours) | Aspiring packagers and release engineers | All of them, with 22 alongside; the capstone is mandatory | none |
| C: curious (about 12 hours) | Developers and students | 40, 41, 45, 46, and 52 if you like (it adds about 7 hours) | Labs optional; quizzes and observations are not |

The full path is about 43 hours end to end: 42.5 hours for modules 40 to 52, plus about an hour for the exam.

## The modules

Hours come from each module's meta bar. The last column is what the module lets you do.

| # | Module | Hours | Labs | The promise |
|---|--------|-------|------|-------------|
| 40 | [How an OS gets built](40-how-an-os-gets-built.md) | 3 | 4 | Build a bootable-shaped OS tree in a minute, learn why nobody builds one from nothing, and walk the thirteen steps from Red Hat's source to your server. |
| 41 | [Anatomy of a package](41-anatomy-of-a-package.md) | 2.5 | 4 | Take a Rocky RPM apart byte by byte, read its header, open the source RPM and spec, and see why dependencies and scriptlets appear that nobody typed. |
| 42 | [What is inside an OS](42-what-is-inside-an-os.md) | 3 | 4 | Sort an installed Rocky into layers, name the few packages that make it Rocky, and read the x86-64-v3 baseline and hardening flags from a binary. |
| 43 | [Getting onto a disk: installer and install media](43-installer-and-install-media.md) | 3 | 4 | Take apart `boot.iso`, see that it holds an installer and a pointer rather than the OS, and prove the file you downloaded is the one Rocky published. |
| 44 | [Images: cloud, container and bootc](44-images-cloud-container-bootc.md) | 2.5 | 5 | See the same packages in four shapes, what each shape leaves out, and how Rocky builds the image set. |
| 45 | [Rocky's pipeline I: from source to build](45-pipeline-source-to-build.md) | 3 | 4 | Follow one package from Red Hat's source to a Koji build with public tools only, and rebuild `which` bit for bit. |
| 46 | [Rocky's pipeline II: compose to your server](46-pipeline-compose-to-your-server.md) | 3 | 4 | Follow a signed build through the compose, staging, production, mirrors and the advisory to your own `dnf`, and find the station an update is waiting at. |
| 47 | [Trust I: signatures and keys](47-trust-signatures-and-keys.md) | 3 | 4 | Say exactly what a green `rpm -K` proves and what it never did, and follow Rocky's release keys across both key files. |
| 48 | [Trust II: Secure Boot, module signing, reproducibility, siblings](48-trust-secure-boot-and-reproducibility.md) | 3 | 5 | Read the chain from firmware to a loaded kernel module with real evidence, then rank what "the same build" can and cannot prove. |
| 49 | [Build your own packages and repository](49-build-your-own-packages-and-repo.md) | 3 | 4 | Build a two-package chain, sign it with your own key, serve a repository, and rebuild Rocky's `which` exactly. |
| 50 | [Build your own build system (single-host Koji)](50-build-your-own-koji.md) | 3.5 | 5 | Stand up a one-VM Koji, build `which` twice, read the task tree, and compare with Rocky's public hub. |
| 51 | [Build your own install media](51-build-your-own-install-media.md) | 3 | 5 | Build a boot ISO with `lorax`, add a kickstart, check it against the official ISO, and read a real install-and-boot test. |
| 52 | [Capstone: MyOrg lab](52-capstone-myorg-lab.md) | 6 to 8 | 5 | Build a small distribution of your own on Rocky's packages, with your own identity packages and signing key, checked by a script. |
| 53 | [Field exam](53-field-exam.md) | 1 | none | A closing exam over all four journeys. It is still being written. |

Quick tour modules: [21 · Inside Rocky Linux](21-inside-rocky-linux.md) and [22 · Building RPM Packages](22-building-rpms.md). The scripts, spec files and configs the heavier labs use are on the [lab kits](lab-kits.md) page.

## What you need to run the labs

Every lab has a status line that names its environment tier. The tiers run from "any shell" to "a real VM with root".

| Tier | What it needs | Fallback if you do not have it |
|------|---------------|--------------------------------|
| A: Rocky shell | Any Rocky 10 VM or container (for example `podman run rockylinux/rockylinux:10`). No special VM features. | None needed. This is the fallback for the others. |
| B: build tools | Tier A plus `mock` and EPEL, network access to the repositories, and a systemd host for mock's nspawn. | A container variant where the rebuild proof is replaced by reading the logged result. |
| C: root VM | A real VM with root. Typical need: 4 vCPU, 8 GiB RAM and 20 GB of free disk, with each lab stating its own numbers. | A read-along with captured logs, plus the observe-only steps on Tier A. |
| D: network services | Tier A or C plus outbound access to public Rocky services. | Dated saved captures, clearly marked. |

A laptop with a Rocky 10 container is enough for much of the series. The heavier labs, such as building install media and a single-host Koji, need Tier C hardware, and each lab states its own numbers.

## How the evidence boxes work

This series covers a moving target: a public pipeline whose numbers change, whose inner parts are partly hidden, and whose trust story is only partly checkable from outside. So three boxes appear throughout. Learn them once here.

<!-- ev: SERIES-AUTHORING 5.1 | official | example box, shape only -->
!!! evidence "Observed: what an evidence box looks like"
    **Seen on:** Rocky 10.2 x86_64, 2026-11-06. This box marks a claim that comes from running something, a project statement, or reasoning, and says which. The title starts with one of four signals: "Observed:" (we ran it and saw it), "Stated by the project:" (a project page or maintainer says it), "Our reading:" (reasoning from facts, nobody states it), or "Reported, not confirmed:" (secondhand).

    **Check it yourself:** a command you can run, for example `rpm -q rocky-release`.

<!-- ev: SERIES-AUTHORING 5.2 | official | example box, shape only -->
!!! freshness "As of 2026-11-06 on Rocky 10.2"
    This box holds a value that changes, such as a count or a version, with its date and how often it tends to change. The mechanism around it stays true; the number is what ages.

    **Re-check:** the command that gives you today's value.

!!! unknown "What nobody outside the project can tell you"
    Each module has one of these. It lists the questions that the public record does not answer. "Not public" means the project has not published it. "Not tested" means we did not run it. The two are never swapped, and we do not guess to fill the gap.

Three more habits are worth knowing. A number is always given with its date and a command to re-check it. A percentage always states what it is a percentage of. And where a lab does not carry an author's test, it says so instead of presenting an untested command as a step.

## An honest note on what is tested

Every lab carries a status of Tested, Tested partly or Read-along, with the platform and the date. Counted from the status lines on 2026-11-07, modules 40 to 52 hold 57 labs: 43 Tested, 6 Tested partly and 8 Read-along. Module 53, the field exam, has no labs. Dates in the series are UTC: lab runs on the evening of 6 November in the US appear in the logs as 7 November. Most of the Tested labs ran on a Rocky 10.2 x86_64 machine. Where a result came from aarch64 rather than x86_64, the text says which.

A few things were not done, and the pages say so where they matter. Installing and booting media you produce yourself is covered by one read-along: a stock-repository ISO built with `lorax` installed unattended under QEMU software emulation and booted to a login prompt, but no login was typed, and it was not a branded ISO. Building and booting a MyOrg-branded ISO or image (capstone milestones M7 and M8) is design only. KIWI container builds were tested on aarch64 only, and KIWI disk images and `livemedia-creator` were not tried on x86_64. The capstone's identity, build, signing and repository milestones (M0 to M6) are tested, with 28 of 28 checks passing in a clean run.

The [lab kits](lab-kits.md) page lists six downloadable lab kits, each with its own tested status. Some of the series is read-only on purpose: where a step needs a live build system you do not have, you read captured output instead.

Public information only. Where the public record stops, the text says "not public" and stops with it. Where a tool is the current way of doing something, such as the compose tool, the text names it with a date, teaches the idea first, and keeps the tool name in an easy-to-edit spot so a replacement is a small change.

**Start:** [40 · How an OS gets built](40-how-an-os-gets-built.md)
