#!/bin/sh
# ram-only-secrets-install.sh
#
# Fully automates Sections 5.1 (Prerequisites) and 5.2 (One-time setup) of
# ram-only-secrets-pipeline.md. Self-contained -- generates the swap guard,
# the two helper scripts and the systemd unit itself, no other files needed
# alongside it.
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

# The only five operations a test cannot fake without root: asking whether
# a path is a block device, reading its device number, mount, umount, and
# comparing this process's mount namespace with PID 1's. tests/run.sh
# replaces exactly these five, plus ros_pause so the tests don't wait;
# everything else runs as is.
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
# YOUR_APP_USER, the same step that ran before this mount existed.
ros_mount_noswap() {
  mount -t tmpfs -o noswap,size=2m,nr_inodes=16,mode=0700,nosuid,nodev,noexec tmpfs "$1"
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

# ros_mount_secrets_dir DIR: make DIR its own tmpfs with "noswap", so the
# decrypted file in it can never be paged out, whatever swap gets switched
# on after the check ran. shmem_writeout() puts noswap pages straight back
# (mm/shmem.c:1601) and their mapping is unevictable (mm/shmem.c:3106-3107).
# The boot unit uses it for /run/YOUR_APP-secrets, and both the installer
# and YOUR_APP-secrets-open for /run/YOUR_APP-secrets-edit, where the
# plaintext edit copy lives.
#
# Idempotent, because YOUR_APP-secrets-commit restarts the unit: a noswap
# tmpfs already at DIR is reused as is. It never stacks a second tmpfs on
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
# refused, e.g. in an unprivileged container), it warns and leaves DIR a
# plain directory on /run, the layout this pipeline always used. The swap
# check stays the gate then, as it always was; the only swap it lets
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
    if [ "$ros_mfs" = tmpfs ] && ros_has_opt noswap "$ros_mopts"; then
      ros_info "$ros_dir is already a noswap tmpfs; reusing it."
      return 0
    fi
    ros_say "$ros_dir is already a mount point ($ros_mfs: $ros_mopts) but not a noswap tmpfs. Refusing; nothing was written to it. Unmount it (umount $ros_dir) and try again."
    return 1
  fi

  if ! ros_kernel_has_tmpfs_noswap; then
    ros_say "warning: kernel '$(cat "$ROS_OSRELEASE" 2>/dev/null)' predates tmpfs noswap (Linux 6.4). $ros_dir stays a plain directory on /run's shared tmpfs, whose pages the kernel may swap; the swap check remains the only protection."
    return 0
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
  if ! ros_mount_noswap "$ros_dir"; then
    if ! ros_mounts_at "$ros_dir" || [ "$ros_mcount" -ne 0 ]; then
      ros_say "mount failed but something is mounted at $ros_dir now. Refusing; nothing was written to it."
      return 1
    fi
    ros_say "warning: could not mount a noswap tmpfs on $ros_dir (see mount's error above). It stays a plain directory on /run's shared tmpfs, whose pages the kernel may swap; the swap check remains the only protection."
    return 0
  fi
  if ! ros_mounts_at "$ros_dir" || [ "$ros_mcount" -ne 1 ] ||
     [ "$ros_mfs" != tmpfs ] || ! ros_has_opt noswap "$ros_mopts"; then
    ros_umount "$ros_dir" 2>/dev/null || true
    ros_say "the new tmpfs on $ros_dir does not report noswap in $ROS_MOUNTINFO. Unmounted it again. Refusing; nothing was written to it."
    return 1
  fi
  ros_info "mounted a noswap tmpfs on $ros_dir."
  return 0
}

# ros_noswap_status DIR: report, never refuse, whether DIR is a noswap
# tmpfs. When the boot unit falls back to the plain directory, it says so
# only in the journal; YOUR_APP-secrets-open and -commit call this, so the
# fallback also shows up where the operator is looking.
ros_noswap_status() {
  if ! ros_mounts_at "$1"; then
    ros_say "warning: cannot read $ROS_MOUNTINFO, so whether $1 is a noswap tmpfs is unknown."
    return 0
  fi
  if [ "$ros_mcount" -eq 1 ] && [ "$ros_mfs" = tmpfs ] && ros_has_opt noswap "$ros_mopts"; then
    ros_info "$1 is a noswap tmpfs."
    return 0
  fi
  if [ "$ros_mcount" -eq 0 ] && ! ros_kernel_has_tmpfs_noswap; then
    ros_info "$1 is a plain directory on /run; this kernel predates tmpfs noswap (Linux 6.4)."
    return 0
  fi
  if ros_kernel_has_tmpfs_noswap; then
    ros_say "warning: $1 is not a noswap tmpfs ($ros_mcount mount(s) there), although this kernel supports noswap. Files in it can be swapped out; while the swap check passes, only into zram. The journal of the unit that mounts it (journalctl -b) says why; restarting that unit tries the mount again."
  else
    ros_say "warning: $1 has $ros_mcount mount(s) on it, none a noswap tmpfs; this kernel predates noswap (Linux 6.4). Files in it can be swapped out; while the swap check passes, only into zram."
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

echo "== Section 5.1: checking prerequisites =="

# Swap is accepted only when it cannot put anything on persistent disk.
# tmpfs (where the RAM-only .env file will live, Section 3) is swappable
# like any other memory: with a swap partition or swap file active, the
# kernel can page decrypted secrets out to it under memory pressure --
# exactly the plaintext-on-disk exposure this pipeline exists to prevent,
# just relocated. zram is the one exception, since it swaps into
# compressed RAM; ros_guard (the ros-lib block above) accepts it only
# without a writeback backing device and only while kdump is off, and
# refuses everything else. A hard requirement, not a tunable: there is no
# override flag for this check.
if ! ros_guard; then
  echo >&2
  echo "SWAP CHECK FAILED -- refusing to install." >&2
  echo >&2
  echo "Active swap on this host:" >&2
  cat /proc/swaps >&2 || true
  echo >&2
  echo "Swap is accepted only as zram without a writeback device, and only" >&2
  echo "while kdump is off. Anything else can put decrypted secrets on disk." >&2
  echo "See documentation/ABOUT.md Section 2 and documentation/COMPONENTS.md" >&2
  echo "Section 4.5 for the full reasoning." >&2
  echo >&2
  echo "There is no override flag for this check. Nothing has been changed yet." >&2
  exit 1
fi

FAIL=0

if ! command -v systemd-creds >/dev/null 2>&1; then
  echo "MISSING: systemd-creds (part of the systemd package)" >&2
  echo "  Debian/Ubuntu: sudo apt update && sudo apt install --only-upgrade systemd" >&2
  echo "  Fedora/RHEL:   sudo dnf upgrade systemd" >&2
  FAIL=1
fi

for tool in shred base64 sha256sum install stat readlink nano systemctl; do
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

# --- 0. Shared swap guard (Section 4.5) ---
# The ros-lib block above, copied out of this very file, so the boot unit
# and both helper scripts run the exact rules this installer just checked.
GUARD="/usr/local/sbin/${APP}-secrets-guard"
ros_render_guard "${APP}-secrets-guard" "$SELF" > "$GUARD"
if ! grep -q '^ros_main()' "$GUARD" || ! sh -n "$GUARD"; then
  rm -f "$GUARD"
  echo "Could not copy the swap guard out of $SELF -- run this installer from" >&2
  echo "a saved file, not a pipe or process substitution. Aborting." >&2
  exit 1
fi
chmod 750 "$GUARD"
echo "Installed $GUARD"

# --- 1. Helper scripts ---
cat > "/usr/local/sbin/${APP}-secrets-open" <<SCRIPT_EOF
#!/bin/sh
# Prepares an editable plaintext copy of the current secrets bundle in RAM,
# on a noswap tmpfs of its own where the kernel supports it.
set -eu
umask 077

EDIT_DIR=/run/${APP}-secrets-edit
EDIT_FILE=/run/${APP}-secrets-edit/env.edit
OLD_EDIT_FILE=/dev/shm/${APP}-env.edit
RUNNING_ENV=/run/${APP}-secrets/.env
GUARD=/usr/local/sbin/${APP}-secrets-guard
INSTALLER=/root/ram-only-secrets-install.sh

if [ "\$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo \$0)" >&2
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
if [ -e /proc/\$\$/coredump_filter ]; then echo 0 > /proc/\$\$/coredump_filter; fi

# Hard requirement, not a tunable -- the shared swap guard refuses any swap
# that could put secrets on disk (documentation/COMPONENTS.md Section 4.5,
# documentation/ABOUT.md Section 2). No override flag.
/usr/local/sbin/${APP}-secrets-guard check || exit 1

# Earlier versions kept the edit copy in /dev/shm, which systemd mounts
# without noswap. Don't start a new edit while an old one sits there.
if [ -e "\$OLD_EDIT_FILE" ]; then
  echo "An edit from an earlier version of this script is still at \$OLD_EDIT_FILE," >&2
  echo "on swappable /dev/shm. Copy what you still need from it, then remove it:" >&2
  echo "  shred -u \$OLD_EDIT_FILE" >&2
  exit 1
fi

if [ -f "\$EDIT_FILE" ]; then
  echo "An edit is already in progress at \$EDIT_FILE -- finish it with ${APP}-secrets-commit, or discard it: shred -u \$EDIT_FILE" >&2
  exit 1
fi

# The edit copy gets what the .env gets: its own root-only tmpfs with
# noswap (documentation/COMPONENTS.md Section 4.4). Where noswap is not
# available, the guard warns and this stays a root-only directory on /run.
"\$GUARD" mount "\$EDIT_DIR" || exit 1
install -d -m 0700 "\$EDIT_DIR"

if [ -f "\$RUNNING_ENV" ]; then
  cp "\$RUNNING_ENV" "\$EDIT_FILE"
else
  : > "\$EDIT_FILE"
fi
chmod 600 "\$EDIT_FILE"

# A warning, never a refusal, if the running .env is not on its noswap tmpfs.
"\$GUARD" status /run/${APP}-secrets || true

# Backstop cleanup: if a standalone copy of the installer is still sitting
# at the standard path, and it is NOT part of a kept git checkout (Section
# 7.4), remove it. Every helper-script run and every boot (Section 4.2) all
# perform this same check, so a missed self-delete gets caught quickly
# either way, without any of them needing to know an arbitrary path.
if [ -e "\$INSTALLER" ] && ! git -C "\$(dirname "\$INSTALLER")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rm -f "\$INSTALLER"
fi

echo "Edit the copy now, with core dumps of the editor switched off the same way:"
echo "  sudo sh -c 'echo 0 > /proc/\\\$\\\$/coredump_filter && exec nano \$EDIT_FILE'"
echo "Then run: sudo ${APP}-secrets-commit"
echo "The copy lives in RAM (\$EDIT_DIR) and is removed automatically on commit."
SCRIPT_EOF

cat > "/usr/local/sbin/${APP}-secrets-commit" <<SCRIPT_EOF
#!/bin/sh
# Re-encrypts the edited bundle, refreshes the running RAM copy, wipes the
# temp edit file, and prints a fresh backup blob + its checksum.
set -eu
umask 077

EDIT_DIR=/run/${APP}-secrets-edit
EDIT_FILE=/run/${APP}-secrets-edit/env.edit
BLOB=/etc/credstore.encrypted/${APP}-env
GUARD=/usr/local/sbin/${APP}-secrets-guard
INSTALLER=/root/ram-only-secrets-install.sh

if [ "\$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo \$0)" >&2
  exit 1
fi

# Same core dump protection as in ${APP}-secrets-open (see the comment
# there); here it covers systemd-creds encrypt, which reads the plaintext.
if [ -e /proc/\$\$/coredump_filter ]; then echo 0 > /proc/\$\$/coredump_filter; fi

# Whatever stops this script before the shred below, say where the
# plaintext still is.
trap 'if [ -e "\$EDIT_FILE" ]; then echo "The plaintext edit copy is still at \$EDIT_FILE. Fix the problem above and run ${APP}-secrets-commit again, or discard the edit: shred -u \$EDIT_FILE" >&2; fi' EXIT

# Hard requirement, not a tunable -- the shared swap guard refuses any swap
# that could put secrets on disk (documentation/COMPONENTS.md Section 4.5,
# documentation/ABOUT.md Section 2). No override flag.
/usr/local/sbin/${APP}-secrets-guard check || exit 1

if [ ! -s "\$EDIT_FILE" ]; then
  echo "No edit found at \$EDIT_FILE (or it's empty) -- run ${APP}-secrets-open first." >&2
  exit 1
fi

systemd-creds encrypt --name=${APP}-env "\$EDIT_FILE" "\$BLOB"
shred -u "\$EDIT_FILE"
# Drop the edit tmpfs. On the plain-directory fallback there is nothing to
# unmount, and a busy mount (a shell still inside it) stays until reboot,
# empty; neither is an error.
umount "\$EDIT_DIR" 2>/dev/null || true
rmdir "\$EDIT_DIR" 2>/dev/null || true

systemctl restart ${APP}-secrets.service
"\$GUARD" status /run/${APP}-secrets || true

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
# Check swap only after the host has switched its swap on. Swap units
# (fstab, zram-generator, gpt-auto) are ordered Before=swap.target
# (systemd.swap(5)). Three packaged services run swapon themselves and are
# ordered before nothing: zram-tools' zramswap.service, Ubuntu's
# zram-config.service and dphys-swapfile.service. After= on a unit that is
# not installed does nothing. Swap that anything else switches on later
# is caught only by the next ${APP}-secrets-open or -commit.
After=swap.target zramswap.service zram-config.service dphys-swapfile.service
# The guard lives under /usr/local; wait for it if that is a mount of its own.
RequiresMountsFor=/usr/local/sbin/${APP}-secrets-guard
Before=user@${APP_UID}.service

[Service]
Type=oneshot
RemainAfterExit=yes
LoadCredentialEncrypted=${APP}-env:/etc/credstore.encrypted/${APP}-env
# Keeps the memory of every process in this unit, install copying the
# credential included, out of core dumps (systemd.exec(5); the helper
# scripts explain why ulimit -c 0 would not do).
CoredumpFilter=0
# Hard requirement, not a tunable -- see documentation/COMPONENTS.md Sections
# 4.2 and 4.5 for why. No override: if any active swap could put secrets on
# disk, this unit never writes the .env file, rather than start with the
# guarantee broken. (systemd has already decrypted the credential by then,
# into its own credentials directory on a noswap tmpfs or ramfs.)
ExecStartPre=/usr/local/sbin/${APP}-secrets-guard check
# Give /run/${APP}-secrets its own tmpfs with "noswap" (Linux >= 6.4), so the
# decrypted file can never be paged out, whatever swap is switched on later.
# Reused as is on restart; where noswap is unavailable it warns and keeps
# the plain directory.
ExecStart=/usr/local/sbin/${APP}-secrets-guard mount /run/${APP}-secrets
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
# The plaintext goes into its own noswap tmpfs, like the .env
# (ros_mount_secrets_dir above), never into /dev/shm, which systemd mounts
# without noswap. From here on this shell and everything it starts (nano,
# systemd-creds) keep their memory out of core dumps; the generated
# ${APP}-secrets-open explains why ulimit -c 0 is not enough.
EDIT_DIR="/run/${APP}-secrets-edit"
EDIT_FILE="$EDIT_DIR/env.edit"
if [ -e "/proc/$$/coredump_filter" ]; then echo 0 > "/proc/$$/coredump_filter"; fi
if ! ros_mount_secrets_dir "$EDIT_DIR"; then
  echo "Could not prepare $EDIT_DIR for the plaintext. Nothing was encrypted." >&2
  exit 1
fi
install -d -m 0700 "$EDIT_DIR"
trap 'if [ -e "$EDIT_FILE" ]; then echo "The plaintext is still at $EDIT_FILE -- remove it: shred -u $EDIT_FILE" >&2; fi' EXIT

echo
echo "Opening an editor for your REAL secret values now (KEY=value, one per line)."
echo "Save and exit when done -- in nano, that's Ctrl+O then Enter, then Ctrl+X."
: > "$EDIT_FILE"
chmod 600 "$EDIT_FILE"
nano "$EDIT_FILE"

if [ ! -s "$EDIT_FILE" ]; then
  echo "Nothing was saved -- aborting before encrypting an empty bundle." >&2
  shred -u "$EDIT_FILE"
  umount "$EDIT_DIR" 2>/dev/null || true
  rmdir "$EDIT_DIR" 2>/dev/null || true
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

# umask 077: the blob gets the same mode here as after -secrets-commit.
(umask 077; systemd-creds encrypt --name="${APP}-env" "$EDIT_FILE" "/etc/credstore.encrypted/${APP}-env")
shred -u "$EDIT_FILE"
umount "$EDIT_DIR" 2>/dev/null || true
rmdir "$EDIT_DIR" 2>/dev/null || true
trap - EXIT

# --- 5-6. Enable, start, verify ---
systemctl daemon-reload
systemctl enable --now "${APP}-secrets.service"
systemctl status "${APP}-secrets.service" --no-pager || true
ls -l "/run/${APP}-secrets/.env"
# Own tmpfs with noswap (Section 4.5)? A warning here means the plain
# directory; the unit's journal says why: journalctl -u ${APP}-secrets.service
"$GUARD" status "/run/${APP}-secrets"

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
