#!/bin/sh
# ram-only-secrets-install.sh
#
# Fully automates Sections 5.1 (Prerequisites) and 5.2 (One-time setup) of
# ram-only-secrets-pipeline.md. Self-contained -- generates the two helper
# scripts and the systemd unit itself, no other files needed alongside it.
#
# The one thing this script cannot and will not automate: your actual
# secret values. It opens nano for exactly that one step and nothing else.
#
# Usage:
#   sudo ./ram-only-secrets-install.sh APP_NAME APP_USER [UID]
#
#   APP_NAME  -- short identifier, e.g. "myapp" (becomes YOUR_APP throughout)
#   APP_USER  -- the unprivileged user that owns the RAM copy (must already exist)
#   UID       -- APP_USER's numeric UID (optional; auto-detected if omitted)
#
# Where to run this from (Section 5.0): if you're keeping this script in a
# version-controlled config repo (Section 7.4 -- the recommended pattern),
# run it from that checkout and it stays there; this script detects a git
# work tree and will not delete itself in that case. If you downloaded it
# as a one-off, run it from /root/ so the automatic cleanup described below
# (and the boot-time/helper-script backstop) can find and remove it. Either
# way, read it before running it as root -- "trust a script you haven't
# read" is not a habit worth starting here.

set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo $0 ...)" >&2
  exit 1
fi

# This script reads confirmations and opens nano -- neither works correctly
# piped through something like "curl ... | sudo sh". Worse than just
# failing: a piped invocation can make `read` consume bytes from the same
# stream the shell is still executing script from, producing confusing,
# unpredictable behavior rather than a clean error. Refuse outright instead.
if [ ! -t 0 ]; then
  echo "This script must be run interactively, not piped in -- it asks for" >&2
  echo "confirmations and opens an editor. Save it to a file and run it" >&2
  echo "directly: sudo ./ram-only-secrets-install.sh ..." >&2
  exit 1
fi

# Resolve this script's own absolute path now, before anything else --
# needed later for self-deletion, and $0 alone isn't reliable once the
# working directory might have changed.
case "$0" in
  /*) SELF="$0" ;;
  *)  SELF="$(pwd)/$0" ;;
esac

echo "== Before anything else =="
printf 'Have you already chosen a password manager for this pipeline (Section 7.1)? [y/N] '
read -r PM_CHOSEN
case "$PM_CHOSEN" in
  [yY]*) ;;
  *)
    echo
    echo "Choose one first -- see Section 7.1 for real options (Bitwarden," >&2
    echo "1Password, KeePassXC, pass). What you save there is not an extra" >&2
    echo "copy of the backup -- it IS the backup. If this host is ever lost" >&2
    echo "and nothing was saved to a password manager, the secrets are gone" >&2
    echo "permanently, with no other recovery path. Nothing has been changed yet." >&2
    exit 1
    ;;
esac

APP="${1:?Usage: $0 APP_NAME APP_USER [UID]}"
APP_USER="${2:?Usage: $0 APP_NAME APP_USER [UID]}"
APP_UID="${3:-$(id -u "$APP_USER" 2>/dev/null || true)}"

if [ -z "$APP_UID" ]; then
  echo "Could not determine a UID for '$APP_USER' -- does that user exist yet?" >&2
  echo "Create it first, or pass the UID explicitly as the 3rd argument." >&2
  exit 1
fi

APP_HOME="$(eval echo "~${APP_USER}")"
if [ ! -d "$APP_HOME" ]; then
  echo "Warning: resolved home directory '$APP_HOME' for '$APP_USER' does not exist." >&2
  echo "The boot-time history-cleanup line will simply skip files under it -- harmless, but check APP_USER is right." >&2
fi

echo "== Section 5.1: checking prerequisites =="

FAIL=0

if ! command -v systemd-creds >/dev/null 2>&1; then
  echo "MISSING: systemd-creds (part of the systemd package)" >&2
  echo "  Debian/Ubuntu: sudo apt update && sudo apt install --only-upgrade systemd" >&2
  echo "  Fedora/RHEL:   sudo dnf upgrade systemd" >&2
  FAIL=1
fi

for tool in shred base64 sha256sum install nano systemctl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "MISSING: $tool" >&2
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "Install what's missing above, then re-run this script. Nothing has been changed yet." >&2
  exit 1
fi

echo "Prerequisites OK:"
systemctl --version | head -1
if systemd-creds has-tpm2 >/dev/null 2>&1; then
  echo "TPM2 present (not used by this pipeline -- host-key mode only, throughout)"
else
  echo "No TPM2 -- host-only key will be used, which is what this pipeline assumes throughout"
fi

echo
echo "== Section 5.2: one-time setup =="

# --- 1. Helper scripts ---
cat > "/usr/local/sbin/${APP}-secrets-open" <<SCRIPT_EOF
#!/bin/sh
# Prepares an editable plaintext copy of the current secrets bundle in RAM.
set -eu

EDIT_FILE=/dev/shm/${APP}-env.edit
RUNNING_ENV=/run/${APP}-secrets/.env
INSTALLER=/root/ram-only-secrets-install.sh

if [ "\$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo \$0)" >&2
  exit 1
fi

if [ -f "\$EDIT_FILE" ]; then
  echo "An edit is already in progress at \$EDIT_FILE -- finish or discard it first." >&2
  exit 1
fi

if [ -f "\$RUNNING_ENV" ]; then
  cp "\$RUNNING_ENV" "\$EDIT_FILE"
else
  : > "\$EDIT_FILE"
fi
chmod 600 "\$EDIT_FILE"

# Backstop cleanup: if a standalone copy of the installer is still sitting
# at the standard path, and it is NOT part of a kept git checkout (Section
# 7.4), remove it. Every helper-script run and every boot (Section 4.2) all
# perform this same check, so a missed self-delete gets caught quickly
# either way, without any of them needing to know an arbitrary path.
if [ -e "\$INSTALLER" ] && ! git -C "\$(dirname "\$INSTALLER")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rm -f "\$INSTALLER"
fi

echo "Edit \$EDIT_FILE now, then run: ${APP}-secrets-commit"
echo "This file lives in RAM (/dev/shm) and is removed automatically on commit."
SCRIPT_EOF

cat > "/usr/local/sbin/${APP}-secrets-commit" <<SCRIPT_EOF
#!/bin/sh
# Re-encrypts the edited bundle, refreshes the running RAM copy, wipes the
# temp edit file, and prints a fresh backup blob + its checksum.
set -eu

EDIT_FILE=/dev/shm/${APP}-env.edit
BLOB=/etc/credstore.encrypted/${APP}-env
INSTALLER=/root/ram-only-secrets-install.sh

if [ "\$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo \$0)" >&2
  exit 1
fi

if [ ! -s "\$EDIT_FILE" ]; then
  echo "No edit found at \$EDIT_FILE (or it's empty) -- run ${APP}-secrets-open first." >&2
  exit 1
fi

systemd-creds encrypt --name=${APP}-env "\$EDIT_FILE" "\$BLOB"
shred -u "\$EDIT_FILE"

systemctl restart ${APP}-secrets.service

# Same backstop cleanup as -secrets-open -- see the comment there.
if [ -e "\$INSTALLER" ] && ! git -C "\$(dirname "\$INSTALLER")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rm -f "\$INSTALLER"
fi

echo
echo "Committed. Blob re-encrypted and the RAM copy has been refreshed."
echo "Remember to recreate any already-running service that needs the new value."
echo
echo "New blob checksum (sha256) -- for the verification step in Section 6:"
sha256sum "\$BLOB"
echo
echo "New blob, base64 -- useful ONLY paired with a host-key backup"
echo "(Section 7.5, optional). Without that key it's exactly as useless as"
echo "leaving it on disk. The plaintext values you just edited, not this"
echo "blob, are what disaster recovery depends on by default (Section 8.1)"
echo "-- make sure your saved copy of those is current too, not just this."
echo "Copy this ENTIRE line into your password manager now:"
base64 -w0 "\$BLOB"; echo
echo

printf 'Have you copied the base64 blob above into your password manager and verified it per Section 6? [y/N] '
read -r CONFIRM
case "\$CONFIRM" in
  [yY]*)
    echo
    echo "Good. Now run these in YOUR OWN shell (not this script) -- a script"
    echo "cannot clear a parent shell's live history for you:"
    echo '  bash: history -c && history -w'
    echo '  zsh:  history -c && fc -W'
    echo "Terminal scrollback (best-effort, not every terminal honors this):"
    printf "  printf '"
    printf '\\033[3J'
    echo "'"
    ;;
  *)
    echo
    echo "Not clearing history yet -- but save that blob first, not after."
    echo "It's the only thing that survives losing this host."
    echo "Re-run this reminder any time; nothing above was destructive."
    ;;
esac
SCRIPT_EOF

chmod 750 "/usr/local/sbin/${APP}-secrets-open" "/usr/local/sbin/${APP}-secrets-commit"
echo "Installed /usr/local/sbin/${APP}-secrets-open and /usr/local/sbin/${APP}-secrets-commit"

# --- 2. systemd unit ---
cat > "/etc/systemd/system/${APP}-secrets.service" <<UNIT_EOF
[Unit]
Description=Decrypt ${APP} secrets into RAM
DefaultDependencies=no
Before=user@${APP_UID}.service

[Service]
Type=oneshot
RemainAfterExit=yes
LoadCredentialEncrypted=${APP}-env:/etc/credstore.encrypted/${APP}-env
ExecStart=/bin/sh -c 'install -d -m 0750 -o ${APP_USER} -g ${APP_USER} /run/${APP}-secrets && install -m 0600 -o ${APP_USER} -g ${APP_USER} "\$CREDENTIALS_DIRECTORY/${APP}-env" /run/${APP}-secrets/.env'
ExecStartPost=/bin/sh -c 'for f in /root/.bash_history /root/.zsh_history ${APP_HOME}/.bash_history ${APP_HOME}/.zsh_history; do [ -e "\$f" ] && : > "\$f"; done; true'
ExecStartPost=/bin/sh -c 'i=/root/ram-only-secrets-install.sh; if [ -e "\$i" ] && ! git -C "\$(dirname "\$i")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then rm -f "\$i"; fi; true'

[Install]
WantedBy=multi-user.target
UNIT_EOF
echo "Installed /etc/systemd/system/${APP}-secrets.service"

# --- 3. credstore directory ---
install -d -m 0755 /etc/credstore.encrypted

# --- 4. First-ever encrypt: the one genuinely interactive step ---
echo
echo "Opening an editor for your REAL secret values now (KEY=value, one per line)."
echo "Save and exit when done -- in nano, that's Ctrl+O then Enter, then Ctrl+X."
: > "/dev/shm/${APP}-env.edit"
chmod 600 "/dev/shm/${APP}-env.edit"
nano "/dev/shm/${APP}-env.edit"

if [ ! -s "/dev/shm/${APP}-env.edit" ]; then
  echo "Nothing was saved -- aborting before encrypting an empty bundle." >&2
  shred -u "/dev/shm/${APP}-env.edit"
  exit 1
fi

printf 'Have you saved each individual secret value you just typed into your password manager (Section 7.1/7.2)? [y/N] '
read -r VALUES_SAVED
case "$VALUES_SAVED" in
  [yY]*) ;;
  *) echo "Not blocking on this -- but these values, not the encrypted blob," >&2
     echo "are what disaster recovery actually depends on by default when" >&2
     echo "this host is lost (Section 8.1). Go back and save them now." >&2 ;;
esac

systemd-creds encrypt --name="${APP}-env" "/dev/shm/${APP}-env.edit" "/etc/credstore.encrypted/${APP}-env"
shred -u "/dev/shm/${APP}-env.edit"

# --- 5-6. Enable, start, verify ---
systemctl daemon-reload
systemctl enable --now "${APP}-secrets.service"
systemctl status "${APP}-secrets.service" --no-pager || true
ls -l "/run/${APP}-secrets/.env"

# --- 7. First backup ---
echo
echo "== First backup -- useful ONLY paired with a host-key backup"
echo "(Section 7.5, optional). Without that key it's exactly as useless as"
echo "leaving it on disk -- the plaintext values from step 4, already saved"
echo "to your password manager, are what disaster recovery depends on by"
echo "default (Section 8.1), not this blob. =="
echo "Copy this into your password manager now anyway (Section 7.2) --"
echo "it's what makes the faster recovery path possible if you ever add"
echo "the host-key backup later:"
sha256sum "/etc/credstore.encrypted/${APP}-env"
base64 -w0 "/etc/credstore.encrypted/${APP}-env"; echo
echo
printf 'Have you copied the base64 blob above into your password manager and verified it per Section 6? [y/N] '
read -r BLOB_SAVED
case "$BLOB_SAVED" in
  [yY]*) echo "Good." ;;
  *) echo "Go back and save it now -- this blob also goes stale the moment" >&2
     echo "you next run ${APP}-secrets-commit, so there's no 'later' here." >&2 ;;
esac

echo
echo "== Setup complete. Remaining steps this script does NOT do for you: =="
echo "  - Symlink your app's own .env file:"
echo "      ln -s /run/${APP}-secrets/.env /path/to/your/app/.env"
echo "  - Clear this session's shell history now, same as Section 5.2 step 10:"
echo "      bash: history -c && history -w"
echo "      zsh:  history -c && fc -W"
echo "  - Consider Section 7.5 (optional credential.secret backup) before"
echo "    you forget the host key exists -- read the tradeoff first."

# --- Self-delete, unless this is a kept git checkout (Section 7.4) ---
if git -C "$(dirname "$SELF")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo
  echo "This script is inside a git work tree -- leaving it in place, per"
  echo "Section 7.4 (keep it in your config repo for future reproducibility)."
else
  echo
  echo "Not inside a git repo -- removing this script now (Section 5.0)."
  echo "The boot service and both helper scripts also check for a stray copy"
  echo "at /root/ram-only-secrets-install.sh as a backstop, in case this line"
  echo "is ever skipped (e.g. the process is killed before reaching it)."
  rm -f -- "$SELF"
fi
