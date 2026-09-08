#!/usr/bin/env bash
# Question: in the reconstruction, which mechanism produces which denial — and
# does the answer match what paper_final.md §3.3, §3.7 and §3.7a say it is?
#
# Runs the census and the discriminating probes inside the reconstruction and
# checks each row against a written-down expectation. An expectation that
# cannot be tested on this host (every M row, where the kernel has no Landlock)
# is reported SKIP and makes the script exit 2 — never a silent pass.
#
#   ./30-attribution-census.sh              run and assert
#   ./30-attribution-census.sh --capture D  also write raw output under D
#
# Exit: 0 every testable expectation met, 1 a mismatch, 2 could not run.
set -uo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CAPTURE=""
[ "${1:-}" = "--capture" ] && { CAPTURE="${2:?--capture needs a directory}"; mkdir -p "$CAPTURE"; }

run_in() { "$HERE/20-enter-target.sh" -- "$@" 2>/dev/null; }

echo "== conditions"
printf 'date              %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'host kernel       %s\n' "$(uname -r)"
printf 'landlock on host  %s\n' \
	"$(grep -q '^CONFIG_SECURITY_LANDLOCK=y' /boot/config-"$(uname -r)" 2>/dev/null && echo yes || \
	   { zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_SECURITY_LANDLOCK=y' && echo yes || echo no; })"
echo

CENSUS=$(run_in /workspace/.harness/probe census)
ATTR=$(run_in /workspace/.harness/probe attribute)
IDENT=$(run_in /workspace/.harness/probe id)
if [ -n "$CAPTURE" ]; then
	printf '%s\n' "$IDENT"  > "$CAPTURE/identity.txt"
	printf '%s\n' "$CENSUS" > "$CAPTURE/census.txt"
	printf '%s\n' "$ATTR"   > "$CAPTURE/attribute.txt"
fi
[ -n "$CENSUS" ] || { echo "SKIP: the reconstruction produced no census" >&2; exit 2; }

pass=0 fail=0 skip=0

# expect <haystack-name> <row prefix> <expected verdict> [why]
expect() {
	local hay="$1" row="$2" want="$3" why="${4:-}"
	local line
	line=$(printf '%s\n' "${!hay}" | grep -F -m1 -- "$row")
	if [ -z "$line" ]; then
		printf '  SKIP  %-38s (row not produced)\n' "$row"; skip=$((skip + 1)); return
	fi
	local got=${line#"$row"}
	got=$(printf '%s' "$got" | sed 's/^ *//')
	if [ "$got" = "$want" ]; then
		printf '  ok    %-38s %s\n' "$row" "$got"; pass=$((pass + 1))
	else
		printf '  FAIL  %-38s got %-22s want %s %s\n' "$row" "$got" "$want" "$why"
		fail=$((fail + 1))
	fi
}

echo "== identity (paper §3.1; target capture verification/real/identity.txt)"
for want in 'uid=0 gid=0 groups=[0 65534]' \
            'CapEff:	000001ffffffffff' \
            '/proc/self/uid_map: 0       1000          1' \
            '/proc/self/setgroups: deny'; do
	if printf '%s\n' "$IDENT" | grep -qF -- "$want"; then
		printf '  ok    %s\n' "$want"; pass=$((pass + 1))
	else
		printf '  FAIL  missing: %s\n' "$want"; fail=$((fail + 1))
	fi
done

echo
echo "== census (paper §3.3 N+F column; target capture verification/real/probe-census.txt)"
expect CENSUS 'unshare(CLONE_NEWNS)'              'FAIL errno=1 EPERM'  '(F)'
expect CENSUS 'unshare(CLONE_NEWUSER)'            'FAIL errno=1 EPERM'  '(F)'
expect CENSUS 'clone(CLONE_NEWNS)'                'OK'                  '(F2: not denied)'
expect CENSUS 'clone(CLONE_NEWUTS|NEWNS)'         'OK'                  '(F2)'
expect CENSUS 'clone(CLONE_NEWUSER)'              'OK'                  '(F2)'
expect CENSUS 'mount(tmpfs,/mnt)'                 'FAIL errno=1 EPERM'  '(F)'
expect CENSUS 'mount(MS_SLAVE,/) in clone(NEWNS)' 'FAIL exit status 1'  '(issue #1: the verdict, not the exit code)'
expect CENSUS 'pivot_root(/tmp,/tmp)'             'FAIL errno=1 EPERM'  '(F)'
expect CENSUS 'ptrace(PTRACE_TRACEME)'            'FAIL errno=1 EPERM'  '(F)'
expect CENSUS 'mknod(chr 1:3 /tmp/nodprobe)'      'FAIL errno=1 EPERM'  '(N: CAP_MKNOD is checked in the initial userns)'
expect CENSUS 'mknod(chr 0:0 = whiteout)'         'OK'                  '(F11: a whiteout tests nothing)'
expect CENSUS 'setuid(1000)'                      'FAIL errno=22 EINVAL' '(N: unmapped id)'
expect CENSUS 'setuid(0)'                         'OK'
expect CENSUS 'setgroups(0,NULL)'                 'FAIL errno=1 EPERM'  '(N: setgroups=deny)'
expect CENSUS 'chown(f,0,0)'                      'OK'
expect CENSUS 'chown(f,0,42)'                     'FAIL errno=22 EINVAL' '(F3: the ownership wall)'
expect CENSUS 'lchown(f,0,42)'                    'FAIL errno=22 EINVAL' '(F3)'
expect CENSUS 'chroot(/tmp)'                      'OK'
expect CENSUS 'memfd_create+exec'                 'OK'
expect CENSUS 'write(/etc/probe)'                 'FAIL errno=13 EACCES' '(N: /etc is owned by an unmapped id)'

echo
echo "== attribution (paper §3.7a; target capture verification/real/extkernel-newapi.txt)"
expect ATTR 'mount(2) bogus target'               'FAIL errno=1 EPERM'  '(EPERM for a bogus path = pre-execution = F)'
expect ATTR 'umount2(2) bogus target'             'FAIL errno=1 EPERM'  '(F)'
expect ATTR 'pivot_root(2) bogus paths'           'FAIL errno=1 EPERM'  '(F)'
expect ATTR 'process_vm_readv(bogus pid)'         'FAIL errno=1 EPERM'  '(F14: the kernel would answer ESRCH)'
expect ATTR 'pidfd_getfd(-1,-1) [control]'        'FAIL errno=9 EBADF'  '(control: executed, not filtered)'
expect ATTR 'fsopen(tmpfs)'                       'OK'                  '(F13: may_mount() passes)'
expect ATTR 'fsmount(tmpfs)'                      'OK'                  '(F13)'
expect ATTR 'move_mount(-> bogus dest)'           'FAIL errno=2 ENOENT' '(F13: move_mount executes; the filter does not name it)'
expect ATTR 'seccomp(NEW_LISTENER)'               'OK'                  '(F14: the supervisor tier is installable)'
expect ATTR 'open /proc/self/mem O_RDONLY'        'OK'                  '(F14: argument reads have a channel)'

echo
echo "== mechanism M (paper §3.3 correction, §3.7 fact 3)"
if printf '%s\n' "$ATTR" | grep -qF 'landlock_create_ruleset(VERSION)   OK'; then
	expect ATTR 'move_mount(-> /tmp/mm-probe)'      'FAIL errno=1 EPERM'  '(M: security_move_mount)'
	expect ATTR 'openat(detached tmpfs, O_DIRECTORY)' 'FAIL errno=13 EACCES' '(M: an LSM cannot resolve a detached mount)'
	expect ATTR 'open /proc/self/mem O_RDWR'        'FAIL errno=13 EACCES' '(M: the write allowlist, at file-open granularity)'
else
	echo "  SKIP  every M row: this kernel has no Landlock, so the write-scoped"
	echo "        mechanism cannot be applied here. The M attributions stay [S]"
	echo "        (kernel source, security/landlock/fs.c) + [T] (target capture),"
	echo "        never [V] on this host. Re-run on a distro kernel to close it."
	skip=$((skip + 3))
fi

echo
printf '== %d ok, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ -n "$CAPTURE" ] && echo "raw output under $CAPTURE"
[ "$fail" -gt 0 ] && exit 1
[ "$skip" -gt 0 ] && exit 2
exit 0
