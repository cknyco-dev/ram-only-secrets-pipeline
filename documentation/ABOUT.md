# RAM-Only Secrets Pipeline via `systemd-creds`

A self-contained pattern for storing application secrets (API keys, tokens,
database passwords, signing keys — anything an app reads from environment
variables) so that **plaintext never touches persistent disk**, while still
surviving reboots automatically with no manual re-entry.

This document is meant to be genuinely standalone: everything needed to
implement this on a fresh server — for any application that reads a `.env`
file — is here, including the actual helper scripts, not just a description
of them. It is not tied to any particular application, host, or deployment
— every path below uses generic placeholders (`YOUR_APP`, `YOUR_APP_USER`)
you substitute per install.

---

## 1. What this is

A two-stage secrets pipeline:

1. **At rest**: secret values live as one `systemd-creds`-encrypted
   ciphertext blob on normal persistent disk. Reading it requires the host's
   own local credential key — the blob is useless if copied to another
   machine.
2. **At runtime**: a root-owned, one-time (`oneshot`) systemd service
   decrypts that blob into `/run/` — a `tmpfs` RAM-backed filesystem — as a
   plain `KEY=value` env file, *before* the application's own service starts.
   The application reads that file normally, unaware anything unusual
   happened. Nothing is ever written back to persistent disk in plaintext.

## 2. Why this shape

- **Ciphertext at rest, plaintext only in RAM — provided swap is off.** If
  the disk is imaged, snapshotted, or stolen, the secrets are encrypted.
  But `tmpfs` (where the decrypted `.env` file lives, Section 3) is
  swappable by default like any other memory: under memory pressure the
  kernel can page it out to a swap device exactly like any other memory
  page, putting plaintext secrets right back onto persistent disk — just
  in a swap partition/file instead of a plain one. **No active swap on the
  host is therefore a hard precondition of the RAM-only guarantee, not an
  optional hardening step.** Section 5.1 checks for this before touching
  anything else and refuses to proceed if any swap is active, with no
  override flag — the same check also runs at every boot (Section 4.2)
  and before every secret edit (Section 4.4), since swap can be enabled
  after installation too. `vm.swappiness=0` is not an acceptable
  substitute for this — it only makes swapping less likely, not
  impossible; a genuinely absent swap device is the only guarantee strong
  enough to rely on here. If a host truly cannot go without swap for
  unrelated reasons, encrypted swap is the only theoretically sound
  alternative — but this pipeline does not detect, verify, or grant any
  exception for it; that path is entirely manual, unsupported, and your
  own responsibility to get right end to end.
- **No manual re-entry on reboot.** The oneshot unit re-decrypts
  automatically at boot, ordered before whatever consumes it.
- **Host-bound by design, not a limitation to work around.** `systemd-creds`
  derives its key from the local machine
  (`/var/lib/systemd/credential.secret`, or a TPM if present). The encrypted
  blob is *only* decryptable on the host that encrypted it — a feature for
  this threat model, but it means **the blob itself is not a portable
  backup** — see Section 7.
- **No new infrastructure.** `systemd-creds` has shipped as part of `systemd`
  since v250, actively developed since — nothing extra to install on most
  current Linux servers.

## 3. Architecture

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
