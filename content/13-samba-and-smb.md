---
title: Samba and SMB
type: module
track: linux-internals
tags: [linux-internals, samba, smb, cifs, smbd, winbind, active-directory, acl, xattr, nt-acl, idmap, file-sharing]
requires: ["Rocky 9.x VM with root", "samba + samba-client + samba-common + cifs-utils installed", "SELinux enforcing (getenforce = Enforcing) with policycoreutils-python-utils for semanage", "attr/libcap for getfattr/setcap (Lab 3)", "a second host or loopback mount for the client labs", "AD lab is dry/conceptual — no domain controller required"]
module_number: 13
status: reviewed
created: 2026-07-08
---

# 13 - Samba and SMB

Backlink: [[00 - Track Overview]]

> Scope: SMB as a protocol and Samba as the Linux implementation of it, built from first principles for the admin who has bounced off Samba three times. Start with what SMB *is* (a stateful, authenticated, Windows-native file/print protocol) and why that single fact forces every design decision that confuses people: a separate password store, its own daemons, its own ACL model, its own name-resolution stack. Then go deep on the daemon split (`smbd`/`nmbd`/`winbindd`), `smb.conf` anatomy, the passdb and the NT hash, share security, AD membership and id-mapping, and the NT-ACL-in-an-xattr model. The through-line: **most Samba pain is identity and permissions, not the protocol** — reconciling an SMB identity with a POSIX one, and reconciling a Windows NT ACL with the Unix mode that is always the real ceiling. By the end you should be able to stand up and secure a share, map an SMB identity to a POSIX identity in your sleep, read a `testparm`/`smbstatus` dump like a sentence, and walk all three permission layers (share ACL, NT ACL, POSIX) to find who is actually denying a write.

---

## Concept deep-dive

### 1. What SMB/CIFS actually is, and why the dialect matters

Strip away the folklore and SMB (Server Message Block) is a **request/response protocol for remote file and printer access**, born in the DOS/Windows world in the 1980s. A client opens a TCP connection (port 445 on anything modern), authenticates, connects to a named share (a "tree connect"), and then issues operations — open, read, write, query-info, set-info, close — against files inside that share. It is **stateful** (the server tracks your open handles, byte-range locks, and change-notify subscriptions) and **authenticated by default** (there is a real identity behind every session). Hold onto those two properties: statefulness is why `smbd` forks a process per connection and why `smbstatus` can show you live locks, and mandatory authentication is why Samba needs its own password database. Samba is the open-source suite that speaks this protocol on Unix — `samba(7)` describes it as "a collection of programs that implements the Server Message Block (SMB) protocol for UNIX systems and provides Active Directory services."

"CIFS" (Common Internet File System) is a marketing name Microsoft slapped on the SMB1 generation in the late 1990s. People use "SMB" and "CIFS" interchangeably, but precisely, **CIFS == SMB1**, the ancient dialect. The name survives on Linux mostly in the *kernel client*: the module is `cifs.ko` and you mount with `mount -t cifs`, even though that client happily negotiates modern SMB3. So "cifs" in a mount command is a historical label, not a statement about which dialect is on the wire.

The dialect generations, which is the single most useful thing to have straight:

- **SMB1 / CIFS** (`NT1`, plus even older `LANMAN1`/`LANMAN2`/`CORE`). 1980s–90s design: no meaningful encryption, no secure dialect negotiation (so it's downgrade-attackable), chatty and high-latency, and dependent on NetBIOS for name resolution. This is the protocol EternalBlue/WannaCry rode in on. It is dead: Samba 4.11 (2019) removed SMB1 from the default negotiation and Microsoft has been ripping the SMB1 client/server out of Windows. Do not enable it unless a genuinely ancient client leaves you no choice.
- **SMB2 (2.0.2 through 2.1)**, introduced with Vista / Server 2008. A radical simplification: a handful of compound-able commands instead of hundreds, large reads/writes, request pipelining ("credits"), durable handles. This is the modern floor.
- **SMB3 (3.0, 3.0.2, 3.1.1)**, from Windows 8 / Server 2012 onward. Adds end-to-end **encryption**, pre-auth integrity (3.1.1) that defeats downgrade attacks, secure negotiation, multichannel, and RDMA (SMB Direct). `SMB3_11` (3.1.1) is the current best dialect.

On a stock Rocky 9 box the negotiation is already sane. `smb.conf(5)` documents `client min protocol = SMB2_02` and `client max protocol = default` (which resolves to `SMB3_11`); since Samba 4.11 the server side defaults to `server min protocol = SMB2_02` and negotiates up to `SMB3_11`. Net effect: SMB1 is off, SMB2 is the floor, SMB3.1.1 is used whenever the client can. To raise the floor explicitly you set, in `[global]`, `server min protocol = SMB3_00`.

Scale/failure notes: the two classic dialect failures are equal-and-opposite. (1) Someone re-enables SMB1 (`server min protocol = NT1`) to appease one legacy scanner/appliance and reopens the whole box to downgrade and pre-auth attacks — this is a finding on every audit. (2) Someone raises `server min protocol` to `SMB3_11` for hardening and silently locks out an older client fleet or a backup appliance that only speaks SMB2, producing "mount works from my laptop, fails from the NAS." Always confirm the *oldest* client that must connect before touching the protocol floor.

### 2. The daemons: smbd, nmbd, winbindd (and why there are three)

The three-daemon split trips up everyone, because most of the time you only need one of them. Each maps to a distinct job and a distinct systemd unit.

- **`smbd(8)`** — "provides the file and print services to SMB clients." This is the core. It terminates SMB sessions, authenticates users, and does the actual file and print I/O. Because SMB is stateful and per-connection, `smbd` **forks one process per client connection** (you'll see many `smbd` processes under load, one per session). Unit: `smb.service`. If you run any Samba file server at all, you run `smbd`.
- **`nmbd(8)`** — "provides NetBIOS nameservice and browsing support." It handles NetBIOS-over-TCP name registration/resolution and the legacy "Network Neighborhood" browse list. Unit: `nmb.service`. Here's the part people miss: **NetBIOS is an SMB1-era mechanism.** On an SMB2/3-only network where DNS (or WS-Discovery) does name resolution, you often don't need `nmbd` at all. Run it only if you actually need NetBIOS name resolution or browse-list advertising. Treating `nmb` as mandatory is a common cargo-cult.
- **`winbindd(8)`** — "used for integrating authentication and the user database into unix." This is the domain-membership daemon. When the box is joined to a domain (AD member or the legacy NT4 style), `winbindd` resolves *domain* users and groups to Unix UID/GID via NSS, authenticates domain logins via PAM, and maintains the machine trust to the DC. Unit: `winbind.service`. **You do not run `winbindd` on a standalone server** — it exists purely to bridge a domain into the local Unix identity space.

One more daemon that causes real confusion: `samba(8)` (unit `samba.service`) is a *different* program used **only** when the box is an Active Directory **Domain Controller**. In that mode `samba` subsumes the file/print/AD services and you do **not** run `smbd`/`nmbd` alongside it. So the mental model is two mutually exclusive worlds: file-server mode runs `smbd` (+ optionally `nmbd`, + `winbindd` if domain-joined); AD-DC mode runs `samba`. Ninety-nine percent of the time you support the first.

Supporting programs you'll live in (all from `samba(7)`): `smbclient` (an ftp-like client), `testparm` (config validator), `smbstatus` (live sessions/locks), `smbpasswd`/`pdbedit` (account management), `net` (the swiss-army admin tool), `wbinfo` (winbind diagnostics), `nmblookup` (NetBIOS queries), `samba-tool` (AD administration).

Scale/failure notes: the most common "why won't Samba start / why is it broken" root causes here are (a) running the wrong daemon set — someone enabling `smb` on a box that's supposed to be an AD DC, or enabling `winbind` on a standalone server where it has nothing to do; and (b) forgetting that `smbd` forks per connection, so a `ulimit`/`nofile` ceiling or `max smbd processes` cap manifests as "new clients can't connect" only past a certain concurrency. `smbstatus -p` (process list) is your first look when connections are being refused under load.

### 3. `smb.conf` anatomy: `[global]` versus shares

Everything lives in `/etc/samba/smb.conf`, an INI-style file with `[section]` headers. There are exactly two kinds of section and understanding the split is 80% of reading any Samba config.

- **`[global]`** holds parameters that configure the server as a whole *or* set defaults inherited by every share. In `smb.conf(5)` these are tagged `(G)`.
- **Share sections** — `[sharename]` — each export one resource (a directory, a printer). Parameters usable in a share are tagged `(S)`; crucially, most `(S)` parameters can *also* appear in `[global]`, where they become the default for all shares. So `read only = yes` in `[global]` makes every share read-only unless a share overrides it. This inheritance is why a parameter you "didn't set on this share" still has an effect.

Two special sections: **`[homes]`** auto-maps each authenticated user to a share named after them, pointing at their Unix home directory (so `alice` connecting to `\\server\alice` lands in `/home/alice`); and **`[printers]`** exposes the system print queues.

The `[global]` parameters that decide the server's whole personality:

- `workgroup` — the NetBIOS workgroup, or the short NT domain name (e.g. `WORKGROUP`, or `SAMDOM`).
- `server role` — the single most important selector. Valid values in `smb.conf(5)`: `standalone server`, `member server`, `classic primary domain controller`, `classic backup domain controller`, `active directory domain controller`, and `auto` (the default, which derives the role from `security`). Setting `server role` explicitly is the modern, unambiguous way to pick what the box is.
- `security` — the older knob that overlaps with `server role`. `user` (the default: authenticate against the local Samba account database), `domain` (NT4 domain member), `ads` (Active Directory member). For a standalone file server, `security = user`.
- `passdb backend` — where local Samba accounts live; `tdbsam` is the Rocky default (see §5).
- `server min protocol` / `server max protocol` — the dialect floor/ceiling from §1.

Scale/failure notes: `smb.conf` is deceptively forgiving — a typo'd parameter name is often silently ignored, and a share that inherits a bad `[global]` default fails in a way that looks share-specific. **Never edit `smb.conf` without running `testparm` afterward** (§ Lab 4); it's the only thing that tells you the file will actually load and shows you the *effective* config after inheritance and defaults are applied. The second classic trap is `security` and `server role` disagreeing; set `server role` explicitly and let `security` follow, rather than fighting the `auto` derivation.

### 4. Defining and securing a share

A share is a directory plus an access policy. The `(S)` parameters, with their verified `smb.conf(5)` defaults, are the vocabulary:

- `path` — the directory to export, e.g. `path = /srv/samba/finance`.
- `valid users` — who may connect at all; accepts users and `@group`, e.g. `valid users = alice @finance`.
- `read only` — the write gate. On a share it **defaults to read-only** (`read only = yes`); you open writes with `read only = no`. The inverted synonyms `writable = yes` / `writeable = yes` / `write ok = yes` all mean `read only = no` — a frequent source of "wait, which way does this flag point?" confusion. Pick one spelling and stick to it.
- `write list` — users/groups who get write access *even on a read-only share*, e.g. `write list = @admins`.
- `browseable` (aka `browsable`) — whether the share shows up in the browse list; default `yes`. `browseable = no` hides it (still reachable by explicit path). Hiding is not security; it's tidiness.
- `create mask` — bitwise-ANDed with the mode of newly created files; default `0744`. `directory mask` — same for new directories; default `0755`.
- `force group` / `force user` — force the group (or user) identity used for all file access in the share, so files land with a predictable owning group regardless of who wrote them.
- `guest ok` (aka `public`) — allow access with no password, mapped to the guest account; default `no`.
- `hosts allow` / `hosts deny` — host-based ACL by name/IP/subnet.
- `comment` — free-text description shown to clients.

A worked, secured department share — authenticated group members only, new files group-writable and inheriting the right group:

```
[finance]
    comment = Finance department share
    path = /srv/samba/finance
    valid users = @finance
    read only = no
    browseable = yes
    create mask = 0660
    directory mask = 0770
    force group = finance
```

Securing a share on Rocky is **three layers that must all agree**, and this is where most "permission denied over SMB but the Unix perms look fine" tickets live:

1. **POSIX layer** — the directory's owner/group/mode on the underlying filesystem. `chgrp finance /srv/samba/finance && chmod 2770 /srv/samba/finance` (the `2` is setgid so new files inherit the group — see [[01 - Permissions and Access Control]] §3).
2. **Samba layer** — `valid users`, `read only`, `create mask`, etc., in `smb.conf`.
3. **SELinux layer** — enforcing by default on Rocky, and it will block `smbd` from serving a directory that isn't labeled for Samba even when POSIX and Samba config are perfect. The correct, durable fix is the file-context type `samba_share_t`:
   ```
   semanage fcontext -a -t samba_share_t "/srv/samba/finance(/.*)?"
   restorecon -Rv /srv/samba/finance
   ```
   The looser alternative is the boolean `samba_export_all_rw` (or `_ro`), which lets `smbd` serve content regardless of its type label — broadest blast radius, use only when you genuinely can't relabel a tree (e.g. a mount owned by another domain). For the `[homes]` share you additionally need `setsebool -P samba_enable_home_dirs on`. This is the SMB instance of the general rule from [[12 - SELinux and Hardening]]: relabel with `semanage fcontext` + `restorecon` (durable), don't `chcon` (evaporates on relabel).

And the firewall: Samba ships a predefined firewalld service. `firewall-cmd --permanent --add-service=samba && firewall-cmd --reload` opens 445/tcp, 139/tcp, and the NetBIOS UDP ports.

Scale/failure notes: the three-layer model is the whole game. A senior debugging "access denied over SMB" checks all three in order and states which one fired: POSIX (`ls -ld` the path, check the setgid bit and group), Samba (`testparm` + `valid users`/`read only`), SELinux (`ls -Zd` the path for `samba_share_t`, and `ausearch -m avc -ts recent` for a `smbd_t` denial). Jumping to `setsebool samba_export_all_rw 1` because it "makes it work" is the SMB version of `setenforce 0` — it papers over a labeling problem and over-permits the whole server.

### 5. Authentication and the passdb: why SMB needs its own password store

This is the concept that unlocks Samba, and almost nobody explains it. **SMB does not authenticate with the hash in `/etc/shadow`.** The protocol authenticates with a challenge/response built on the **NT hash** — an MD4 hash of the password encoded as UTF-16LE. To compute the challenge response, the *server* must possess the NT hash itself. But `/etc/shadow` stores a one-way crypt/SHA-512 hash that is useless for the SMB challenge (you can't derive the NT hash from it). Therefore Samba is *forced* to keep its own credential store — the **passdb** (historically "the SAM"). This is not Samba being difficult; it's a direct consequence of the wire protocol.

The consequence you must internalize: **every SMB user needs two things** — (a) a POSIX account (in `/etc/passwd` or NSS) to own files and pass Unix permission checks, and (b) a passdb entry holding the NT hash to actually authenticate over SMB. The POSIX account supplies the uid/gid; the passdb supplies the SMB credential. Miss either half and you get a confusing failure: no POSIX account → the SMB name has no Unix identity to map to; no passdb entry → authentication fails outright.

The `passdb backend` parameter selects the store:

- **`tdbsam`** (Rocky default) — accounts in a local trivial database (`passdb.tdb`). Zero config, recommended by the Samba team for sites under a few hundred users.
- **`ldapsam`** — accounts in LDAP, for large or multi-server deployments.
- **`smbpasswd`** — the legacy flat text file (`/etc/samba/smbpasswd`); deprecated, kept for backward compatibility.

Two tools manage the passdb, and knowing which does what saves time:

- **`smbpasswd(8)`** — day-to-day password and simple account management, operating against whatever backend is configured (not just the legacy file). `smbpasswd -a <user>` adds a user (the POSIX account must already exist), plain `smbpasswd <user>` changes a password, `-x` deletes, `-d`/`-e` disable/enable, `-n` sets a null password, `-s` reads from stdin for scripting. As root it edits the passdb directly.
- **`pdbedit(8)`** — the fuller account-database manager (root only) that does what `smbpasswd` can't. `pdbedit -L` lists accounts, `pdbedit -L -v` dumps the full SAM record for each; `-a -u`/`-x -u` add/delete; `-P <policy>` reads an account policy (min password length, lockout, password age), and paired with `-C <value>` sets it. Its unique power is **backend migration**: `pdbedit -i <src> -e <dst>` imports from one passdb backend and exports to another (e.g. migrate `smbpasswd` → `tdbsam`, or `tdbsam` → `ldapsam`).

Rule of thumb: `smbpasswd` for passwords and enable/disable; `pdbedit` to inspect the full record, manage policy, or migrate backends.

**User mapping.** Samba always needs a Unix uid/gid for each SMB user. On a standalone/local-user server the Unix account must exist before `smbpasswd -a`. When Windows usernames don't match Unix usernames, `username map = /etc/samba/smbusers` maps them (e.g. Windows `Administrator` → Unix `root`, or several SMB names collapsed onto one Unix account). On a domain member you don't create local accounts at all — winbind synthesizes them (§6).

Scale/failure notes: the number-one Samba support ticket in the standalone world is "I created the Linux user and set the password but SMB login fails" — because the user has a POSIX account but no passdb entry (`smbpasswd -a` was never run), or was added but not enabled. `pdbedit -L -v <user>` is the instant diagnostic: if the account isn't listed, the passdb half is missing. The second trap is password *drift*: the Unix password and the Samba NT hash are independent stores, so changing one via `passwd` does not change the other. Sites that need them in sync use `unix password sync = yes` (which drives `passwd` from `smbpasswd`) or move to AD so there's one authority.

### 6. Server roles and AD membership: winbind vs SSSD, `net ads join`, idmap

Joining Active Directory is where Samba gets deep, but the shape is simple: the box becomes a **domain member**, domain users/groups become usable Unix identities, and `smbd` authenticates clients against the domain's DCs via Kerberos. The `[global]` skeleton for an AD member server:

```
[global]
    security = ads
    workgroup = SAMDOM
    realm = SAMDOM.EXAMPLE.COM
    kerberos method = secrets and keytab

    winbind refresh tickets = yes
    winbind use default domain = yes
    template shell = /bin/bash
    template homedir = /home/%D/%U

    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config SAMDOM : backend = rid
    idmap config SAMDOM : range = 10000-999999
```

Two ways to actually join:

- **`net ads join -U administrator`** (`net(8)`) — the manual path. It creates the machine (workstation trust) account in AD and stores the machine secret locally. Relatives: `net ads testjoin` (validate), `net ads leave` (unjoin), `net ads info`/`net ads lookup` (DC info).
- **`realm join --membership-software=samba --client-software=winbind ad.example.com -U administrator`** (`realm(8)`, realmd) — the higher-level path that wires `smb.conf`, the join, `nsswitch.conf`, and PAM in one step. `--client-software` accepts `winbind` or `sssd`; `realm discover`/`realm list`/`realm leave` handle the rest of the lifecycle.

Then NSS makes domain users appear as Unix users (`/etc/nsswitch.conf`, keeping `files` first): `passwd: files winbind` and `group: files winbind`. On Rocky, PAM+NSS are wired together with **authselect**: `authselect select winbind with-mkhomedir --force` (add `oddjobd` for on-demand home creation). Bring it up and verify: `systemctl enable --now smb nmb winbind`, then `wbinfo --ping-dc`, `wbinfo -u`, `getent passwd 'SAMDOM\demo01'`.

**`winbind` vs `SSSD`** is the decision that matters and has a clean answer for our world: **if the box is a Samba file server, use winbind.** Red Hat supports a Samba/`smbd` file server on AD only with `winbindd` providing the domain identities, because SSSD lacks the Windows-ACL support and NTLM fallback that `smbd` relies on. SSSD is the lighter, preferred choice for plain AD *client* login (SSH, sudo, workstation auth) where no Samba file service runs. SSSD also supports only a single AD forest; multi-forest, or a need for NTLM/NetBIOS, pushes you to winbind.

**ID mapping (`idmap config`)** is the piece that causes silent, cross-server data-ownership corruption when done wrong, so it earns real attention. AD identifies principals by **SID**; Unix needs a numeric **uid/gid**. The idmap layer bridges them, configured per-domain (`idmap config <DOMAIN> : backend` and `: range`), with the mandatory `*` default domain that must use a *writable* backend (`tdb`) for the BUILTIN SIDs, and non-overlapping ranges. The backends (each has its own man page, e.g. `idmap_rid(8)`):

- **`tdb`** — the default *writable, allocating* backend: hands out IDs first-come-first-served from its range into a local database. **Not deterministic across servers** — the same user gets a different uid on each host. Use it only for the `*` default domain.
- **`rid`** — *algorithmic and deterministic*, no database: `uid = RID - base_rid + range_low`. Identical config on every member → identical IDs everywhere, with no AD schema changes. Cannot be the default backend. This is the best general choice when you don't control AD's POSIX attributes.
- **`ad`** — *read-only*, reads `uidNumber`/`gidNumber` (RFC2307 attributes) straight from AD, and can pull login shell/homedir too. Deterministic and centrally authoritative, but requires AD to be pre-populated with POSIX attributes. Use when AD already carries them or you need central control of IDs.
- **`autorid`** — like `rid` but auto-assigns range slots per domain; good for many or unknown trusted domains with zero manual ID management.

Scale/failure notes: idmap misconfiguration is the classic multi-server disaster. Two Samba members both using `tdb` for the domain will assign the *same* AD user *different* uids, so a file written by "alice" on server A shows as owned by "bob" (or an unmapped number) on server B — invisible until users notice cross-server ownership chaos. The fix is a deterministic backend (`rid` with identical `smb.conf`, or `ad` reading from a populated AD) on every member. Overlapping ranges are the other footgun: the `*` range and a domain range must be disjoint, or BUILTIN/domain SIDs collide. Diagnose the whole chain with `wbinfo`: `wbinfo -p` (daemon alive) → `wbinfo -t` (trust secret / secure channel) → `wbinfo -u` (winbind enumeration) → `getent passwd <user>` (NSS wiring). If `wbinfo -u` works but `getent` doesn't, the problem is `nsswitch.conf`, not the join.

### 7. Permissions and ACLs: reconciling the POSIX and Windows models

Two permission worlds coexist on a Samba server, and reconciling them is where most real-world "access denied" tickets are born. The **POSIX layer** is Unix mode bits plus POSIX draft ACLs on the backing filesystem (xfs on Rocky 9 has ACL support on by default; see [[01 - Permissions and Access Control]] §5). The **NT ACL layer** is the Windows security-descriptor model: Windows SIDs mapped to a richer allow/deny permission set that POSIX ACLs cannot fully express. `vfs_acl_xattr(8)` is the module that bridges them: with `vfs objects = acl_xattr` it stores the full Windows NT ACL in the **`security.NTACL`** extended attribute of each file, so permissions set from the Windows "Security" tab survive even when the POSIX model can't represent them. Read that xattr raw with `getfattr -n security.NTACL <file>`, or manage the NT ACL from Linux with `smbcacls //server/share <file> -U <user>`. Without `acl_xattr`, `nt acl support = yes` (the default) maps NT ACLs onto POSIX ACLs as best it can, which is lossy for anything POSIX can't encode.

**How a new file gets its mode is the part that surprises people.** When a client creates a file, Samba computes the mode from the requested access AND-ed with `create mask` (default `0744`) then OR-ed with `force create mode`; directories use `directory mask`/`force directory mode`. So a share left at defaults silently strips group- and other-write off every new file, and "the app can't write the file its teammate just created" traces straight back to `create mask = 0744`. The usual group-collaboration share sets `force group = <grp>`, `create mask = 0664`, and `directory mask = 2775` (the leading `2` is setgid, so children inherit the group), often with `force create mode = 0664`. `inherit permissions = yes` makes new objects copy the parent's mode instead; `inherit acls = yes` and `map acl inherit = yes` carry ACL inheritance down the tree.

**POSIX permissions are a hard ceiling the NT ACL cannot exceed.** This is the single most confusing Samba behavior: you can grant a user Full Control on the Windows Security tab, but if the underlying Unix mode or POSIX ACL doesn't allow the write, the kernel still denies it, Windows reports "access denied," and `ls -l` looks reasonable. Effective access is the AND of the share level (`valid users`/`write list`/`read only`), Samba's NT ACL check, and the POSIX check on the backing file. The senior instinct is to check all three layers rather than the one the user is pointing at: `testparm -v` for the effective share knobs, `smbcacls` for the NT ACL, and `getfacl`/`ls -l` for the POSIX reality.

One xattr caveat carried from [[04 - Filesystems and the VFS]] §9: SMB round-trips `user.*` xattrs and stores its own `security.NTACL` on the server side, but the protocol does not transport the `security.*` namespace, so file capabilities (`security.capability`) and SELinux labels (`security.selinux`) do not survive on an SMB mount, the same limitation NFS has.

Scale/failure notes: the recurring permission failures are (1) `create mask` stripping group-write so collaboration breaks on newly created files (fix with `create mask`/`directory mask`/`force group` plus a setgid directory); (2) treating the Windows ACL as authoritative when POSIX is the ceiling, chasing the NT ACL while the Unix mode is the real denier; and (3) forgetting SELinux, where a wrong `security.selinux` type (not `samba_share_t`, or `samba_export_all_rw` off) makes smbd's own access fail in a way that reads like a permission bug but is a labeling bug (see [[12 - SELinux and Hardening]]).

### 8. Useful VFS modules

Samba's I/O path is a stack of pluggable **VFS modules** listed in `vfs objects` (order matters — they're layered). The ones worth knowing, all in the `samba` package:

- **`vfs_acl_xattr(8)`** — stores the NT ACL in `security.NTACL` (§7); the backbone of Windows-ACL shares.
- **`vfs_fruit(8)`** — macOS interop: implements Apple's SMB2 AAPL extensions (fast Finder enumeration, resource forks, FinderInfo) and Time Machine support. It **must** be stacked with `streams_xattr`, and `fruit` must appear *before* `streams_xattr`; if you're also translating illegal filename characters, put `catia` first: `vfs objects = catia fruit streams_xattr`. Key options include `fruit:time machine = yes` and `fruit:metadata`. Mis-ordering this stack is a classic "macOS clients behave weirdly" cause.
- **`vfs_shadow_copy2(8)`** — exposes filesystem snapshots (LVM/Btrfs/`.snapshots`) as Windows "Previous Versions"/VSS, so users self-serve file restores from the Explorer Properties tab. Options like `shadow:snapdir` and `shadow:format` (strftime) map snapshot directories to the VSS timeline.
- **`vfs_full_audit(8)`** — logs share operations (open/read/write/unlink) to syslog for auditing/compliance.
- **`vfs_recycle(8)`** — recycle-bin behavior: deletes move to a repository directory instead of unlinking (`recycle:repository`, `recycle:keeptree`, `recycle:versions`).

Adjacent modules present on Rocky: `vfs_catia`, `vfs_streams_xattr`, `vfs_worm`, `vfs_virusfilter`, `vfs_btrfs`, `vfs_snapper`.

Scale/failure notes: VFS module *ordering* is the subtle failure. The stack is applied in the sequence listed in `vfs objects`, so `fruit` after `streams_xattr` breaks Apple metadata, and putting an auditing/recycle module in the wrong position can mask or double-handle operations. When a customer's macOS Time Machine or "Previous Versions" behaves oddly, check the `vfs objects` order first, before anything else.

### 9. The client side: `smbclient` and `mount.cifs`

Two ways to consume an SMB share from Linux.

**`smbclient(1)`** (package `samba-client`) is an ftp-like client — no mount, interactive or scripted. List shares on a server: `smbclient -L //server -N` (the `-N` suppresses the password prompt for an anonymous listing; `-U%` forces a null session). Connect to a share: `smbclient //server/share -U DOMAIN/user`, then use ftp-style verbs inside (`ls`, `cd`, `get`, `put`, `mget`, `mput`, `prompt`, `recurse`). Script it non-interactively with `-c "cd sub; get file"`. Cap the dialect ceiling with `-m SMB3` (`--max-protocol`; it still negotiates down). `smbclient` is the fastest way to answer "is the server even answering and what shares does it advertise" without touching the mount stack.

**`mount.cifs(8)`** (package `cifs-utils`) is the kernel client — a real mount via `cifs.ko`:

```
mount -t cifs //server/share /mnt/point -o vers=3.1.1,credentials=/etc/smb-creds,uid=1000,gid=1000,seal
```

The options that matter:

- **Credentials**: prefer `credentials=<file>` (a root-owned file with `username=`, `password=`, `domain=` lines) so secrets stay out of `/proc/mounts` and shell history. `username=`/`password=`/`domain=` inline also exist but leak.
- **Dialect**: `vers=` takes `1.0`, `2.0`, `2.1`, `3.0`, `3.02`, `3.1.1`, `3`, or `default`. Use `vers=3.1.1` against EL9 servers; never `1.0`.
- **Encryption**: `seal` requests SMB3 per-share encryption.
- **Ownership/perms**: `uid=`, `gid=`, `file_mode=`, `dir_mode=`, `forceuid`/`forcegid`. These matter most against Windows/SMB2/3 servers where Unix extensions are off — without them everything shows as the mounting user or root. This is a direct consequence of §7: the server isn't sending Unix ownership, so the client synthesizes it from mount options.
- **Caching/perf**: `cache=` (`none`/`strict`/`loose`), `actimeo=` (attribute-cache timeout), `multiuser` (per-user credentials against the server), `noserverino` (client generates inode numbers).

Scale/failure notes: the two recurring client failures are (1) a `vers=` mismatch — an old client defaulting to a dialect the hardened server refuses, giving a cryptic mount error rather than "protocol too old," fixed by pinning `vers=`; and (2) the ownership surprise — files on a mounted Windows share all showing as `root:root` or the mounting user because the admin didn't set `uid=`/`gid=`/`file_mode=`, which is not a permissions bug but the expected result of the server not transporting Unix identity. And the xattr caveat from §7 shows up client-side too: `getcap`/`getfattr -n security.capability` on files under a CIFS mount returns nothing, because SMB does not carry the `security.*` namespace.

---

## Hands-on labs

> All labs assume a **throwaway Rocky 9 VM** with root (or `sudo`). SELinux should be **enforcing** (`getenforce`), because half the point is learning to work *with* it, not around it. Install the tooling once:
>
> ```bash
> sudo dnf install -y samba samba-client samba-common cifs-utils \
>   policycoreutils-python-utils attr libcap
> ```
> `samba`/`samba-common` give `smbd`/`nmbd`/`testparm`/`pdbedit`; `samba-client` gives `smbclient`; `cifs-utils` gives `mount.cifs`; `policycoreutils-python-utils` gives `semanage`/`restorecon`; `attr`/`libcap` give `getfattr`/`setcap` for Lab 3. Each lab cleans up after itself. The AD lab (Lab 5) is deliberately dry — no domain controller required.

### Lab 1 — Stand up a standalone share and reach it with both clients

**Objective:** Build a minimal, correctly-secured standalone share (POSIX + Samba + SELinux + firewall), then read and write it with `smbclient` and `mount.cifs` on the loopback interface — proving all three security layers agree.

**Setup:**
```bash
sudo groupadd -f smbdemo
sudo useradd -M -s /sbin/nologin -G smbdemo smbuser 2>/dev/null || sudo usermod -aG smbdemo smbuser
sudo mkdir -p /srv/samba/demo
sudo chgrp smbdemo /srv/samba/demo
sudo chmod 2770 /srv/samba/demo            # setgid so new files inherit the group
echo "hello from the server" | sudo tee /srv/samba/demo/readme.txt >/dev/null
sudo chgrp smbdemo /srv/samba/demo/readme.txt
```

**Steps:**
1. Append a share to `smb.conf` and set the global role explicitly:
   ```bash
   sudo tee -a /etc/samba/smb.conf >/dev/null <<'EOF'

   [demo]
       comment = Lab 1 standalone share
       path = /srv/samba/demo
       valid users = @smbdemo
       read only = no
       browseable = yes
       create mask = 0660
       directory mask = 0770
       force group = smbdemo
   EOF
   # ensure the global role is unambiguous (edit [global] if needed):
   sudo grep -qE '^\s*server role' /etc/samba/smb.conf || \
     sudo sed -i '/^\[global\]/a \    server role = standalone server' /etc/samba/smb.conf
   ```
2. Validate before starting anything — `testparm` is non-negotiable:
   ```bash
   testparm -s 2>&1 | sed -n '1,40p'
   ```
3. Label for SELinux and open the firewall:
   ```bash
   sudo semanage fcontext -a -t samba_share_t "/srv/samba/demo(/.*)?"
   sudo restorecon -Rv /srv/samba/demo
   ls -Zd /srv/samba/demo                    # expect samba_share_t
   sudo firewall-cmd --permanent --add-service=samba && sudo firewall-cmd --reload
   ```
4. Create the Samba credential (the passdb half — see Lab 2 for the deep dive) and start the daemon:
   ```bash
   (echo 'Lab1Pass!'; echo 'Lab1Pass!') | sudo smbpasswd -s -a smbuser
   sudo smbpasswd -e smbuser
   sudo systemctl enable --now smb
   ```
5. List and enter the share with `smbclient` over loopback:
   ```bash
   smbclient -L //127.0.0.1 -U 'smbuser%Lab1Pass!'         # 'demo' appears
   smbclient //127.0.0.1/demo -U 'smbuser%Lab1Pass!' \
     -c 'get readme.txt /tmp/from_smb.txt; put /etc/hostname uploaded.txt; ls'
   cat /tmp/from_smb.txt                                    # "hello from the server"
   ```
6. Now mount it with the kernel client and write through the mount:
   ```bash
   printf 'username=smbuser\npassword=Lab1Pass!\n' | sudo tee /root/.smbcred >/dev/null
   sudo chmod 600 /root/.smbcred
   sudo mkdir -p /mnt/demo
   sudo mount -t cifs //127.0.0.1/demo /mnt/demo \
     -o vers=3.1.1,credentials=/root/.smbcred,uid=$(id -u smbuser),gid=$(getent group smbdemo | cut -d: -f3)
   mount | grep /mnt/demo                                   # confirm vers=3.1.1
   echo "written via mount.cifs" | sudo tee /mnt/demo/via_mount.txt >/dev/null
   ls -l /mnt/demo
   ```

**Prove it:**
```bash
# The file the mount wrote is visible on the server's real filesystem, group-owned smbdemo:
sudo ls -l /srv/samba/demo/via_mount.txt | grep -q smbdemo && echo "WRITE LANDED WITH CORRECT GROUP"
# The negotiated dialect is SMB3, not SMB1:
sudo smbstatus -b 2>/dev/null | grep -Ei 'SMB3' && echo "DIALECT IS SMB3"
# SELinux label is correct (serving worked WITHOUT samba_export_all_rw):
ls -Zd /srv/samba/demo | grep -q samba_share_t && echo "LABELED samba_share_t"
```
Seeing all three lines means POSIX ownership, Samba auth, SELinux labeling, and the SMB3 dialect all lined up.

**Teardown:**
```bash
sudo umount /mnt/demo 2>/dev/null; sudo rmdir /mnt/demo 2>/dev/null
sudo systemctl disable --now smb
sudo smbpasswd -x smbuser 2>/dev/null
sudo semanage fcontext -d "/srv/samba/demo(/.*)?" 2>/dev/null
sudo firewall-cmd --permanent --remove-service=samba && sudo firewall-cmd --reload
sudo userdel smbuser 2>/dev/null; sudo groupdel smbdemo 2>/dev/null
sudo rm -rf /srv/samba/demo /root/.smbcred /tmp/from_smb.txt
# remove the [demo] block you appended (and the server role line if sed added it):
sudo sed -i '/^\[demo\]/,/^$/d' /etc/samba/smb.conf
```

### Lab 2 — Authentication and the passdb: prove the two-account model

**Objective:** Demonstrate concretely that an SMB user needs *both* a POSIX account and a passdb entry, that the NT hash store is independent of `/etc/shadow`, and drive `smbpasswd` and `pdbedit` including a backend inspection.

**Setup:**
```bash
sudo useradd -M -s /sbin/nologin authdemo
echo 'authdemo:UnixPw123!' | sudo chpasswd     # sets the UNIX (shadow) password only
sudo systemctl enable --now smb
```

**Steps:**
1. Show the POSIX account exists but has no SMB identity yet, and that SMB login fails:
   ```bash
   getent passwd authdemo                                  # POSIX account present
   sudo pdbedit -L | grep authdemo || echo "NOT in passdb yet"
   smbclient -L //127.0.0.1 -U 'authdemo%UnixPw123!' ; echo "exit=$?"
   ```
   The login fails even though the *Unix* password is correct — SMB can't use the shadow hash.
2. Add the passdb entry (the NT-hash half) with a *different* password to prove the stores are independent:
   ```bash
   (echo 'SmbPw456!'; echo 'SmbPw456!') | sudo smbpasswd -s -a authdemo
   sudo smbpasswd -e authdemo
   ```
3. Now the SMB password works and the Unix password still does not:
   ```bash
   smbclient -L //127.0.0.1 -U 'authdemo%SmbPw456!'  >/dev/null && echo "SMB PW WORKS"
   smbclient -L //127.0.0.1 -U 'authdemo%UnixPw123!' >/dev/null 2>&1 || echo "UNIX PW REJECTED BY SMB"
   ```
4. Inspect the full SAM record with `pdbedit` and confirm the configured backend:
   ```bash
   sudo pdbedit -L -v authdemo | sed -n '1,20p'            # full record: SIDs, flags, times
   testparm -s --parameter-name 'passdb backend' 2>/dev/null   # tdbsam on Rocky
   ```
5. See the account-policy surface `pdbedit` exposes that `smbpasswd` doesn't:
   ```bash
   sudo pdbedit -P 'minimum password length'               # read a policy value
   ```

**Prove it:**
```bash
# The two credential stores are genuinely independent:
sudo pdbedit -L | grep -q authdemo && echo "PASSDB ENTRY EXISTS" && \
smbclient -L //127.0.0.1 -U 'authdemo%SmbPw456!' >/dev/null 2>&1 && echo "SMB AUTH USES NT HASH, NOT SHADOW"
```
If the SMB password authenticates while the Unix password is rejected by SMB, you've proven the NT-hash passdb is a separate store — the entire reason Samba needs a passdb.

**Teardown:**
```bash
sudo smbpasswd -x authdemo 2>/dev/null
sudo userdel authdemo 2>/dev/null
sudo systemctl disable --now smb
```

### Lab 3 — Permissions and ACLs: diagnose why a user cannot write

**Objective:** Reproduce the two most common Samba permission failures on one share, `create mask` silently stripping group-write from new files, and POSIX permissions acting as a ceiling the share config can't override, then inspect both permission views (`getfacl` for POSIX, `smbcacls` for the NT ACL) so you can tell which layer is denying.

**Setup:** run as root on a Rocky 9 box with `samba`, `samba-client`, and `acl` installed; SELinux stays enforcing. Create a group, two users, and a group-collaboration directory.
```bash
groupadd -f team
useradd -m -G team alice 2>/dev/null; useradd -m -G team bob 2>/dev/null
printf 'Passw0rd1!\nPassw0rd1!\n' | smbpasswd -a -s alice
printf 'Passw0rd1!\nPassw0rd1!\n' | smbpasswd -a -s bob
mkdir -p /srv/team
chgrp team /srv/team; chmod 2775 /srv/team          # setgid: children inherit group 'team'
chcon -t samba_share_t /srv/team
cat >> /etc/samba/smb.conf <<'EOF'

[team]
   path = /srv/team
   valid users = @team
   read only = no
   create mask = 0744
   directory mask = 0755
EOF
testparm -s >/dev/null && systemctl restart smb
```

**Steps:**
1. Reproduce the `create mask` footgun. Write a file through the share as alice, then read its mode on the server side:
   ```bash
   smbclient //localhost/team -U alice%'Passw0rd1!' -c 'put /etc/hostname shared.txt'
   stat -c '%n %A' /srv/team/shared.txt        # group-write bit is absent: create mask 0744 stripped it
   sudo -u bob test -w /srv/team/shared.txt && echo "bob can write" || echo "bob CANNOT write (expected)"
   ```
2. Fix the mask so the team can collaborate, and prove new files now carry group-write:
   ```bash
   sed -i 's/create mask = 0744/create mask = 0664/; s/directory mask = 0755/directory mask = 2775/' /etc/samba/smb.conf
   testparm -s >/dev/null && systemctl restart smb
   smbclient //localhost/team -U alice%'Passw0rd1!' -c 'put /etc/hostname shared2.txt'
   stat -c '%n %A' /srv/team/shared2.txt        # now has group-write (create mask 0664)
   sudo -u bob test -w /srv/team/shared2.txt && echo "bob can write (fixed)"
   ```
3. Show the POSIX ceiling. Tighten the on-disk mode and confirm the share can't grant past it:
   ```bash
   chmod 600 /srv/team/shared2.txt              # owner-only on disk
   smbclient //localhost/team -U bob%'Passw0rd1!' -c 'put /etc/hostname shared2.txt' \
     2>&1 || echo "bob write DENIED by the POSIX ceiling despite valid users=@team"
   ```
4. Inspect both permission views to localize a denial:
   ```bash
   getfacl /srv/team/shared2.txt                                 # the POSIX reality (the ceiling)
   smbcacls //localhost/team shared2.txt -U alice%'Passw0rd1!'   # the NT ACL Samba presents
   ```

**Prove it:**
```bash
stat -c '%n  %A' /srv/team/shared.txt /srv/team/shared2.txt
```
The first file lacking a group-write bit while the second carries it (until step 3 tightened it) is the proof that `create mask`, not the share's `valid users`, governs new-file permissions, and that the on-disk POSIX mode is the final authority over anything the share or NT ACL claims.

**Teardown:**
```bash
sed -i '/^\[team\]/,/directory mask/d' /etc/samba/smb.conf
systemctl restart smb
smbpasswd -x alice; smbpasswd -x bob
userdel -r alice 2>/dev/null; userdel -r bob 2>/dev/null; groupdel team
rm -rf /srv/team
```
(This lab added a `[team]` share, two SMB+POSIX users, a group, and `/srv/team`; the teardown removes all of them.)

### Lab 4 — Troubleshooting: `testparm`, `smbstatus`, and reading the logs

**Objective:** Build the diagnostic reflexes — validate config with `testparm`, watch live sessions and locks with `smbstatus`, turn up logging safely, and reload config without dropping clients. Deliberately break a share and find it by reading tools, not guessing.

**Setup:**
```bash
sudo mkdir -p /srv/samba/tshoot
sudo semanage fcontext -a -t samba_share_t "/srv/samba/tshoot(/.*)?"
sudo restorecon -Rv /srv/samba/tshoot
sudo useradd -M -s /sbin/nologin tshuser 2>/dev/null
(echo 'TshPw000!'; echo 'TshPw000!') | sudo smbpasswd -s -a tshuser ; sudo smbpasswd -e tshuser
sudo tee -a /etc/samba/smb.conf >/dev/null <<'EOF'

[tshoot]
    path = /srv/samba/tshoot
    valid users = tshuser
    read only = no
EOF
sudo systemctl restart smb
```

**Steps:**
1. Introduce a realistic config error and catch it with `testparm` *before* it bites a user:
   ```bash
   sudo sed -i 's/read only = no/read olny = no/' /etc/samba/smb.conf   # typo'd parameter
   testparm -s 2>&1 | grep -i 'ignoring unknown\|olny' || echo "testparm flags unknown parameters"
   sudo sed -i 's/read olny = no/read only = no/' /etc/samba/smb.conf   # fix it
   testparm -s >/dev/null 2>&1 && echo "config valid again"
   ```
2. Use `testparm -v` to see an *effective* default you never set (proving inheritance from §3):
   ```bash
   testparm -sv 2>/dev/null | grep -E 'create mask|server min protocol|map to guest'
   ```
3. Reload config the safe way (no dropped sessions) instead of restarting:
   ```bash
   sudo smbcontrol all reload-config && echo "config reloaded live"
   ```
4. Open a live session from another shell and watch it in `smbstatus`:
   ```bash
   smbclient //127.0.0.1/tshoot -U 'tshuser%TshPw000!' \
     -c 'put /etc/hosts held.txt; posix_whoami; ls' &
   sleep 1
   sudo smbstatus            # connections
   sudo smbstatus -S         # shares view
   sudo smbstatus -p         # smbd processes (per-connection fork model from §2)
   ```
5. Turn up logging to diagnose an auth/access problem, then read the right log file:
   ```bash
   sudo sed -i '/^\[global\]/a \    log level = 3' /etc/samba/smb.conf
   sudo smbcontrol all reload-config
   smbclient //127.0.0.1/tshoot -U 'tshuser%wrongpass' -c 'ls' 2>/dev/null; true
   sudo ls /var/log/samba/
   sudo grep -iE 'authentication|NT_STATUS|denied' /var/log/samba/log.smbd | tail -15
   ```
6. Correlate an SELinux-shaped failure the senior way (even if none fired here, learn the reflex):
   ```bash
   sudo ausearch -m avc -ts recent -c smbd 2>/dev/null | tail -20 || echo "no smbd AVCs (labeling is correct)"
   ```

**Prove it:**
```bash
# testparm catches the bad param, smbstatus sees the fork-per-connection model, logs record the failed auth:
testparm -s >/dev/null 2>&1 && echo "TESTPARM VALIDATES CLEAN CONFIG"
sudo grep -qiE 'NT_STATUS_(LOGON_FAILURE|WRONG_PASSWORD)' /var/log/samba/log.smbd && \
  echo "FAILED AUTH IS IN log.smbd"
```

**Teardown:**
```bash
sudo sed -i '/^\s*log level = 3/d' /etc/samba/smb.conf
sudo smbpasswd -x tshuser 2>/dev/null; sudo userdel tshuser 2>/dev/null
sudo semanage fcontext -d "/srv/samba/tshoot(/.*)?" 2>/dev/null
sudo rm -rf /srv/samba/tshoot
sudo sed -i '/^\[tshoot\]/,/^$/d' /etc/samba/smb.conf
sudo systemctl restart smb
```

### Lab 5 — AD membership, dry run (conceptual, no DC required)

**Objective:** Walk the AD-member configuration and the join/verify command sequence *without* an actual domain controller, so the mechanics from §6 are concrete: what goes in `[global]`, what `net ads join` would do, and the `wbinfo` diagnostic ladder. Nothing here contacts a real domain, so it's safe on any VM.

**Setup:**
```bash
sudo dnf install -y samba-winbind samba-winbind-clients realmd authselect 2>/dev/null
mkdir -p /tmp/adlab
```

**Steps:**
1. Draft an AD-member `[global]` to a scratch file and validate it with `testparm` (validates syntax without joining):
   ```bash
   cat > /tmp/adlab/smb.conf <<'EOF'
   [global]
       security = ads
       workgroup = SAMDOM
       realm = SAMDOM.EXAMPLE.COM
       server role = member server
       kerberos method = secrets and keytab
       winbind refresh tickets = yes
       winbind use default domain = yes
       template shell = /bin/bash
       template homedir = /home/%D/%U

       idmap config * : backend = tdb
       idmap config * : range = 3000-7999
       idmap config SAMDOM : backend = rid
       idmap config SAMDOM : range = 10000-999999
   EOF
   testparm -s /tmp/adlab/smb.conf 2>&1 | sed -n '1,30p'
   ```
2. Read (do not run) the two join paths and articulate what each does:
   ```bash
   cat <<'EOF'
   MANUAL:   net ads join -U administrator
             -> creates the machine trust account in AD, stores the machine secret,
                writes the keytab. Verify with:  net ads testjoin
   REALMD:   realm join --membership-software=samba --client-software=winbind \
                  ad.example.com -U administrator
             -> does the same join AND wires smb.conf, nsswitch.conf, and PAM in one step.
   EOF
   ```
3. Show the NSS wiring that makes domain users into Unix users, and the authselect profile that PAM needs:
   ```bash
   grep -E '^(passwd|group):' /etc/nsswitch.conf              # would become: files winbind
   authselect list                                            # 'winbind' profile is available
   echo "On a real join:  authselect select winbind with-mkhomedir --force"
   ```
4. Walk the `wbinfo` diagnostic ladder (these will fail cleanly with no DC — read the *intent*):
   ```bash
   echo "1) wbinfo -p        # is winbindd alive?"
   echo "2) wbinfo -t        # is the machine trust / secure channel to the DC healthy?"
   echo "3) wbinfo --ping-dc # is a DC reachable?"
   echo "4) wbinfo -u        # can winbind enumerate domain users?"
   echo "5) getent passwd 'SAMDOM\\\\someuser'   # is NSS wired so the user is a Unix user?"
   echo "Rule: if (4) works but (5) fails, the problem is nsswitch, not the join."
   ```
5. Reinforce the idmap decision from §6 in one sentence you could give a customer:
   ```bash
   cat <<'EOF'
   idmap: use 'rid' (deterministic, identical smb.conf on every member -> identical uids,
   no AD schema changes) unless AD already carries RFC2307 uidNumber/gidNumber, in which
   case use 'ad'. Never leave a domain on 'tdb' across multiple servers -- non-deterministic
   ids mean the same user owns files under different uids on different hosts.
   And for a Samba FILE server on AD, use winbind, not SSSD (Red Hat only supports winbind
   behind smbd).
   EOF
   ```

**Prove it:**
```bash
# The member-server config is syntactically valid and resolves the role/idmap correctly:
testparm -s /tmp/adlab/smb.conf 2>&1 | grep -q 'Loaded services' && echo "AD-MEMBER CONFIG PARSES" && \
testparm -sv /tmp/adlab/smb.conf 2>/dev/null | grep -qi 'server role = ROLE_DOMAIN_MEMBER\|member server' && \
  echo "ROLE RESOLVES TO DOMAIN MEMBER"
```
(You've validated the configuration and rehearsed the join/verify sequence without needing a domain — the mechanics are what transfer to the real join.)

**Teardown:**
```bash
rm -rf /tmp/adlab
```

---

## Curated resources

**Primary — Samba upstream (the authoritative source for behavior):**

- [smb.conf(5) — samba.org](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html) — The definitive parameter reference: `(G)` vs `(S)` tagging, `server role`/`security`, the share parameters and their defaults, protocol knobs. Read the `[global]` and per-share sections before authoring anything; when a blog and this disagree, this wins. Confirm the shipped Rocky 9 form against rockyman (below).
- [Samba wiki: Setting up Samba as a Standalone Server](https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Standalone_Server) — The canonical procedure behind Labs 1–2: `tdbsam`, `smbpasswd -a`, the POSIX-account-plus-passdb model.
- [Samba wiki: Setting up Samba as a Domain Member](https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Domain_Member) — The `security = ads` `[global]`, `net ads join`, winbind NSS/PAM wiring, and the idmap config skeleton used in Lab 5.
- [Samba wiki: idmap config](https://wiki.samba.org/index.php/Idmap_config) and the backend man pages [idmap_rid(8)](https://www.samba.org/samba/docs/current/man-html/idmap_rid.8.html), [idmap_ad(8)](https://www.samba.org/samba/docs/current/man-html/idmap_ad.8.html), [idmap_autorid(8)](https://www.samba.org/samba/docs/current/man-html/idmap_autorid.8.html) — The deterministic-vs-allocating distinction that prevents the cross-server ownership disaster in §6. Read `rid` first; it's the right default.
- [Samba3-HOWTO ch.11 — Account Information Databases](https://www.samba.org/samba/docs/old/Samba3-HOWTO/passdb.html) — Why the NT hash forces a separate passdb, and the `smbpasswd`/`tdbsam`/`ldapsam` backends. The clearest statement of the §5 concept.
- [vfs_acl_xattr(8) — samba.org](https://www.samba.org/samba/docs/current/man-html/vfs_acl_xattr.8.html) and [Samba wiki: Setting up a Share Using Windows ACLs](https://wiki.samba.org/index.php/Setting_up_a_Share_Using_Windows_ACLs) — NT ACLs stored in the `security.NTACL` xattr; the backbone of §7 and the Windows-managed-permissions share.

**Man pages (the ABI — read the flags, don't guess them):**

- [samba(7)](https://www.samba.org/samba/docs/current/man-html/samba.7.html), [smbd(8)](https://www.samba.org/samba/docs/current/man-html/smbd.8.html), [nmbd(8)](https://www.samba.org/samba/docs/current/man-html/nmbd.8.html), [winbindd(8)](https://www.samba.org/samba/docs/current/man-html/winbindd.8.html) — The daemon split from §2 in the authors' own words. `samba(7)` is the map of the whole suite.
- [smbclient(1)](https://www.samba.org/samba/docs/current/man-html/smbclient.1.html), [mount.cifs(8)](https://www.kernel.org/doc/html/latest/filesystems/cifs/index.html) / [mount.cifs man](https://man7.org/linux/man-pages/man8/mount.cifs.8.html) — The client surface from §9: `-L`/`-U`/`-N`/`-c` and `vers=`/`credentials=`/`seal`/`uid=`.
- [testparm(1)](https://www.samba.org/samba/docs/current/man-html/testparm.1.html), [smbstatus(1)](https://www.samba.org/samba/docs/current/man-html/smbstatus.1.html), [smbpasswd(8)](https://www.samba.org/samba/docs/current/man-html/smbpasswd.8.html), [pdbedit(8)](https://www.samba.org/samba/docs/current/man-html/pdbedit.8.html), [net(8)](https://www.samba.org/samba/docs/current/man-html/net.8.html), [wbinfo(1)](https://www.samba.org/samba/docs/current/man-html/wbinfo.1.html) — The operational and troubleshooting tools from Labs 2 and 4, and the AD verification ladder in Lab 5.
- [smbd_selinux(8)](https://rockyman.org/9.7/selinux-policy-doc/man8/smbd_selinux.8.html) — The `samba_share_t` file type and the `samba_export_all_ro/rw`, `samba_enable_home_dirs`, `smbd_anon_write` booleans that gate every share on an enforcing Rocky box (§4). This is the SELinux half people forget.

**Vendor / distro:**

- [Red Hat: Using Samba as a server (RHEL 9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_using_network_file_services/assembly_using-samba-as-a-server_configuring-and-using-network-file-services) and [Connecting RHEL directly to AD using Samba Winbind](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/integrating_rhel_systems_directly_with_windows_active_directory/connecting-rhel-systems-directly-to-ad-using-samba-winbind_integrating-rhel-systems-directly-with-active-directory) — The distro-native procedures Rocky mirrors, including the supported-only-with-winbind statement behind the §6 winbind-vs-SSSD decision.
- [RFC 8276 — File System Extended Attributes in NFSv4](https://www.rfc-editor.org/rfc/rfc8276.html) — §5 (user-namespace-only scope) and §9 ("Clients MUST NOT accord any system-interpreted semantics to xattrs") explain why neither NFS nor SMB carries the `security.*` namespace, so file capabilities and SELinux labels do not survive a network mount.
- [rockyman.org](https://rockyman.org/) — https://rockyman.org/ — authoritative Rocky Linux 9 man-page index (versioned 8/9/10). Verify every command and `smb.conf` key against the *shipped* Rocky 9.7 pages here rather than upstream, since packaged option sets can lag or differ. Every man page cited in this module (`smb.conf(5)`, `testparm(1)`, `smbpasswd(8)`, `pdbedit(8)`, `net(8)`, `smbclient(1)`, `mount.cifs(8)`, `smbstatus(1)`, `wbinfo(1)`, `smbd_selinux(8)`) was confirmed present in the Rocky 9.7 catalog.

---

## Senior signal

- **Explains *why* Samba is shaped the way it is, from the protocol.** SMB authenticates with the NT hash, so the server must hold it, so there's a passdb separate from `/etc/shadow`; SMB is stateful and per-connection, so `smbd` forks per client and `smbstatus` shows live locks. Mid-level memorizes `smbpasswd -a`; senior derives the need for it.
- **Knows the two-account model cold and diagnoses it instantly.** Every SMB user needs a POSIX account (uid/gid, file ownership) *and* a passdb entry (NT hash). "Made the Linux user, SMB still fails" → `pdbedit -L -v` to check the passdb half, and knows the Unix and Samba passwords are independent stores unless `unix password sync` is on.
- **Debugs "access denied over SMB" as three layers, in order, naming which fired.** POSIX (`ls -ld`, setgid group), Samba (`testparm`, `valid users`/`read only`), SELinux (`ls -Zd` for `samba_share_t`, `ausearch -m avc -c smbd`). Reaches for `semanage fcontext` + `restorecon`, and treats `setsebool samba_export_all_rw 1` as the SMB `setenforce 0` — a last resort, not a fix.
- **Runs `testparm` after every edit and reads the *effective* config.** Knows a typo'd parameter is silently ignored, that `(S)` params in `[global]` become per-share defaults (inheritance), and uses `testparm -v` to see defaults like `create mask`/`server min protocol` rather than assuming them.
- **Picks the right daemon set and the right dialect floor.** `smbd` (+ `nmbd` only if NetBIOS is truly needed, + `winbindd` only if domain-joined) for a file server; `samba` only for an AD DC, never alongside `smbd`. Refuses to re-enable SMB1, and confirms the oldest required client before raising `server min protocol`.
- **Gets id-mapping right across servers.** Uses `rid` (deterministic) or `ad` (RFC2307 from AD) on every member, never leaves a domain on `tdb` across multiple hosts, keeps ranges disjoint, and knows winbind (not SSSD) is the supported identity source behind a Samba file server on AD.
- **Debugs Samba permissions across all three layers.** Knows effective access is the AND of the share ACL (`valid users`/`write list`), the NT ACL (`smbcacls`), and the POSIX mode/ACL (`getfacl`); that POSIX is the hard ceiling an NT ACL cannot exceed; and that `create mask`/`directory mask` govern new-file permissions. So "Windows says access denied but `ls` looks fine" and "the mask stripped group-write" are immediate diagnoses, and SELinux (`samba_share_t`/`samba_export_all_rw`) is recognized as a distinct fourth layer.
- **Reads `smbstatus`/`log.smbd` fluently and reloads without an outage.** Uses `smbstatus -p`/`-S`/`-L` for the fork model, sessions, and locks; turns up `log level` and reads `NT_STATUS_*` in `/var/log/samba/log.smbd`; and reaches for `smbcontrol all reload-config` over a service restart on a production file server (⚠️ restarting `smbd` drops active client sessions — schedule a window).

---

## See also

- [[04 - Filesystems and the VFS]] — SMB is a filesystem protocol over the wire; the xattr *namespaces* (`user.*` / `trusted.*` / `system.*` / `security.*`), the page cache the client caches into (`cache=`/`actimeo=`), and inode/ownership semantics all come from there. The permissions and ACL model in §7 builds on that module's POSIX-permission and xattr coverage, including the `security.*` namespace caveat that limits SMB and NFS alike.
- [[01 - Permissions and Access Control]] — the POSIX layer (mode bits, the setgid-directory group-inheritance used in every lab, POSIX ACLs) that Samba maps to and from, and the file *capabilities* (`security.capability`) that Lab 3 proves don't survive an SMB round-trip.
- [[02 - Users, Authentication and PAM]] — where the POSIX identity half of the two-account model comes from (NSS, PAM), and the substrate winbind plugs into on a domain member (`nss_winbind`, `pam_winbind`, `authselect`) so AD users become Unix users.
- [[12 - SELinux and Hardening]] — the MAC layer that gates every share on Rocky: `samba_share_t` labeling with `semanage fcontext` + `restorecon` (never `chcon`), the `samba_*` booleans, and the `security.selinux` label that, like `security.capability`, is a `security.*` xattr and therefore does not transit SMB/NFS.
