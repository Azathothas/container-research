#!/bin/sh
# Reconstruct the target's mount topology, then hand off to confine.
#
# Runs as pid 1 of a privileged container. Everything here needs mount(2),
# which is exactly what the reconstructed runtime will not have — so it all
# happens before the confinement is applied, and none of it is reachable from
# inside.
#
# The shape comes from verification/real/mountinfo.txt: a tmpfs root owned by
# uid 1000, a 64 MiB tmpfs /tmp, a 256 MiB /dev/shm, six bind-mounted device
# nodes and no others, /usr /lib /lib64 /bin /sbin from the host filesystem,
# a handful of individual /etc files, /proc, and two large writable trees at
# /workspace and /state. Notably absent, and absent on the target: /etc/passwd,
# /run, /var, /dev/fuse, /dev/ptmx, /sys.
#
# Exit codes: 0 ran, 1 the payload failed, 2 could not run.
set -eu

R=/target
HOST_UID="${TARGET_HOST_UID:-1000}"

die() { echo "targetfs: $*" >&2; exit 2; }

mountpoint -q / 2>/dev/null || true
[ "$(id -u)" = 0 ] || die "must start as root (privileged container)"
mount -t tmpfs -o mode=755,uid="$HOST_UID",gid="$HOST_UID" tmpfs "$R" 2>/dev/null \
  || die "cannot mount tmpfs; run the container with --privileged"

# ---------------------------------------------------------------- skeleton
# Only what the target has. Creating /run or /var here would quietly repair
# the very absence half the paper's failures depend on.
mkdir -p "$R"/tmp "$R"/dev "$R"/dev/shm "$R"/etc "$R"/proc \
         "$R"/usr "$R"/lib "$R"/lib64 "$R"/bin "$R"/sbin \
         "$R"/workspace "$R"/state "$R"/home

# / itself is uid-1000-owned but *not* writable on the target: that is
# mechanism M, applied later. The tmpfs mode below matches the target's 755.

mount -t tmpfs -o size=65536k,uid="$HOST_UID",gid="$HOST_UID" tmpfs "$R"/tmp
mount -t tmpfs -o size=262144k,uid="$HOST_UID",gid="$HOST_UID" tmpfs "$R"/dev/shm
chmod 1777 "$R"/tmp "$R"/dev/shm

# ---------------------------------------------------------------- system tree
for d in usr lib lib64; do
	[ -d "/$d" ] || continue
	mount --bind "/$d" "$R/$d"
done
# The target's /bin and /sbin are both binds of /usr/bin, not symlinks.
mount --bind /usr/bin "$R"/bin
mount --bind /usr/bin "$R"/sbin

# ---------------------------------------------------------------- /etc
# Individually bind-mounted files, exactly as the target does it — which is
# why /etc as a whole has no passwd, group or shadow. getpwuid(0) failing is a
# load-bearing property (paper §8.4 field guide, udocker and treesandbox both
# die on it), so it must not be repaired by copying a whole /etc.
for f in ca-certificates.conf ld.so.cache ld.so.conf nsswitch.conf \
         protocols services resolv.conf; do
	[ -f "/etc/$f" ] || continue
	: > "$R/etc/$f"
	mount --bind "/etc/$f" "$R/etc/$f"
done
[ -d /etc/ld.so.conf.d ] && mkdir -p "$R"/etc/ld.so.conf.d && mount --bind /etc/ld.so.conf.d "$R"/etc/ld.so.conf.d
[ -d /etc/ssl ] && mkdir -p "$R"/etc/ssl && mount --bind /etc/ssl "$R"/etc/ssl

# ---------------------------------------------------------------- devices
# Six nodes, bind-mounted from the host's devtmpfs. mknod(2) is denied inside,
# so anything not bound here cannot be created there: no /dev/fuse (which is
# why every FUSE path in the paper is unreachable), no /dev/ptmx (which is why
# PTY allocation is unavailable), no /dev/pts.
for n in null zero full random urandom tty; do
	[ -e "/dev/$n" ] || continue
	: > "$R/dev/$n"
	mount --bind "/dev/$n" "$R/dev/$n"
done

mount -t proc proc "$R"/proc

# ---------------------------------------------------------------- writable
# /workspace and /state are the target's two large writable non-tmpfs trees.
# A bind of a host directory keeps them out of the root tmpfs, as there.
[ -n "${TARGET_WORKSPACE:-}" ] && [ -d "${TARGET_WORKSPACE}" ] && \
	mount --bind "${TARGET_WORKSPACE}" "$R"/workspace
chown "$HOST_UID:$HOST_UID" "$R"/workspace "$R"/state 2>/dev/null || true

# ---------------------------------------------------------------- pivot
mkdir -p "$R"/.oldroot
cd "$R"
pivot_root . .oldroot
umount -l /.oldroot
rmdir /.oldroot 2>/dev/null || true

# The confine binary and the probes are staged into /workspace by
# 20-enter-target.sh before this script runs.
exec /workspace/.harness/enter.sh "$@"
