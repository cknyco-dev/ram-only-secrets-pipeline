# RAM-Only Secrets Pipeline

[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![systemd](https://img.shields.io/badge/requires-systemd%20%E2%89%A5%20250-blue)](https://systemd.io/CREDENTIALS/)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)](#requirements)
[![Issues Welcome](https://img.shields.io/badge/issues-welcome-brightgreen)](#contributing)
[![Maintenance](https://img.shields.io/badge/maintained-yes-brightgreen)](#contributing)
[![Last commit](https://img.shields.io/github/last-commit/cknyco-dev/ram-only-secrets-pipeline)](https://github.com/cknyco-dev/ram-only-secrets-pipeline/commits)
[![Open issues](https://img.shields.io/github/issues/cknyco-dev/ram-only-secrets-pipeline)](https://github.com/cknyco-dev/ram-only-secrets-pipeline/issues)
[![Stars](https://img.shields.io/github/stars/cknyco-dev/ram-only-secrets-pipeline?style=social)](https://github.com/cknyco-dev/ram-only-secrets-pipeline)

Keep application secrets (API keys, tokens, passwords) off persistent disk
entirely, using `systemd-creds` — no extra daemon, no external
secrets-manager service, no network dependency at boot. Ciphertext lives on
disk; the only plaintext copy exists in a `tmpfs` (RAM-backed) directory,
created fresh at every boot and gone the moment the machine powers off or
reboots.

This is a **pattern**, not a hosted product: a systemd unit, two small
shell helper scripts, one optional installer, and `systemd-creds` itself
(bundled with systemd — nothing else to trust). Generic and app-agnostic —
drop it in front of any app that reads a `.env` file.

## Table of contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Backup & disaster recovery](#backup--disaster-recovery)
- [Documentation](#documentation)
- [Repository layout](#repository-layout)
- [Security notes](#security-notes)
- [Contributing](#contributing)
- [License](#license)

## Features

- **No plaintext secrets on persistent disk, ever** — not in the `.env`
  file your app reads, not in a backup snapshot, not in an editor swap
  file left behind by accident.
- **Fresh by construction on every boot** — no stale plaintext copy to
  forget about; a reboot re-decrypts from the encrypted bundle, nothing
  more.
- **One code path for changes** — helper scripts (`*-secrets-open` /
  `*-secrets-commit`) so there is exactly one way to edit secrets, ever,
  and it always ends by printing a fresh backup blob so that step is
  impossible to skip.
- **Shell-history and scrollback leak protection built in** — every step
  that touches real secret values is designed so nothing lands in
  `.bash_history`/`.zsh_history`, with explicit history-clear prompts
  where it can't be avoided. The secrets unit also clears both history
  files as a boot-time backstop (`documentation/COMPONENTS.md` §4.2) —
  deliberately **boot-time only**, not continuous: it guarantees nothing
  from *before* a reboot survives *past* it, for a system where an agent
  with shell access might start a fresh session right after one, but it
  does nothing about history accumulating during a single uptime — that
  gap is what the manual clear-history steps above are still for. Don't
  "fix" this into a cron job or a continuous watcher without re-reading
  why it's boot-scoped.
- **One-command install**, or do every step by hand — both are documented.
- **Backup is load-bearing, not optional, and this says so plainly** — a
  real comparison of password-manager options, exactly what to store and
  when, and an honest disaster-recovery procedure. Skip the backup step
  and losing the host means losing the secrets, permanently — see
  [Backup & disaster recovery](#backup--disaster-recovery).

## How it works

```text
plaintext secrets (root, one-time)
    |  systemd-creds encrypt  (or: YOUR_APP-secrets-commit, day to day)
    v
/etc/credstore.encrypted/YOUR_APP-env      -- ciphertext, persistent disk, safe to leave here
    |  read at boot by YOUR_APP-secrets.service, via LoadCredentialEncrypted=
    v
/run/YOUR_APP-secrets/.env                 -- plaintext, tmpfs (RAM), mode 0600, owned YOUR_APP_USER
    |  symlinked from the app's own working directory
    v
YOUR_APP_DIR/.env  ->  /run/YOUR_APP-secrets/.env
    |
    v
application reads .env normally (docker compose --env-file, dotenv, etc.)
```

> **Placeholder convention**: `YOUR_APP`, `YOUR_APP_USER`, etc. are
> stand-ins for your actual application name and the system user it runs
> as — swap in your own values everywhere you see them. Single
> underscores only, deliberately: this form renders correctly in
> Markdown, shell, and `.ini`-style config alike, unlike `<APP>` (collides
> with shell redirection) or `__APP__` (collides with Markdown bold
> syntax).

Full breakdown of each piece — the encrypted bundle, the decrypt-at-boot
unit, the env-file symlink, and the two helper scripts in full — in
[`documentation/COMPONENTS.md`](documentation/COMPONENTS.md).

## Requirements

- **No active swap anywhere on the host.** `tmpfs` (where the decrypted
  `.env` file lives) is swappable like any other memory, so any active
  swap defeats the RAM-only guarantee this pipeline exists to provide —
  see [`documentation/ABOUT.md`](documentation/ABOUT.md#2-why-this-shape).
  Checked automatically, with no override, everywhere this pipeline
  touches the system: the installer, the boot service, and both helper
  scripts.
- Linux with **systemd ≥ 250** (`systemd-creds` availability; ≥ 259
  recommended for the full feature set this pipeline uses).
- Standard coreutils: `shred`, `base64`, `sha256sum`, `install`, `nano`.
- An unprivileged application user already created, and root/sudo access
  for the one-time setup.

Check directly rather than assuming:

```bash
cat /proc/swaps
# expect only the header line -- see Requirements above if anything else is listed
systemctl --version | head -1
which systemd-creds && systemd-creds --version
which shred base64 sha256sum install nano
```

Missing something? See
[`documentation/INSTALLATION-AND-OPERATION.md`](documentation/INSTALLATION-AND-OPERATION.md#51-prerequisites)
for the exact install commands per distro.

## Installation

**Fast path** — the installer walks you through choosing a password
manager, entering your real secret values in `nano` (never on the command
line, never in shell history), and confirming each backup step before
continuing. Run it interactively, not piped through `curl | sh`:

```bash
curl -O https://raw.githubusercontent.com/cknyco-dev/ram-only-secrets-pipeline/main/ram-only-secrets-install.sh
chmod +x ram-only-secrets-install.sh
sudo ./ram-only-secrets-install.sh YOUR_APP YOUR_APP_USER
```

**Manual path** — every step the installer automates, explained and
runnable by hand, in
[`documentation/INSTALLATION-AND-OPERATION.md`](documentation/INSTALLATION-AND-OPERATION.md#52-one-time-setup).
Use this if you want to understand or adapt each step before trusting a
script to run it for you.

## Usage

Once set up, this is the only workflow you should ever use to change a
secret — never call `systemd-creds encrypt` by hand again, so there is
exactly one code path that produces the blob:

```bash
sudo YOUR_APP-secrets-open
sudo nano /dev/shm/YOUR_APP-env.edit
# add, change, or remove a KEY=value line, save, exit nano
sudo YOUR_APP-secrets-commit
```

`YOUR_APP-secrets-commit` ends by printing a fresh checksum and base64
blob — copy that into your password manager immediately. See
[`documentation/INSTALLATION-AND-OPERATION.md`](documentation/INSTALLATION-AND-OPERATION.md#53-day-to-day-operation)
for the full explanation of why it's structured this way.

## Backup & disaster recovery

> **Two different things end up in your password manager here — know which
> one actually saves you.**
>
> - **The plaintext `KEY=value` lines** (typed during setup, and again on
>   every edit) are what disaster recovery depends on *by default*
>   ([`DISASTER-RECOVERY.md` §8.1](documentation/DISASTER-RECOVERY.md)) —
>   no host key needed, works on any new host. **This is the one that must
>   never be skipped.**
> - **The encrypted blob** (base64, printed after every commit) is
>   ciphertext bound to *this specific host's* own key. Saving it to your
>   password manager does **not**, by itself, protect you from losing this
>   host — without the host's own key too (an explicit, optional step,
>   [`BACKUP.md` §7.5](documentation/BACKUP.md#75-optional-backing-up-the-host-key-itself-for-faster-disaster-recovery)),
>   that blob is exactly as useless as leaving it on disk. Paired with a
>   host-key backup, it becomes a faster recovery path
>   ([`DISASTER-RECOVERY.md` §8.2](documentation/DISASTER-RECOVERY.md)) —
>   without one, it's not a safety net at all.
>
> If you only ever save one of these, save the plaintext values — that's
> the one with no strings attached.

This pipeline gets secrets off disk; backing them up is a separate,
explicit responsibility — nothing here does it for you automatically.

- [`documentation/BACKUP.md`](documentation/BACKUP.md) — choosing a
  password manager, what to store there and when, and the tradeoffs of
  also backing up the host's own encryption key.
- [`documentation/VERIFYING-SAVED-BACKUP.md`](documentation/VERIFYING-SAVED-BACKUP.md)
  — proving a saved backup actually decrypts correctly, before you need it
  for real.
- [`documentation/DISASTER-RECOVERY.md`](documentation/DISASTER-RECOVERY.md)
  — rebuilding on a different server, both with and without a host-key
  backup.

## Documentation

| File | Covers |
| --- | --- |
| [`documentation/ABOUT.md`](documentation/ABOUT.md) | What this is, why it's shaped this way, and the full architecture |
| [`documentation/COMPONENTS.md`](documentation/COMPONENTS.md) | The encrypted bundle, the decrypt-at-boot unit, the env-file symlink, and the two helper scripts (full source) |
| [`documentation/INSTALLATION-AND-OPERATION.md`](documentation/INSTALLATION-AND-OPERATION.md) | Prerequisites, one-time setup (manual and via the installer), and day-to-day secret rotation |
| [`documentation/VERIFYING-SAVED-BACKUP.md`](documentation/VERIFYING-SAVED-BACKUP.md) | Proving a saved backup is actually correct |
| [`documentation/BACKUP.md`](documentation/BACKUP.md) | Password manager choice, what to store and when, host-key backup tradeoffs |
| [`documentation/DISASTER-RECOVERY.md`](documentation/DISASTER-RECOVERY.md) | Rebuilding on a different server |

Read them in the order listed on a first pass — each assumes the last.

## Repository layout

```
.
├── README.md
├── LICENSE
├── SECURITY.md
├── CODEOWNERS
├── .gitignore
├── .gitattributes
├── ram-only-secrets-install.sh
├── .github/
│   └── ISSUE_TEMPLATE/
│       ├── bug_report.yml
│       ├── question.yml
│       └── config.yml
└── documentation/
    ├── ABOUT.md
    ├── COMPONENTS.md
    ├── INSTALLATION-AND-OPERATION.md
    ├── VERIFYING-SAVED-BACKUP.md
    ├── BACKUP.md
    └── DISASTER-RECOVERY.md
```

## Security notes

- **The RAM-only guarantee assumes no active swap, full stop.** `tmpfs` is
  swappable like any other memory — with swap enabled, decrypted secrets
  can be paged out to a swap device under memory pressure, which is
  exactly the disk exposure this pipeline exists to prevent, just
  relocated. There is no override flag for this anywhere in the pipeline;
  see [Requirements](#requirements) and
  [`documentation/ABOUT.md`](documentation/ABOUT.md#2-why-this-shape).
- Review the installer and every generated unit/script before running
  them as root, the same as you would with any script you didn't write
  yourself.
- The encrypted bundle (`/etc/credstore.encrypted/YOUR_APP-env`) is safe
  to commit or leave on disk — it's ciphertext bound to the host's own
  key, not useful by itself to anyone who copies it without the host too.
  The one deliberate exception (optionally backing up the host key itself)
  is documented, tradeoffs included, in
  [`documentation/BACKUP.md`](documentation/BACKUP.md#75-optional-backing-up-the-host-key-itself-for-faster-disaster-recovery).
- **Found a real security gap in this pattern?** Don't post exploit
  details in a public issue — see [`SECURITY.md`](SECURITY.md) for how to
  report it privately instead.

## Contributing

This repository doesn't merge external pull requests — every change ships
from a single, known source, a deliberate choice for a security-sensitive
pattern like this. (Forking itself can't be disabled on a public GitHub
repo — that toggle only exists for private repos — so a PR can still be
opened; it just won't be merged without review, and unsolicited ones may
be closed without engagement.)

**Issues are open and welcome** for bug reports, questions, corrections,
or "this doesn't work on distro X" reports — that feedback is genuinely
useful even without a PR attached; describe the problem and it'll get
picked up from there. Use the [bug report](.github/ISSUE_TEMPLATE/bug_report.yml)
or [question](.github/ISSUE_TEMPLATE/question.yml) template as a starting
point. The one exception is security vulnerabilities in the pattern
itself — see [Security notes](#security-notes) for why those go through
private reporting instead of a public issue.

Repository ownership is recorded in [`CODEOWNERS`](CODEOWNERS) — mostly
symbolic today since there's no PR flow for it to gate, but it states
plainly who's accountable for what ships here.

## License

[MIT](LICENSE) © 2026 [@cknyco](https://github.com/cknyco)
