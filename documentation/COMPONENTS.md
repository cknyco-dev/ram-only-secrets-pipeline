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
# Check swap only after the host has switched its swap on. Swap units
# (fstab, zram-generator, gpt-auto) are ordered Before=swap.target
# (systemd.swap(5)). Three packaged services run swapon themselves and are
# ordered before nothing: zram-tools' zramswap.service, Ubuntu's
# zram-config.service and dphys-swapfile.service. After= on a unit that is
# not installed does nothing. Swap that anything else switches on later
# is caught only by the next YOUR_APP-secrets-open or -commit.
After=swap.target zramswap.service zram-config.service dphys-swapfile.service
# The guard lives under /usr/local; wait for it if that is a mount of its own.
RequiresMountsFor=/usr/local/sbin/YOUR_APP-secrets-guard
Before=user@YOUR_UID.service
# If the app runs as a system service instead of a user session, point
# Before= at that unit instead (e.g. Before=YOUR_APP.service) -- and see
# "One honest limitation" below: Before=, either way, only orders startup,
# it does not gate it.

[Service]
Type=oneshot
RemainAfterExit=yes
LoadCredentialEncrypted=YOUR_APP-env:/etc/credstore.encrypted/YOUR_APP-env
# Keeps the memory of every process in this unit, install copying the
# credential included, out of core dumps (systemd.exec(5); Section 4.4
# explains why ulimit -c 0 would not do).
CoredumpFilter=0
# Hard requirement, not a tunable -- see the explanation right after this
# unit and Section 4.5. No override: if any active swap could put secrets
# on disk, this unit never writes the .env file, rather than start with
# the guarantee broken. (systemd has already decrypted the credential by
# then, into its own credentials directory on a noswap tmpfs or ramfs.)
ExecStartPre=/usr/local/sbin/YOUR_APP-secrets-guard check
# Give /run/YOUR_APP-secrets its own tmpfs with "noswap" (Linux >= 6.4), or
# a ramfs where that is unavailable, so the decrypted file can never be
# paged out, whatever swap is switched on later. Reused as is on restart;
# only if both mounts are refused it warns and keeps the plain directory.
ExecStart=/usr/local/sbin/YOUR_APP-secrets-guard mount /run/YOUR_APP-secrets
# On a noswap tmpfs (capped at 2 MiB) the directory and .env go to
# YOUR_APP_USER, 0750 and 0600, as always. On a ramfs, which has no size
# limit, root keeps both and YOUR_APP_USER reads .env through its group
# (0750 and 0440), so it cannot fill RAM there (ros_mount_ramfs in the guard).
ExecStart=/bin/sh -c 'o="YOUR_APP_USER" m="0600"; if grep -qE "^[^ ]+ [^ ]+ [^ ]+ [^ ]+ /run/YOUR_APP-secrets .* - ramfs " /proc/self/mountinfo; then o="root" m="0440"; fi; install -d -m 0750 -o "$o" -g "YOUR_APP_USER" "/run/YOUR_APP-secrets" && install -m "$m" -o "$o" -g "YOUR_APP_USER" "$CREDENTIALS_DIRECTORY/YOUR_APP-env" "/run/YOUR_APP-secrets/.env"'
# Boot-time history hygiene -- an automatic backstop, not a replacement for
# the manual clear-history steps in Sections 5.2 and 5.3. See the
# explanation right after this unit for what it does and does not cover.
# Adjust the path list to match where YOUR_APP_USER's home actually is.
ExecStartPost=/bin/sh -c 'for f in "/root/.bash_history" "/root/.zsh_history" "/home/YOUR_APP_USER/.bash_history" "/home/YOUR_APP_USER/.zsh_history"; do [ -e "$f" ] && : > "$f"; done; true'
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

**Why `ExecStartPre=`, and why there's no override.** Swap that can reach
disk defeats the RAM-only guarantee this whole pipeline exists to provide
(Section 2). `tmpfs` is swappable like any other memory, so with a swap
partition or swap file active, the kernel can page decrypted secrets out
to disk under memory pressure. `YOUR_APP-secrets-guard check` (Section
4.5) runs *before* `ExecStart=`, so if it refuses, the plaintext `.env`
file is never written in the first place: not written-then-warned-about,
never written at all. systemd itself has decrypted the credential by
then: `ExecStartPre=` gets a fresh credentials directory
(`src/core/service.c:1692-1698` in v259), which systemd mounts as a
`noswap` tmpfs, or as ramfs where the kernel refuses that
(`src/shared/mount-util.c:1966-1991`), and removes again as soon as the
unit fails (`src/core/service.c:2205`, `src/core/unit.c:6302`). It
accepts exactly one kind of swap, zram without a
writeback device, and that only while kdump is off. There is deliberately
no flag or environment variable to bypass it; the only way past this line
is to change the host. The same guard also runs in
`ram-only-secrets-install.sh` (Section 5.1, before touching anything) and
in both helper scripts (Section 4.4, on every edit). Swap can be enabled
after installation too, so a boot-time-only check wouldn't be enough.

**Why the `After=` line.** With `DefaultDependencies=no`, the unit isn't
ordered after anything that switches swap on. Without this line it could
run its check while `/proc/swaps` is still empty, pass, and watch a swap
partition come up a moment later. `After=swap.target` covers every swap
*unit* that keeps its default dependencies: systemd orders those
`Before=swap.target` (`man/systemd.swap.xml:90-95` and
`src/core/swap.c:225-243` in systemd v259; `nofail` doesn't change that,
running inside a container does). That takes care of `/etc/fstab` and
gpt-auto. zram-generator's `dev-zramN.swap` units switch default
dependencies off but declare `Before=swap.target` themselves
(`src/generator.rs:240-244` at tag v1.2.1).

A service that runs `swapon` on its own is not a swap unit, and
`swap.target` doesn't wait for it. Three packaged ones do exactly that,
each with default dependencies and no `Before=swap.target`: zram-tools'
`zramswap.service` (Debian and Ubuntu,
<https://sources.debian.org/data/main/z/zram-tools/0.3.7-1/zramswap.service>;
its `/usr/sbin/zramswap` runs `mkswap` and `swapon` itself), Ubuntu's
`zram-config.service`
(<https://git.launchpad.net/ubuntu/+source/zram-config/plain/debian/zram-config.service?h=ubuntu/resolute>)
and `dphys-swapfile.service`, which sets up a swap *file*
(<https://sources.debian.org/data/main/d/dphys-swapfile/20100506-7.2/debian/service>).
The unit names them after `swap.target`. `After=` on a unit that isn't
installed does nothing, and where one is installed the check simply runs
after it, which is later than `basic.target`. None of the three orders
itself before this unit, so no ordering cycle is expected; `systemd-analyze
verify` has not been run on a real host yet (UNVERIFIED). Swap that
anything else switches on during or after boot, a custom script for
example, is caught only by the next `YOUR_APP-secrets-open` or
`YOUR_APP-secrets-commit`, and Section 4.5 lists what stays protected in
between. The gap predates zram support; it affected the old "no swap at
all" rule just the same.

**Why `RequiresMountsFor=`.** The check runs `/usr/local/sbin/...`, and
the unit starts early. Where `/usr/local` is a file system of its own, this
line makes the unit wait for it instead of failing at boot.

**Why `CoredumpFilter=0`.** Every process of this unit, the guard and
the `install` that copies the credential included, starts with a core
dump filter of 0, so a crash dumps none of its memory. Section 4.4
explains why `LimitCORE=0` alone is not enough on Ubuntu. systemd parses
`0` as an empty mask and writes it to `/proc/self/coredump_filter` for
each command (`src/shared/coredump-util.c:38-77,172-179` and
`src/core/exec-invoke.c:5453-5459` in v259; available since v246).

**Why a second `ExecStart=`: a tmpfs of its own, with `noswap`.** `/run`
is one shared tmpfs, and systemd mounts it without `noswap`
(`src/shared/mount-setup.c:180-198` in v259), so a file in it is ordinary
swappable memory. On Linux 6.4 and later, `YOUR_APP-secrets-guard mount`
gives `/run/YOUR_APP-secrets` its own small tmpfs with the `noswap`
option. The kernel never writes a page of such a tmpfs to any swap device
(`mm/shmem.c:1601` in Linux 7.0.14), so the decrypted file stays in RAM
even if someone switches a swap partition on after the check ran.
Restarting the unit (which `YOUR_APP-secrets-commit` does) reuses the
existing mount and never stacks a second one on top. Where `noswap` isn't
available, on a kernel older than 6.4 or when the mount is refused, it
mounts a ramfs instead. ramfs pages are never swapped either
(`ramfs_get_inode()` marks every mapping unevictable, `fs/ramfs/inode.c`),
which is also systemd's own fallback for credentials. Debian 12 (6.1)
gets this path. Only if the
ramfs mount is refused too (inside an unprivileged container, for
example) it logs a warning and keeps the plain directory, the layout this
pipeline always used; the swap check stays the gate then, as before. It
refuses outright if the directory is already some other mount, or if a
fresh mount doesn't report `noswap` or doesn't show up as ramfs.

**Who owns `.env`.** On a `noswap` tmpfs nothing changes: the directory
and `.env` belong to `YOUR_APP_USER`, 0750 and 0600, and the tmpfs is
capped at 2 MiB. A ramfs has no size limit and ignores every mount option
but `mode`, and the kernel's own documentation says "only root (or a
trusted user) should be allowed write access to a ramfs mount"
(`Documentation/filesystems/ramfs-rootfs-initramfs.rst`). If the app user
owned the directory or the file there, it could fill RAM with pages
nothing can reclaim. So on a ramfs, and only there, the unit makes the
directory `root:YOUR_APP_USER` 0750 and `.env` `root:YOUR_APP_USER` 0440,
and the app user reads the file through its group. Three consequences on
such a host:

- The process that reads `.env` must actually carry that group. A login
  shell of the user does. A systemd service with `User=` and a different
  `Group=` does not (only groups that list the user as a member are
  added), nor does a container started with a bare `--user UID`; use
  `Group=YOUR_APP_USER`, `--user UID:GID`, or `--group-add keep-groups`
  for rootless podman.
- Every other member of that group can read the secrets too. The
  installer names any it finds.
- The installer refuses if the group is missing (the unit needs it on
  every kernel), and if the user is not in it on a kernel without
  `noswap`; with `noswap` that only draws a warning.

The mount has to land in the host's mount namespace, otherwise the
application never sees it. systemd gives a unit a namespace of its own
for many settings, not only the obvious `PrivateMounts=`,
`ProtectSystem=` and `PrivateTmp=`: `ProtectHome=`, `PrivateDevices=`,
`ReadOnlyPaths=`, `InaccessiblePaths=`, `BindPaths=`,
`ProtectKernelTunables=`, `ProtectProc=`, `RuntimeDirectory=` and more
(the full list is `exec_needs_mount_namespace()`,
`src/core/execute.c:259-346` in v259). A drop-in anywhere, including a
global `/etc/systemd/system/service.d/`, can add one. The guard therefore
compares its own mount namespace with PID 1's before it mounts or deletes
anything, and refuses if they differ. `tests/run.sh` checks that the
generated unit sets none of these. To see which layout a host got:

```bash
findmnt -no FSTYPE,OPTIONS /run/YOUR_APP-secrets
# expect: tmpfs  rw,nosuid,nodev,noexec,relatime,size=2048k,nr_inodes=16,...,noswap
#     or: ramfs  rw,nosuid,nodev,noexec,relatime,mode=700   (kernel older than 6.4;
#         ramfs shows the mount option, not the directory's current mode)
# no output: plain directory -- journalctl -u YOUR_APP-secrets.service says why
```

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
initial setup. They are printed here exactly as the installer generates
them (`tests/run.sh` checks that they match).

**Where the edit copy lives.** In `/run/YOUR_APP-secrets-edit/env.edit`,
on a small root-only tmpfs of its own that `YOUR_APP-secrets-guard mount`
sets up with `noswap`, the same step the unit uses for the `.env`
(Section 4.2). `YOUR_APP-secrets-commit` unmounts it again. Earlier
versions used `/dev/shm`, which is RAM but swappable: systemd mounts it
without `noswap` (`src/shared/mount-setup.c:162-170` in v259), so copying
the `.env` there gave up its `noswap` protection for the whole edit.
`/tmp` was never an option, since it isn't guaranteed to be RAM-backed.
Where `noswap` isn't available, the edit directory stays a root-only
directory on `/run`, as swappable as `/dev/shm` was. `YOUR_APP-secrets-open`
refuses to start while an edit from the old location is still in
`/dev/shm`.

**The same gate as the unit.** Both scripts refuse to run at all when
`YOUR_APP-secrets-guard check` (Section 4.5) refuses, same hard requirement
and same reasoning as the boot unit's `ExecStartPre=` above. Swap can be
enabled after installation too, so this can't be a boot-time-only check.
If `YOUR_APP-secrets-commit` stops early for any reason, a refusal
included, it says where the plaintext still is and how to remove it.
Both scripts also run `YOUR_APP-secrets-guard status`, which warns when
`/run/YOUR_APP-secrets` is neither a `noswap` tmpfs nor a ramfs; apart
from the journal, that is the only place a fallback to the plain
directory shows up.

**Core dumps.** Both scripts set their own `/proc/PID/coredump_filter` to
0 before they touch any plaintext, and so does the installer before it
opens `nano`. `ulimit -c 0` or `LimitCORE=0` would not do on Ubuntu.
apport registers itself as a pipe in `kernel.core_pattern`
(`/usr/share/apport/apport:684-690` in apport 2.34.1, Ubuntu 26.04), and
for a pipe the kernel ignores `RLIMIT_CORE`, apart from the value 1 it
reserves to catch recursive crashes (`fs/coredump.c:979-998` in Linux
7.0.14). apport honours the limit only for the extra core file it writes
into the crashed process's working directory (`write_user_coredump()`,
`apport:265-281`); the crash report under `/var/crash` gets the core read
from standard input either way (`apport:1047`). A filter of 0 makes the
kernel leave every memory mapping, heap and stack included, out of the
core, whichever handler receives it (`Documentation/filesystems/proc.rst`,
section 3.4; `vma_dump_size()`, `fs/coredump.c:1594`). Only the vDSO is
always dumped. The value is inherited across fork and exec
(`kernel/fork.c:1103-1110`, `include/linux/mm_types.h:1922-1938`), so it
covers `cp`, `nano` and `systemd-creds encrypt` started by the script.
The editor you start yourself is a separate process, so
`YOUR_APP-secrets-open` prints the command that starts it the same way:

```bash
sudo sh -c 'echo 0 > /proc/$$/coredump_filter && exec nano /run/YOUR_APP-secrets-edit/env.edit'
```

The single quotes matter: `$$` has to be expanded by the new `sh`, not by
your own shell.

`/usr/local/sbin/YOUR_APP-secrets-open`:

<!-- helper-open: begin -->
```sh
#!/bin/sh
# Prepares an editable plaintext copy of the current secrets bundle in RAM,
# on a noswap tmpfs of its own, or a ramfs where noswap is unavailable.
set -eu
umask 077

EDIT_DIR=/run/YOUR_APP-secrets-edit
EDIT_FILE=/run/YOUR_APP-secrets-edit/env.edit
OLD_EDIT_FILE=/dev/shm/YOUR_APP-env.edit
RUNNING_ENV=/run/YOUR_APP-secrets/.env
GUARD=/usr/local/sbin/YOUR_APP-secrets-guard
INSTALLER=/root/ram-only-secrets-install.sh

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

# No plaintext in a core dump of this script or of anything it starts.
# ulimit -c 0 is not enough: with a pipe in kernel.core_pattern, which is
# how apport runs on Ubuntu, the kernel ignores RLIMIT_CORE
# (fs/coredump.c:979-998 in Linux 7.0.14). A coredump_filter of 0 leaves
# the process's memory mappings, heap and stack included, out of any dump
# (Documentation/filesystems/proc.rst, section 3.4), and every child
# inherits it across fork and exec (kernel/fork.c:1103-1110). No such file
# means a kernel built without ELF core dumps (fs/proc/base.c:3392-3393).
# If the write fails, set -e stops the script before it touches any
# plaintext.
if [ -e /proc/$$/coredump_filter ]; then echo 0 > /proc/$$/coredump_filter; fi

# Hard requirement, not a tunable -- the shared swap guard refuses any swap
# that could put secrets on disk (documentation/COMPONENTS.md Section 4.5,
# documentation/ABOUT.md Section 2). No override flag.
/usr/local/sbin/YOUR_APP-secrets-guard check || exit 1

# Earlier versions kept the edit copy in /dev/shm, which systemd mounts
# without noswap. Don't start a new edit while an old one sits there.
if [ -e "$OLD_EDIT_FILE" ]; then
  echo "An edit from an earlier version of this script is still at $OLD_EDIT_FILE," >&2
  echo "on swappable /dev/shm. Copy what you still need from it, then remove it:" >&2
  echo "  shred -u $OLD_EDIT_FILE" >&2
  exit 1
fi

if [ -f "$EDIT_FILE" ]; then
  echo "An edit is already in progress at $EDIT_FILE -- finish it with YOUR_APP-secrets-commit, or discard it: shred -u $EDIT_FILE" >&2
  exit 1
fi

# The edit copy gets what the .env gets: its own root-only tmpfs with
# noswap, or a ramfs where that is unavailable (documentation/COMPONENTS.md
# Section 4.4). Only if both mounts are refused, the guard warns and this
# stays a root-only directory on /run.
"$GUARD" mount "$EDIT_DIR" || exit 1
install -d -m 0700 "$EDIT_DIR"

if [ -f "$RUNNING_ENV" ]; then
  cp "$RUNNING_ENV" "$EDIT_FILE"
else
  : > "$EDIT_FILE"
fi
chmod 600 "$EDIT_FILE"

# A warning, never a refusal, if the running .env is on neither a noswap
# tmpfs nor a ramfs.
"$GUARD" status "/run/YOUR_APP-secrets" || true

# Backstop cleanup: if a standalone copy of the installer is still sitting
# at the standard path, and it is NOT part of a kept git checkout (Section
# 7.4), remove it. Every helper-script run and every boot (Section 4.2) all
# perform this same check, so a missed self-delete gets caught quickly
# either way, without any of them needing to know an arbitrary path.
if [ -e "$INSTALLER" ] && ! git -C "$(dirname "$INSTALLER")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rm -f "$INSTALLER"
fi

echo "Edit the copy now, with core dumps of the editor switched off the same way:"
echo "  sudo sh -c 'echo 0 > /proc/\$\$/coredump_filter && exec nano $EDIT_FILE'"
echo "Then run: sudo YOUR_APP-secrets-commit"
echo "The copy lives in RAM ($EDIT_DIR) and is removed automatically on commit."
```
<!-- helper-open: end -->

`/usr/local/sbin/YOUR_APP-secrets-commit`:

<!-- helper-commit: begin -->
```sh
#!/bin/sh
# Re-encrypts the edited bundle, refreshes the running RAM copy, wipes the
# temp edit file, and prints a fresh backup blob + its checksum.
set -eu
umask 077

EDIT_DIR=/run/YOUR_APP-secrets-edit
EDIT_FILE=/run/YOUR_APP-secrets-edit/env.edit
BLOB=/etc/credstore.encrypted/YOUR_APP-env
GUARD=/usr/local/sbin/YOUR_APP-secrets-guard
INSTALLER=/root/ram-only-secrets-install.sh

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

# Same core dump protection as in YOUR_APP-secrets-open (see the comment
# there); here it covers systemd-creds encrypt, which reads the plaintext.
if [ -e /proc/$$/coredump_filter ]; then echo 0 > /proc/$$/coredump_filter; fi

# Whatever stops this script before the shred below, say where the
# plaintext still is.
trap 'if [ -e "$EDIT_FILE" ]; then echo "The plaintext edit copy is still at $EDIT_FILE. Fix the problem above and run YOUR_APP-secrets-commit again, or discard the edit: shred -u $EDIT_FILE" >&2; fi' EXIT

# Hard requirement, not a tunable -- the shared swap guard refuses any swap
# that could put secrets on disk (documentation/COMPONENTS.md Section 4.5,
# documentation/ABOUT.md Section 2). No override flag.
/usr/local/sbin/YOUR_APP-secrets-guard check || exit 1

if [ ! -s "$EDIT_FILE" ]; then
  echo "No edit found at $EDIT_FILE (or it's empty) -- run YOUR_APP-secrets-open first." >&2
  exit 1
fi

systemd-creds encrypt --name=YOUR_APP-env "$EDIT_FILE" "$BLOB"
shred -u "$EDIT_FILE"
# Drop the edit tmpfs. On the plain-directory fallback there is nothing to
# unmount, and a busy mount (a shell still inside it) stays until reboot,
# empty; neither is an error.
umount "$EDIT_DIR" 2>/dev/null || true
rmdir "$EDIT_DIR" 2>/dev/null || true

systemctl restart "YOUR_APP-secrets.service"
"$GUARD" status "/run/YOUR_APP-secrets" || true

# Same backstop cleanup as -secrets-open -- see the comment there.
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
echo "New blob, base64 -- useful ONLY paired with a host-key backup"
echo "(Section 7.5, optional). Without that key it's exactly as useless as"
echo "leaving it on disk. The plaintext values you just edited, not this"
echo "blob, are what disaster recovery depends on by default (Section 8.1)"
echo "-- make sure your saved copy of those is current too, not just this."
echo "Copy this ENTIRE line into your password manager now:"
base64 -w0 "$BLOB"; echo
echo

printf 'Have you copied the base64 blob above into your password manager and verified it per Section 6? [y/N] '
read -r CONFIRM
case "$CONFIRM" in
  [yY]*)
    echo
    echo "Good. Now run these in YOUR OWN shell (not this script) -- a script"
    echo "cannot clear a parent shell's live history for you:"
    echo '  bash: history -c && history -w'
    echo '  zsh:  history -c && fc -W'
    echo "Terminal scrollback (best-effort, not every terminal honors this):"
    printf "  printf '"
    printf '\033[3J'
    echo "'"
    ;;
  *)
    echo
    echo "Not clearing history yet -- but save that blob first, not after."
    echo "It's the only thing that survives losing this host."
    echo "Re-run this reminder any time; nothing above was destructive."
    ;;
esac
```
<!-- helper-commit: end -->

A script is a child process: it cannot reach into your interactive
shell's in-memory history and erase it for you, no matter what it prints.
The best `YOUR_APP-secrets-commit` can do is wait for your confirmation,
then hand you the exact commands to run yourself, in the shell you're
actually typing in. See Section 5.2 step 10 for why this matters.

Make both executable once, at install time. `750`, not `755` — these scripts handle secret material and root-only execution is already self-enforced inside them (see the UID check in each), so there's no reason to leave world-execute set too:

```bash
chmod 750 /usr/local/sbin/YOUR_APP-secrets-open /usr/local/sbin/YOUR_APP-secrets-commit
```

### 4.5 The swap guard: one check, used everywhere

`/usr/local/sbin/YOUR_APP-secrets-guard` holds the rules for when swap is
acceptable, plus the `noswap` mount from Sections 4.2 and 4.4. The
installer runs the same code before it changes anything, the boot unit
runs it as `ExecStartPre=` and `ExecStart=`, and both helper scripts run
it before every edit. The logic exists exactly once: it lives in
`ram-only-secrets-install.sh` between the `# --- ros-lib begin ---` and
`# --- ros-lib end ---` lines, and the installer copies that block out
byte for byte. `tests/run.sh` tests the same block against fixture
`/proc` and `/sys` trees, and fails if the copy printed at the end of this
section differs from it.

Three subcommands, no flags:

- `YOUR_APP-secrets-guard check` (also what runs with no argument) exits 0
  if no active swap can put secrets on disk, and 1 with the reason
  otherwise.
- `YOUR_APP-secrets-guard mount DIRECTORY` is the `noswap` tmpfs step of
  Sections 4.2 and 4.4. It refuses when it doesn't run in PID 1's mount
  namespace.
- `YOUR_APP-secrets-guard status DIRECTORY` reports whether DIRECTORY is
  a `noswap` tmpfs. It warns but never refuses, and always exits 0.

**Is zram really just RAM?** Almost. zram is a block device that keeps
whatever is written to it compressed in memory ("Pages written to these
disks are compressed and stored in memory itself",
`Documentation/admin-guide/blockdev/zram.rst:8-10` in Linux 7.0), so
swapping to it moves pages from one part of RAM to another. Two features
can still carry its contents to disk, and the guard closes both:

1. **Writeback.** Once a zram device has a backing device
   (`/sys/block/zramN/backing_dev`, or `writeback-device=` in
   `zram-generator.conf`), a write to `/sys/block/zramN/writeback` moves
   idle or incompressible pages onto that partition. Debian 13, Ubuntu
   24.04 and Ubuntu 26.04 all build their kernels with
   `CONFIG_ZRAM_WRITEBACK=y` (Ubuntu 26.04 checked; Debian 13 and Ubuntu
   24.04 UNVERIFIED), so the feature is there to be switched on. The
   guard refuses any zram swap whose `backing_dev` isn't `none`.
2. **kdump.** With a crash kernel armed, a kernel panic saves a memory
   dump to `/var/crash`. The dump filter kdump-tools uses by default
   (`makedumpfile -d 31`) drops page cache and process memory, but zram's
   compressed pool is kernel memory, so it stays in the dump, and the
   `crash` utility can decompress zram-swapped pages from it. The guard
   refuses zram swap while kdump is armed. (This conclusion comes from
   reading makedumpfile's source, which has no filter for zram's
   allocator; it has not been tested against a real dump.)

Hibernation needs no rule of its own. The kernel writes a hibernation
image only to an active swap area (`kernel/power/swap.c:343-346`, which
reaches `swap_type_of()`/`find_first_swap()` in
`mm/swapfile.c:1994-2036`; both skip anything not swapped on), and with
only zram active, that image sits in RAM and is gone at power-off.
systemd refuses zram as a hibernation target anyway
(`src/shared/hibernate-util.c:293-296` in v259).

**Which zram setup.** Prefer `systemd-zram-generator` over `zram-tools`
or Ubuntu's `zram-config`. The generator creates `dev-zramN.swap` units,
which the boot unit's `After=swap.target` waits for (Section 4.2), and its
configuration names the one option that matters here,
`writeback-device=`. The other two switch swap on from a service; the
unit orders itself after those services by name, but a renamed or
home-grown equivalent is only caught at the next edit.

**The rules, in the order the guard applies them.** Kernel line numbers
are from Linux stable v7.0.14, the source of Ubuntu 26.04's 7.0.0-34
kernel
(`https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/<path>?h=v7.0.14`);
`zram_drv.c` means `drivers/block/zram/zram_drv.c`.

| # | Rule | Why | Source |
| --- | --- | --- | --- |
| 1 | `/proc/swaps` must be readable, and is read with a single `read(2)`. If it is missing while the rest of `/proc` is there, the kernel has no swap support and the check passes. | The check this replaces skipped itself on an unreadable file, which is failing open. Reading line by line would let a concurrent `swapoff` hide an entry. | `mm/swapfile.c:3041`, `2936-2955`; `fs/seq_file.c:226`, `255-280` |
| 2 | No entry whose type is `file`, or anything else but `partition`. | `file` is a swap file on a filesystem, so on disk. | `mm/swapfile.c:3002` |
| 3 | No escaped names, and every device node must be visible where the guard runs. | Names are octal-escaped, so a deleted node shows up as `...\040(deleted)`. The guard refuses rather than guess. | `mm/swapfile.c:2998` |
| 4 | The device's major number must be the one `/proc/devices` lists as `zram`. | Identity by kernel number, not by name. A disk node named `zram9` is refused, and so is swap on a disk partition, LVM, dm-crypt or a loop device. | `zram_drv.c:3286` |
| 5 | `backing_dev` must read `none`. If the attribute doesn't exist, `disksize` must (writeback compiled out). | Without a backing device, zram's only write path to another device returns `-ENODEV`. | `zram_drv.c:709-712`, `1258-1259`, `3001-3003` |
| 6 | While zram swap is active, kdump must be off: `crash_loaded` reads 0 and `crash_size` reads 0. | A panic dump keeps zram's compressed pool. Reserved memory counts as armed, because kdump-tools loads the crash kernel later in boot than this unit runs. `crash_size` answers `EBUSY` while the kexec lock is held, so the guard reads it a second time after one second before it counts it as armed. | `Documentation/ABI/testing/sysfs-kernel-kexec-kdump`, `kernel/kexec_core.c:1271-1279,1332-1333`, `kernel/crash_core.c:352-364` |
| - | Hibernation with a resume device on a disk: a note, never a refusal. | See above. | `kernel/power/hibernate.c:1284` |

Rule 5 cannot be undone behind the guard's back while the device stays
swapped on. `backing_dev` can only be set before `disksize`
(`zram_drv.c:743-745` returns `-EBUSY` afterwards), a reset is refused
while the device is open (`zram_drv.c:2951`), and `swapon` holds it open
exclusively until `swapoff` (`mm/swapfile.c:3372`). Adding a backing
device takes swapoff, reset, configure and swapon, and the next check
sees the result. Anything the guard cannot read or parse is refused.
Where a single swap area is at fault, the refusal names it, and
`YOUR_APP-secrets-guard check` always ends with "No override exists.
Nothing was changed." The installer prints its own closing lines instead,
and a refused `mount` says that nothing was written to the directory.

The same holds on all three target releases:

| | Ubuntu 26.04 | Debian 13 | Ubuntu 24.04 |
| --- | --- | --- | --- |
| Kernel | 7.0.0-34 (stable 7.0.14) | 6.12.107 | 6.8.0-146 (based on 6.8.12) |
| `CONFIG_ZRAM_WRITEBACK` | y | y (UNVERIFIED) | y (UNVERIFIED) |
| `CONFIG_CRASH_DUMP` | y | y (UNVERIFIED) | y (UNVERIFIED) |
| `backing_dev` prints `none` when unset | `zram_drv.c:711` | `:463` | `:450` (v6.8) |
| `writeback` without backing device: `-ENODEV` | `:1258-1259` | `:654-655` | `:643-644` (v6.8) |
| `backing_dev` after `disksize`: `-EBUSY` | `:742-745` | `:499-501` | `:488-490` (v6.8) |
| tmpfs `noswap` (Linux 6.4 and later) | yes | yes | yes |
| kdump state in sysfs | `/sys/kernel/kexec/crash_*`, plus `/sys/kernel/kexec_crash_*` links | `/sys/kernel/kexec_crash_*` | `/sys/kernel/kexec_crash_*` |

**Ubuntu turns kdump on by default.** Since 24.10, Ubuntu's installer
enables kdump on machines with at least 4 CPU threads, at least 6 GB and
less than 2 TB of RAM, more free space in `/var` than 5 times RAM plus
swap, and an amd64 or s390x CPU, or arm64 with UEFI
(<https://ubuntu.com/server/docs/how-to/software/kernel-crash-dump/>,
section "kdump is enabled by default where applicable"). The memory
reservation doesn't depend on that decision, though. The `kdump-tools`
package always installs `/etc/default/grub.d/kdump-tools.cfg`
(`debian/rules:42-45` in kdump-tools 1:1.10.7ubuntu3, Ubuntu 26.04), and
on amd64 that file adds
`crashkernel=2G-4G:320M,4G-32G:512M,32G-64G:1024M,64G-128G:2048M,128G-:4096M`
to every boot (`debian/kdump-tools.grub.default`). So any such host with
2 GB of RAM or more reserves crash memory while `kdump-tools` is
installed, and rule 6 refuses zram swap there. Setting `USE_KDUMP=0` in
`/etc/default/kdump-tools` stops the crash kernel from loading but keeps
the memory reserved, which the guard still counts as armed. The clean way
out is `apt remove kdump-tools` (which removes that grub file), then
`update-grub` and a reboot; removing `crashkernel=` by hand from the grub
configuration works too. Until the next boot, `kdump-config unload`
followed by `echo 0 > /sys/kernel/kexec/crash_size`
(`/sys/kernel/kexec_crash_size` before Linux 7.0) does the same.

**What the guard does not cover.** These are the limits that remain,
stated plainly:

- **It checks a point in time.** The guard runs at install, at every boot
  and at the start of every edit and commit. A disk swap switched on in
  between goes unnoticed until the next of those. At boot that includes
  swap switched on by a service the unit doesn't know by name (Section
  4.2). The `noswap` mounts keep the `.env` and the edit copy out of such
  a swap, but not the other plaintext listed in the next item.

  A continuous watch is left out on purpose. The kernel announces swap
  changes only through `poll()` on `/proc/swaps` (`swaps_poll()`,
  `mm/swapfile.c:2921-2933`, woken on swapoff at `:2912` and on swapon at
  `:3549`). A systemd `.path` unit can't use that: path units are built
  on inotify (`man/systemd.path.xml:49-54` in v259), and inotify doesn't
  work on `/proc` (inotify(7), "Limitations and caveats"). udev can't
  either, since `mm/swapfile.c` sends no uevent. A watcher would need
  compiled code, which is a new dependency. A timer that reruns
  `YOUR_APP-secrets-guard check` needs nothing new, but it only notices,
  as late as its interval, and has no safe automatic reaction:
  `swapoff` under memory pressure or stopping the application are
  decisions for a person. If you want one anyway, give it `OnFailure=`
  alerting and treat it as detection only.

  What prevents instead of detects: put `MemorySwapMax=0` on your
  application's own unit (systemd.resource-control(5)). It sets the
  cgroup's `memory.swap.max`, and the kernel then swaps none of that
  cgroup's anonymous memory, whatever swap is switched on later
  (`Documentation/admin-guide/cgroup-v2.rst:1841-1846` in Linux 7.0).
  That includes zram, so the application loses that headroom. For a
  session-based application, the unit is `user@YOUR_UID.service` (a
  drop-in via `systemctl edit user@YOUR_UID.service`); that this also
  covers rootless containers started from that session, and what
  docker's `--memory-swap` equal to `--memory` does, is UNVERIFIED.
- **Plaintext outside the `noswap` mounts is ordinary memory.** `nano`'s
  buffers during an edit, the `systemd-creds encrypt` process during a
  commit, and above all your application's own memory once it has read
  the `.env` can all be swapped. Into zram that's harmless; into a disk
  swap switched on later (previous item) it isn't. The credentials
  directory systemd decrypts into is not part of this list on Linux 6.4
  and later: systemd mounts it as a `noswap` tmpfs, falls back to ramfs,
  and only as a last resort to a plain tmpfs without `noswap`
  (`src/shared/mount-util.c:1966-1971` in v259).
- **It cannot see the past.** If a zram device ever had a backing device
  and writeback ran, those pages stay on that partition after the backing
  device is removed; the kernel only closes the file
  (`zram_drv.c:686-698`). If this host ever used `writeback-device=`,
  wipe or discard that partition.
- **kdump without any swap is unchanged.** Going by makedumpfile's
  source, the default dump filter leaves page cache (tmpfs included) and
  process memory out of a dump, but kernel-side leftovers such as
  terminal or pipe buffers, or freed memory that was never cleared, may
  still be in it. That was true before zram was allowed, and neither part
  has been tested against a real dump.
- **Hibernation.** While only zram is active, no image can reach disk.
  But an image contains all of RAM, `noswap` tmpfs and credentials
  included, so a disk swap switched on later changes that. If this host
  must never hibernate, add `nohibernate` (or `hibernate=no`) to the
  kernel command line and `AllowHibernation=no` to a
  `/etc/systemd/sleep.conf.d/` drop-in. The guard prints a note when a
  resume device on a disk is configured.
- **Kernels older than 6.4.** The `.env` and the edit copy each get a
  ramfs instead of a `noswap` tmpfs: never swapped, but without a size
  limit, which is why root owns both there and the app user reads `.env`
  through its group (Section 4.2).
- **Both mounts refused** (an unprivileged container, for example). The
  `.env` stays on `/run`'s shared tmpfs, the layout this pipeline always
  used, and the edit copy on a root-only directory next to it. zram swap
  is still accepted there, since swapping into zram keeps pages in RAM.
- **Core dumps** of a crashing process can reach disk through apport or
  systemd-coredump, with or without swap. The pipeline's own processes
  set their core dump filter to 0 (Sections 4.2 and 4.4), which keeps
  their memory out of any dump whichever handler runs. Your
  application's own dumps are out of scope (`SECURITY.md`). On Ubuntu,
  `LimitCORE=0` does not keep them out of `/var/crash`, because apport
  receives the core through a pipe, where the kernel ignores the limit
  (Section 4.4); `CoredumpFilter=0` on the application's unit
  (systemd.exec(5), since v246) does, for every handler.
- **The hypervisor.** A VM snapshot that includes memory, a guest
  suspended to disk, a live-migration stream, or the host swapping guest
  RAM all copy memory somewhere this guest cannot see or check. Out of
  scope.
- **Other ways around the rules that need root anyway.** The guard
  identifies a swap area by resolving the path `/proc/swaps` prints in
  its own mount namespace; no kernel interface gives an active swap
  area's device number directly. A swap switched on from another mount
  namespace, under a path that matches a zram node here but points to a
  different device there, would pass. Setting that up takes
  `CAP_SYS_ADMIN`, so it doesn't happen by accident. Memory that the
  kernel demotes to persistent memory onlined as ordinary RAM (the dax
  kmem driver) is also outside anything a swap rule sees. Both are out of
  scope, like the hypervisor.

**The script in full**, exactly as the installer generates it:

<!-- ros-guard: begin -->
```sh
#!/bin/sh
# YOUR_APP-secrets-guard -- generated by ram-only-secrets-install.sh
# from the ros-lib block below. Rules and references:
# documentation/COMPONENTS.md Section 4.5.
# Usage: YOUR_APP-secrets-guard check | YOUR_APP-secrets-guard mount DIRECTORY | YOUR_APP-secrets-guard status DIRECTORY
# --- ros-lib begin ---
# Swap-safety guard for the RAM-only secrets pipeline.
#
# This block is the single source of the swap rules. The installer runs it
# directly (Section 5.1, before anything is changed) and copies it byte for
# byte into /usr/local/sbin/YOUR_APP-secrets-guard, which the boot unit and
# both helper scripts call. tests/run.sh loads the same lines, and checks
# that documentation/COMPONENTS.md Section 4.5 prints them unchanged. The
# rules therefore exist once and cannot drift apart.
#
# The rule: swap is acceptable only when no swapped-out page can reach
# persistent disk. Every active swap area must be a zram device (compressed
# RAM) without a writeback backing device, and kdump must not be armed while
# such swap is on. Whatever this code cannot positively prove safe, it
# refuses. There is no override, by design.
#
# Kernel line numbers are from Linux stable v7.0.14, the source of Ubuntu
# 26.04's 7.0.0-34 kernel:
#   https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/<path>?h=v7.0.14
# Documentation/ paths are from mainline v7.0:
#   https://raw.githubusercontent.com/torvalds/linux/v7.0/<path>
# Debian 13 (6.12) and Ubuntu 24.04 (6.8) behave the same for every rule
# used here; COMPONENTS.md Section 4.5 lists the per-version references.

# Files the checks read. Plain assignments on purpose, never
# ${VAR:-default}: no environment variable can point a real run at other
# files, because that would be an override flag under another name.
# tests/run.sh changes them after loading this block, to point at fixtures.
ROS_SWAPS=/proc/swaps
ROS_DEVICES=/proc/devices
ROS_MOUNTINFO=/proc/self/mountinfo
ROS_OSRELEASE=/proc/sys/kernel/osrelease
ROS_SYS_BLOCK=/sys/dev/block
ROS_SYS_KERNEL=/sys/kernel
ROS_SYS_POWER=/sys/power

ros_me=${0##*/}
ros_say() { printf '%s: %s\n' "$ros_me" "$*" >&2; }
ros_info() { printf '%s: %s\n' "$ros_me" "$*"; }

# The only six operations a test cannot fake without root: asking whether
# a path is a block device, reading its device number, mounting a noswap
# tmpfs, mounting a ramfs, umount, and comparing this process's mount
# namespace with PID 1's. tests/run.sh replaces exactly these six, plus
# ros_pause so the tests don't wait; everything else runs as is.
ros_is_blockdev() { [ -b "$1" ]; }
# stat prints a device node's major and minor number in hex, lowercase and
# without "0x", and -L follows a symlink to the node. GNU coreutils does,
# and so do the Rust uutils that Ubuntu 26.04 installs as coreutils by
# default: uutils 0.8.0 src/uu/stat/src/stat.rs:1133,1136 (major()/minor()
# of st_rdev), :683-697 (hex output), :975 (-L). coreutils is already
# required (sha256sum, base64 -w0, shred).
ros_stat_devnum() { stat -L -c '%t %T' -- "$1" 2>/dev/null; }
# 0 only if this process shares PID 1's mount namespace, i.e. a mount made
# here is the host's mount. Reading /proc/1/ns/mnt needs root (proc(5),
# /proc/pid/ns/); anything unreadable counts as "not the same". Inside a
# container PID 1 is the container's init, so the check passes there and
# the kernel's own refusal of the noswap mount (see below) takes over.
ros_same_mount_ns() {
  ros_ns_self=$(readlink /proc/self/ns/mnt 2>/dev/null) || return 1
  ros_ns_init=$(readlink /proc/1/ns/mnt 2>/dev/null) || return 1
  [ -n "$ros_ns_self" ] && [ "$ros_ns_self" = "$ros_ns_init" ]
}
ros_pause() { sleep 1; }
# size=2m: one systemd credential may be up to 1 MiB (CREDENTIAL_SIZE_MAX,
# systemd v259 src/shared/creds-util.h:12). mode=0700 keeps the directory
# root-only until the unit's next ExecStart= line hands it to
# YOUR_APP_USER, the same step that ran before this mount existed (on a
# ramfs, that line keeps root as the owner instead; see below).
ros_mount_noswap() {
  mount -t tmpfs -o noswap,size=2m,nr_inodes=16,mode=0700,nosuid,nodev,noexec tmpfs "$1"
}
# ramfs where noswap is unavailable (kernel older than 6.4, or the noswap
# mount refused). Its pages are never swapped: ramfs_get_inode() marks every
# mapping unevictable (fs/ramfs/inode.c, mapping_set_unevictable()), which
# is why systemd falls back to ramfs for $CREDENTIALS_DIRECTORY too. ramfs
# ignores every option but mode and has no size limit, so "only root (or a
# trusted user) should be allowed write access to a ramfs mount"
# (Documentation/filesystems/ramfs-rootfs-initramfs.rst). On a ramfs the
# unit therefore keeps root as the owner of the directory and .env, with
# read-only access for group YOUR_APP_USER. nosuid,nodev,noexec are
# generic mount flags.
ros_mount_ramfs() {
  mount -t ramfs -o mode=0700,nosuid,nodev,noexec ramfs "$1"
}
ros_umount() { umount "$1"; }

# zram registers one dynamic block major named "zram"
# (drivers/block/zram/zram_drv.c:3286, register_blkdev(0, "zram")), listed
# under "Block devices:" in /proc/devices. That number, not a device name,
# identifies a zram device below: a device node can be called anything.
# Prints nothing if the zram module isn't loaded.
ros_zram_major() {
  [ -r "$ROS_DEVICES" ] || return 0
  ros_zm_block=0
  while read -r ros_zm_a ros_zm_b; do
    if [ "$ros_zm_a" = Block ]; then ros_zm_block=1; continue; fi
    if [ "$ros_zm_block" = 1 ] && [ "$ros_zm_b" = zram ]; then
      # Digits only, so a garbled line can never compare as a match below.
      case "$ros_zm_a" in ''|*[!0-9]*) return 0 ;; esac
      printf '%s\n' "$ros_zm_a"
      return 0
    fi
  done < "$ROS_DEVICES"
  return 0
}

ros_swap_remedy() {
  ros_say "Fix: swapoff '$1', then remove it from /etc/fstab or its systemd swap unit (systemctl list-units --type=swap --all) so it does not come back at boot. zram swap without a writeback device is accepted instead; see documentation/COMPONENTS.md Section 4.5."
}

# ros_check_one_swap FILENAME TYPE: one line of /proc/swaps.
ros_check_one_swap() {
  ros_f=$1 ros_t=$2

  # The kernel prints "partition" for a block device and "file" for
  # anything else (mm/swapfile.c:3002). A swap file sits on a filesystem,
  # so its pages land on disk by definition.
  if [ "$ros_t" != partition ]; then
    if [ "$ros_t" = file ]; then
      ros_say "swap file '$ros_f' is active. A swap file lives on a filesystem, so swapped-out pages land on disk. Refusing."
    else
      ros_say "swap area '$ros_f' has type '$ros_t', which is not a block device. Refusing."
    fi
    ros_swap_remedy "$ros_f"
    return 1
  fi

  # Names are printed with space, tab, newline and backslash escaped as
  # \ooo (seq_file_path, mm/swapfile.c:2998), so a deleted node shows up as
  # "...\040(deleted)". A zram node never needs escaping: refuse rather
  # than guess what an escaped name points at.
  case "$ros_f" in
    *\\*)
      ros_say "swap device name '$ros_f' contains escaped characters (a deleted node, or unusual characters in the path). Refusing."
      ros_swap_remedy "$ros_f"
      return 1 ;;
  esac
  # Also refuses a node this mount namespace cannot see (e.g. a private /dev).
  if ! ros_is_blockdev "$ros_f"; then
    ros_say "swap device '$ros_f' is not a block device visible from here. Refusing."
    ros_swap_remedy "$ros_f"
    return 1
  fi

  # Exactly two hex words, "MAJOR MINOR"; anything else is refused.
  ros_dn=$(ros_stat_devnum "$ros_f") || ros_dn=
  ros_h1=${ros_dn%% *} ros_h2=${ros_dn#* }
  case "$ros_dn" in *" "*) ;; *) ros_h1= ;; esac
  case "$ros_h1:$ros_h2" in
    :*|*:|*:*:*|*[!0-9a-fA-F:]*)
      ros_say "cannot read the device number of '$ros_f' (got '$ros_dn'; is stat from coreutils installed?). Refusing."
      return 1 ;;
  esac
  ros_maj=$((0x$ros_h1)) ros_min=$((0x$ros_h2))

  if [ -z "$ros_zmaj" ] || [ "$ros_maj" -ne "$ros_zmaj" ]; then
    ros_say "swap device '$ros_f' ($ros_maj:$ros_min) is not a zram device. Swap on a disk partition, LVM volume, loop device or any other real block device can put swapped-out secrets on disk. Refusing."
    ros_swap_remedy "$ros_f"
    return 1
  fi

  # /sys/dev/block/MAJ:MIN is the device's own sysfs directory
  # (Documentation/ABI/testing/sysfs-dev), where zram keeps its attributes.
  ros_sys=$ROS_SYS_BLOCK/$ros_maj:$ros_min
  if [ -e "$ros_sys/backing_dev" ]; then
    # "none" when unset, otherwise the backing partition's path
    # (zram_drv.c:709-712). With a backing device set, a write to
    # /sys/block/zramN/writeback moves pages onto that partition
    # (Documentation/admin-guide/blockdev/zram.rst, "writeback"); without
    # one, writeback_store() returns -ENODEV (zram_drv.c:1258-1259), and the
    # writeback path is the only place zram submits a write bio to anything.
    #
    # The answer cannot change while the device stays swapped on:
    # backing_dev can only be set before disksize (-EBUSY afterwards,
    # zram_drv.c:743-745), a reset is refused while the device is open
    # (zram_drv.c:2951), and swapon holds it open exclusively until swapoff
    # (mm/swapfile.c:3372). Adding a backing device means swapoff, reset,
    # set, swapon, and the next check sees it.
    if ! ros_bd=$(cat "$ros_sys/backing_dev" 2>/dev/null); then
      ros_say "cannot read $ros_sys/backing_dev for zram swap '$ros_f'. Refusing."
      return 1
    fi
    if [ "$ros_bd" != none ]; then
      ros_say "zram swap '$ros_f' has writeback backing device '$ros_bd'. zram can move swapped-out pages, secrets included, onto that partition. Refusing."
      ros_say "Fix: swapoff '$ros_f', drop the backing device (zram-generator: remove writeback-device= from zram-generator.conf; otherwise stop writing /sys/block/zramN/backing_dev), then set the device up again. Pages written back earlier stay on that partition: wipe it."
      return 1
    fi
  elif [ -e "$ros_sys/disksize" ]; then
    # A zram device with no backing_dev attribute at all: the kernel was
    # built with CONFIG_ZRAM_WRITEBACK=n, which compiles the attribute and
    # the whole writeback path out (zram_drv.c:3001-3003, 3025-3027).
    :
  else
    ros_say "no zram attributes for '$ros_f' under $ros_sys. Refusing."
    return 1
  fi
  return 0
}

# ros_swap_is_ram_only: 0 if there is no active swap, or if every active
# swap area is a zram device without a writeback backing device. Sets
# ros_swap_count and ros_swap_summary for the caller.
ros_swap_is_ram_only() {
  ros_swap_count=0
  ros_swap_summary="no active swap"
  ros_zmaj=

  # /proc/swaps exists only in kernels built with CONFIG_SWAP
  # (mm/swapfile.c:3041). Missing while the rest of /proc is there: this
  # kernel cannot swap at all. Missing along with it: /proc isn't mounted
  # and nothing can be proven.
  if [ ! -e "$ROS_SWAPS" ]; then
    if [ -e "$ROS_DEVICES" ]; then
      ros_swap_summary="kernel built without swap support"
      return 0
    fi
    ros_say "cannot find $ROS_SWAPS or $ROS_DEVICES; is /proc mounted? Refusing."
    return 1
  fi
  # The check this replaces skipped itself when the file was unreadable,
  # i.e. it failed open. An unreadable swap list proves nothing: refuse.
  # Read the file with one read(2) and parse the copy. /proc/swaps is a
  # seq_file: whenever a read(2) finds the seq_file buffer empty, the
  # kernel restarts the listing at the saved record number
  # (fs/seq_file.c:226), and swap_start() finds that record by counting
  # the swap areas in use at that moment, holding swapon_mutex only until
  # that read(2) returns (mm/swapfile.c:2936-2955). A shell's read builtin
  # issues many small read(2) calls, so a swapoff between two of them
  # could shift the count and skip the next entry. cat asks for far more
  # than the file holds, and one read(2) then fills every record that fits
  # in the one-page buffer in a single pass (fs/seq_file.c:255-280) -- all
  # of them, unless dozens of long-named swap areas are active.
  if [ ! -r "$ROS_SWAPS" ] || ! ros_swaps=$(cat "$ROS_SWAPS" 2>/dev/null); then
    ros_say "cannot read $ROS_SWAPS, so active swap cannot be ruled out. Refusing."
    return 1
  fi

  ros_zmaj=$(ros_zram_major)
  ros_ok=
  # The here-document feeds the copy to the loop without a subshell, so
  # the counters survive. Expanded text is not rescanned for backslashes,
  # so escaped names like "\040" reach the check below unchanged. Every
  # refusal inside returns from the function; the only way the group
  # itself can fail is a here-document the shell could not set up (older
  # bash writes it to a temporary file), and then nothing was checked.
  {
    # Fixed header line (mm/swapfile.c:2990). Anything else means the
    # format changed and this parser can no longer be trusted.
    IFS= read -r ros_line || ros_line=
    case "$ros_line" in
      Filename*) ;;
      *) ros_say "unexpected first line in $ROS_SWAPS: '$ros_line'. Refusing."
         return 1 ;;
    esac
    # "|| [ -n ... ]" still checks a last line without a trailing newline.
    while read -r ros_file ros_type _ || [ -n "$ros_file" ]; do
      [ -n "$ros_file" ] || continue
      ros_swap_count=$((ros_swap_count + 1))
      ros_check_one_swap "$ros_file" "$ros_type" || return 1
      ros_ok="$ros_ok $ros_file"
    done
  } <<ROS_SWAPS_EOF || { ros_say "could not parse the copy of $ROS_SWAPS. Refusing."; return 1; }
$ros_swaps
ROS_SWAPS_EOF

  if [ "$ros_swap_count" -gt 0 ]; then
    ros_swap_summary="active swap is zram only, without a writeback device:$ros_ok"
  fi
  return 0
}

# ros_kdump_armed: 0 if a crash kernel is loaded, or memory is reserved for
# one (kdump-tools loads it later in boot than this unit runs).
#
# Why it matters once zram is on: after a panic, the capture kernel saves
# memory to /var/crash (kdump-tools' KDUMP_COREDIR default). Its default
# filter, makedumpfile -d 31, drops page cache and process memory, but
# zram's compressed pool is kernel memory and is kept, and the crash
# utility can decompress zram-swapped pages from such a dump (crash
# diskdump.c try_zram_decompress). That puts swapped-out secrets in a file
# on disk. (Read from makedumpfile's source, not tested on a real dump.)
#
# 7.0 has /sys/kernel/kexec/crash_{loaded,size}
# (Documentation/ABI/testing/sysfs-kernel-kexec-kdump) plus best-effort
# compat links /sys/kernel/kexec_crash_* (kernel/kexec_core.c:1332-1333);
# 6.8 and 6.12 have only the latter. Neither present: kernel built without
# CONFIG_CRASH_DUMP, so no kdump. Present but unreadable or not a number:
# treated as armed (fail closed).
#
# crash_size fails with EBUSY while another task holds the kexec lock, for
# example while kdump-tools loads the crash kernel
# (kernel/crash_core.c:352-364, passed on by kernel/kexec_core.c:1271-1279).
# One retry after a second keeps such an overlap from turning into a
# refusal; a second failure still counts as armed.
ros_kdump_armed() {
  if [ -e "$ROS_SYS_KERNEL/kexec/crash_loaded" ] || [ -e "$ROS_SYS_KERNEL/kexec/crash_size" ]; then
    ros_kl=$ROS_SYS_KERNEL/kexec/crash_loaded ros_ks=$ROS_SYS_KERNEL/kexec/crash_size
  elif [ -e "$ROS_SYS_KERNEL/kexec_crash_loaded" ] || [ -e "$ROS_SYS_KERNEL/kexec_crash_size" ]; then
    ros_kl=$ROS_SYS_KERNEL/kexec_crash_loaded ros_ks=$ROS_SYS_KERNEL/kexec_crash_size
  else
    return 1
  fi
  ros_kload=$(cat "$ros_kl" 2>/dev/null) || return 0
  if ! ros_ksize=$(cat "$ros_ks" 2>/dev/null); then
    ros_pause
    if ! ros_ksize=$(cat "$ros_ks" 2>/dev/null); then
      ros_say "cannot read $ros_ks (the kernel answers EBUSY while a crash kernel is being loaded; try again in a moment). Counted as armed."
      return 0
    fi
  fi
  case "$ros_kload" in 0|1) ;; *) return 0 ;; esac
  case "$ros_ksize" in ''|*[!0-9]*) return 0 ;; esac
  [ "$ros_kload" = 1 ] && return 0
  [ "$ros_ksize" -gt 0 ] && return 0
  return 1
}

# ros_hibernation_note: information only, never a refusal.
# The kernel writes a hibernation image only to an ACTIVE swap area
# (kernel/power/swap.c:343-346 -> swap_type_of()/find_first_swap(), which
# skip anything not swapped on, mm/swapfile.c:1994-2036). After the checks
# above that can only be zram, which is RAM and gone at power-off. A
# resume device on a disk is harmless while that disk is not swapped on,
# but it shows this host is set up to hibernate to disk.
ros_hibernation_note() {
  # "disk" is listed only while hibernation is possible at all
  # (kernel/power/main.c:762-763).
  ros_pstate=$(cat "$ROS_SYS_POWER/state" 2>/dev/null) || return 0
  case " $ros_pstate " in *" disk "*) ;; *) return 0 ;; esac
  # MAJ:MIN of the resume device, "0:0" when none is set
  # (kernel/power/hibernate.c:1284).
  ros_resume=$(cat "$ROS_SYS_POWER/resume" 2>/dev/null) || return 0
  case "$ros_resume" in ''|0:0) return 0 ;; esac
  ros_rzmaj=$(ros_zram_major)
  if [ -n "$ros_rzmaj" ] && [ "${ros_resume%%:*}" = "$ros_rzmaj" ]; then
    return 0
  fi
  ros_say "note: hibernation is enabled and resume device $ros_resume is configured. It is not an active swap area (the check above would have refused it), so no image can be written there now. If it is ever swapped on again, hibernating writes all of RAM, these secrets included, to that disk. Consider nohibernate on the kernel command line and AllowHibernation=no in a systemd sleep.conf.d drop-in."
  return 0
}

# tmpfs "noswap" arrived in Linux 6.4 (commit 2c6efe9cf2d7, "shmem: add
# support to ignore swap"; Documentation/filesystems/tmpfs.rst). Ubuntu
# 24.04 (6.8), Debian 13 (6.12) and Ubuntu 26.04 (7.0) all have it.
ros_kernel_has_tmpfs_noswap() {
  ros_rel=$(cat "$ROS_OSRELEASE" 2>/dev/null) || return 1
  ros_kmaj=${ros_rel%%.*}
  ros_krest=${ros_rel#*.}
  ros_kmin=${ros_krest%%[!0-9]*}
  case "$ros_kmaj:$ros_kmin" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "$ros_kmaj" -gt 6 ] && return 0
  [ "$ros_kmaj" -eq 6 ] && [ "$ros_kmin" -ge 4 ] && return 0
  return 1
}

ros_has_opt() {
  case ",$2," in *",$1,"*) return 0 ;; esac
  return 1
}

# ros_mounts_at DIR: sets ros_mcount (how many mounts sit exactly at DIR),
# plus ros_mfs and ros_mopts (filesystem type and superblock options of the
# last one) from /proc/self/mountinfo. Superblock options come after the
# " - " separator; tmpfs lists ",noswap" there (mm/shmem.c:4955-4956).
ros_mounts_at() {
  ros_mcount=0 ros_mfs='' ros_mopts=''
  [ -r "$ROS_MOUNTINFO" ] || return 1
  while read -r _ _ _ _ ros_mp ros_rest; do
    [ "$ros_mp" = "$1" ] || continue
    case "$ros_rest" in *" - "*) ;; *) continue ;; esac
    ros_tail=${ros_rest#* - }       # FSTYPE SOURCE SUPEROPTIONS
    ros_mfs=${ros_tail%% *}
    ros_tail=${ros_tail#* }         # SOURCE SUPEROPTIONS
    ros_mopts=${ros_tail#* }
    ros_mopts=${ros_mopts%% *}
    ros_mcount=$((ros_mcount + 1))
  done < "$ROS_MOUNTINFO"
  return 0
}

# ros_unswappable_mount: 0 if the one mount ros_mounts_at found is a
# noswap tmpfs or a ramfs, the two filesystems whose pages are never
# swapped; ros_mdesc then names which.
ros_unswappable_mount() {
  if [ "$ros_mfs" = tmpfs ] && ros_has_opt noswap "$ros_mopts"; then
    ros_mdesc='noswap tmpfs'
    return 0
  fi
  if [ "$ros_mfs" = ramfs ]; then
    ros_mdesc=ramfs
    return 0
  fi
  return 1
}

# ros_mount_secrets_dir DIR: make DIR its own tmpfs with "noswap", so the
# decrypted file in it can never be paged out, whatever swap gets switched
# on after the check ran. shmem_writeout() puts noswap pages straight back
# (mm/shmem.c:1601) and their mapping is unevictable (mm/shmem.c:3106-3107).
# The boot unit uses it for /run/YOUR_APP-secrets, and both the installer
# and YOUR_APP-secrets-open for /run/YOUR_APP-secrets-edit, where the
# plaintext edit copy lives.
#
# Idempotent, because YOUR_APP-secrets-commit restarts the unit: a noswap
# tmpfs or ramfs already at DIR is reused as is. It never stacks a second tmpfs on
# top (that would hide the old plaintext, not free it) and never remounts
# (noswap cannot be added on remount, mm/shmem.c:4850-4855). It needs
# CAP_SYS_ADMIN in the initial user namespace (mm/shmem.c:4693-4698) and
# PID 1's mount namespace, and refuses in any other: a mount made in a
# private namespace is invisible to the application, and the check below
# would vouch for a directory the application never sees. systemd gives a
# unit its own namespace for many settings (PrivateTmp=, ProtectSystem=,
# ProtectHome=, ReadOnlyPaths=, PrivateDevices= and more; systemd v259
# src/core/execute.c:259-346, exec_needs_mount_namespace()), so keep all
# of them off the unit that runs this.
#
# Where noswap is not available (kernel older than 6.4, or the mount is
# refused), it mounts a ramfs instead (ros_mount_ramfs above). Only if that
# is refused too, e.g. in an unprivileged container, it warns and leaves
# DIR a plain directory on /run, the layout this pipeline always used. The
# swap check stays the gate then, as it always was; the only swap it lets
# through is zram, which is RAM. What it never does is let a file land in
# a mount it cannot vouch for.
ros_mount_secrets_dir() {
  ros_dir=$1
  case "$ros_dir" in
    /?*) ;;
    *) ros_say "mount: need an absolute directory, got '$ros_dir'."; return 2 ;;
  esac
  if ! ros_same_mount_ns; then
    ros_say "this process does not run in PID 1's mount namespace (or cannot compare the two; that needs root), so a mount made here would not be the one the application sees. A drop-in probably gives the unit a private namespace (systemctl cat on the unit shows it; see the list in COMPONENTS.md Section 4.2). Refusing; nothing was written to $ros_dir."
    return 1
  fi
  if ! ros_mounts_at "$ros_dir"; then
    ros_say "cannot read $ROS_MOUNTINFO. Refusing; nothing was written to $ros_dir."
    return 1
  fi
  if [ "$ros_mcount" -gt 1 ]; then
    ros_say "$ros_dir has $ros_mcount mounts stacked on it. Refusing; nothing was written to it. Unmount them (umount $ros_dir until it is a plain directory) and try again."
    return 1
  fi
  if [ "$ros_mcount" -eq 1 ]; then
    if ros_unswappable_mount; then
      ros_info "$ros_dir is already a $ros_mdesc; reusing it."
      return 0
    fi
    ros_say "$ros_dir is already a mount point ($ros_mfs: $ros_mopts) but neither a noswap tmpfs nor a ramfs. Refusing; nothing was written to it. Unmount it (umount $ros_dir) and try again."
    return 1
  fi

  # Moving from the old layout: a .env left in the plain directory sits on
  # /run's shared, swappable tmpfs. Delete it before the new mount hides it,
  # where it would linger unseen until reboot. (The edit directory never
  # holds a .env, so there this does nothing.)
  rm -f -- "$ros_dir/.env"
  if [ ! -d "$ros_dir" ] && ! mkdir -m 0700 -- "$ros_dir"; then
    ros_say "cannot create $ros_dir. Refusing; nothing was written to it."
    return 1
  fi

  if ros_kernel_has_tmpfs_noswap; then
    if ros_mount_noswap "$ros_dir"; then
      if ! ros_mounts_at "$ros_dir" || [ "$ros_mcount" -ne 1 ] ||
         [ "$ros_mfs" != tmpfs ] || ! ros_has_opt noswap "$ros_mopts"; then
        ros_umount "$ros_dir" 2>/dev/null || true
        ros_say "the new tmpfs on $ros_dir does not report noswap in $ROS_MOUNTINFO. Unmounted it again. Refusing; nothing was written to it."
        return 1
      fi
      ros_info "mounted a noswap tmpfs on $ros_dir."
      return 0
    fi
    if ! ros_mounts_at "$ros_dir" || [ "$ros_mcount" -ne 0 ]; then
      ros_say "mount failed but something is mounted at $ros_dir now. Refusing; nothing was written to it."
      return 1
    fi
    ros_say "warning: could not mount a noswap tmpfs on $ros_dir (see mount's error above). Trying ramfs instead."
  else
    ros_info "kernel '$(cat "$ROS_OSRELEASE" 2>/dev/null)' predates tmpfs noswap (Linux 6.4); using ramfs for $ros_dir instead."
  fi

  if ros_mount_ramfs "$ros_dir"; then
    if ! ros_mounts_at "$ros_dir" || [ "$ros_mcount" -ne 1 ] || [ "$ros_mfs" != ramfs ]; then
      ros_umount "$ros_dir" 2>/dev/null || true
      ros_say "the new ramfs on $ros_dir does not show up as ramfs in $ROS_MOUNTINFO. Unmounted it again. Refusing; nothing was written to it."
      return 1
    fi
    ros_info "mounted a ramfs on $ros_dir (never swapped)."
    return 0
  fi
  if ! ros_mounts_at "$ros_dir" || [ "$ros_mcount" -ne 0 ]; then
    ros_say "mount failed but something is mounted at $ros_dir now. Refusing; nothing was written to it."
    return 1
  fi
  ros_say "warning: could not mount a ramfs on $ros_dir either (see mount's error above). It stays a plain directory on /run's shared tmpfs, whose pages the kernel may swap; the swap check remains the only protection."
  return 0
}

# ros_noswap_status DIR: report, never refuse, whether DIR is a noswap
# tmpfs or a ramfs. When the boot unit falls back to the plain directory, it
# says so only in the journal; YOUR_APP-secrets-open and -commit call this,
# so the fallback also shows up where the operator is looking.
ros_noswap_status() {
  if ! ros_mounts_at "$1"; then
    ros_say "warning: cannot read $ROS_MOUNTINFO, so whether $1 is a noswap tmpfs or a ramfs is unknown."
    return 0
  fi
  if [ "$ros_mcount" -eq 1 ] && ros_unswappable_mount; then
    ros_info "$1 is a $ros_mdesc."
    return 0
  fi
  if [ "$ros_mcount" -eq 0 ]; then
    ros_say "warning: $1 is a plain directory on /run's shared tmpfs, neither a noswap tmpfs nor a ramfs. Files in it can be swapped out; while the swap check passes, only into zram. The journal of the unit that mounts it (journalctl -b) says why; restarting that unit tries the mount again."
  else
    ros_say "warning: $1 has $ros_mcount mount(s) on it, not a single noswap tmpfs or ramfs. Files in it can be swapped out; while the swap check passes, only into zram."
  fi
  return 0
}

# ros_guard: the single gate for the installer, the boot unit and both
# helper scripts.
ros_guard() {
  ros_swap_is_ram_only || return 1
  if [ "$ros_swap_count" -gt 0 ] && ros_kdump_armed; then
    ros_say "zram swap is active and kdump is armed (a crash kernel is loaded, or memory is reserved for one via crashkernel=). After a kernel panic, the dump written to /var/crash keeps zram's compressed pool, swapped-out secrets included. Refusing."
    ros_say "Fix, one of: switch zram swap off; or switch kdump off for good by removing crashkernel= from the kernel command line (Ubuntu: /etc/default/grub.d/kdump-tools.cfg, then update-grub and reboot). USE_KDUMP=0 alone keeps the memory reserved and is still refused. Until the next boot only: kdump-config unload, then echo 0 > /sys/kernel/kexec/crash_size (/sys/kernel/kexec_crash_size before Linux 7.0)."
    return 1
  fi
  ros_hibernation_note
  ros_info "swap check passed: $ros_swap_summary."
  return 0
}

# ros_render_guard NAME SOURCE: print the standalone guard script, i.e.
# this block cut out of SOURCE (the installer) between its two marker
# lines, plus a header and the call to ros_main. Used by the installer and
# by tests/run.sh; never called inside the installed guard itself.
ros_render_guard() {
  printf '#!/bin/sh\n'
  printf '# %s -- generated by ram-only-secrets-install.sh\n' "$1"
  printf '# from the ros-lib block below. Rules and references:\n'
  printf '# documentation/COMPONENTS.md Section 4.5.\n'
  printf '# Usage: %s check | %s mount DIRECTORY | %s status DIRECTORY\n' "$1" "$1" "$1"
  sed -n '/^# --- ros-lib begin ---$/,/^# --- ros-lib end ---$/p' "$2"
  # shellcheck disable=SC2016 # "$@" is meant literally, for the new script
  printf 'ros_main "$@"\n'
}

ros_usage() { ros_say "usage: $ros_me check | $ros_me mount DIRECTORY | $ros_me status DIRECTORY"; }

# ros_main: entry point of the installed guard. No flags beyond these three
# subcommands, and none that weakens a check.
ros_main() {
  case "${1:-check}" in
    check)
      if [ $# -gt 1 ]; then ros_usage; return 2; fi
      if ros_guard; then return 0; fi
      ros_say "No override exists. Nothing was changed."
      return 1 ;;
    mount)
      if [ $# -ne 2 ]; then ros_usage; return 2; fi
      ros_mount_secrets_dir "$2" ;;
    status)
      if [ $# -ne 2 ]; then ros_usage; return 2; fi
      ros_noswap_status "$2" ;;
    *)
      ros_usage
      return 2 ;;
  esac
}
# --- ros-lib end ---
ros_main "$@"
```
<!-- ros-guard: end -->

Root-only, like the helper scripts. The boot unit and both helpers call
it by this exact path:

```bash
chmod 750 /usr/local/sbin/YOUR_APP-secrets-guard
```
