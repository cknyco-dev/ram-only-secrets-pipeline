## 5. Installation and operation

### 5.0 Fast path: `ram-only-secrets-install.sh`

Sections 5.1 and 5.2 below are automated end-to-end by
`ram-only-secrets-install.sh`, shipped alongside this document. It performs
every check and every step described in 5.1/5.2 — including generating
the swap guard (Section 4.5), both helper scripts (Section 4.4) and the
systemd unit (Section 4.2) itself, with your app name/user/UID
substituted in automatically — and stops only for the one step that has
to stay interactive: filling in your actual secret values in `nano`.

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

**Hard requirement, checked first: no swap that can reach disk.** `tmpfs`
(where the decrypted `.env` file will live, Section 3) is swappable by
default like any other memory. With a swap partition or swap file active,
the kernel can page plaintext secrets out to it under memory pressure,
defeating the entire RAM-only guarantee this pipeline exists to provide
(`documentation/ABOUT.md` Section 2). Swap on zram passes, because zram
keeps swapped pages compressed in RAM, but only without a writeback
backing device and only while kdump is off; `documentation/COMPONENTS.md`
Section 4.5 has every rule. This is not a soft recommendation: the
installer, the boot unit, and both helper scripts all run the same check
and refuse to go on when it fails, with no override flag anywhere.

```bash
cat /proc/swaps
# expect: only the header line ("Filename Type Size Used Priority"), or
# only /dev/zramN lines below it. Anything else is swap that can reach
# disk -- disable and remove it before going any further:
sudo swapoff /dev/sdXN     # that device or swap file; swapoff -a for all
# then remove/comment its entries so it doesn't return on reboot:
grep -n swap /etc/fstab
systemctl list-units --type=swap --all

# zram swap only: no zram device may have a writeback backing device
cat /sys/block/zram*/backing_dev
# expect: none, once per device (zram-generator: drop writeback-device=
# from zram-generator.conf)

# zram swap only: kdump must be off -- expect every value to be 0. Linux
# 7.0 has /sys/kernel/kexec/crash_*, older kernels only the
# /sys/kernel/kexec_crash_* names. No output at all means a kernel without
# kdump support, which passes too.
grep . /sys/kernel/kexec/crash_loaded /sys/kernel/kexec/crash_size \
       /sys/kernel/kexec_crash_loaded /sys/kernel/kexec_crash_size 2>/dev/null
# anything else: see "Ubuntu turns kdump on by default" in COMPONENTS.md 4.5.
# Once the guard is installed (Section 5.2 step 1), it is the authority:
# /usr/local/sbin/YOUR_APP-secrets-guard check

# 6.4 or later gives the .env and the edit copy their own noswap tmpfs
# (older: plain /run directories)
uname -r
```

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
# every Linux install already (GNU or Ubuntu 26.04's uutils), confirm
# rather than assume:
which shred base64 sha256sum install stat readlink getent nano
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

# 1. Install the swap guard from Section 4.5 and the two helper scripts
#    from Section 4.4, and make them executable. Rather than pasting the
#    guard's few hundred lines, you can copy it out of the installer:
#      { echo '#!/bin/sh'
#        sed -n '/^# --- ros-lib begin ---$/,/^# --- ros-lib end ---$/p' ram-only-secrets-install.sh
#        echo 'ros_main "$@"'; } > /usr/local/sbin/YOUR_APP-secrets-guard
nano /usr/local/sbin/YOUR_APP-secrets-guard
nano /usr/local/sbin/YOUR_APP-secrets-open
nano /usr/local/sbin/YOUR_APP-secrets-commit
chmod 750 /usr/local/sbin/YOUR_APP-secrets-guard /usr/local/sbin/YOUR_APP-secrets-open /usr/local/sbin/YOUR_APP-secrets-commit
# Then run the same check the installer runs first:
/usr/local/sbin/YOUR_APP-secrets-guard check
# expect: "... swap check passed: ...". A refusal names what to fix.

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
#    only the command that starts nano is.
#    The file goes on its own noswap tmpfs (Section 4.4), and this shell
#    first sets its core dump filter to 0, which nano and systemd-creds
#    inherit (Section 4.4 explains why ulimit -c 0 is not enough).
echo 0 > /proc/$$/coredump_filter
/usr/local/sbin/YOUR_APP-secrets-guard mount /run/YOUR_APP-secrets-edit
install -d -m 0700 /run/YOUR_APP-secrets-edit
: > /run/YOUR_APP-secrets-edit/env.edit
chmod 600 /run/YOUR_APP-secrets-edit/env.edit
nano /run/YOUR_APP-secrets-edit/env.edit
# type your real KEY=value lines inside the editor now, save, exit
(umask 077; systemd-creds encrypt --name=YOUR_APP-env /run/YOUR_APP-secrets-edit/env.edit /etc/credstore.encrypted/YOUR_APP-env)
shred -u /run/YOUR_APP-secrets-edit/env.edit
umount /run/YOUR_APP-secrets-edit; rmdir /run/YOUR_APP-secrets-edit
# (umount fails harmlessly where the guard kept a plain directory)

# 5. Enable and start the unit -- this performs the first decrypt into RAM.
systemctl daemon-reload
systemctl enable --now YOUR_APP-secrets.service

# 6. Verify.
systemctl status YOUR_APP-secrets.service
ls -l /run/YOUR_APP-secrets/.env
# expect: -rw------- YOUR_APP_USER YOUR_APP_USER
grep -c '=' /run/YOUR_APP-secrets/.env
# sanity-check the line count only -- do not print values
/usr/local/sbin/YOUR_APP-secrets-guard status /run/YOUR_APP-secrets
# expect on Linux 6.4+: "... is a noswap tmpfs." A warning means it stayed
# a plain directory; journalctl -u YOUR_APP-secrets.service says why.

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
- [ ] `sudo /usr/local/sbin/YOUR_APP-secrets-guard check` still passes --
      no OS-level swap that can reach disk (distinct from the editor swap
      files in the bullet above) has been enabled since Section 5.1, and
      kdump is still off if zram swap is on. Required, not optional -- see
      `documentation/ABOUT.md` Section 2.
- [ ] On Linux 6.4 or later, `findmnt /run/YOUR_APP-secrets` shows a
      `tmpfs` with `noswap` among its options.
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
sudo sh -c 'echo 0 > /proc/$$/coredump_filter && exec nano /run/YOUR_APP-secrets-edit/env.edit'
# add, change, or remove a KEY=value line, save, exit nano
sudo YOUR_APP-secrets-commit
```

`YOUR_APP-secrets-open` prints that editor line too. Keep the single
quotes: `$$` has to be the PID of the new `sh`, whose core dump filter
`nano` then inherits (Section 4.4). If `YOUR_APP-secrets-commit` refuses,
the edit copy stays where it is, on its `noswap` tmpfs, and the script
says so; fix what it names and run it again, or discard the edit with
`shred -u`.

`YOUR_APP-secrets-commit`'s own output ends with the fresh checksum and the
fresh base64 blob — that output *is* the next step: copy it into your
password manager immediately (Section 7). The blob changes on every commit,
since it's a brand-new ciphertext of whatever the edit file contained — the
old backed-up blob is now stale the moment you commit, which is why the
script prints a new one every single time rather than leaving that as a
separate step you have to remember.

### 5.4 Updating a host set up before the swap guard

A host installed before the swap guard existed keeps working unchanged,
under the older and stricter rule of no swap at all. Moving it to the
current version doesn't touch the encrypted bundle, so no secret needs
re-entering. Don't re-run the installer for this: it would open `nano`
on an empty file and replace the bundle with whatever you type.

Finish or discard any edit in progress first (`/dev/shm/YOUR_APP-env.edit`
must not exist; the new `YOUR_APP-secrets-open` refuses to start while it
does). Then:

```bash
# --- as root, from a checkout of this repository ---
{ echo '#!/bin/sh'
  sed -n '/^# --- ros-lib begin ---$/,/^# --- ros-lib end ---$/p' ram-only-secrets-install.sh
  echo 'ros_main "$@"'; } > /usr/local/sbin/YOUR_APP-secrets-guard
chmod 750 /usr/local/sbin/YOUR_APP-secrets-guard
/usr/local/sbin/YOUR_APP-secrets-guard check

# Replace both helper scripts completely with the versions in Section 4.4
# (the edit copy moved, so patching the old swap test is not enough), and
# the [Unit] block plus the CoredumpFilter=/ExecStartPre=/ExecStart= lines
# of the unit with those from Section 4.2:
nano /usr/local/sbin/YOUR_APP-secrets-open
nano /usr/local/sbin/YOUR_APP-secrets-commit
nano /etc/systemd/system/YOUR_APP-secrets.service
systemctl daemon-reload
systemctl restart YOUR_APP-secrets.service
/usr/local/sbin/YOUR_APP-secrets-guard status /run/YOUR_APP-secrets
```

On Linux 6.4 and later, where the mount is allowed, the restart deletes
the old `.env` from `/run`'s shared tmpfs, mounts the new `noswap` tmpfs
in its place and writes the file again inside it. Otherwise it warns and
keeps the plain directory, and `status` says so. Switch zram swap on only
after this, and only without a writeback device.
