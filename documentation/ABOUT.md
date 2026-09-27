# RAM-Only Secrets Pipeline via `systemd-creds`

A self-contained pattern for storing application secrets (API keys, tokens,
database passwords, signing keys — anything an app reads from environment
variables) so that **plaintext never touches persistent disk**, while still
surviving reboots automatically with no manual re-entry. That promise has
stated limits, among them the application's own memory, core dumps and
the hypervisor; Section 4.5 ("What the guard does not cover") lists them
all.

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
   decrypts that blob into `/run/` — a `tmpfs` RAM-backed filesystem, on
   Linux 6.4 and later a dedicated one mounted with `noswap` — as a plain
   `KEY=value` env file, *before* the application's own service starts.
   The application reads that file normally, unaware anything unusual
   happened. The pipeline itself never writes plaintext back to
   persistent disk; what it cannot control is listed in Section 4.5
   under "What the guard does not cover".

## 2. Why this shape

- **Ciphertext at rest, plaintext only in RAM, provided no swap can reach
  disk.** If the disk is imaged, snapshotted, or stolen, the secrets are
  encrypted. But `tmpfs` (where the decrypted `.env` file lives, Section 3)
  is swappable by default like any other memory: under memory pressure the
  kernel can page it out to a swap partition or swap file, putting
  plaintext secrets right back onto persistent disk. **Swap that can reach
  disk is therefore ruled out as a hard precondition of the RAM-only
  guarantee, not an optional hardening step.**

  Two setups pass. The first is no swap at all. The second is swap on zram
  only, since zram keeps swapped pages compressed in RAM, as long as two
  conditions hold: the zram device has no writeback backing device (which
  would let it move pages onto a partition), and kdump is off while zram
  swap is on (after a kernel panic, the dump written to `/var/crash` keeps
  zram's compressed pool). Everything else is refused: a swap partition, a
  swap file, LVM or dm-crypt swap, zram with a backing device. Section 5.1
  checks this before touching anything else, with no override flag, and
  the same check runs at every boot (Section 4.2) and at the start of
  every secret edit and commit (Section 4.4), since swap can be enabled
  after installation too.
  Section 4.5 lists every rule with its kernel reference, and the limits
  that remain.

  On Linux 6.4 and later, the decrypted file also gets a tmpfs of its own,
  mounted with `noswap`, so the kernel won't page it out even to a swap
  device switched on after the check ran. The plaintext copy used during
  an edit gets the same kind of mount. Where that isn't available (an
  older kernel, or a container that refuses the mount), the unit warns and
  keeps the plain directory on `/run`, the layout this pipeline always
  used. zram swap is still accepted there: swapping into zram keeps pages
  in RAM, so the `noswap` mount is defense in depth, not the gate.

  `vm.swappiness=0` is not an acceptable substitute for any of this. It
  only makes swapping less likely, not impossible. If a host truly needs
  disk-backed swap for unrelated reasons, encrypted swap is the only
  theoretically sound alternative, but this pipeline does not detect,
  verify, or grant any exception for it; that path is entirely manual,
  unsupported, and your own responsibility to get right end to end.
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
/run/YOUR_APP-secrets/.env                 -- plaintext, own noswap tmpfs (RAM), mode 0600, owned YOUR_APP_USER
    |  symlinked from the app's own working directory
    v
YOUR_APP_DIR/.env  ->  /run/YOUR_APP-secrets/.env
    |
    v
application reads .env normally (docker compose --env-file, dotenv, etc.)
```
