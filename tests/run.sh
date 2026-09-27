#!/bin/sh
# tests/run.sh -- tests for the shared swap guard (the ros-lib block inside
# ram-only-secrets-install.sh), run against fixture /proc and /sys trees.
#
# Runs unprivileged, on Linux or macOS, under any POSIX shell:
#   sh tests/run.sh        (also: dash, bash or ksh tests/run.sh)
# Exit status is 0 only if every test passed.
#
# How it fakes a host without root: it cuts the ros-lib block out of the
# installer with the same sed expression the installer uses to generate
# /usr/local/sbin/YOUR_APP-secrets-guard, loads it, points the seven ROS_*
# path variables at a fixture tree, and replaces the five root-only
# wrappers (ros_is_blockdev, ros_stat_devnum, ros_mount_noswap,
# ros_umount, ros_same_mount_ns) plus ros_pause. Everything else runs
# exactly as shipped. A fake device node is a regular file with a
# NODE.devnum sidecar holding "MAJOR MINOR" in hex, the way stat -c
# '%t %T' prints it.
#
# It also renders the installer's generated files (guard, both helper
# scripts, the unit) with sample values and checks them, checks that
# documentation/COMPONENTS.md Section 4.5 prints the guard unchanged, and
# runs shellcheck when it is installed.
# Many patterns below match shell source, "$" included, on purpose.
# shellcheck disable=SC2016
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
INSTALLER=$REPO/ram-only-secrets-install.sh
COMPONENTS=$REPO/documentation/COMPONENTS.md

T=$(mktemp -d "${TMPDIR:-/tmp}/ros-tests.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
trap 'exit 1' INT TERM

pass=0 fail=0 skip=0
ok()     { pass=$((pass + 1)); echo "ok   $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL $1"; printf '     %s\n' "$2"; }
skipped() { skip=$((skip + 1)); echo "skip $1 ($2)"; }

# t NAME RC PATTERN CMD...
# Runs CMD in a subshell. Passes if it exits with RC and its combined
# stdout+stderr matches the case pattern PATTERN ('*' = anything). A
# PATTERN starting with '!' must NOT match.
t() {
  tn=$1 trc=$2 tpat=$3
  shift 3
  ( "$@" ) > "$T/out" 2>&1
  trun=$?
  tout=$(cat "$T/out")
  if [ "$trun" -ne "$trc" ]; then
    not_ok "$tn" "exit $trun, want $trc. Output: $tout"
    return
  fi
  tneg=0
  case "$tpat" in '!'*) tneg=1; tpat=${tpat#!} ;; esac
  # shellcheck disable=SC2254 # $tpat is a pattern on purpose
  case "$tout" in
    $tpat) tm=1 ;;
    *) tm=0 ;;
  esac
  if [ "$tm" -ne "$tneg" ]; then
    ok "$tn"
  else
    not_ok "$tn" "output $( [ "$tneg" = 1 ] && echo 'must not match' || echo 'does not match') '$tpat': $tout"
  fi
}

# expect NAME CONDITION...: plain assertion, CONDITION is a command.
expect() {
  en=$1
  shift
  if "$@"; then ok "$en"; else not_ok "$en" "condition failed: $*"; fi
}

is_root() { [ "$(id -u)" -eq 0 ]; }
not_grep() { ! grep -q "$@"; }
# line_before FILE ERE1 ERE2: the first line matching ERE1 comes before the
# first line matching ERE2, and both exist.
line_before() {
  lb1=$(grep -nE "$2" "$1" | head -n 1 | cut -d: -f1)
  lb2=$(grep -nE "$3" "$1" | head -n 1 | cut -d: -f1)
  [ -n "$lb1" ] && [ -n "$lb2" ] && [ "$lb1" -lt "$lb2" ]
}

# --- Load the ros-lib block, exactly as the installer copies it out ---------

LIB_SED='/^# --- ros-lib begin ---$/,/^# --- ros-lib end ---$/p'
sed -n "$LIB_SED" "$INSTALLER" > "$T/lib.sh"
if ! grep -q '^ros_main()' "$T/lib.sh"; then
  echo "FAIL cannot find the ros-lib block in $INSTALLER" >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$T/lib.sh"

F=$T/fx
ROS_SWAPS=$F/proc/swaps
ROS_DEVICES=$F/proc/devices
ROS_MOUNTINFO=$F/proc/self/mountinfo
ROS_OSRELEASE=$F/proc/sys/kernel/osrelease
ROS_SYS_BLOCK=$F/sys/dev/block
ROS_SYS_KERNEL=$F/sys/kernel
ROS_SYS_POWER=$F/sys/power

ros_is_blockdev() { [ -f "$1" ] && [ -f "$1.devnum" ]; }
ros_stat_devnum() { cat "$1.devnum" 2>/dev/null; }
FAKE_MOUNT=ok
ros_mount_noswap() {
  case $FAKE_MOUNT in
    ok)
      echo "99 25 0:77 / $1 rw,nosuid,nodev,noexec,relatime shared:9 - tmpfs tmpfs rw,size=2048k,nr_inodes=16,mode=700,inode64,noswap" >> "$ROS_MOUNTINFO" ;;
    nonoswap)
      echo "99 25 0:77 / $1 rw,nosuid,nodev,noexec,relatime shared:9 - tmpfs tmpfs rw,size=2048k,nr_inodes=16,mode=700,inode64" >> "$ROS_MOUNTINFO" ;;
    fail)
      echo "mount: $1: permission denied." >&2
      return 32 ;;
  esac
}
ros_umount() {
  grep -F -v " $1 " "$ROS_MOUNTINFO" > "$ROS_MOUNTINFO.new"
  mv "$ROS_MOUNTINFO.new" "$ROS_MOUNTINFO"
}
FAKE_NS=same
ros_same_mount_ns() { [ "$FAKE_NS" = same ]; }
# ros_pause runs PAUSE_HOOK instead of sleeping, so a test can change the
# fixture between the first read and the retry.
PAUSE_HOOK=:
ros_pause() { eval "$PAUSE_HOOK"; }

# --- Fixture builders --------------------------------------------------------

reset() {
  chmod -R u+rwx "$F" 2>/dev/null
  rm -rf "$F"
  mkdir -p "$F/proc/self" "$F/proc/sys/kernel" "$F/sys/dev/block" \
           "$F/sys/kernel" "$F/sys/power" "$F/dev" "$F/run"
  printf 'Character devices:\n  1 mem\n  4 tty\n\nBlock devices:\n  7 loop\n  8 sd\n  9 md\n252 zram\n253 device-mapper\n259 blkext\n' > "$ROS_DEVICES"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n' > "$ROS_SWAPS"
  printf '25 30 0:23 / /run rw,nosuid,nodev,noexec,relatime shared:5 - tmpfs tmpfs rw,size=816856k,mode=755,inode64\n' > "$ROS_MOUNTINFO"
  echo 7.0.0-34-generic > "$ROS_OSRELEASE"
  echo 'freeze mem' > "$ROS_SYS_POWER/state"
  echo 0:0 > "$ROS_SYS_POWER/resume"
}

# node NAME MAJOR_HEX MINOR_HEX: fake block device node $F/dev/NAME.
node() { : > "$F/dev/$1"; echo "$2 $3" > "$F/dev/$1.devnum"; }

# swapline PATH TYPE: one /proc/swaps entry, laid out like the kernel's
# (name padded to 40 columns, at least one space; mm/swapfile.c:2999-3006).
swapline() {
  sp=$1
  while [ ${#sp} -lt 40 ]; do sp="$sp "; done
  [ ${#1} -ge 40 ] && sp="$sp "
  if [ "$2" = file ]; then
    printf '%sfile\t\t8388604\t\t0\t\t-2\n' "$sp" >> "$ROS_SWAPS"
  else
    printf '%s%s\t8388604\t\t0\t\t100\n' "$sp" "$2" >> "$ROS_SWAPS"
  fi
}

# zram N BACKING: zram device N (major 252 = 0xfc) with its sysfs
# attributes, swapped on. BACKING is backing_dev's content, or "-" for a
# kernel built with CONFIG_ZRAM_WRITEBACK=n (no attribute at all).
zram() {
  node "zram$1" fc "$(printf %x "$1")"
  zd=$ROS_SYS_BLOCK/252:$1
  mkdir -p "$zd"
  echo 4294967296 > "$zd/disksize"
  [ "$2" = - ] || echo "$2" > "$zd/backing_dev"
  swapline "$F/dev/zram$1" partition
}

# disk NAME MAJOR_HEX MINOR_HEX: a non-zram block device, swapped on.
disk() {
  node "$1" "$2" "$3"
  mkdir -p "$ROS_SYS_BLOCK/$((0x$2)):$((0x$3))"
  swapline "$F/dev/$1" partition
}

kdump_old() { echo "$1" > "$ROS_SYS_KERNEL/kexec_crash_loaded"; echo "$2" > "$ROS_SYS_KERNEL/kexec_crash_size"; }
kdump_new() {
  mkdir -p "$ROS_SYS_KERNEL/kexec"
  echo "$1" > "$ROS_SYS_KERNEL/kexec/crash_loaded"
  echo "$2" > "$ROS_SYS_KERNEL/kexec/crash_size"
}
hibernation() { echo 'freeze mem disk' > "$ROS_SYS_POWER/state"; echo "$1" > "$ROS_SYS_POWER/resume"; }

echo "# swap rules"

reset
t "no swap: header line only" 0 "*swap check passed: no active swap*" ros_guard

reset; rm "$ROS_SWAPS"
t "no /proc/swaps while /proc is there (CONFIG_SWAP=n)" 0 "*without swap support*" ros_guard

reset; rm "$ROS_SWAPS" "$ROS_DEVICES"
t "no /proc at all fails closed" 1 "*is /proc mounted*" ros_guard

if is_root; then
  skipped "unreadable /proc/swaps fails closed" "root can read mode 000"
else
  reset; chmod 000 "$ROS_SWAPS"
  t "unreadable /proc/swaps fails closed" 1 "*cannot read*swaps*" ros_guard
fi

reset; printf 'Name Kind\n' > "$ROS_SWAPS"
t "unexpected header line" 1 "*unexpected first line*" ros_guard

reset; : > "$ROS_SWAPS"
t "empty /proc/swaps" 1 "*unexpected first line*" ros_guard

reset; zram 0 none
t "zram only, backing_dev none" 0 "*zram only, without a writeback device:*zram0*" ros_guard

reset; zram 0 /dev/sda5
t "zram with writeback backing device" 1 "*writeback backing device '/dev/sda5'*" ros_guard

reset; zram 0 -
t "zram, writeback compiled out (no backing_dev attr)" 0 "*zram only*" ros_guard

if is_root; then
  skipped "unreadable backing_dev fails closed" "root can read mode 000"
else
  reset; zram 0 none; chmod 000 "$ROS_SYS_BLOCK/252:0/backing_dev"
  t "unreadable backing_dev fails closed" 1 "*cannot read*backing_dev*" ros_guard
fi

reset; zram 0 none; rm -r "$ROS_SYS_BLOCK/252:0"
t "zram major but no zram sysfs attributes" 1 "*no zram attributes*" ros_guard

reset; zram 0 none; zram 1 none
t "two zram devices, both without backing" 0 "*zram0*zram1*" ros_guard

reset; zram 0 none; zram 1 /dev/nvme0n1p3
t "second zram has a backing device" 1 "*zram1*writeback backing device*" ros_guard

reset; swapline /swap.img file
t "swap file" 1 "*swap file '/swap.img'*on disk*" ros_guard

reset; disk sda2 8 2
t "disk partition" 1 "*sda2' [(]8:2[)] is not a zram device*" ros_guard

reset; disk dm-1 fd 1
t "dm-crypt / LVM swap (major 253)" 1 "*[(]253:1[)] is not a zram device*" ros_guard

reset; zram 0 none; disk sda2 8 2
t "mixed: zram, then disk partition" 1 "*sda2*not a zram device*" ros_guard

reset; disk sda2 8 2; zram 0 none
t "mixed: disk partition, then zram" 1 "*sda2*not a zram device*" ros_guard

reset; zram 0 none; swapline /swap.img file
t "mixed: zram and swap file" 1 "*swap file*" ros_guard

reset; node zram9 8 3; mkdir -p "$ROS_SYS_BLOCK/8:3"; echo 1 > "$ROS_SYS_BLOCK/8:3/disksize"
swapline "$F/dev/zram9" partition
t "odd name: node called zram9 but major 8" 1 "*zram9' [(]8:3[)] is not a zram device*" ros_guard

reset; node myswap fc 0; mkdir -p "$ROS_SYS_BLOCK/252:0"; echo none > "$ROS_SYS_BLOCK/252:0/backing_dev"
swapline "$F/dev/myswap" partition
t "odd name: zram node under another name is identified by major" 0 "*zram only*myswap*" ros_guard

reset; zram 0 none; mkdir -p "$F/dev/a-rather-long-directory-name-for-this-test"
node a-rather-long-directory-name-for-this-test/zram1 fc 1
mkdir -p "$ROS_SYS_BLOCK/252:1"; echo none > "$ROS_SYS_BLOCK/252:1/backing_dev"
swapline "$F/dev/a-rather-long-directory-name-for-this-test/zram1" partition
t "odd name: path longer than 40 columns" 0 "*zram only*" ros_guard

reset; swapline '/dev/my\040swap' partition
t "odd name: escaped space in path" 1 "*escaped characters*" ros_guard

reset; zram 0 none
printf '%s\\040(deleted)                  partition\t8388604\t\t0\t\t100\n' "$F/dev/zram1" >> "$ROS_SWAPS"
t "odd name: deleted node" 1 "*escaped characters*" ros_guard

reset; swapline "$F/dev/zram3" partition
t "odd name: node not visible here (private /dev)" 1 "*not a block device visible*" ros_guard

reset; : > "$F/dev/imposter"; swapline "$F/dev/imposter" partition
t "odd name: regular file listed as partition" 1 "*not a block device visible*" ros_guard

reset; swapline none virtual
t "unknown type (lxcfs 'virtual')" 1 "*type 'virtual'*" ros_guard

reset; zram 0 none; printf 'Block devices:\n  8 sd\n' > "$ROS_DEVICES"
t "zram module not in /proc/devices" 1 "*not a zram device*" ros_guard

reset; zram 0 none; printf 'Block devices:\nfc zram\n' > "$ROS_DEVICES"
t "garbled zram line in /proc/devices" 1 "*not a zram device*" ros_guard

reset; zram 0 none; echo "zz 0" > "$F/dev/zram0.devnum"
t "device number not hex" 1 "*device number*" ros_guard
reset; zram 0 none; : > "$F/dev/zram0.devnum"
t "no device number at all (stat missing?) names stat" 1 "*device number*is stat*installed*" ros_guard

reset; zram 0 none; echo "fc" > "$F/dev/zram0.devnum"
t "device number with one word" 1 "*device number*" ros_guard

reset; zram 0 none; echo "fc 0:1" > "$F/dev/zram0.devnum"
t "device number with extra colon" 1 "*device number*" ros_guard

reset; node sda2 8 2; mkdir -p "$ROS_SYS_BLOCK/8:2"
printf '%s    partition\t8388604\t0\t-2' "$F/dev/sda2" >> "$ROS_SWAPS"
t "last line without trailing newline is still checked" 1 "*not a zram device*" ros_guard

reset; zram 0 none; zram 1 none; zram 2 none; disk sda2 8 2
t "fourth of four entries is still checked" 1 "*sda2*not a zram device*" ros_guard
# A seq_file restarts its listing on every read(2) that finds its buffer
# empty; parsing the file line by line with the shell's read would give a
# concurrent swapoff room to hide an entry (see the comment in the lib).
expect "/proc/swaps is read once into a variable, not line by line" \
  grep -qF 'ros_swaps=$(cat "$ROS_SWAPS"' "$T/lib.sh"
expect "no loop reads /proc/swaps directly" not_grep -F '} < "$ROS_SWAPS"' "$T/lib.sh"
# A here-document the shell cannot set up runs nothing and would pass.
expect "a failed here-document refuses instead of passing" \
  grep -qF '} <<ROS_SWAPS_EOF || { ros_say "could not parse the copy of $ROS_SWAPS. Refusing."; return 1; }' "$T/lib.sh"

echo "# kdump"

reset
t "kdump attributes absent (CONFIG_CRASH_DUMP=n)" 1 "*" ros_kdump_armed
reset; kdump_old 0 0
t "kdump not armed (6.x layout)" 1 "*" ros_kdump_armed
reset; kdump_old 0 536870912
t "crashkernel= memory reserved" 0 "*" ros_kdump_armed
reset; kdump_old 1 536870912
t "crash kernel loaded" 0 "*" ros_kdump_armed
reset; kdump_new 0 0; echo 1 > "$ROS_SYS_KERNEL/kexec_crash_loaded"
t "7.0 layout wins over compat links" 1 "*" ros_kdump_armed
reset; kdump_new 1 0
t "7.0 layout, loaded" 0 "*" ros_kdump_armed
reset; kdump_new 0 268435456
t "7.0 layout, reserved only" 0 "*" ros_kdump_armed
reset; kdump_new 0 0; rm "$ROS_SYS_KERNEL/kexec/crash_size"
t "7.0 layout, size missing counts as armed" 0 "*" ros_kdump_armed
reset; kdump_new garbage 0
t "garbled crash_loaded counts as armed" 0 "*" ros_kdump_armed
reset; kdump_old 0 12x
t "garbled crash_size counts as armed" 0 "*" ros_kdump_armed
if is_root; then
  skipped "crash_size busy once, then readable" "root can read mode 000"
  skipped "crash_size busy twice counts as armed" "root can read mode 000"
else
  # crash_size returns EBUSY while the kexec lock is taken; one retry.
  reset; kdump_new 0 0; chmod 000 "$ROS_SYS_KERNEL/kexec/crash_size"
  PAUSE_HOOK='chmod 644 "$ROS_SYS_KERNEL/kexec/crash_size"'
  t "crash_size busy once, then readable: not armed" 1 "*" ros_kdump_armed
  reset; kdump_new 0 0; chmod 000 "$ROS_SYS_KERNEL/kexec/crash_size"
  PAUSE_HOOK=:
  t "crash_size busy twice counts as armed, and says so" 0 "*cannot read*crash_size*EBUSY*" ros_kdump_armed
fi
PAUSE_HOOK=:

reset; kdump_old 1 536870912
t "guard: no swap + kdump armed (unchanged: allowed)" 0 "*no active swap*" ros_guard
reset; zram 0 none; kdump_old 1 536870912
t "guard: zram + crash kernel loaded" 1 "*kdump is armed*crashkernel=*" ros_guard
reset; zram 0 none; kdump_new 0 536870912
t "guard: zram + crashkernel= reserved" 1 "*kdump is armed*" ros_guard
reset; zram 0 none; kdump_new 0 0
t "guard: zram + kdump off" 0 "*zram only*" ros_guard

echo "# hibernation (information only)"

reset; zram 0 none; hibernation 0:0
t "zram + hibernation, no resume device" 0 "!*hibernat*" ros_guard
reset; zram 0 none; hibernation 252:0
t "zram + resume configured on the zram device" 0 "!*hibernat*" ros_guard
reset; zram 0 none; hibernation 8:3
t "zram + resume configured on an inactive disk" 0 "*note: hibernation*8:3*zram only*" ros_guard
reset; hibernation 8:3
t "no swap + resume configured on a disk" 0 "*note: hibernation*8:3*" ros_guard
reset; zram 0 none; echo 8:3 > "$ROS_SYS_POWER/resume"
t "resume configured but hibernation unavailable" 0 "!*hibernat*" ros_guard
reset; zram 0 none; hibernation 8:3; disk sda3 8 3
t "zram + resume on a disk that is active swap" 1 "*sda3*not a zram device*" ros_guard

echo "# kernel version (tmpfs noswap needs >= 6.4)"

for kv in 7.0.0-34-generic:0 6.8.0-146-generic:0 6.12.107+deb13-amd64:0 6.4.0:0 \
          6.10.3-arch1-1:0 6.3.13:1 6.1.0-40-amd64:1 5.15.0-100-generic:1 garbage:1 :1; do
  reset; echo "${kv%:*}" > "$ROS_OSRELEASE"
  t "noswap support for kernel '${kv%:*}'" "${kv##*:}" "*" ros_kernel_has_tmpfs_noswap
done
reset; rm "$ROS_OSRELEASE"
t "noswap support when osrelease is unreadable" 1 "*" ros_kernel_has_tmpfs_noswap

echo "# noswap mount of the secrets directory"

D=$F/run/myapp-secrets
lines_at() { grep -c " $1 " "$ROS_MOUNTINFO"; }

reset; FAKE_MOUNT=ok
t "fresh mount on 7.0" 0 "*mounted a noswap tmpfs on*" ros_mount_secrets_dir "$D"
expect "fresh mount: exactly one mount at the directory" [ "$(lines_at "$D")" = 1 ]
t "restart reuses the existing noswap tmpfs" 0 "*already a noswap tmpfs; reusing it*" ros_mount_secrets_dir "$D"
expect "restart: still exactly one mount, nothing stacked" [ "$(lines_at "$D")" = 1 ]

reset; FAKE_MOUNT=ok; mkdir -p "$D"; echo 'OLD=plaintext' > "$D/.env"
t "migration from the plain-directory layout" 0 "*mounted a noswap tmpfs*" ros_mount_secrets_dir "$D"
expect "migration: old .env on /run's shared tmpfs is deleted first" [ ! -e "$D/.env" ]

reset; echo "90 25 0:50 / $D rw,relatime shared:44 - tmpfs tmpfs rw,size=1024k,inode64" >> "$ROS_MOUNTINFO"
t "existing tmpfs without noswap is refused" 1 "*not a noswap tmpfs*nothing was written*" ros_mount_secrets_dir "$D"

reset; echo "90 25 8:1 / $D rw,relatime shared:44 - ext4 /dev/sda1 rw" >> "$ROS_MOUNTINFO"
t "existing ext4 mount is refused" 1 "*[(]ext4: rw[)] but not a noswap tmpfs*" ros_mount_secrets_dir "$D"

reset
echo "90 25 0:50 / $D rw,relatime shared:44 - tmpfs tmpfs rw,size=2048k,inode64,noswap" >> "$ROS_MOUNTINFO"
echo "91 90 0:51 / $D rw,relatime shared:45 - tmpfs tmpfs rw,size=2048k,inode64,noswap" >> "$ROS_MOUNTINFO"
t "stacked mounts are refused" 1 "*2 mounts stacked*" ros_mount_secrets_dir "$D"

reset; echo "90 25 0:50 / $D-old rw,relatime shared:44 - tmpfs tmpfs rw,inode64,noswap" >> "$ROS_MOUNTINFO"
FAKE_MOUNT=ok
t "a noswap tmpfs at a similar path does not count" 0 "*mounted a noswap tmpfs*" ros_mount_secrets_dir "$D"

reset; echo 6.1.0-40-amd64 > "$ROS_OSRELEASE"; mkdir -p "$D"; echo 'OLD=x' > "$D/.env"
t "kernel 6.1: warn, keep plain directory" 0 "*predates tmpfs noswap*" ros_mount_secrets_dir "$D"
expect "kernel 6.1: nothing mounted" [ "$(lines_at "$D")" = 0 ]

reset; zram 0 none; echo 6.1.0-40-amd64 > "$ROS_OSRELEASE"
t "kernel 6.1 with zram swap: warn, keep plain directory (R9)" 0 "*predates tmpfs noswap*" ros_mount_secrets_dir "$D"

reset; FAKE_MOUNT=fail
t "mount refused (e.g. unprivileged container): warn, plain directory" 0 "*permission denied*could not mount a noswap tmpfs*" ros_mount_secrets_dir "$D"
expect "mount refused: nothing mounted" [ "$(lines_at "$D")" = 0 ]

reset; FAKE_MOUNT=nonoswap
t "mount without noswap in mountinfo is refused" 1 "*does not report noswap*Unmounted*" ros_mount_secrets_dir "$D"
expect "mount without noswap: it was unmounted again" [ "$(lines_at "$D")" = 0 ]

reset
t "relative directory is rejected" 2 "*absolute directory*" ros_mount_secrets_dir run/myapp-secrets

reset; FAKE_NS=other; mkdir -p "$D"; echo 'OLD=plaintext' > "$D/.env"
t "private mount namespace is refused" 1 "*not run in PID 1's mount namespace*nothing was written*" ros_mount_secrets_dir "$D"
expect "private mount namespace: the host's .env is left alone" [ -e "$D/.env" ]
expect "private mount namespace: nothing mounted" [ "$(lines_at "$D")" = 0 ]
FAKE_NS=same

echo "# status (warns, never refuses)"

reset; FAKE_MOUNT=ok; ros_mount_secrets_dir "$D" > /dev/null 2>&1
t "status: noswap tmpfs" 0 "*is a noswap tmpfs.*" ros_noswap_status "$D"
reset; mkdir -p "$D"
t "status: plain directory on 7.0 warns" 0 "*warning:*not a noswap tmpfs*" ros_noswap_status "$D"
reset; echo "90 25 0:50 / $D rw,relatime shared:44 - tmpfs tmpfs rw,size=1024k,inode64" >> "$ROS_MOUNTINFO"
t "status: tmpfs without noswap warns" 0 "*warning:*not a noswap tmpfs*" ros_noswap_status "$D"
reset; echo 6.1.0-40-amd64 > "$ROS_OSRELEASE"; mkdir -p "$D"
t "status: plain directory on 6.1 is expected" 0 "!*warning*" ros_noswap_status "$D"
reset; echo 6.1.0-40-amd64 > "$ROS_OSRELEASE"
echo "90 25 0:50 / $D rw,relatime shared:44 - tmpfs tmpfs rw,size=1024k,inode64" >> "$ROS_MOUNTINFO"
t "status: foreign mount on 6.1 warns without claiming noswap support" 0 "*warning:*predates noswap*" ros_noswap_status "$D"
if is_root; then
  skipped "status: unreadable mountinfo warns" "root can read mode 000"
else
  reset; chmod 000 "$ROS_MOUNTINFO"
  t "status: unreadable mountinfo warns" 0 "*warning: cannot read*" ros_noswap_status "$D"
fi

if is_root; then
  skipped "unreadable mountinfo fails closed" "root can read mode 000"
else
  reset; chmod 000 "$ROS_MOUNTINFO"
  t "unreadable mountinfo fails closed" 1 "*cannot read*mountinfo*" ros_mount_secrets_dir "$D"
fi
FAKE_MOUNT=ok

echo "# entry point (no override flags)"

reset
t "no argument means check" 0 "*swap check passed*" ros_main
reset; disk sda2 8 2
t "check refuses and says nothing changed" 1 "*not a zram device*No override exists. Nothing was changed.*" ros_main check
reset
t "check takes no extra arguments" 2 "*usage*" ros_main check --force
t "unknown subcommand (no --force or similar)" 2 "*usage*" ros_main --force
t "mount without a directory" 2 "*usage*" ros_main mount
t "status without a directory" 2 "*usage*" ros_main status
reset
t "mount subcommand" 0 "*mounted a noswap tmpfs*" ros_main mount "$D"
t "status subcommand" 0 "*is a noswap tmpfs*" ros_main status "$D"

echo "# generated files"

# The installer and this file must cut the block out the same way.
expect "installer generates the guard with the same sed expression" \
  grep -qF "  sed -n '$LIB_SED' \"\$2\"" "$INSTALLER"
expect "lib assigns exactly the seven ROS_* paths replaced above" \
  [ "$(grep -c '^ROS_[A-Z_]*=/' "$T/lib.sh")" = 7 ]
# Any ${ROS_...} expansion (e.g. ${ROS_SWAPS:-/proc/swaps}) would let the
# environment redirect a real run: an override flag by another name.
expect "lib reads no ROS_* path from the environment" \
  not_grep '[$]{ROS_' "$T/lib.sh"
# The mount wrapper is replaced above, so check its option string here.
expect "the real mount asks for noswap" grep -q 'mount -t tmpfs -o noswap,' "$T/lib.sh"
expect "the real namespace check compares with PID 1" grep -qF 'readlink /proc/1/ns/mnt' "$T/lib.sh"
expect "the real namespace check compares both links" \
  grep -qF '[ -n "$ros_ns_self" ] && [ "$ros_ns_self" = "$ros_ns_init" ]' "$T/lib.sh"

ros_render_guard YOUR_APP-secrets-guard "$INSTALLER" > "$T/guard"
expect "rendered guard passes sh -n" sh -n "$T/guard"
expect "rendered guard ends by calling ros_main" [ "$(tail -n 1 "$T/guard")" = 'ros_main "$@"' ]
t "rendered guard runs standalone: bad subcommand" 2 "*usage*" sh "$T/guard" --force
# On a real host this checks the real /proc; only the exit status is fixed.
sh "$T/guard" check > "$T/out" 2>&1
grc=$?
expect "rendered guard runs standalone against this host (exit $grc)" [ "$grc" -le 1 ]

awk '/^<!-- ros-guard: begin -->$/ {f=1; next} /^<!-- ros-guard: end -->$/ {f=0} f' "$COMPONENTS" |
  sed '1{/^```/d;}' | sed '${/^```/d;}' > "$T/guard.doc"
expect "COMPONENTS.md Section 4.5 prints the guard unchanged" cmp -s "$T/guard" "$T/guard.doc"

# The manual copy command in INSTALLATION-AND-OPERATION.md Section 5.4,
# run as printed (target path swapped for a scratch file), must produce the
# same block.
awk '/^\{ echo .#!\/bin\/sh.$/ {f=1} f {print} f && /> \/usr\/local\/sbin\/YOUR_APP-secrets-guard$/ {exit}' \
  "$REPO/documentation/INSTALLATION-AND-OPERATION.md" |
  sed "s#> /usr/local/sbin/YOUR_APP-secrets-guard\$#> \"$T/guard.manual\"#" > "$T/manual.sh"
( cd "$REPO" && sh "$T/manual.sh" )
expect "manual copy command from Section 5.4 yields a valid guard" sh -n "$T/guard.manual"
sed '1d;$d' "$T/guard.manual" > "$T/guard.manual.body"
expect "manual copy command from Section 5.4 copies the block unchanged" \
  cmp -s "$T/lib.sh" "$T/guard.manual.body"

# render START END OUT: expand one of the installer's heredocs with sample
# values, the same way the installer does at install time.
render() {
  {
    echo "APP=${RENDER_APP:-myapp} APP_USER=myuser APP_UID=1001 APP_HOME=/home/myuser"
    echo "cat <<$2"
    awk -v s="$1" -v e="$2" 'f && $0 == e {exit} f {print} $0 == s {f=1}' "$INSTALLER"
    echo "$2"
  } > "$T/render.sh"
  sh "$T/render.sh" > "$3"
}
# shellcheck disable=SC2016 # the installer's own heredoc lines, verbatim
render 'cat > "/usr/local/sbin/${APP}-secrets-open" <<SCRIPT_EOF' SCRIPT_EOF "$T/open"
# shellcheck disable=SC2016
render 'cat > "/usr/local/sbin/${APP}-secrets-commit" <<SCRIPT_EOF' SCRIPT_EOF "$T/commit"
# shellcheck disable=SC2016
render 'cat > "/etc/systemd/system/${APP}-secrets.service" <<UNIT_EOF' UNIT_EOF "$T/unit"

# COMPONENTS.md Section 4.4 prints both helper scripts as generated for
# APP=YOUR_APP; keep the two from drifting apart.
# shellcheck disable=SC2016
RENDER_APP=YOUR_APP render 'cat > "/usr/local/sbin/${APP}-secrets-open" <<SCRIPT_EOF' SCRIPT_EOF "$T/open.yours"
# shellcheck disable=SC2016
RENDER_APP=YOUR_APP render 'cat > "/usr/local/sbin/${APP}-secrets-commit" <<SCRIPT_EOF' SCRIPT_EOF "$T/commit.yours"
for h in open commit; do
  awk -v b="<!-- helper-$h: begin -->" -v e="<!-- helper-$h: end -->" \
    '$0 == b {f=1; next} $0 == e {f=0} f' "$COMPONENTS" |
    sed '1{/^```/d;}' | sed '${/^```/d;}' > "$T/$h.doc"
  expect "COMPONENTS.md Section 4.4 prints -secrets-$h as generated" cmp -s "$T/$h.yours" "$T/$h.doc"
done

for h in open commit; do
  expect "rendered -secrets-$h passes sh -n" sh -n "$T/$h"
  expect "rendered -secrets-$h calls the guard and stops on refusal" \
    grep -qxF '/usr/local/sbin/myapp-secrets-guard check || exit 1' "$T/$h"
  expect "rendered -secrets-$h clears coredump_filter before the guard runs" \
    line_before "$T/$h" '^if \[ -e /proc/[$][$]/coredump_filter \]; then echo 0 > /proc/[$][$]/coredump_filter; fi$' \
                        '^/usr/local/sbin/myapp-secrets-guard check'
  expect "rendered -secrets-$h keeps the edit copy on the edit tmpfs" \
    grep -qx 'EDIT_FILE=/run/myapp-secrets-edit/env.edit' "$T/$h"
  expect "rendered -secrets-$h reports the .env's noswap status" \
    grep -qxF '"$GUARD" status /run/myapp-secrets || true' "$T/$h"
done
expect "rendered -secrets-open mounts the edit tmpfs before copying" \
  line_before "$T/open" '^"[$]GUARD" mount "[$]EDIT_DIR" [|][|] exit 1$' '^  cp "[$]RUNNING_ENV"'
expect "rendered -secrets-open refuses a leftover /dev/shm edit" \
  line_before "$T/open" '^if \[ -e "[$]OLD_EDIT_FILE" \]' '^"[$]GUARD" mount'
sh -c "$(grep -E '^EDIT_FILE=|sudo sh -c' "$T/open")" > "$T/out" 2>&1
expect "rendered -secrets-open prints a single-quoted editor command" \
  grep -qxF "  sudo sh -c 'echo 0 > /proc/\$\$/coredump_filter && exec nano /run/myapp-secrets-edit/env.edit'" "$T/out"
expect "rendered -secrets-commit names leftover plaintext on any early exit" \
  line_before "$T/commit" '^trap .*shred -u' '^/usr/local/sbin/myapp-secrets-guard check'
expect "rendered -secrets-commit unmounts the edit tmpfs after shred" \
  line_before "$T/commit" '^shred -u "[$]EDIT_FILE"$' '^umount "[$]EDIT_DIR" 2>/dev/null [|][|] true$'
expect "rendered -secrets-commit survives the plain-directory fallback" \
  grep -qxF 'umount "$EDIT_DIR" 2>/dev/null || true' "$T/commit"
expect "rendered -secrets-commit unmounts before restarting the unit" \
  line_before "$T/commit" '^umount ' '^systemctl restart '
expect "no generated file edits in /dev/shm any more" \
  not_grep -E '^EDIT_FILE=/dev/shm|nano "?/dev/shm' "$T/open" "$T/commit" "$INSTALLER"
expect "unit orders itself after swap.target and the swapon services" \
  grep -qx 'After=swap.target zramswap.service zram-config.service dphys-swapfile.service' "$T/unit"
expect "unit waits for the guard's mount" \
  grep -qx 'RequiresMountsFor=/usr/local/sbin/myapp-secrets-guard' "$T/unit"
expect "unit clears coredump_filter" grep -qx 'CoredumpFilter=0' "$T/unit"
expect "unit runs the guard as ExecStartPre" \
  grep -qx 'ExecStartPre=/usr/local/sbin/myapp-secrets-guard check' "$T/unit"
expect "unit mounts the noswap tmpfs before writing .env" \
  line_before "$T/unit" '^ExecStart=/usr/local/sbin/myapp-secrets-guard mount /run/myapp-secrets$' \
                        '^ExecStart=/bin/sh -c .install -d '
# Settings that give a unit its own mount namespace (systemd v259
# src/core/execute.c:259-346, exec_needs_mount_namespace()).
expect "unit has no private mount namespace (the mount must reach the host)" \
  not_grep -E '^(PrivateMounts|ProtectSystem|ProtectHome|PrivateTmp|PrivateDevices|PrivateIPC|PrivateNetwork|PrivatePIDs|NetworkNamespacePath|IPCNamespacePath|TemporaryFileSystem|RuntimeDirectory|StateDirectory|CacheDirectory|LogsDirectory|ConfigurationDirectory|ReadOnlyPaths|ReadWritePaths|InaccessiblePaths|ExecPaths|NoExecPaths|BindPaths|BindReadOnlyPaths|MountImages|ExtensionImages|ExtensionDirectories|RootDirectory|RootImage|ProtectKernelTunables|ProtectKernelModules|ProtectKernelLogs|ProtectControlGroups|ProtectClock|ProtectHostname|ProtectProc|ProcSubset|MountFlags|MountAPIVFS|BPFFilesystem|PrivateUsers)=' "$T/unit"
expect "no copy of the old 'wc -l < /proc/swaps' test is left" \
  not_grep -F 'wc -l < /proc/swaps' "$INSTALLER"
expect "installer checks swap before it writes any file" \
  line_before "$INSTALLER" '^if ! ros_guard; then$' '> "(/usr/local/sbin|/etc/systemd|[$]GUARD|[$]EDIT_FILE|/run/)'
expect "installer clears its own coredump_filter before nano" \
  line_before "$INSTALLER" '^if \[ -e "/proc/[$][$]/coredump_filter" \]' '^nano "[$]EDIT_FILE"$'
expect "installer mounts the edit tmpfs before the plaintext is written" \
  line_before "$INSTALLER" '^if ! ros_mount_secrets_dir "[$]EDIT_DIR"; then$' '^: > "[$]EDIT_FILE"$'
expect "installer unmounts the edit tmpfs without dying on the fallback" \
  grep -qxF 'umount "$EDIT_DIR" 2>/dev/null || true' "$INSTALLER"
expect "rendered guard documents all three subcommands" \
  grep -qF '# Usage: YOUR_APP-secrets-guard check | YOUR_APP-secrets-guard mount DIRECTORY | YOUR_APP-secrets-guard status DIRECTORY' "$T/guard"

echo "# syntax and lint"

for s in sh dash bash ksh; do
  if command -v "$s" >/dev/null 2>&1; then
    for f in "$INSTALLER" "$HERE/run.sh" "$T/guard" "$T/open" "$T/commit"; do
      expect "$s -n ${f##*/}" "$s" -n "$f"
    done
  else
    skipped "$s -n" "$s not installed"
  fi
done
if command -v shellcheck >/dev/null 2>&1; then
  for f in "$INSTALLER" "$HERE/run.sh" "$T/guard" "$T/open" "$T/commit"; do
    if shellcheck -s sh "$f" > "$T/sc" 2>&1; then
      ok "shellcheck ${f##*/}"
    else
      not_ok "shellcheck ${f##*/}" "$(cat "$T/sc")"
    fi
  done
else
  skipped "shellcheck" "not installed"
fi

echo "passed=$pass failed=$fail skipped=$skip"
[ "$fail" -eq 0 ]
