## 5. Installation and operation

### 5.0 Fast path: `ram-only-secrets-install.sh`

Sections 5.1 and 5.2 below are automated end-to-end by
`ram-only-secrets-install.sh`, shipped alongside this document. It performs
every check and every step described in 5.1/5.2 — including generating
both helper scripts (Section 4.4) and the systemd unit (Section 4.2) itself,
with your app name/user/UID substituted in automatically — and stops only
for the one step that has to stay interactive: filling in your actual
secret values in `nano`.

```bash
chmod +x ram-only-secrets-install.sh
sudo ./ram-only-secrets-install.sh YOUR_APP YOUR_APP_USER
# UID is auto-detected from YOUR_APP_USER; pass it as a 3rd argument only
# if that lookup fails for some reason.
```

**Read the script before you run it as root** — it's a genuinely small,
plain shell file, not a black box, and "trust a script you haven't read"
isn't a habit worth starting for anything that touches secrets. Sections
5.1 and 5.2 below are that same script's logic, spelled out step by step,
for exactly that reason: so you can verify what it does before running it,
or do it by hand yourself if you'd rather not run a script at all.

**It also won't let you get ahead of yourself, and it cleans up after
itself.** Three things this fast path adds beyond the bare mechanics of
5.1/5.2:

- **A hard gate before anything else runs**: it asks whether you've already
  chosen a password manager (Section 7.1) and refuses to touch the system
  at all until you answer yes — generating real secret material with
  nowhere safe to back it up is the one ordering mistake worth actually
  preventing, not just warning about afterward.
- **Confirmation prompts, not just printed reminders**, right after the
  values you typed into `nano` and right after the first blob backup is
  printed — matching the same confirmation already built into
  `YOUR_APP-secrets-commit` (Section 4.4). These warn rather than block,
  since the setup is already working either way by that point; they exist
  so the reminder can't be scrolled past unread.
- **Deletes itself when it's done**, unless it's running from inside a git
  work tree — in which case it's a kept config-repo checkout (Section 7.4)
  and is left alone. It always knows its own path (`$0`), which is exactly
  the thing the boot service and helper scripts *can't* know about an
  arbitrary copy elsewhere — see the note on the backstop cleanup in
  Sections 4.2 and 4.4 for why those two also independently check the one
  standard location (`/root/ram-only-secrets-install.sh`) for a copy that
  didn't get cleaned up, e.g. because the process was killed before
  reaching that last line.

### 5.1 Prerequisites

Don't take these on faith — check them directly.

```bash
# systemd-creds has shipped as part of systemd since v250. Confirm both
# the binary and systemctl agree on a recent-enough version:
systemctl --version | head -1
which systemd-creds && systemd-creds --version

# Optional, but worth knowing either way: is there a TPM you could bind
# encryption to instead of (or alongside) the host-only key? Not required
# for this pipeline -- host-key-only is what's used throughout -- but a
# real hardware-backed option if you want it later.
systemd-creds has-tpm2 || echo "no TPM2 -- host-only key will be used, which is what this pipeline assumes throughout"

# The plain coreutils this pipeline relies on -- present on virtually
# every Linux install already, confirm rather than assume:
which shred base64 sha256sum install nano
```

If `systemd-creds` is missing entirely, or `systemctl --version` reports
something clearly old, update the `systemd` package itself (it's not a
separate install — `systemd-creds` comes bundled with it):

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install --only-upgrade systemd

# Fedora / RHEL / CentOS Stream
sudo dnf upgrade systemd
```

If any of the coreutils tools are genuinely missing (rare — they ship by
default on nearly every distribution):

```bash
# Debian / Ubuntu
sudo apt install coreutils nano

# Fedora / RHEL / CentOS Stream
sudo dnf install coreutils nano
```

Also needed, not a package to install: an unprivileged application user
already created (`YOUR_APP_USER`) and root/sudo access for the one-time
setup below.

### 5.2 One-time setup

```bash
# --- as root ---

# 1. Install the two helper scripts from Section 4.4 and make them executable.
nano /usr/local/sbin/YOUR_APP-secrets-open
nano /usr/local/sbin/YOUR_APP-secrets-commit
chmod 750 /usr/local/sbin/YOUR_APP-secrets-open /usr/local/sbin/YOUR_APP-secrets-commit

# 2. Install the systemd unit from Section 4.2.
nano /etc/systemd/system/YOUR_APP-secrets.service

# 3. Create the encrypted-credentials directory if it doesn't exist yet.
install -d -m 0755 /etc/credstore.encrypted

# 4. First-ever encrypt: prepare the initial bundle directly, since no
#    running RAM copy exists yet for YOUR_APP-secrets-open to seed from.
#    IMPORTANT: this heredoc is shown with placeholder values for
#    illustration only. Do NOT type your real secret values into a heredoc
#    or an echo/printf command at an interactive prompt -- an interactive
#    shell's history file records the exact command you typed, values and
#    all, in plaintext, forever, which is precisely what this whole
#    document exists to avoid. Create the empty file, then edit it with
#    nano instead -- nano's own buffer is never written to shell history,
#    only the command "nano /dev/shm/YOUR_APP-env.edit" is.
: > /dev/shm/YOUR_APP-env.edit
chmod 600 /dev/shm/YOUR_APP-env.edit
nano /dev/shm/YOUR_APP-env.edit
# type your real KEY=value lines inside the editor now, save, exit
systemd-creds encrypt --name=YOUR_APP-env /dev/shm/YOUR_APP-env.edit /etc/credstore.encrypted/YOUR_APP-env
shred -u /dev/shm/YOUR_APP-env.edit

# 5. Enable and start the unit -- this performs the first decrypt into RAM.
systemctl daemon-reload
systemctl enable --now YOUR_APP-secrets.service

# 6. Verify.
systemctl status YOUR_APP-secrets.service
ls -l /run/YOUR_APP-secrets/.env
# expect: -rw------- YOUR_APP_USER YOUR_APP_USER
grep -c '=' /run/YOUR_APP-secrets/.env
# sanity-check the line count only -- do not print values

# 7. Take the FIRST backup now, the same way every later commit prints one.
sha256sum /etc/credstore.encrypted/YOUR_APP-env
base64 -w0 /etc/credstore.encrypted/YOUR_APP-env; echo
# Copy that base64 line into your password manager now, dated today.
# Then verify it per Section 6 before moving on.

# 7b. OPTIONAL -- read Section 7.5 before running this. Backs up the host's
#     own encryption key. Saved once here, never changes afterward -- but
#     it changes what's safe to do with the blob from step 7 onward. Do
#     not run this line until you've read why.
sha256sum /var/lib/systemd/credential.secret
sudo base64 -w0 /var/lib/systemd/credential.secret; echo

# --- as YOUR_APP_USER, or via the app's own deploy step ---

# 8. Symlink the app's env file to the RAM copy, once.
ln -s /run/YOUR_APP-secrets/.env YOUR_APP_DIR/.env

# 9. Start/restart the application normally -- it now reads secrets that
#    exist only in RAM. Any future change goes through Section 5.3, never
#    through step 4 above again.

# 10. Clear this session's shell history now. Steps 7/7b printed real
#     secret material to this terminal -- that's scrollback, not history,
#     but if you copy-pasted any value into another command anywhere in
#     this session, THAT command is sitting in your history file in
#     plaintext right now. Run the line for your shell, in this same
#     shell (a script cannot do this step for you -- see the note on
#     YOUR_APP-secrets-commit in Section 4.4 for why):
#       bash: history -c && history -w
#       zsh:  history -c && fc -W
#     Then, best-effort (not every terminal honors this):
#       printf '\033[3J'
```

**Verification checklist**

- [ ] `systemctl is-enabled YOUR_APP-secrets.service` reports `enabled`
- [ ] Reboot the host once, deliberately, and confirm `/run/YOUR_APP-secrets/.env`
      exists with correct content *without* any manual step.
- [ ] Confirm no plaintext copy exists anywhere on persistent disk (check
      shell history, `/tmp`, any editor swap/backup files).
- [ ] Confirm `/etc/credstore.encrypted/YOUR_APP-env` is unreadable as
      plaintext (`file /etc/credstore.encrypted/YOUR_APP-env` should report
      binary/opaque data, not text).
- [ ] The base64 blob backup is saved in the password manager and verified
      per Section 6.
- [ ] Real secret values are also recorded in the password manager,
      separately from the blob backup.

### 5.3 Day-to-day operation

This is the only workflow you should use after the one-time setup above —
never call `systemd-creds encrypt` by hand again once these scripts exist,
so there is exactly one code path that produces the blob.

```bash
sudo YOUR_APP-secrets-open
sudo nano /dev/shm/YOUR_APP-env.edit
# add, change, or remove a KEY=value line, save, exit nano
sudo YOUR_APP-secrets-commit
```

`YOUR_APP-secrets-commit`'s own output ends with the fresh checksum and the
fresh base64 blob — that output *is* the next step: copy it into your
password manager immediately (Section 7). The blob changes on every commit,
since it's a brand-new ciphertext of whatever the edit file contained — the
old backed-up blob is now stale the moment you commit, which is why the
script prints a new one every single time rather than leaving that as a
separate step you have to remember.
