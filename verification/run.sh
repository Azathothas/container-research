#!/usr/bin/env bash
# Reproduce every empirical claim in paper_final.md.
#
# The target runtime is modelled out of two independent mechanisms — a user
# namespace with a partial ID map, and a seccomp filter — so that each observed
# denial can be attributed to the one that actually produces it. Sections are
# selectable:
#
#   ./run.sh                 everything
#   ./run.sh census spawn    only those sections
#
# Sections: census spawn bwrap tar libarchive lilipod podman interpose
#           lookpath arch sources arithmetic
#
# Requires: go, gcc, docker (running), network for image pulls. Sections that
# need a missing dependency print SKIP and continue.
set -uo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${OUT:-$HERE/build}"
RES="${RES:-$HERE/results}"
mkdir -p "$OUT" "$RES"

say() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

want() {
	[ "$#" -eq 0 ] && return 0
	for s in "${SECTIONS[@]}"; do [ "$s" = "$1" ] && return 0; done
	return 1
}
SECTIONS=("$@")
sel() { [ "${#SECTIONS[@]}" -eq 0 ] && return 0; want "$1"; }

# ---------------------------------------------------------------- build
say "building the harness"
have go || { echo "FATAL: go is required"; exit 1; }
(cd "$HERE/confine" && CGO_ENABLED=0 go build -o "$OUT/confine" .) || exit 1
(cd "$HERE/probe" && CGO_ENABLED=0 go build -o "$OUT/probe" .) || exit 1
if have gcc; then
	gcc -O2 -static -o "$OUT/cprobe" "$HERE/cprobe/cprobe.c" || exit 1
	gcc -O2 -shared -fPIC -o "$OUT/shim.so" "$HERE/interpose/shim.c" -ldl || exit 1
else
	echo "SKIP: gcc missing, C probe and interposer unavailable"
fi

# The models. USERNS maps only 0->0 and denies setgroups; SECCOMP denies
# unshare/setns/mount/umount2/pivot_root/ptrace and nothing else.
MODEL=(CONFINE_USERNS=1 CONFINE_EXTRA_GROUP=42 CONFINE_SECCOMP=1)
USERNS_ONLY=(CONFINE_USERNS=1 CONFINE_EXTRA_GROUP=42)
SECCOMP_ONLY=(CONFINE_SECCOMP=1 CONFINE_DENY_CLONE_NS=1 CONFINE_DENY_SETGROUPS=1
	CONFINE_DENY_MKNOD=1 CONFINE_DENY_CHOWN_NONZERO=1 CONFINE_DENY_SETUID_NONZERO=1)

# ---------------------------------------------------------------- census
if sel census; then
	say "runtime census: which mechanism produces which denial"
	{
		echo "## unconfined host root"
		"$OUT/probe" id
		"$OUT/probe" census
		echo
		echo "## user namespace only (map 0->0, setgroups=deny, holds gid 42)"
		mkdir -p /tmp/squash-probe && chown 1000:1000 /tmp/squash-probe 2>/dev/null
		env "${USERNS_ONLY[@]}" "$OUT/confine" "$OUT/probe" id
		env "${USERNS_ONLY[@]}" "$OUT/confine" "$OUT/probe" census
		echo
		echo "## seccomp only, with every verdict written into the filter"
		env "${SECCOMP_ONLY[@]}" "$OUT/confine" "$OUT/probe" census
		echo
		echo "## reconstructed model: userns + seccomp{unshare,setns,mount,umount2,pivot_root,ptrace}"
		env "${MODEL[@]}" "$OUT/confine" "$OUT/probe" id
		env "${MODEL[@]}" "$OUT/confine" "$OUT/probe" census
		if [ -x "$OUT/cprobe" ]; then
			echo
			echo "## single-threaded C probe (a Go process cannot probe unshare(CLONE_NEWUSER))"
			echo "# unconfined:"; "$OUT/cprobe"
			echo "# userns only:"; env "${USERNS_ONLY[@]}" "$OUT/confine" "$OUT/cprobe"
			echo "# model:"; env "${MODEL[@]}" "$OUT/confine" "$OUT/cprobe"
		fi
	} 2>&1 | tee "$RES/census.txt"
fi

# ---------------------------------------------------------------- spawn
if sel spawn; then
	say "Go os/exec credential matrix"
	{
		echo "## unconfined"; "$OUT/probe" spawn
		echo; echo "## userns only (setgroups denied by the namespace)"
		env "${USERNS_ONLY[@]}" "$OUT/confine" "$OUT/probe" spawn
		echo; echo "## seccomp denies setgroups"
		env CONFINE_SECCOMP=1 CONFINE_DENY_SETGROUPS=1 "$OUT/confine" "$OUT/probe" spawn
	} 2>&1 | tee "$RES/spawn.txt"
fi

# ---------------------------------------------------------------- bwrap
if sel bwrap; then
	say "bubblewrap differential: which denial yields which message"
	if have docker && docker info >/dev/null 2>&1; then
		docker run --rm --privileged --security-opt seccomp=unconfined \
			-v "$OUT:/s" debian:bookworm bash -c '
apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y bubblewrap >/dev/null 2>&1 || {
	echo "SKIP: no apt network"; exit 0; }
bwrap --version
echo "## unconfined"; bwrap --bind / / /bin/echo bwrap-ok
echo "## model (clone allowed, mount denied)"
CONFINE_USERNS=1 CONFINE_SECCOMP=1 /s/confine /usr/bin/bwrap --bind / / /bin/true
echo "## clone(CLONE_NEW*) additionally denied"
CONFINE_USERNS=1 CONFINE_SECCOMP=1 CONFINE_DENY_CLONE_NS=1 /s/confine /usr/bin/bwrap --bind / / /bin/true
echo "## userns only, no filter"
CONFINE_USERNS=1 /s/confine /usr/bin/bwrap --bind / / /bin/echo bwrap-ok
echo "## model, with runimages --unshare-user-try"
CONFINE_USERNS=1 CONFINE_SECCOMP=1 /s/confine /usr/bin/bwrap --unshare-user-try --bind / / /bin/true
' 2>&1 | tee "$RES/bwrap.txt"
	else
		echo "SKIP: docker not running" | tee "$RES/bwrap.txt"
	fi
fi

# ---------------------------------------------------------------- tar
if sel tar; then
	say "the ownership wall: GNU tar restoring gid 42"
	{
		rm -rf /tmp/tartest && mkdir -p /tmp/tartest/src/etc /tmp/tartest/o /tmp/tartest/o2
		echo secret > /tmp/tartest/src/etc/shadow
		tar --owner=0 --group=42 -cf /tmp/tartest/layer.tar -C /tmp/tartest/src etc
		tar --version | head -1
		echo "## userns only — no filter rule for chown anywhere"
		env "${USERNS_ONLY[@]}" "$OUT/confine" "$(command -v tar)" \
			-xf /tmp/tartest/layer.tar -C /tmp/tartest/o
		echo "rc=$?"
		echo "## same, with --no-same-owner"
		env "${USERNS_ONLY[@]}" "$OUT/confine" "$(command -v tar)" --no-same-owner \
			-xf /tmp/tartest/layer.tar -C /tmp/tartest/o2
		echo "rc=$?"
		echo "resulting ownership:"; ls -ln /tmp/tartest/o2/etc/
	} 2>&1 | tee "$RES/tar.txt"
fi

# ---------------------------------------------------------------- libarchive
if sel libarchive; then
	say "libarchive: what -20 in dwarfs' 'short write: -20 != N' actually is"
	if have docker && docker info >/dev/null 2>&1; then
		docker run --rm --privileged -v "$HERE:/v" debian:bookworm bash -c '
apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y gcc libarchive-dev >/dev/null 2>&1 || {
	echo "SKIP: no apt network"; exit 0; }
dpkg -l libarchive-dev | tail -1
gcc -O2 -o /tmp/sw /v/libarchive/short_write.c -larchive || exit 1
mkdir -p /small /big && mount -t tmpfs -o size=8M tmpfs /small
echo "## 32 MB into an 8 MB filesystem"; /tmp/sw /small 33554432
echo "## control: same write with room"; /tmp/sw /big 33554432
' 2>&1 | tee "$RES/libarchive.txt"
	else
		echo "SKIP: docker not running" | tee "$RES/libarchive.txt"
	fi
fi

# ---------------------------------------------------------------- lilipod
if sel lilipod; then
	say "lilipod @872755a: one wall or two?"
	if [ ! -x "$OUT/lilipod-stock" ]; then
		rm -rf "$OUT/lilipod-src"
		git clone -q --depth 1 https://github.com/89luca89/lilipod "$OUT/lilipod-src" && (
			cd "$OUT/lilipod-src"
			git fetch -q --depth 1 origin 872755a7cef33c238ea2d11b2310b3116944eb48 2>/dev/null &&
				git checkout -q FETCH_HEAD
			# go:embed needs a busybox blob and a built pty agent
			docker run --rm alpine:latest cat /bin/busybox > busybox && chmod +x busybox
			CGO_ENABLED=0 go build -mod vendor -o pty ptyagent/main.go ptyagent/pty.go
			tar czf pty.tar.gz pty
			CGO_ENABLED=0 go build -mod vendor -o "$OUT/lilipod-stock" main.go
		)
	fi
	if [ -x "$OUT/lilipod-stock" ]; then
		mkdir -p "$OUT/stubbin" "$OUT/lhome"
		# lilipod hard-requires these three on PATH even as root, even for pull
		for b in getsubids newuidmap newgidmap; do
			printf '#!/bin/sh\nexit 0\n' > "$OUT/stubbin/$b"
			chmod +x "$OUT/stubbin/$b"
		done
		export PATH="$OUT/stubbin:$PATH" LILIPOD_HOME="$OUT/lhome"
		{
			(cd "$OUT/lilipod-src" && git log -1 --format='commit %H')
			echo "## pull, unconfined"
			"$OUT/lilipod-stock" pull alpine:latest 2>&1 | tr '\r' '\n' | tail -1
			for c in "model:${MODEL[*]}" \
				"model+clone denied:${MODEL[*]} CONFINE_DENY_CLONE_NS=1" \
				"userns only, no filter:${USERNS_ONLY[*]}" \
				"model, ROOTFUL=true:${MODEL[*]} ROOTFUL=true"; do
				echo "## ${c%%:*}"
				# shellcheck disable=SC2086
				env ${c#*:} "$OUT/confine" "$OUT/lilipod-stock" --log-level debug \
					run --rm alpine:latest /bin/echo hi 2>&1 |
					grep -aE 'proc_utils.go:(24|74|79)|error:' | head -3
			done
			echo "## first wall bypassed (UNSHARED=true): the next wall"
			env "${MODEL[@]}" ROOTFUL=true UNSHARED=true "$OUT/confine" "$OUT/lilipod-stock" \
				run --rm --userns host alpine:latest /bin/echo hi 2>&1 |
				tr '\r' '\n' | grep -aE 'tar:|exit status' | head -3
		} 2>&1 | tee "$RES/lilipod.txt"
	else
		echo "SKIP: could not build lilipod" | tee "$RES/lilipod.txt"
	fi
fi

# ---------------------------------------------------------------- podman
if sel podman; then
	say "podman: how far does it get, and what actually stops it"
	if have docker && docker info >/dev/null 2>&1; then
		docker save alpine:latest -o "$OUT/alpine.tar" 2>/dev/null
		docker run --rm --privileged --security-opt seccomp=unconfined \
			-v "$OUT:/s" debian:bookworm bash -c '
apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y podman >/dev/null 2>&1 || {
	echo "SKIP: no apt network"; exit 0; }
podman --version
M="CONFINE_USERNS=1 CONFINE_SECCOMP=1"
echo "## can any process become non-root?"
env $M /s/confine /usr/bin/setpriv --reuid=1000 --regid=1000 --clear-groups /bin/true
echo "## info, default (overlay) storage driver"
env $M /s/confine /usr/bin/podman info 2>&1 | tail -2
echo "## info, --storage-driver vfs and redirected paths"
mkdir -p /w/store /w/run /w/tmp
env $M TMPDIR=/w/tmp /s/confine /usr/bin/podman --root /w/store --runroot /w/run \
	--storage-driver vfs info --format "OCIRuntime={{.Host.OCIRuntime.Name}} driver={{.Store.GraphDriverName}}" 2>&1 | tail -2
echo "## load a local image: peel the denials back one at a time"
i=0
for extra in "" "CONFINE_ALLOW_UNSHARE=1" "CONFINE_ALLOW_UNSHARE=1 CONFINE_ALLOW_MOUNT=1" ; do
	i=$((i+1)); mkdir -p /w$i/store /w$i/run /w$i/tmp
	echo "   [$M $extra]"
	env $M $extra TMPDIR=/w$i/tmp /s/confine /usr/bin/podman --root /w$i/store \
		--runroot /w$i/run --storage-driver vfs load -q -i /s/alpine.tar 2>&1 |
		grep -aoE "creating mount namespace before pivot[^\"]*|remount /[^\"]*|lchown [^\"]*|Loaded.*" | head -1
done
echo "   [userns only, no filter]"
mkdir -p /w9/store /w9/run /w9/tmp
env CONFINE_USERNS=1 TMPDIR=/w9/tmp /s/confine /usr/bin/podman --root /w9/store \
	--runroot /w9/run --storage-driver vfs load -q -i /s/alpine.tar 2>&1 |
	grep -aoE "lchown [^\"]*|Loaded.*" | head -1
' 2>&1 | tee "$RES/podman.txt"
	else
		echo "SKIP: docker not running" | tee "$RES/podman.txt"
	fi
fi

# ---------------------------------------------------------------- interpose
if sel interpose && [ -f "$OUT/shim.so" ]; then
	say "LD_PRELOAD reach: C vs Go"
	{
		cat > "$OUT/cchown.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
int main(void){int rc=lchown("/tmp/shimtarget",0,42);
printf("c lchown() rc=%d %s\n",rc,rc?strerror(errno):"");return 0;}
EOF
		mkdir -p "$OUT/gochown"
		cat > "$OUT/gochown/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
)

func main() { fmt.Println("go os.Lchown ->", os.Lchown("/tmp/shimtarget", 0, 42)) }
EOF
		printf 'module gochown\n\ngo 1.21\n' > "$OUT/gochown/go.mod"
		gcc -O2 -o "$OUT/cchown" "$OUT/cchown.c"
		(cd "$OUT/gochown" && CGO_ENABLED=0 go build -o "$OUT/gochown-nocgo" .)
		(cd "$OUT/gochown" && CGO_ENABLED=1 go build -o "$OUT/gochown-cgo" . 2>/dev/null) ||
			cp "$OUT/gochown-nocgo" "$OUT/gochown-cgo"
		for p in cchown gochown-nocgo gochown-cgo; do
			: > /tmp/shimtarget
			echo "## $p under the shim"
			LD_PRELOAD="$OUT/shim.so" "$OUT/$p"
		done
		: > /tmp/shimtarget
		echo "## go lchown(0,42) under the reconstructed runtime"
		env "${MODEL[@]}" "$OUT/confine" "$OUT/gochown-nocgo"
	} 2>&1 | tee "$RES/interpose.txt"
fi

# ---------------------------------------------------------------- lookpath
if sel lookpath; then
	say "Go path resolution across a chroot"
	{
		mkdir -p "$OUT/lookprobe" /tmp/emptyroot
		cat > "$OUT/lookprobe/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func main() {
	before := exec.Command("/bin/sh", "-c", "exit 0")
	fmt.Println("A. Command(\"/bin/sh\") built BEFORE chroot, Err =", before.Err)
	if err := syscall.Chroot(os.Args[1]); err != nil {
		fmt.Println("chroot:", err)
		os.Exit(1)
	}
	syscall.Chdir("/")
	_, err := exec.LookPath("/bin/sh")
	fmt.Println("B. LookPath(\"/bin/sh\") AFTER chroot        =", err)
	after := exec.Command("/bin/sh", "-c", "exit 0")
	fmt.Println("C. Command built AFTER chroot, Run          =", after.Run())
	_, err = exec.LookPath("sh")
	fmt.Println("D. LookPath(\"sh\") AFTER chroot             =", err)
}
EOF
		printf 'module lookprobe\n\ngo 1.21\n' > "$OUT/lookprobe/go.mod"
		(cd "$OUT/lookprobe" && CGO_ENABLED=0 go build -o "$OUT/lookprobe-bin" .)
		rm -rf "$OUT/minroot" && mkdir -p "$OUT/minroot"
		cid=$(docker create --rm alpine:latest 2>/dev/null) &&
			docker export "$cid" 2>/dev/null | tar -x -C "$OUT/minroot" &&
			docker rm -f "$cid" >/dev/null 2>&1
		echo "## chroot into an image rootfs whose /dev is empty"
		"$OUT/lookprobe-bin" "$OUT/minroot"
		echo "## chroot into a root that has no /bin/sh (the wrong-root case)"
		"$OUT/lookprobe-bin" /tmp/emptyroot
		echo "## chroot execution under the reconstructed model"
		env "${MODEL[@]}" "$OUT/confine" "$(command -v chroot)" "$OUT/minroot" \
			/bin/sh -c 'head -2 /etc/os-release; id; apk --version'
	} 2>&1 | tee "$RES/lookpath.txt"
fi

# ---------------------------------------------------------------- arch
if sel arch; then
	say "a distribution rootfs entered by chroot: what works and what it costs"
	if have docker && docker info >/dev/null 2>&1; then
		{
			R="$OUT/archroot"
			rm -rf "$R" && mkdir -p "$R"
			docker pull -q archlinux:latest >/dev/null 2>&1
			cid=$(docker create --rm archlinux:latest) &&
				docker export "$cid" | tar -x -C "$R" 2>/dev/null
			docker rm -f "$cid" >/dev/null 2>&1
			cp /etc/resolv.conf "$R/etc/resolv.conf"
			CH=$(command -v chroot)
			run_in() { env "${MODEL[@]}" "$OUT/confine" "$CH" "$R" "$@"; }

			echo "## symlinks in the shipped rootfs"
			printf 'total=%s absolute=%s\n' \
				"$(find "$R" -type l | wc -l)" \
				"$(find "$R" -type l -lname '/*' | wc -l)"
			ls -l "$R/etc/mtab"

			echo "## A. plain chroot, no /proc, mtab left as the shipped dangling symlink"
			run_in /bin/bash -c 'head -2 /etc/os-release; id; echo "packages: $(pacman -Q | wc -l)"' 2>&1 | grep -av '^warning:'

			echo "## B. pacman -Sy with the rootfs as shipped"
			run_in /usr/bin/pacman -Sy --noconfirm 2>&1 | tail -3

			echo "## C. same after disabling DownloadUser (an unmapped uid)"
			sed -i 's/^DownloadUser/#DownloadUser/' "$R/etc/pacman.conf"
			run_in /usr/bin/pacman -Sy --noconfirm 2>&1 | tail -3

			echo "## D. install with signatures enforced, before the keyring exists"
			grep -m1 '^SigLevel' "$R/etc/pacman.conf"
			run_in /usr/bin/pacman -S --noconfirm --needed tree 2>&1 | grep -aiE 'gpgme|signature|installing' | head -3

			echo "## E. after pacman-key --init && --populate"
			run_in /usr/bin/pacman-key --init >/dev/null 2>&1
			run_in /usr/bin/pacman-key --populate archlinux >/dev/null 2>&1
			run_in /usr/bin/pacman -S --noconfirm --needed tree 2>&1 | grep -aiE 'keyring|integrity|installing' | head -3
			run_in /usr/bin/tree --version 2>&1 | head -1

			echo "## F. does pacman need /etc/mtab? CheckSpace is commented out by default"
			grep -m1 'CheckSpace' "$R/etc/pacman.conf"
			rm -f "$R/etc/mtab"
			run_in /usr/bin/pacman -S --noconfirm --needed which 2>&1 | grep -aiE 'installing|error' | head -2
			echo "## G. with CheckSpace enabled and no /etc/mtab"
			sed -i 's/^#CheckSpace/CheckSpace/' "$R/etc/pacman.conf"
			run_in /usr/bin/pacman -S --noconfirm --needed bc 2>&1 | grep -aiE 'mount points|mtab|installing' | head -3
			echo "## H. with CheckSpace enabled and a static /etc/mtab"
			printf 'none / none rw 0 0\n' > "$R/etc/mtab"
			run_in /usr/bin/pacman -S --noconfirm --needed bc 2>&1 | grep -aiE 'disk space|installing' | head -2
			run_in /bin/bash -c 'echo "packages now: $(pacman -Q | wc -l)"' 2>&1 | tail -1
		} 2>&1 | tee "$RES/arch.txt"
	else
		echo "SKIP: docker not running" | tee "$RES/arch.txt"
	fi
fi

# ---------------------------------------------------------------- sources
if sel sources; then
	say "source claims"
	{
		G=$(go env GOROOT)
		echo "## go: the setgroups guard"
		grep -n "_SYS_setgroups" -B 1 "$G/src/syscall/exec_linux.go" | head -4
		echo "## go: LookPath ignores PATH for a name containing a slash"
		sed -n '61,67p' "$G/src/os/exec/lp_unix.go"
		for r in "containers/bubblewrap:bubblewrap.c:clone_flags = SIGCHLD|Creating new namespace failed|Failed to make / slave" \
			"qaidvoid/onelf::symlink_target_within_root" \
			"89luca89/lilipod::ROOTFUL" ; do
			repo=${r%%:*}; rest=${r#*:}; file=${rest%%:*}; pat=${rest#*:}
			d="$OUT/src-$(basename "$repo")"
			[ -d "$d" ] || git clone -q --depth 1 "https://github.com/$repo" "$d" 2>/dev/null
			echo "## $repo"
			if [ -n "$file" ]; then grep -nE "$pat" "$d/$file" | head -6
			else grep -rnE "$pat" --include='*.rs' --include='*.go' "$d" | head -6; fi
		done
	} 2>&1 | tee "$RES/sources.txt"
fi

# ---------------------------------------------------------------- arithmetic
if sel arithmetic; then
	say "arithmetic"
	python3 - <<'EOF' 2>&1 | tee "$RES/arithmetic.txt"
b = 225641729
print(f"{b} bytes = {b/1048576:.10f} MiB = {b/1e6:.6f} MB")
print(f"onelf's displayed 215.2 matches MiB ({b/1048576:.2f}), not MB ({b/1e6:.2f})")
print(f"payload 213.6 + runtime ~1.6 = {213.6+1.6:.1f}; 603.7/215.2 = {603.7/215.2:.3f}")
print(f"full capability mask 0x1ffffffffff has {bin(0x1ffffffffff).count('1')} bits set (0..40)")
print(f"a 298 MB payload into a 64 MiB /tmp overshoots by {298e6/(64*1048576):.1f}x")
EOF
fi

say "results written to $RES"
