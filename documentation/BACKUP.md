## 7. Backup strategy — of this solution, not of the secret values

Two completely different things need backing up, and conflating them is a
mistake. This pipeline automates neither — both are a manual discipline the
operator has to actually keep up, which is exactly why this section spells
out not just *what* goes in a password manager, but *which* tool, and the
precise moment each thing needs to be saved.

### 7.1 Choosing a password manager

Any of these work for this pipeline's purposes — the only real requirements
are: it encrypts what you store, it's reachable independently of the server
this pipeline protects (so losing that server doesn't also lose the backup),
and it supports both short individual entries (for secret values) and a
longer free-text note (for the base64 blob). Four reasonable, well-known
options, deliberately spanning the cloud-synced/fully-local tradeoff rather
than picking one:

| Tool | Model | Cost | Notes |
|---|---|---|---|
| [**Bitwarden**](https://bitwarden.com) | Cloud-synced (or self-hosted server) | Free tier: unlimited entries and devices | Open-source clients; the easiest default for most people |
| [**1Password**](https://1password.com) | Cloud-synced | Paid | Polished UI, strong family/team sharing if more than one person needs access |
| [**KeePassXC**](https://keepassxc.org) | Fully local — one encrypted file you control | Free | No cloud account, no third-party trust relationship at all — the closest match to this document's own "no new third-party trust" reasoning in Section 2; you're responsible for syncing/backing up the file yourself |
| [**`pass`**](https://www.passwordstore.org) | Local, GPG-encrypted, one file per entry | Free | Plain-text-friendly and git-friendly by design (encrypted per-entry, not one big blob), a natural fit if you're already comfortable with the command-line tooling this whole pipeline uses |

Cloud-synced tools (Bitwarden, 1Password) trade the "no third-party
dependency" ideal for convenience and multi-device access, with backup/sync
handled by the vendor. Fully local tools (KeePassXC, `pass`) keep that
dependency at zero, at the cost of you being responsible for getting a copy
of the vault itself off this host — store it somewhere that isn't this same
server, or the point of a backup is defeated. Pick based on that tradeoff,
not on any technical requirement of this pipeline — it doesn't care which
one you use.

### 7.2 What goes in it, and when

This table is the actual operational discipline — the pipeline can't enforce
any of it, so treat it as a checklist to follow by hand every time:

| What | When | Where |
|---|---|---|
| Each individual secret value | The moment it's first generated or obtained — **before** it's ever typed into the plaintext bundle in Section 5.2 or 5.3 | One password-manager entry per secret |
| A secret value, after it changes | Immediately after the Section 5.3 commit that changed it | Update that same entry, don't leave the old value sitting there |
| The base64 encrypted blob | Right after Section 5.2 step 7 (initial setup), and after **every** Section 5.3 commit | One note, dated, replacing the previous one — see Section 7.3 |
| Confirming a blob save is correct | Immediately after every blob save, using Section 6's checksum comparison | Not stored — this is a check you run, not an entry you keep |

Two failure modes this table exists to prevent: forgetting to save a secret
value at all (so a lost host means a lost credential, not just a lost
server), and saving the blob once and never again (so it silently goes
stale the moment you next rotate anything, and you don't find out until you
actually need it).

### 7.3 The encrypted blob backup

`YOUR_APP-secrets-commit` prints exactly the text to paste, every time it
runs (Section 5.3) — copy it immediately, verify it per Section 6, and
overwrite the old dated note (e.g. "Credstore blob (base64) — Latest Blob
(2026-09-19)"). Be precise about what this backup actually protects
against: it is ciphertext, safe to store anywhere, but **it is only
decryptable on the exact host that created it** (`systemd-creds`'s key is
host-bound) — unless you've deliberately chosen otherwise per Section 7.5.
By default, it does **not** help rebuild on a different machine — a fresh
host has a different key and the blob is permanently unreadable there. Its
real value, by default, is recovering *this* host after e.g. accidental
deletion of `/etc/credstore.encrypted/` with the OS otherwise intact —
restoring the saved blob directly is much faster than re-deriving it from
every individual secret value.

### 7.4 What's safe to version-control instead

Also worth version-controlling, since none of it is sensitive even if the
repo is public — plain text, no secret content:

1. The unit file (Section 4.2)
2. Both helper scripts (Section 4.4)
3. `ram-only-secrets-install.sh` (Section 5.0)
4. This document

**A genuinely public, cloneable repo is the actual goal here** — *provided*
you have not also backed up the host key per Section 7.5 below. Put items
1–4 in one, and a stranger — running whatever needs a `.env` file — has
everything required to reproduce this on their own server: the installer
that does it in one command, the unit file and scripts it generates (kept
here too, so nobody has to trust the installer blindly), and the exact
manual sequence in Section 5.1/5.2 if they'd rather not run a script at
all. The only things that stay out of that repo, ever, are the actual
secret values and the base64 blob backups — both belong in each operator's
own password manager (Section 7.1), never in git. That last sentence has
one exception, read next.

### 7.5 Optional: backing up the host key itself, for faster disaster recovery

Step 7b in Section 5.2 backs up `/var/lib/systemd/credential.secret` — the
host's own local key material that `systemd-creds` derives its encryption
from when no TPM is in use (which is the mode this whole document assumes
throughout). Unlike the blob, this file is created once and does not change
on its own, so it's a true one-time backup, not something you re-save after
every commit.

**What this actually buys you.** The default disaster-recovery path in
Section 8 assumes a fresh host generates a *new*, different key, so the old
blob is permanently unreadable there and every secret value has to be
re-typed from the password manager by hand. If you restore this key file
onto the new host *before* running `systemd-creds` for the first time —
overwriting whatever the fresh install auto-generated — the new host now
shares the old host's exact key. Restore the blob on top of that and it
decrypts immediately: no re-typing every individual secret, just two files
restored. (This document has not independently verified that the "host"
key mode is unaffected by anything else machine-specific, e.g. the
machine's own ID — the mechanism described here is the mode's intended
design, not something tested end-to-end in this session. If you rely on
this for real disaster recovery, prove it once, deliberately: restore both
files to a genuinely separate test VM and confirm decryption succeeds,
before you need it for real.)

**What this costs you — read this before running step 7b.** The whole
reason Section 7.4 could say the encrypted blob is safe in a *public* repo
is that the blob alone is useless without a key that never leaves the host.
The moment you also back up that key — to a password manager, which is a
different security boundary than the host itself — that guarantee is gone.
A public repo containing the blob, combined with a password-manager
compromise that reaches this key backup, is now sufficient to decrypt
everything. This isn't a small caveat: it changes the blob from "safe
anywhere" to "exactly as sensitive as the key itself," permanently, for as
long as the key backup exists.

**So, concretely:** if you do step 7b, stop keeping the blob in a public
(or even shared-private) repo — move it to the same password manager entry
as the key, or somewhere with equivalent protection. If you'd rather keep
the blob's "safe even if public" property, skip step 7b entirely and accept
that disaster recovery on a new host means retyping secret values from
Section 7.1's password manager, per Section 8's default path. Pick one;
don't do both halfheartedly.
