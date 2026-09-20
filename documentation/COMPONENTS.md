## 4. Components

### 4.1 The encrypted bundle

One plaintext file, one line per secret, standard `KEY=value` shape:

```text
DB_PASSWORD=...
API_KEY_SOMETHING=...
SIGNING_SECRET=...
```

Encrypted once at install time (Section 5.2), then only ever changed via
the `YOUR_APP-secrets-commit` script (Section 4.4) — never edited directly
with `systemd-creds encrypt` by hand after initial setup, so the scripts
stay the single source of truth for how the blob gets produced.

### 4.2 The decrypt-at-boot unit

`/etc/systemd/system/YOUR_APP-secrets.service`:

```ini
[Unit]
Description=Decrypt YOUR_APP secrets into RAM
DefaultDependencies=no
Before=user@YOUR_UID.service
# If the app runs as a system service instead of a user session, point
# Before= at that unit instead (e.g. Before=YOUR_APP.service) -- and see
# "One honest limitation" below: Before=, either way, only orders startup,
# it does not gate it.

[Service]
Type=oneshot
RemainAfterExit=yes
LoadCredentialEncrypted=YOUR_APP-env:/etc/credstore.encrypted/YOUR_APP-env
# Hard requirement, not a tunable -- see the explanation right after this
# unit. No override: if swap is active, this unit refuses to decrypt
# anything into tmpfs at all, rather than start with the guarantee broken.
ExecStartPre=/bin/sh -c '[ ! -r /proc/swaps ] || [ "$(wc -l < /proc/swaps)" -le 1 ] || { echo "YOUR_APP-secrets: refusing to start -- swap is active on this host; tmpfs-resident secrets are swappable to disk while enabled. Disable swap (swapoff -a; remove from fstab/systemd) and restart this unit." >&2; exit 1; }'
ExecStart=/bin/sh -c 'install -d -m 0750 -o YOUR_APP_USER -g YOUR_APP_USER /run/YOUR_APP-secrets && install -m 0600 -o YOUR_APP_USER -g YOUR_APP_USER "$CREDENTIALS_DIRECTORY/YOUR_APP-env" /run/YOUR_APP-secrets/.env'
# Boot-time history hygiene -- an automatic backstop, not a replacement for
# the manual clear-history steps in Sections 5.2 and 5.3. See the
# explanation right after this unit for what it does and does not cover.
# Adjust the path list to match where YOUR_APP_USER's home actually is.
ExecStartPost=/bin/sh -c 'for f in /root/.bash_history /root/.zsh_history /home/YOUR_APP_USER/.bash_history /home/YOUR_APP_USER/.zsh_history; do [ -e "$f" ] && : > "$f"; done; true'
# Installer cleanup backstop -- see Section 5.0. Removes a stray copy of
# ram-only-secrets-install.sh at the standard path, unless it's sitting
# inside a kept git checkout (Section 7.4), in which case it's left alone.
ExecStartPost=/bin/sh -c 'i=/root/ram-only-secrets-install.sh; if [ -e "$i" ] && ! git -C "$(dirname "$i")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then rm -f "$i"; fi; true'

[Install]
WantedBy=multi-user.target
```

`RemainAfterExit=yes` matters — this is a oneshot that runs once at boot and
is then considered "active" without a running process; systemd won't try to
restart it or consider it failed once it exits 0. `Before=` guarantees the
plaintext file exists before anything that needs it starts.

**Why `ExecStartPre=`, and why there's no override.** Swap defeats the
RAM-only guarantee this whole pipeline exists to provide (Section 2) —
`tmpfs` is swappable like any other memory, so active swap means the
kernel can page decrypted secrets out to a disk-backed swap device under
memory pressure. This check runs *before* `ExecStart=`, so if swap is
active, the plaintext `.env` file is never written in the first place —
not written-then-warned-about, never written at all. There is
deliberately no flag or environment variable to bypass it; the only way
past this line is to actually remove swap from the host. The same check,
for the same reason, also runs in `ram-only-secrets-install.sh` (Section
5.1, before touching anything) and in both helper scripts (Section 4.4,
on every edit) — swap can be enabled after installation too, so a
boot-time-only check wouldn't be enough.

**One honest limitation, not hidden: a failed unit doesn't automatically
stop the app.** `Before=` (used above) only orders startup — it is not a
dependency. If this unit fails for any reason (the swap check above
included), systemd does not, by itself, stop `user@YOUR_UID.service` —
or whatever `Before=` target you're using — from starting anyway. In
practice the app then finds a missing or dangling `.env` symlink and
typically fails on its own, but that's the app's own behavior saving you,
not a systemd guarantee.

If the app runs as its own system service (the `Before=YOUR_APP.service`
variant mentioned above), close this gap by adding a real dependency on
*that* unit — YOUR_APP.service, not this one:

```ini
[Unit]
Requires=YOUR_APP-secrets.service
After=YOUR_APP-secrets.service
```

With that in place, a failed `YOUR_APP-secrets.service` — from the swap
check or any other reason — actually blocks `YOUR_APP.service` from
starting at all, instead of merely being ordered before it. There's no
equivalent for the default `user@YOUR_UID.service` case: session startup
isn't gated this way, so that path still relies on the app failing on the
missing file, same as always.

**Why `ExecStartPost=`, and what it actually solves that the interactive
`history -c` in Sections 5.2/5.3/8.2 doesn't.** Those manual steps only
work if the operator actually remembers to run them, immediately, every
time. This line removes that dependency on human memory — at boot, with no
live interactive shell involved at all, systemd (running as root) can
simply truncate the history files directly; there's no "child process can't
reach a parent shell's memory" problem here, because there's no parent
shell in the picture. The result: even a forgotten manual clear is bounded
to "exposed at most until the next reboot," not "exposed indefinitely."

Two honest limitations, not hidden:

- **It only reaches accounts this line explicitly lists.** It can truncate
  root's history and `YOUR_APP_USER`'s, because those paths are known
  ahead of time. If a *different* individual human operator logs in under
  their own personal account and runs sensitive commands via `sudo` from
  there, this line has no way to know that account exists and won't touch
  it. Practical takeaway: do the sensitive steps in this document as `root`
  or `YOUR_APP_USER` specifically, not from an arbitrary personal login, if
  you want this backstop to actually cover you.
- **It clears the whole history file, not just the sensitive lines.** This
  is a real, deliberate trade — simple and reliable versus surgical and
  fragile. On a host whose `root`/`YOUR_APP_USER` accounts exist mainly to
  run this pipeline, that's an easy trade to accept. If those same accounts
  are also used interactively for a lot of unrelated work whose history is
  worth keeping, weigh that before enabling this line — it's a deliberate
  choice, not something to copy in without reading this paragraph.

### 4.3 The application's own env-file symlink

In the application's working directory, once:

```bash
ln -s /run/YOUR_APP-secrets/.env YOUR_APP_DIR/.env
```

The app then reads this exactly like a normal `.env` file — it has no idea
the target is a `tmpfs` path.

### 4.4 The helper scripts — the actual files, not just a description

Two scripts, both root-only, both installed to `/usr/local/sbin/` and made
executable. These are the only supported way to change a secret after
initial setup. Editing happens in `/dev/shm`, never `/tmp` — `/dev/shm` is
guaranteed `tmpfs` (RAM) on every mainstream Linux distribution; `/tmp` is
not guaranteed to be RAM-backed everywhere, so it's the wrong choice even as
a short-lived scratch file. Both scripts also refuse to run at all if swap
is active on the host, same hard requirement and same reasoning as the
boot unit's `ExecStartPre=` above — swap can be enabled after installation
too, so this can't be a boot-time-only check.

`/usr/local/sbin/YOUR_APP-secrets-open`:

```bash
#!/bin/sh
# Prepares an editable plaintext copy of the current secrets bundle in RAM.
set -eu

EDIT_FILE=/dev/shm/YOUR_APP-env.edit
RUNNING_ENV=/run/YOUR_APP-secrets/.env
INSTALLER=/root/ram-only-secrets-install.sh

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

# Hard requirement, not a tunable -- see Section 4.2 for why. No override.
if [ -r /proc/swaps ] && [ "$(wc -l < /proc/swaps)" -gt 1 ]; then
  echo "SWAP IS ACTIVE on this host -- refusing to run." >&2
  echo "tmpfs-resident secrets are swappable to disk while swap is enabled," >&2
  echo "which is exactly what this pipeline exists to prevent. Disable swap" >&2
  echo "first (swapoff -a, then remove it from fstab/systemd permanently)." >&2
  exit 1
fi

if [ -f "$EDIT_FILE" ]; then
  echo "An edit is already in progress at $EDIT_FILE -- finish or discard it first." >&2
  exit 1
fi

if [ -f "$RUNNING_ENV" ]; then
  cp "$RUNNING_ENV" "$EDIT_FILE"
else
  : > "$EDIT_FILE"
fi
chmod 600 "$EDIT_FILE"

# Backstop cleanup -- see Section 5.0. Same check the boot unit (Section
# 4.2) also runs, so a missed self-delete gets caught quickly either way.
if [ -e "$INSTALLER" ] && ! git -C "$(dirname "$INSTALLER")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rm -f "$INSTALLER"
fi

echo "Edit $EDIT_FILE now, then run: YOUR_APP-secrets-commit"
echo "This file lives in RAM (/dev/shm) and is removed automatically on commit."
```

`/usr/local/sbin/YOUR_APP-secrets-commit`:

```bash
#!/bin/sh
# Re-encrypts the edited bundle, refreshes the running RAM copy, wipes the
# temp edit file, and prints a fresh backup blob + its checksum so the
# backup step is impossible to forget.
set -eu

EDIT_FILE=/dev/shm/YOUR_APP-env.edit
BLOB=/etc/credstore.encrypted/YOUR_APP-env
INSTALLER=/root/ram-only-secrets-install.sh

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

# Hard requirement, not a tunable -- see Section 4.2 for why. No override.
if [ -r /proc/swaps ] && [ "$(wc -l < /proc/swaps)" -gt 1 ]; then
  echo "SWAP IS ACTIVE on this host -- refusing to run." >&2
  echo "tmpfs-resident secrets are swappable to disk while swap is enabled," >&2
  echo "which is exactly what this pipeline exists to prevent. Disable swap" >&2
  echo "first (swapoff -a, then remove it from fstab/systemd permanently)." >&2
  exit 1
fi

if [ ! -s "$EDIT_FILE" ]; then
  echo "No edit found at $EDIT_FILE (or it's empty) -- run YOUR_APP-secrets-open first." >&2
  exit 1
fi

systemd-creds encrypt --name=YOUR_APP-env "$EDIT_FILE" "$BLOB"
shred -u "$EDIT_FILE"

systemctl restart YOUR_APP-secrets.service

# Same backstop cleanup as YOUR_APP-secrets-open -- see Section 5.0.
if [ -e "$INSTALLER" ] && ! git -C "$(dirname "$INSTALLER")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rm -f "$INSTALLER"
fi

echo
echo "Committed. Blob re-encrypted and the RAM copy has been refreshed."
echo "Remember to recreate any already-running service that needs the new value."
echo
echo "New blob checksum (sha256) -- for the verification step in Section 6:"
sha256sum "$BLOB"
echo
echo "New blob, base64 -- copy this ENTIRE line into your password manager now:"
base64 -w0 "$BLOB"; echo
echo

# A script is a child process -- it cannot reach into your interactive
# shell's in-memory history and erase it for you, no matter what it prints.
# The best it can do is wait for your confirmation, then hand you the exact
# commands to run yourself, right now, in the shell you're actually typing
# in. See Section 5.2 step 10 for why this matters and what these commands
# actually do.
printf 'Have you copied the base64 blob above into your password manager and verified it per Section 6? [y/N] '
read -r CONFIRM
case "$CONFIRM" in
  [yY]*)
    echo
    echo "Good. Now run these in YOUR OWN shell (not this script) to clear this"
    echo "session's history -- pick the line for your shell:"
    echo '  bash: history -c && history -w'
    echo '  zsh:  history -c && fc -W'
    echo "Then, if your terminal supports it, clear scrollback too (best-effort,"
    echo "not every terminal honors this): printf '\\033[3J'"
    ;;
  *)
    echo
    echo "Not clearing anything. Re-run this reminder any time -- nothing above"
    echo "was destructive, this was only a prompt."
    ;;
esac
```

Make both executable once, at install time. `750`, not `755` — these scripts handle secret material and root-only execution is already self-enforced inside them (see the UID check in each), so there's no reason to leave world-execute set too:

```bash
chmod 750 /usr/local/sbin/YOUR_APP-secrets-open /usr/local/sbin/YOUR_APP-secrets-commit
```
