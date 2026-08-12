---
title: Users, Authentication and PAM
type: module
track: linux-internals
tags: [linux-internals, authentication, pam, nss, sudo, polkit, identity, security, shadow, nsswitch]
requires: [Rocky 9.x VM with root, pamtester (EPEL), strace, nss-tools]
module_number: 2
status: reviewed
created: 2026-07-08
---

# 02 — Users, Authentication and PAM

Backlink: [[00 - Track Overview]]

> Scope: where identity comes from on a Linux box, and what actually happens between "user types a password" and "a process runs with a UID." We cover the on-disk identity databases (`passwd`/`shadow` and their hashing), the NSS resolution layer that turns a name into a record from *any* backend, the full PAM stack (auth/account/password/session, the control-flag algebra, the canonical modules), `sudo`/sudoers as a privilege-transition engine, and polkit as the D-Bus-era authorization broker. The through-line: **identity resolution (NSS) and authentication (PAM) are two orthogonal subsystems that people constantly conflate**, and half of all "login is broken" tickets come from not knowing which one is failing.

---

## Concept deep-dive

### 0. The mental model: three orthogonal questions

A staff engineer keeps these separate at all times, because they fail independently and are debugged with different tools:

```
  ┌───────────────────────────────────────────────────────────────┐
  │  1. WHO EXISTS?            "Is there a user 'alice'?"           │
  │     → NSS (nsswitch.conf) → getpwnam/getgrnam → files/sss/ldap  │
  │                                                                 │
  │  2. IS IT REALLY THEM?     "Prove you are alice."               │
  │     → PAM auth stack → pam_unix / pam_sss / pam_faillock ...    │
  │                                                                 │
  │  3. MAY THEY DO THIS?      "May alice run X / mount Y?"          │
  │     → sudoers, polkit rules, capabilities, SELinux, DAC bits    │
  └───────────────────────────────────────────────────────────────┘
```

Concrete illustration of the split: `id alice` succeeding while `ssh alice@host` fails means **NSS works, PAM/auth is broken**. `getent passwd alice` returning nothing but `ssh` still somehow letting a cached user in means the opposite. The single most common senior-vs-mid tell in this module is instantly knowing that `getent` tests NSS and `pamtester`/the actual login tests PAM, and never using one to "prove" the other.

Also critical: **`/etc/passwd` is not read directly by well-written software.** Programs call `getpwnam(3)`/`getpwuid(3)`, which route through NSS. A user defined only in LDAP/SSSD has *no line in `/etc/passwd`* yet `id` resolves them. Grepping `/etc/passwd` to "check if a user exists" is a mid-level habit that breaks the moment a directory service is involved.

### 1. The on-disk identity databases

#### `/etc/passwd` — the seven colon-separated fields

```
name:password:UID:GID:GECOS:home:shell
alice:x:1000:1000:Alice Ex,,,:/home/alice:/bin/bash
```

- Field 2 is a legacy password field. `x` means "the hash lives in `/etc/shadow`." A literal empty field means *no password required* (dangerous); a `*` or `!` means *no valid password / cannot log in via password*. Historically the hash sat here, world-readable — the entire reason `shadow` exists.
- `UID` 0 is root **by number, not by name.** The kernel only knows UID 0; the name `root` is a userspace convenience resolved via NSS. Any account with UID 0 is root. (`awk -F: '$3==0' /etc/passwd` should return exactly one line on a sane box — a classic audit check.)
- UID ranges are policy, not kernel: `SYS_UID_MIN`/`SYS_UID_MAX` (system accounts) and `UID_MIN`/`UID_MAX` (regular users, typically 1000–60000) live in `/etc/login.defs`. `useradd` reads them; the kernel does not care.
- The shell field being `/sbin/nologin` or `/bin/false` is an *authorization* control enforced by login programs, not the kernel. `nologin` prints a message and exits non-zero; `false` just exits. Neither prevents `su - user -s /bin/bash` if you have the rights, and neither stops a systemd service from running as that user (services don't spawn a login shell).

#### `/etc/shadow` — nine fields, and the hash format

```
name:hash:lastchg:min:max:warn:inactive:expire:reserved
alice:$y$j9T$F5Jx...$3Nq...:19814:0:99999:7:::
```

Fields after the hash are the aging policy consumed by `pam_unix`'s **account** phase and by `chage`:
- `lastchg` — days since epoch (1970-01-01) of last password change. `0` is a special poison value meaning "must change at next login."
- `min`/`max` — minimum/maximum days between changes.
- `warn` — days of warning before expiry.
- `inactive` — days after password expiry before the account is locked.
- `expire` — absolute account expiration (days since epoch), independent of the password.

The **hash field** is the interesting part. Modern format is Modular Crypt Format (MCF):

```
$id$params$salt$hash
$y$ j9T $ F5JxABCD... $ 3Nq8...
 │   │        │           └── the actual derived key, base64 (crypt variant)
 │   │        └── salt, base64
 │   └── algorithm parameters (yescrypt: encodes N, r, p cost)
 └── algorithm id
```

Algorithm ids you must recognize on sight:

| id | algorithm | notes |
|----|-----------|-------|
| `$1$` | MD5-crypt | ancient, do not use |
| `$5$` | SHA-256-crypt | `rounds=` optional |
| `$6$` | SHA-512-crypt | RHEL 7/8 default, still everywhere |
| `$y$` | **yescrypt** | RHEL 9 / Fedora 35+ / Debian 11+ / Ubuntu 22.04+ default |
| `$gy$` | gost-yescrypt | GOST variant |
| `$7$` | scrypt | rare |
| `$2b$` | bcrypt | common in app land, not the shadow default |

A field that is `!`, `!!`, `*`, or empty is **not a hash** and can never match any input, so those accounts cannot authenticate by password. `!!` conventionally means "password was never set"; a `!` prefix on an otherwise valid hash means "locked" (`passwd -l` / `usermod -L` just prepend `!`, and `-u` strips it — the underlying hash is preserved, which is why unlocking restores the old password).

**yescrypt mechanism** (why the default changed): it is a memory-hard KDF built on scrypt/Salsa20, deliberately expensive in *RAM* as well as CPU so GPU/ASIC cracking rigs can't parallelize cheaply. The `params` field (`j9T`, `jAT`, ...) encodes the cost. `j9T` is the default ~5-rounds-equivalent profile. This is a genuine security upgrade over SHA-512-crypt, which is only CPU-hard.

**The `crypt()` boundary — a detail that trips up seniors.** For decades `crypt(3)` lived in glibc. RHEL 8+ / Fedora and most modern distros moved it to **libxcrypt** (`libcrypt.so.2`), a separate, actively maintained library. yescrypt support (`$y$`) comes from libxcrypt ≥ 4.3, *not* glibc. So "does this box support yescrypt hashes" is really "what libxcrypt version is installed," and cross-distro hash portability depends on the *verifying* library also understanding `$y$`. Copying a `$y$` shadow line to an older box whose `libcrypt` predates yescrypt = permanent auth failure with no obvious error.

**Which algorithm gets used for a *new* password** is chosen by whoever computes the hash:
- `pam_unix` reads its own module arg (`sha512`, `yescrypt`, `rounds=`) in `/etc/pam.d/*`.
- `login.defs` `ENCRYPT_METHOD` and `YESCRYPT_COST_FACTOR` are the distro-wide default consulted by `passwd`/`chpasswd`/`useradd`.
- These can disagree. If `login.defs` says `SHA512` but the PAM `password` line says `yescrypt`, an interactive `passwd` (which goes through PAM) produces `$y$` while a scripted `chpasswd --crypt-method` might produce `$6$`. Knowing that the hash algorithm is set at *write* time and never migrates on its own explains why a box has a mix of `$6$` and `$y$` hashes years after an upgrade.

#### `/etc/group` and `/etc/gshadow`

```
group:password:GID:member1,member2
wheel:x:10:alice,bob
```

Group membership has two sources that must be reconciled:
1. **Primary group** — field 4 of the user's `passwd` entry (the GID). Set at process creation, always present in the credential set.
2. **Supplementary groups** — the membership list in `/etc/group` (or the NSS `initgroups` database for directory backends).

`id` shows both; `groups` shows the currently *effective* set. The classic gotcha: adding a user to a group with `usermod -aG wheel alice` updates `/etc/group` but **does not retroactively change any already-running process's supplementary group set.** Supplementary groups are baked into the process credentials at login via `initgroups(3)` / `setgroups(2)` and inherited across `fork`/`exec`. The user must start a *new login session* for it to take effect — `newgrp`/`sg` or a fresh SSH session, not `source ~/.bashrc`. This is a kernel-credential-lifetime fact, not a caching bug.

### 2. NSS — the Name Service Switch

NSS is glibc's plugin framework for the "who exists / resolve this name" question. `/etc/nsswitch.conf` maps each **database** to an ordered list of **service** backends, plus optional per-status **action** overrides.

```
passwd:     files sss systemd
group:      files sss systemd
shadow:     files sss
hosts:      files myhostname resolve [!UNAVAIL=return] dns
```

**Mechanism.** A call like `getpwnam("alice")` enters glibc, which reads (and caches, per-process) `nsswitch.conf`, then for the `passwd` database walks the service list left to right. For service `sss` it `dlopen`s **`libnss_sss.so.2`** from the library path and calls the well-known symbol `_nss_sss_getpwnam_r`. The `.2` suffix is the NSS module ABI version (glibc 2.x uses `.2`; you'll still see `.so` symlinks). Each backend is a shared object named `libnss_SERVICE.so.X` — this is why adding a new identity source (LDAP, SSSD, systemd-homed, Windows via winbind) is just "install a package that drops a `libnss_*.so` and add a word to `nsswitch.conf`."

```
  getpwnam("alice")            glibc
        │
        ▼
  read /etc/nsswitch.conf  ──►  passwd: files sss systemd
        │
        ├─► dlopen libnss_files.so   → _nss_files_getpwnam_r  (reads /etc/passwd)
        │      status = notfound  →  default action: continue
        │
        ├─► dlopen libnss_sss.so     → _nss_sss_getpwnam_r    (talks to sssd over
        │      status = success   →  default action: return    a UNIX socket)
        │
        └─► (systemd never reached because sss returned)
```

**The 14 databases**: `aliases, ethers, group, gshadow, hosts, initgroups, netgroup, networks, passwd, protocols, publickey, rpc, services, shadow`. For this module the ones that matter are `passwd`, `group`, `shadow`, and `initgroups` (supplementary-group expansion for directory users).

**Status → action algebra.** Each backend returns one of four statuses; each status has a default action, overridable inline with `[STATUS=ACTION]`:

| STATUS | meaning | default action |
|--------|---------|----------------|
| `success` | found the entry | `return` |
| `notfound` | backend works, entry absent | `continue` |
| `unavail` | backend permanently down/unconfigured | `continue` |
| `tryagain` | backend temporarily busy | `continue` |

Actions: `return` (stop, use this result), `continue` (try next backend), `merge` (glibc 2.24+, only meaningful for `group`/`initgroups` — combine supplementary group memberships across backends instead of taking only the first). `[!STATUS=ACTION]` negates.

The canonical production idiom is `[SUCCESS=return]` and, more subtly, controlling failure behavior. Consider `hosts: files dns [!UNAVAIL=return]` — this says "if DNS returns anything other than 'the DNS service is unavailable,' stop here (don't fall through to more backends)." For identity, an entry like:

```
passwd: files [SUCCESS=return] sss
```

means a *local* user shadows a directory user of the same name (files wins, and we stop). Removing `[SUCCESS=return]` doesn't change much here because `success`→`return` is already the default, but making it explicit documents intent.

**Failure modes and scale behavior:**
- **`nsswitch.conf` is cached per process at first lookup.** A long-running daemon that started before you edited `nsswitch.conf` keeps the old config until restart. "I fixed nsswitch but sshd still can't see LDAP users" → restart sshd.
- **`nscd` / `sssd` caching.** With `nscd` running, `getent` results are cached; a deleted user can still resolve until the cache expires or `nscd -i passwd` invalidates it. SSSD has its own cache (`sss_cache -E`). This is *identity* caching, entirely separate from PAM.
- **Ordering is a security boundary.** `passwd: sss files` (directory first) means a directory admin can define a UID-0 user and own your box; `files sss` (local first) is the safe default. Getting this backwards is a real finding in security audits.
- **A hung backend stalls every `getpwnam` on the box.** If `sss` blocks (SSSD wedged, LDAP server unreachable and no timeout), *every* program doing a name lookup — `ls -l`, `ps`, `sshd` — hangs in the NSS call. `ls -l` "hanging" is a classic symptom of a directory-service outage, not a disk problem. `strace -f ls -l` showing a stuck `connect()`/`poll()` to an LDAP socket is the proof.
- **Static linking breaks NSS.** Because NSS `dlopen`s modules at runtime, a fully statically linked binary cannot use them — glibc warns about this at link time. A static busybox on a rescue image only sees `/etc/passwd`, never LDAP.

### 3. PAM — Pluggable Authentication Modules

PAM answers "is it really them" (and manages the surrounding session/account/password lifecycle) **independently of where the identity is stored.** An application (`sshd`, `login`, `sudo`, `su`, `gdm`, `cron`, `crond`) links `libpam` and delegates all authentication policy to config files in `/etc/pam.d/`, so the *same* sshd binary can do local passwords, Kerberos, 2FA, or smartcards purely by config.

#### The four management groups (stacks)

Every PAM-aware operation runs up to four independent stacks:

| type | question | typical modules |
|------|----------|-----------------|
| `auth` | prove identity (password, token, biometric) | `pam_unix`, `pam_sss`, `pam_faillock`, `pam_google_authenticator`, `pam_krb5` |
| `account` | is this account *allowed* right now? (expiry, time, access rules) | `pam_unix` (aging), `pam_nologin`, `pam_access`, `pam_time`, `pam_sss` |
| `password` | change the authentication token | `pam_pwquality`, `pam_pwhistory`, `pam_unix`, `pam_sss` |
| `session` | set up / tear down the session environment | `pam_systemd`, `pam_limits`, `pam_loginuid`, `pam_mkhomedir`, `pam_keyinit`, `pam_selinux` |

These are separate stacks with separate module lists. A password may *authenticate* fine (auth) yet be *expired* (account fails), which is why "wrong password" and "account expired" are distinct failures — a mid-level often conflates them.

#### The config line format

```
type    control        module-path        module-arguments
auth    required        pam_unix.so        try_first_pass nullok
auth    [default=die]   pam_faillock.so    authfail
password requisite      pam_pwquality.so   retry=3 minlen=12
```

- **module-path**: bare name → resolved from `/lib64/security/` (or `/lib/security/`); leading `/` → absolute. Always use the bare name and let PAM pick the right arch dir.
- **`@include`** pulls in another file's lines of *all* types; **`substack`** includes another file as a sub-stack whose done/die verdicts don't jump out of the parent. RHEL's `system-auth` and `password-auth` are the shared building blocks every service `@include`s (via the `include`/`substack` directives written by authselect).

#### Control flags — the part everyone gets subtly wrong

Two syntaxes. The **legacy keywords** are shorthands for the **rich `[value=action]`** form. The stack is walked top to bottom, each module returns a value (`success`, `auth_err`, `user_unknown`, `new_authtok_reqd`, `ignore`, ...), and the control decides what happens and what the stack's final verdict is.

| keyword | equivalent rich form | behavior |
|---------|---------------------|----------|
| `required` | `[success=ok new_authtok_reqd=ok ignore=ignore default=bad]` | failure → stack ultimately **fails**, but *keep running the rest* (so failure timing/logging doesn't reveal which module failed) |
| `requisite` | `[success=ok new_authtok_reqd=ok ignore=ignore default=die]` | failure → **stop immediately**, return to app now |
| `sufficient` | `[success=done new_authtok_reqd=done default=ignore]` | success → **stop and succeed** (unless a prior `required` already failed); failure → ignored, keep going |
| `optional` | `[success=ok new_authtok_reqd=ok default=ignore]` | verdict only matters if it's the *only* module in the stack |

The **rich syntax** `[value1=action1 value2=action2 ...]` is where real policy lives. Actions:
- `ok` — set the stack's running verdict to this module's result (but keep going).
- `done` — like `ok`, but **stop the stack now** with success.
- `bad` — mark the running verdict as failure (keep going).
- `die` — like `bad`, but **stop now** with failure.
- `ignore` — this module's result doesn't affect the verdict.
- `reset` — clear the running verdict back to initial.
- **`N` (an integer)** — *jump forward N modules of the same type*, skipping them. This is how RHEL's `pam_faillock` sandwich works and it's the single most misread PAM construct in the wild.

The RHEL 9 `system-auth` **faillock sandwich**:

```
auth  required  pam_faillock.so preauth       # count/deny before we even try the password
auth  sufficient pam_unix.so nullok try_first_pass
auth  [default=die] pam_faillock.so authfail  # on password failure, record it and die
auth  sufficient pam_faillock.so authsucc     # on success, clear the counter
```

The `preauth`/`authfail`/`authsucc` invocations plus the jump-and-die logic implement "lock the account after N failures." Reading this correctly — that `pam_faillock` appears *three times* with different args and that `[default=die]` short-circuits — is a senior signal.

#### Module internals (the ABI)

A PAM module is a `.so` exporting the six service functions the loader calls by name, e.g. `pam_sm_authenticate(pam_handle_t*, flags, argc, argv)` for the auth group, `pam_sm_acct_mgmt`, `pam_sm_chauthtok` (password), `pam_sm_open_session`/`pam_sm_close_session`, `pam_sm_setcred`. The module never talks to the terminal directly — it calls back into the **conversation function** the *application* registered via `pam_start()`, passing `PAM_PROMPT_ECHO_OFF` (password) or `PAM_PROMPT_ECHO_ON` (username) messages. This indirection is why the *same* `pam_unix.so` works for a text `login`, a GUI `gdm`, and an SSH session: each supplies a conversation function appropriate to its UI. Data is stashed across modules via `pam_set_item`/`pam_get_item` (notably `PAM_AUTHTOK`, the password — this is how `try_first_pass` lets a later module reuse the password an earlier one already prompted for) and `pam_set_data`.

`pam_start()` reads the config and builds the module list; `pam_authenticate()` runs the auth stack; `pam_acct_mgmt()` the account stack; `pam_setcred()` establishes credentials (Kerberos tickets, group membership); `pam_open_session()`/`pam_close_session()` bracket the session; `pam_chauthtok()` the password change. `sshd` calls these in a specific order and *any* of them failing denies login — so "correct password, still rejected" is very often `account` (expired) or `session` (`pam_loginuid` failing in a container, `pam_nologin` because `/etc/nologin` exists) rather than `auth`.

#### Canonical modules worth knowing cold

- **`pam_unix.so`** — the workhorse. `auth`: verify against `/etc/shadow` via `crypt()`. `account`: enforce shadow aging. `password`: write a new hash (honors `sha512`/`yescrypt`/`rounds=`). Args: `nullok` (allow empty passwords — a hardening red flag), `try_first_pass`/`use_first_pass` (reuse `PAM_AUTHTOK`), `shadow`, `remember=` (delegates history to `pam_pwhistory` on modern systems).
- **`pam_sss.so`** — hands auth/account/password/session off to the SSSD daemon (which fronts LDAP/AD/Kerberos/IdM and caches offline).
- **`pam_faillock.so`** — brute-force lockout, replaced `pam_tally2`. State in `/var/run/faillock/`. `faillock --user alice --reset` clears it.
- **`pam_pwquality.so`** — complexity enforcement in the `password` stack (`minlen`, `dcredit`, `ucredit`, `minclass`, `retry`, dictionary check via `cracklib`); config in `/etc/security/pwquality.conf`.
- **`pam_pwhistory.so`** — prevents reuse; hashes in `/etc/security/opasswd`.
- **`pam_limits.so`** — applies `/etc/security/limits.conf` (`ulimit`/`RLIMIT_*`) at session open. In a systemd-managed login, systemd's own `LimitNOFILE=` etc. often override this — a real source of "my ulimit setting is ignored."
- **`pam_systemd.so`** — registers the session with `systemd-logind`, creating the user slice/scope, XDG runtime dir, and seat/session tracking. Without it, `loginctl` shows nothing and `$XDG_RUNTIME_DIR` is unset.
- **`pam_loginuid.so`** — sets the immutable audit login UID (`/proc/self/loginuid`) so the audit subsystem can attribute every later action to the original human. Notoriously fails in unprivileged containers (can't write loginuid), breaking logins that include it in the session stack.
- **`pam_nologin.so`**, **`pam_securetty.so`**, **`pam_access.so`** (`/etc/security/access.conf` — who from where), **`pam_time.so`**, **`pam_env.so`**, **`pam_mkhomedir.so`** (create `$HOME` on first login for directory users).

#### authselect — do not hand-edit on RHEL 9

RHEL 9 generates `system-auth`/`password-auth` from **profiles** via `authselect`. The active files carry a "generated — do not edit" header. Editing them directly means the next `authselect` run (triggered by other tooling) silently reverts you. The supported workflow is `authselect select sssd with-faillock without-nullok`, or a *custom profile* (`authselect create-profile`) for bespoke stacks. Tell-tale of a mid-level fix: hand-edited `system-auth` that mysteriously reverts. (This mirrors the general rule: don't modify package/tool-owned files; use the override mechanism.)

**PAM failure modes at scale:**
- A missing/renamed module in a stack with `required` fails that operation; if it's in `sshd`'s stack you can lock yourself out of a remote box. **Always keep a root shell open while editing PAM.**
- `pam_faillock` state persists across the fix — resetting the config doesn't unlock already-locked accounts; you must `faillock --reset`.
- Order matters within a stack: putting `pam_faillock preauth` *after* `pam_unix` means a locked account still burns a password check.
- A slow backend (`pam_sss` → unreachable LDAP with a long timeout) makes every `sudo`/`ssh` hang for the timeout duration. SSSD offline caching is the mitigation.

### 4. sudo and sudoers — the privilege-transition engine

`sudo` is a setuid-root binary that, after policy approval, uses `setresuid`/`setresgid`/`setgroups` to drop from root to the *target* identity and `execve`s the command. The policy is a **plugin** (`sudoers` is the default; LDAP/SSSD sudoers and third-party plugins exist), and authentication is delegated to **PAM** (`/etc/pam.d/sudo`) — so "sudo won't take my password" is a PAM problem, while "sudo says I'm not allowed" is a sudoers problem. Keeping those two apart is, again, the senior split.

#### The sudoers grammar

```
#            who      host = (runas_user:runas_group)  TAG:  commands
alice        ALL     = (root)                  /usr/bin/systemctl restart nginx
%wheel       ALL     = (ALL:ALL)               ALL
%dba         db01    = (postgres)              NOPASSWD: /usr/bin/psql
```

The five parts of a user spec: **User_List Host_List = (Runas_List) [Tag_Spec] Cmnd_List**. Aliases (`User_Alias`, `Host_Alias`, `Runas_Alias`, `Cmnd_Alias`) let you name sets. Key mechanics:

- **`(runas_user:runas_group)`** — the identity sudo transitions *to*. `(ALL:ALL)` with `-u`/`-g` lets the user pick. Default is root if omitted. `(%group)` targets running-as-a-group.
- **`Defaults`** lines tune behavior globally, per-user (`Defaults:alice`), per-host (`Defaults@host`), per-command (`Defaults!/bin/foo`), or per-runas. Important ones: `timestamp_timeout` (credential-cache minutes; `0`=always prompt, negative=until reboot), `env_reset`/`env_keep` (the environment sanitization that neuters most `LD_*` attacks), `requiretty`, `secure_path` (the *sudo* `PATH`, why `sudo somebinary` can fail while `somebinary` works), `use_pty`/`log_output`/`iolog_dir` (session recording), `!authenticate` and `targetpw`/`rootpw`.
- **Tags**: `NOPASSWD:`/`PASSWD:`, `NOEXEC:` (block the command from spawning further programs via a preloaded `noexec` shim — defeats shell escapes), `SETENV:`, `LOG_INPUT`/`LOG_OUTPUT`.

#### Mechanism and forensics

- **Credential caching** is per-**terminal-session**, stored in `/run/sudo/ts/<user>` as records keyed by `(uid, tty, session-leader-start-time, timestamp)`. This is why two terminals prompt independently and why the timestamp survives across `sudo` calls in one tty but not another. `sudo -k` clears it; `sudo -K` removes the file.
- **`sudoedit` (`sudo -e`)** solves a genuine security hole: running `sudo vim` gives the user a *root shell* via `:!sh`. `sudoedit` instead copies the file to a temp location, runs the editor **as the invoking user** (no root editor, no shell escape to root), then copies back as root. Allowing `sudoedit /etc/foo` in sudoers is dramatically safer than allowing an editor. Historically `sudoedit` itself had path-traversal CVEs (CVE-2023-22809 let extra editor args escape) — worth knowing it's not magic.
- **`visudo`** is mandatory for editing: it locks `sudoers`, validates the grammar before saving, and prevents the classic "syntax error locks everyone out of sudo" disaster. `visudo -c` validates without editing. Drop-ins go in `/etc/sudoers.d/` (loaded via `@includedir`), which is how packages add rules without touching the base file — the package-owned-file-avoidance pattern again.
- **`sudo -l`** shows the *effective* policy for the current user (what sudo actually computed, resolving aliases and LDAP). This is the authoritative "what can I run" check — reading raw `sudoers` and reasoning by hand misses LDAP/SSSD-sourced rules and alias expansion.
- **SELinux integration**: sudoers can pin a `role=`/`type=` so the command runs in a specific SELinux context (`Defaults:alice role=...`). On enforcing systems a sudo grant without the right role can still be denied by policy — a two-layer authorization that confuses people who only know DAC.
- **Logging**: sudo logs to syslog (`authpriv`) by default; `journalctl _COMM=sudo` or `/var/log/secure` shows the command, cwd, and target user. `log_output`+`iolog_dir` records full terminal I/O (keystrokes and output) — the audit feature enterprises actually deploy.

**Dangerous-grant literacy** (a staff engineer spots these instantly as privilege-escalation vectors even when "scoped"): `NOPASSWD: /usr/bin/vi` (shell escape), `... /bin/systemctl` without a specific unit (`systemctl edit` → root shell, or start an attacker unit), `... /usr/bin/find` (`-exec`), `... tar`/`awk`/`less`/`man` (all have shell escapes), any wildcard like `/bin/chmod *` (matches `/bin/chmod 4755 /bin/sh`). GTFOBins is the canonical catalog. Scoping a command in sudoers is *not* the same as sandboxing it.

### 5. polkit (PolicyKit) — authorization for the D-Bus era

`sudo` transitions a *whole process* to another identity from a shell. polkit answers a finer question: "may *this already-running unprivileged process* ask a *privileged system daemon* to perform *this specific action*?" It's the RBAC layer behind `systemctl` (via `systemd`'s D-Bus API), NetworkManager, udisks (mounting), packagekit, `timedatectl`, etc. When a desktop user clicks "install updates" or `systemctl start` prompts for a password, that's polkit, not sudo.

#### Architecture

```
  unprivileged client (e.g. gnome-software, systemctl)
        │  D-Bus method call ("start unit X")
        ▼
  privileged mechanism (systemd, over the system bus)
        │  "may subject S do action A on me?"   ← D-Bus call to polkitd
        ▼
  polkitd (system daemon, runs as root)
        │  1. look up the ACTION (.policy XML)  → default answer + auth requirement
        │  2. evaluate RULES (.rules JS) in order → allow / deny / auth_* 
        │  3. if auth needed → talk to an AUTHENTICATION AGENT in the user's session
        ▼
  agent prompts user (own password, or admin/root password) → result back to polkitd
```

- **Actions** live in `/usr/share/polkit-1/actions/*.policy` (XML). Each declares an action id (e.g. `org.freedesktop.systemd1.manage-units`) and default answers for three subject classes: `allow_any` (remote/inactive), `allow_inactive` (local but not active session), `allow_active` (the user at the active seat). Values: `no`, `yes`, `auth_self`, `auth_admin`, and `*_keep` (cache the grant). This is why an action can be allowed for the physically-present user but require a password over SSH.
- **Rules** live in `/etc/polkit-1/rules.d/` and `/usr/share/polkit-1/rules.d/`, are **JavaScript** evaluated by polkitd's embedded JS engine (Duktape on modern versions), processed in lexical filename order (`/etc` beats `/usr` on ties). A rule calls `polkit.addRule(function(action, subject){...})` and returns a `polkit.Result` (`YES`, `NO`, `AUTH_SELF`, `AUTH_ADMIN`, `AUTH_ADMIN_KEEP`, or nothing to fall through). This is strictly more expressive than sudoers — you can key decisions on action id, subject uid/groups, `subject.local`, `subject.active`, even a lookup against a database.
- **`pkexec`** is polkit's `sudo` analogue: run a program as another user subject to a polkit action. This is the component behind **CVE-2021-4034 "PwnKit"** — `pkexec` didn't validate `argc`, so an attacker passing an empty argv made it read the *environment array* as argv, injecting an attacker-controlled `GCONV_PATH`/`LD` value to load a malicious library **as root, with no authentication prompt at all.** Affected polkit 0.105–0.119 (a 12-year-old bug), fixed in 0.120 / distro backports. The lesson a staff engineer takes: setuid/privileged helpers must treat *every* input including argv/environ as hostile, and "it needs local access" is not a mitigation.
- **CVE-2021-3560** (a companion) was a race in polkitd's D-Bus request handling that let a local user create a UID-0 account. Two back-to-back polkit CVEs in 2021 are why polkit is on every hardening checklist.

**polkit vs sudo — when each is right:**
- `sudo` = "give a human an elevated shell/command from a terminal." Coarse, terminal-oriented, PAM-authenticated, ubiquitous on servers.
- polkit = "let a running service/desktop app request one specific privileged operation, with per-action and per-session-context policy." Finer-grained, D-Bus-oriented, the desktop/systemd-service world.
- On a headless server with no D-Bus session and no auth agent, a polkit action requiring `auth_admin` from a non-active session simply **can't be satisfied** — which is why `systemctl` over SSH sometimes fails with "Interactive authentication required" until you either run as root, use `sudo systemctl`, or install a text auth agent (`pkttyagent`). Recognizing that error as a polkit (not systemd) refusal is the differentiator.

### 6. How a login *actually* happens — the full trace

Putting it together for an SSH password login on RHEL 9:

```
1. sshd accepts TCP, negotiates crypto.
2. sshd calls pam_start("sshd", user, &conv) → reads /etc/pam.d/sshd
      (which @includes password-auth → the shared auth/account/password/session stacks)
3. AUTH stack:
      pam_faillock preauth        → is alice already locked? (reads /var/run/faillock)
      pam_unix                    → getspnam("alice")  [← NSS shadow lookup]
                                    crypt(typed_pw, stored_salt) == stored_hash?
                                    (crypt() lives in libxcrypt, handles $y$)
      pam_faillock authfail/authsucc → record result, lock or clear
      pam_sss                     → (if not local) ask SSSD, which may hit AD/LDAP + cache
4. ACCOUNT stack:
      pam_unix                    → shadow aging: expired? must-change? (field 0/expire)
      pam_sss / pam_access / pam_nologin ...
   → if password is EXPIRED, pam_authenticate() succeeded but pam_acct_mgmt()
     returns PAM_NEW_AUTHTOK_REQD → sshd forces a password change (password stack).
5. sshd resolves the full identity:
      getpwnam("alice")           [← NSS passwd: uid, gid, home, shell]
      initgroups("alice", gid)    [← NSS group/initgroups: supplementary groups]
6. pam_setcred() then SESSION stack:
      pam_loginuid                → write /proc/self/loginuid (audit anchor)
      pam_systemd                 → register session with logind, make user@uid.service
                                    slice + $XDG_RUNTIME_DIR
      pam_limits                  → apply RLIMIT_* from limits.conf
      pam_selinux                 → compute the login SELinux context
      pam_mkhomedir               → create /home/alice if absent (directory users)
7. sshd setgid/setgroups/setuid to alice's credentials, chdir($HOME), execve(shell).
```

Every arrow marked NSS is a *resolution*; every module is *authentication/authorization*. When a login fails, the first diagnostic question is *which numbered step*, and the tools differ per step (getent for NSS steps, PAM debug/journal for module steps).

---

## Hands-on labs

> All labs assume a **throwaway VM** you don't mind breaking (RHEL 9 / Rocky 9 / Fedora, or adapt paths for Debian/Ubuntu). **Keep a second root shell open the entire time** — several labs can lock you out if a step goes wrong. Snapshot the VM first if your hypervisor supports it.

### Lab 1 — Dissecting the hash and proving `crypt()` lives in libxcrypt

**Objective:** See exactly what's in a shadow hash, reproduce it by hand, and prove which library computes it. Kill the "hashes are magic" instinct.

**Setup:**
```bash
# throwaway VM, as root
useradd -m labuser
echo 'labuser:Sup3rSecret!' | chpasswd
```

**Steps:**
1. Look at the raw record and decompose it:
   ```bash
   getent shadow labuser
   # $y$j9T$<salt>$<hash>  → id=y (yescrypt), params=j9T, then salt$hash
   ```
2. Reproduce the hash by hand, feeding back the *stored* algorithm+params+salt so the output must match:
   ```bash
   STORED=$(getent shadow labuser | cut -d: -f2)
   SETTING=$(echo "$STORED" | cut -d'$' -f1-3)      # $y$j9T$<salt>  (no trailing hash)
   python3 -c "import crypt,sys; print(crypt.crypt('Sup3rSecret!', sys.argv[1]))" "\$$SETTING"
   # NOTE: adjust the leading $ — easier is the openssl/perl form below
   perl -e 'print crypt("Sup3rSecret!", $ARGV[0]), "\n"' "$STORED"
   ```
   The `perl`/`crypt` output should be byte-identical to `$STORED`.
3. Prove where `crypt()` comes from:
   ```bash
   ldd "$(which perl)" | grep -i crypt        # may or may not show; perl uses its own
   # definitive: check what provides libcrypt and its version
   readlink -f /lib64/libcrypt.so.2
   rpm -qf /lib64/libcrypt.so.2               # → libxcrypt-x.y.z  (NOT glibc)
   ```
4. Change the algorithm deliberately and watch the prefix change:
   ```bash
   # scripted, forcing SHA-512 instead of the yescrypt default
   echo 'labuser:Sup3rSecret!' | chpasswd --crypt-method SHA512
   getent shadow labuser | cut -d: -f1-2       # now starts with $6$
   ```
5. Lock and inspect:
   ```bash
   passwd -l labuser; getent shadow labuser | cut -d: -f2 | head -c3   # → "!$6"
   passwd -u labuser; getent shadow labuser | cut -d: -f2 | head -c3   # → "$6$"  (old hash restored)
   ```

**Prove it:**
```bash
# The by-hand recomputation equals the stored hash → you understand MCF + salting:
test "$(perl -e 'print crypt("Sup3rSecret!",$ARGV[0])' "$(getent shadow labuser|cut -d: -f2)")" \
     = "$(getent shadow labuser|cut -d: -f2)" && echo "HASH REPRODUCED: PASS"
# And crypt() is libxcrypt, not glibc:
rpm -qf /lib64/libcrypt.so.2 | grep -q libxcrypt && echo "crypt() = libxcrypt: CONFIRMED"
```

**Teardown:**
```bash
userdel -r labuser      # removes the account and its home dir
```

### Lab 2 — Watching NSS resolve, and making `ls -l` hang like a real outage

**Objective:** See glibc `dlopen` the NSS modules, distinguish NSS failure from PAM failure, and reproduce the "directory outage hangs the whole box" symptom in miniature.

**Setup:**
```bash
# tool for tracing; strace is the star here
sudo dnf install -y strace nss-tools 2>/dev/null || sudo apt install -y strace
```

**Steps:**
1. Trace which shared objects a name lookup opens:
   ```bash
   strace -f -e trace=openat getent passwd root 2>&1 | grep -i 'libnss'
   # you'll see libnss_files.so.2 (and libnss_sss.so.2 / libnss_systemd.so.2 if configured)
   ```
2. Confirm the database→backend mapping and the action algebra in play:
   ```bash
   grep -E '^(passwd|group|shadow|hosts):' /etc/nsswitch.conf
   ```
3. Create a *transient* user that exists only via a custom NSS-ish path to prove `/etc/passwd` isn't the only truth. Simplest reproducible version: add a user, then demonstrate `getent` (NSS) vs grep (files-only):
   ```bash
   getent passwd labuser        # NSS answer
   grep '^labuser:' /etc/passwd # files-only answer — same here, but conceptually different
   ```
4. **Break NSS to mimic a hung directory backend.** Point a database at a nonexistent module and watch the failure mode (do this carefully, `hosts` is safest so you don't lock out logins):
   ```bash
   cp /etc/nsswitch.conf /root/nsswitch.bak
   sed -i 's/^hosts:.*/hosts: files doesnotexist dns/' /etc/nsswitch.conf
   getent hosts localhost           # still works: files answers, doesnotexist → unavail → continue
   strace -e trace=openat getent hosts example.com 2>&1 | grep -i 'nss_doesnotexist'
   # observe glibc TRYING to open libnss_doesnotexist.so.2 and failing → UNAVAIL → continue to dns
   cp /root/nsswitch.bak /etc/nsswitch.conf   # RESTORE
   ```
5. Prove the "config is cached per process" fact:
   ```bash
   getent passwd labuser   # populates any nscd/sssd cache
   userdel labuser 2>/dev/null; useradd -M labuser
   # with nscd running, an old cached entry can linger:
   getent passwd labuser   # may show stale data until cache invalidation
   ```

**Prove it:**
```bash
# You can articulate the split: getent (NSS) sees the user; grep (files) is only one backend.
getent passwd root >/dev/null && echo "NSS resolution path traced and understood: PASS"
# And you captured glibc dlopen-ing a backend module by name:
strace -e openat getent passwd root 2>&1 | grep -q 'libnss_files' && echo "NSS dlopen confirmed"
```

**Teardown:**
```bash
cp /root/nsswitch.bak /etc/nsswitch.conf 2>/dev/null   # ensure the edited config is reverted
rm -f /root/nsswitch.bak
userdel labuser 2>/dev/null                            # created with -M, so no home to remove
```

### Lab 3 — Building and tracing a PAM stack; the faillock sandwich

**Objective:** Author a PAM policy for a *test* service, drive it with `pamtester` (never risk `sshd`), and watch the control-flag algebra and faillock counting happen live.

**Setup:**
```bash
sudo dnf install -y pamtester 2>/dev/null || sudo apt install -y pamtester
useradd -m pamlab 2>/dev/null; echo 'pamlab:hunter2' | chpasswd
```

**Steps:**
1. Create an isolated PAM service so nothing you do can lock out real logins:
   ```bash
   cat >/etc/pam.d/labsvc <<'EOF'
   auth     required   pam_faillock.so preauth  deny=3 unlock_time=120
   auth     sufficient pam_unix.so nullok
   auth     [default=die] pam_faillock.so authfail deny=3 unlock_time=120
   auth     sufficient pam_faillock.so authsucc
   auth     required   pam_deny.so
   account  required   pam_unix.so
   EOF
   ```
2. Succeed once, watching it work:
   ```bash
   echo 'hunter2' | pamtester -v labsvc pamlab authenticate
   ```
3. Fail three times and watch the lockout arm (feed wrong passwords):
   ```bash
   for i in 1 2 3; do echo 'wrong' | pamtester -v labsvc pamlab authenticate; done
   faillock --user pamlab            # shows the tally and timestamps
   ```
4. Now the correct password is *also* rejected (account locked) — proving `preauth`'s `[default=die]` path short-circuits before `pam_unix` even runs:
   ```bash
   echo 'hunter2' | pamtester -v labsvc pamlab authenticate   # DENIED despite correct pw
   ```
5. Reset and confirm recovery — showing that config changes don't clear existing state:
   ```bash
   faillock --user pamlab --reset
   echo 'hunter2' | pamtester -v labsvc pamlab authenticate   # succeeds again
   ```
6. Turn on module-level tracing to see the stack walk. Add `debug` to a line and watch the journal:
   ```bash
   sed -i 's/pam_unix.so nullok/pam_unix.so nullok debug/' /etc/pam.d/labsvc
   echo 'hunter2' | pamtester -v labsvc pamlab authenticate
   journalctl -t pamtester -t pam_unix --since '1 min ago' --no-pager | tail -20
   ```

**Prove it:**
```bash
# Lockout arms after exactly 3 failures and blocks a correct password:
faillock --user pamlab --reset
for i in 1 2 3; do echo bad | pamtester labsvc pamlab authenticate 2>/dev/null; done
if echo 'hunter2' | pamtester labsvc pamlab authenticate 2>/dev/null; then
  echo "FAIL: lockout did not engage"
else
  echo "FAILLOCK SANDWICH WORKS: correct password blocked while locked: PASS"
fi
faillock --user pamlab --reset   # cleanup
```

**Teardown:**
```bash
rm -f /etc/pam.d/labsvc          # remove the test PAM service
faillock --user pamlab --reset   # clear any residual lockout state
userdel -r pamlab                # remove the account and its home dir
```

### Lab 4 — sudoers vs polkit: two authorization models on the same box

**Objective:** Grant the *same* capability (restart a service) two different ways, observe credential caching, spot a shell-escape footgun, and see a polkit "auth required" refusal.

**Setup:**
```bash
useradd -m opslab 2>/dev/null; echo 'opslab:ops' | chpasswd
```

**Steps (sudo side):**
1. Add a *scoped* rule via a drop-in (never edit base sudoers), validated by visudo:
   ```bash
   echo 'opslab ALL=(root) NOPASSWD: /usr/bin/systemctl restart chronyd' \
     | visudo -cf - && \
   echo 'opslab ALL=(root) NOPASSWD: /usr/bin/systemctl restart chronyd' \
     > /etc/sudoers.d/opslab
   visudo -c   # validate the whole ruleset
   ```
2. See the *effective* policy and the credential-cache mechanism:
   ```bash
   sudo -u opslab sudo -l                     # authoritative "what can opslab run"
   ls -l /run/sudo/ts/ 2>/dev/null || echo "(no timestamp file until first real sudo)"
   ```
3. Demonstrate the footgun: a broader grant is a root shell. (Illustrate, don't leave it in place.)
   ```bash
   echo 'opslab ALL=(root) NOPASSWD: /usr/bin/vi' > /etc/sudoers.d/opslab-danger
   echo "This grant means: sudo vi, then :!/bin/bash → root shell. Delete it."
   rm -f /etc/sudoers.d/opslab-danger
   ```

**Steps (polkit side):**
4. Observe the polkit refusal for a non-privileged, possibly non-active session:
   ```bash
   # as opslab over a non-active session, this should demand auth (or refuse headless):
   su - opslab -c 'systemctl restart chronyd' ; echo "exit=$?"
   # Expect "Interactive authentication required" → that's polkit, not systemd.
   ```
5. Write a polkit rule that *allows* it without a prompt for a group, and see the difference:
   ```bash
   cat >/etc/polkit-1/rules.d/49-ops.rules <<'EOF'
   polkit.addRule(function(action, subject) {
       if (action.id == "org.freedesktop.systemd1.manage-units" &&
           subject.user == "opslab") {
           return polkit.Result.YES;
       }
   });
   EOF
   # no daemon restart needed on modern polkit; it reloads rules.d automatically
   su - opslab -c 'systemctl restart chronyd' ; echo "exit=$?"   # now allowed
   ```
6. Compare the two grants conceptually: the sudo rule works from a terminal and is PAM-authenticated; the polkit rule works for D-Bus-mediated calls and is evaluated by polkitd in JS.

**Prove it:**
```bash
# sudo path: scoped command allowed, validated grammar:
sudo -u opslab sudo -l 2>/dev/null | grep -q 'systemctl restart chronyd' \
  && echo "SUDO scoped grant active: PASS"
# polkit path: the rule file is present and parses (polkitd logs a parse error if not):
journalctl -u polkit --since '2 min ago' --no-pager | grep -qi 'error' \
  && echo "polkit rule PARSE ERROR — check syntax" \
  || echo "polkit rule loaded cleanly: PASS"
# cleanup
rm -f /etc/sudoers.d/opslab /etc/polkit-1/rules.d/49-ops.rules
```

**Teardown:**
```bash
rm -f /etc/sudoers.d/opslab /etc/sudoers.d/opslab-danger   # drop-in sudo rules (idempotent)
rm -f /etc/polkit-1/rules.d/49-ops.rules                   # polkit rule (reloaded automatically)
userdel -r opslab                                          # remove the account and its home dir
```

---

## Curated resources

**Primary references (the ABI and file-format sources of truth):**

- [The Linux-PAM System Administrators' Guide](http://www.linux-pam.org/Linux-PAM-html/Linux-PAM_SAG.html) — the authoritative explanation of the four management groups, the control-flag algebra (including the full `[value=action]` syntax and the integer-jump action that RHEL's faillock sandwich depends on), and stack-walking semantics. Read the "configuration file" and "modules" sections end to end; this is *the* mechanism doc, not a tutorial.
- [pam.d(5) man page](https://www.man7.org/linux/man-pages/man5/pam.d.5.html) — the exact line format and the default `[value=action]` expansions of `required`/`requisite`/`sufficient`/`optional`. The table of defaults is worth memorizing.
- [The Linux-PAM Module Writers' Guide](http://www.linux-pam.org/Linux-PAM-html/Linux-PAM_MWG.html) — the `pam_sm_*` service-function ABI, the conversation-function callback model, and `pam_get_item`/`PAM_AUTHTOK`. Read this even if you never write a module: it's *why* `try_first_pass` and cross-module password reuse work.
- [nsswitch.conf(5) man page](https://www.man7.org/linux/man-pages/man5/nsswitch.conf.5.html) — the 14 databases, the four statuses (`success`/`notfound`/`unavail`/`tryagain`), their default actions, and the `[STATUS=action]`/`merge` grammar. The definitive statement; when a blog disagrees, this wins.
- [sudoers(5) man page](https://man7.org/linux/man-pages/man5/sudoers.5.html) and [sudoers_timestamp(5)](https://www.sudo.ws/docs/man/sudoers_timestamp.man/) — the full grammar (User/Host/Runas/Cmnd specs, aliases, tags, `Defaults` scoping) and the per-tty credential-cache record format. The sudo.ws docs are maintained by Todd Miller (the author).
- [crypt(5) man page (libxcrypt)](https://man7.org/linux/man-pages/man5/crypt.5.html) — the Modular Crypt Format, every `$id$` prefix, and the per-algorithm parameter encodings including yescrypt's cost params. This is the on-disk hash spec.
- [polkit(8) Reference Manual](https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html) — the actions/rules architecture, the JS `polkit.addRule`/`polkit.Result` API, the `allow_any`/`allow_inactive`/`allow_active` subject model, and rule file ordering. The authoritative polkit doc.

**Distro-current operational docs:**

- [Fedora Change: yescrypt as default hashing method](https://fedoraproject.org/wiki/Changes/yescrypt_as_default_hashing_method_for_shadow) — the rationale and rollout for the `$6$`→`$y$` default flip, and the libxcrypt ≥ 4.3 dependency. Explains why RHEL 9 boxes hash with yescrypt.
- [openwall yescrypt page](https://www.openwall.com/yescrypt/) — the algorithm itself from its author (Alexander Peslyak / Solar Designer): why memory-hardness beats CPU-only hardness against GPU/ASIC cracking, and the parameter model. The primary source on the KDF.
- [Red Hat: Managing authselect / configuring authentication](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_authentication_and_authorization_in_rhel/) — the *supported* way to manage `system-auth`/`password-auth` on RHEL 9. Read this to internalize why you never hand-edit the generated stacks.
- [SSSD documentation (sssd.conf, sss NSS/PAM providers)](https://sssd.io/docs/introduction.html) — how `pam_sss`/`libnss_sss` front LDAP/AD/IdM and cache offline. The real-world reason NSS and PAM both point at one daemon in enterprises.
- https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here (e.g. `chpasswd --crypt-method`, `faillock --reset`, `visudo -cf`) before pasting a lab command into a customer ticket.

**Deep-dive / canonical:**

- [The Linux Programming Interface (TLPI), Kerrisk — chapters on users/groups, passwords, and the credential model](https://man7.org/tlpi/) — Ch. 8 (users/groups, `getpwnam`/`getgrnam`, `crypt`), Ch. 9 (process credentials: real/effective/saved/fs UIDs, `setresuid`, the mechanics `sudo` and setuid binaries actually use). The definitive treatment of the syscall boundary under all of this.
- [LWN: "Namespaces in operation" — user namespaces](https://lwn.net/Articles/532593/) — because rootless containers remap the entire UID/GID identity model; understanding `uid_map`/`gid_map` is the modern extension of this module.
- [Julia Evans — "How does sudo work?" and PAM/strace zines/posts](https://jvns.ca/) — the best hands-on-debugging framing: how to *interrogate* a broken login with `strace` and `/proc` rather than guessing. Great reflex-builder to pair with the dense primary sources.
- [GTFOBins](https://gtfobins.github.io/) — the canonical catalog of shell escapes from "harmless" binaries. Essential for reading a sudoers file and instantly seeing which scoped grants are actually root. Filter by `sudo`.
- [Qualys advisory: PwnKit / CVE-2021-4034 in pkexec](https://blog.qualys.com/vulnerabilities-threat-research/2022/01/25/pwnkit-local-privilege-escalation-vulnerability-discovered-in-polkits-pkexec-cve-2021-4034) — the definitive writeup of the `argc`/environ confusion. Read it as a lesson in how privileged helpers get owned, not just as a CVE.
- [nss-and-pam source: linux-pam on GitHub](https://github.com/linux-pam/linux-pam) — when a man page is ambiguous, read `modules/pam_unix/`, `modules/pam_faillock/`, and `libpam/pam_dispatch.c` (the stack-walk implementation). The dispatch loop is where the control-flag algebra literally lives.

---

## Senior signal

- **Instantly splits "who exists" (NSS) from "is it them" (PAM) from "may they" (sudo/polkit/DAC), and reaches for the right probe:** `getent passwd/shadow/group` tests NSS; `pamtester`/journal tests PAM; `sudo -l`/`pkcheck` tests authorization. Mid-level greps `/etc/passwd` and calls it a user check — which silently lies the moment SSSD/LDAP is in play.
- **Reads the RHEL faillock/pam_unix sandwich correctly:** knows `pam_faillock` appears three times (`preauth`/`authfail`/`authsucc`), that `[default=die]` short-circuits the stack, and that the bare integer action means "jump N modules." Can explain why a *correct* password is rejected on a locked account before `pam_unix` even runs.
- **Knows the hash lives in libxcrypt, not glibc, since RHEL 8+,** that `$y$` = yescrypt (memory-hard, the RHEL 9 default) vs `$6$` = SHA-512-crypt, that the algorithm is chosen at *write* time and never migrates, and that copying a `$y$` shadow line to a box with an old `libcrypt` is a silent permanent lockout.
- **Recognizes a hung identity backend as the cause of a system-wide stall:** `ls -l`, `ps`, and new `sshd` sessions all blocking on an unreachable LDAP server via a stuck NSS `getpwnam`, proven with `strace` showing a wedged `connect()`/`poll()` — not a disk or CPU problem. Also knows `nsswitch.conf` is cached per process, so daemons need a restart after edits.
- **Treats sudoers scoping as necessary-but-not-sufficient:** spots that `NOPASSWD: /usr/bin/vi|find|systemctl|tar|less` are all root-shell escalations (GTFOBins reflex), uses `sudoedit`/`NOEXEC` and drop-ins in `/etc/sudoers.d/` edited via `visudo`, and reads `sudo -l` (effective policy) rather than the raw file because LDAP/SSSD sudoers and alias expansion don't show up in `grep`.
- **Understands polkit as a distinct authorization model from sudo:** JS rules in `rules.d` evaluated by polkitd, per-action `allow_active`/`allow_inactive`/`allow_any` semantics, and immediately identifies "Interactive authentication required" from `systemctl` over SSH as a *polkit* refusal (no active session / no auth agent), not a systemd bug. Carries PwnKit/CVE-2021-3560 as the reason polkit is a hardening focus.
- **Never hand-edits authselect-generated `system-auth`/`password-auth` on RHEL 9,** knows a stray edit reverts on the next tooling run, and manages PAM via `authselect select ... with-faillock without-nullok` or a custom profile. Always keeps a second root shell open while touching PAM or sudoers because a bad `required` line or syntax error is a remote lockout.
- **Distinguishes the credential lifetime facts that produce "phantom" bugs:** supplementary groups are baked into process credentials at login (`initgroups`/`setgroups`) and don't update for running sessions, so `usermod -aG` needs a fresh login; `pam_limits` vs systemd `Limit*=` fight over `ulimit`; and `pam_loginuid` fails in unprivileged containers, breaking any session stack that includes it.

---

## See also

- [[01 - Permissions and Access Control]] — the "may they do this" DAC layer (file mode bits, ownership, ACLs) that sits beside PAM/sudo/polkit; this module's UID/GID identities are exactly what those permission checks resolve against.
- [[12 - SELinux and Hardening]] — the mandatory-access-control layer that can override a passed sudo/polkit grant; ties into the `pam_selinux` session module and the sudoers `role=`/`type=` context pinning covered here.
- [[01 - IAM Core and the Policy Evaluation Engine]] — the cloud version of the three-orthogonal-questions split: authentication (proving identity) vs authorization (policy evaluation) is exactly the PAM-vs-sudoers boundary at the AWS layer.
- [[02 - STS AssumeRole and Federation]] — federated login and temporary role credentials are the cloud analog of NSS/PAM: an external identity provider resolves and authenticates a principal that then gets a scoped credential set.
- [[07 - KMS and Secrets Management]] — where authentication secrets live in the cloud; the shadow/yescrypt hashing story here is the on-host counterpart to managed secret storage and rotation.
